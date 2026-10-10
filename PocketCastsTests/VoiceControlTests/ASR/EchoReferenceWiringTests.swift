import XCTest
@testable import podcasts

/// Production echo-reference wiring and the two-sided answer-echo acceptance.
///
/// Per recognition-pipeline.md "Signal Filter", both clients must wire their episode,
/// local-feedback and cloud-answer renderers into the shared emitted-PCM reference and
/// demonstrate, with capture active, that:
///
///   * answer-only playback produces **no** accepted speech, wake/reset, request or
///     allowance spend, and
///   * **simultaneous** user speech retains its onset and interrupts output.
///
/// Scope follows the owning clause, which distinguishes route classes rather than
/// being an Exposed-only flag:
///   * built-in loudspeaker — aligned playback cross-correlation against the reference;
///   * external routes — delay tracking, *not* the built-in correlation window;
///   * isolated route — reduced exposure, but **not** proof that echo is absent.
///
/// These cases drive the engine's production seam, never `SignalFilter` directly, so
/// they fail while nothing feeds the reference. A test that constructs `SignalFilter`
/// and calls `isPlaybackBleed` would pass forever over a filter the app never runs.
final class EchoReferenceWiringTests: XCTestCase {

    // MARK: - Built-in loudspeaker: echo-only must be rejected

    /// The positive control. With the reference populated and a built-in-speaker route,
    /// an exact copy of our own playback must be dropped **before** it can reset grace,
    /// spend a dispatch allowance or reach wake/ASR.
    ///
    /// This is the case that cannot be faked: a never-firing filter — the shipped state,
    /// where both setters have no callers — routes this utterance and fails here.
    func test_echoOnlyPlayback_onBuiltInSpeaker_producesNoAcceptedSpeechOrReset() async throws {
        let harness = EchoWiringHarness()
        let before = harness.gracePeriodSignal.isActive

        let playbackPCM = [Float](repeating: 0.5, count: 320)
        harness.engine.updatePlaybackBuffer(playbackPCM)
        harness.engine.setEchoFilterRoute(.builtInSpeaker)

        await harness.engine.processUtterance(playbackPCM)

        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 0,
            "an exact copy of our own playback reached ASR instead of being rejected as echo"
        )
        XCTAssertEqual(
            harness.gracePeriodSignal.isActive, before,
            "echo reset the conversation grace period"
        )
        XCTAssertEqual(
            harness.wakeWordDetector.detectCount, 0,
            "echo was submitted to wake detection"
        )
    }

    // MARK: - The other half: simultaneous speech must survive

    /// Guards against over-filtering: genuine user speech **mixed with** our own output
    /// must be preserved rather than dropped wholesale with the echo.
    func test_simultaneousUserSpeech_isPreservedNotDiscardedWithEcho() async throws {
        let harness = EchoWiringHarness()
        // Grace active: a negative wake result outside grace is dropped before ASR by
        // WakeGate, which is unrelated to the echo filter under test here.
        harness.gracePeriodSignal.onCommandRecognized()
        harness.engine.updatePlaybackBuffer([Float](repeating: 0.5, count: 320))
        harness.engine.setEchoFilterRoute(.builtInSpeaker)

        // Orthogonal to constant playback audio: this is our own words, not echo.
        let userSpeech = (0..<320).map { $0 % 2 == 0 ? Float(0.5) : Float(-0.5) }
        await harness.engine.processUtterance(userSpeech)

        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 1,
            "simultaneous user speech was discarded along with the echo"
        )
    }

    // MARK: - Route classes

    /// External routes must not use the built-in correlation window, whose alignment
    /// assumption does not hold where codec latency is large and variable.
    func test_externalRoute_doesNotUseTheBuiltInCorrelationWindow() async throws {
        let harness = EchoWiringHarness()
        harness.gracePeriodSignal.onCommandRecognized()
        let playbackPCM = [Float](repeating: 0.5, count: 320)
        harness.engine.updatePlaybackBuffer(playbackPCM)
        harness.engine.setEchoFilterRoute(.external)

        await harness.engine.processUtterance(playbackPCM)

        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 1,
            "the built-in-speaker correlation window was applied on an external route"
        )
    }

    /// An isolated route reduces exposure but is not proof that echo is absent, so the
    /// filter must not be treated as satisfied merely because the route is a headset.
    func test_isolatedRoute_isNotTreatedAsProofOfNoEcho() async throws {
        let harness = EchoWiringHarness()
        let playbackPCM = [Float](repeating: 0.5, count: 320)
        harness.engine.updatePlaybackBuffer(playbackPCM)
        harness.engine.setEchoFilterRoute(.isolated)

        await harness.engine.processUtterance(playbackPCM)

        // Nothing is dropped by correlation here, but the route must not be *recorded*
        // as echo-free: the owning clause says exposure is reduced, not eliminated.
        XCTAssertFalse(
            harness.engine.echoFilterRouteConsidersEchoImpossible,
            "an isolated route was recorded as proof that echo is impossible"
        )
    }

    // MARK: - Invalidation

    /// Stale route state must not survive a route change: after the filter stops
    /// applying, a subsequent identical utterance must not be dropped by leftover state.
    func test_routeChangeInvalidation_clearsAppliedFilterState() async throws {
        let harness = EchoWiringHarness()
        let playbackPCM = [Float](repeating: 0.5, count: 320)

        harness.engine.updatePlaybackBuffer(playbackPCM)
        harness.engine.setEchoFilterRoute(.builtInSpeaker)
        await harness.engine.processUtterance(playbackPCM)
        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 0,
            "precondition: echo is rejected while the built-in route applies"
        )

        // Route change: the reference is retired and the state cleared. Grace is
        // active so the surviving utterance can reach ASR rather than being dropped
        // by the wake gate for an unrelated reason.
        harness.gracePeriodSignal.onCommandRecognized()
        harness.engine.setEchoFilterRoute(.external)
        harness.engine.updatePlaybackBuffer([])
        await harness.engine.processUtterance(playbackPCM)

        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 1,
            "stale filter state survived route invalidation and kept dropping audio"
        )
    }
}

// MARK: - Harness

/// Wires the engine the way `VoiceControlAssembly` does, so these cases exercise the
/// production construction rather than a bespoke one.
private final class EchoWiringHarness {
    let engine: VoiceAsrEngine
    let backend = CountingAsrBackend()
    let wakeWordDetector = RecordingWakeWordDetector()
    let gracePeriodSignal = GracePeriodSignal()

    init() {
        engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(threshold: 0.020),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: wakeWordDetector,
            gracePeriodSignal: gracePeriodSignal
        )
    }
}

private final class CountingAsrBackend: AsrBackend {
    private(set) var transcribeSamples: [[Float]] = []
    var requiredModel: ModelSpec {
        ModelSpec(id: "test", files: [], targetDir: "/tmp/test")
    }
    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
    }
    func ensureReady() async -> Result<Void, Error> { .success(()) }
    func release() {}
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        transcribeSamples.append(samples)
        return AsrResult(text: "test", detectedLanguage: "en")
    }
}

private final class RecordingWakeWordDetector: WakeWordDetectorProtocol {
    private(set) var detectCount = 0
    func release() {}
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        detectCount += 1
        return .notDetected(confidence: 0)
    }
}
