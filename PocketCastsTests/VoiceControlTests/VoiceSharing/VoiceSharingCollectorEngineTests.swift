import XCTest
@testable import podcasts

/// Drives the REAL `VoiceAsrEngine` → `NativeVadSegmenter` subscription rather than a hand-built segmenter,
/// because the reviewer's condition for production collection was that final proof goes through the production
/// engine path. Everything here is constructed the way `VoiceControlService` constructs it; only the backend,
/// wake detector and audio source are stubs so the test is deterministic without model files.
final class VoiceSharingCollectorEngineTests: XCTestCase {

    private var recordLock = NSLock()
    private var events: [VoiceSharingCollector.SegmentEvent] = []
    private var storeState = VoiceSharingEnrollmentStore.State()
    private var epoch: String? = "epoch-1"
    private var utteranceUnderTest: [Float] = []

    override func setUp() {
        super.setUp()
        events = []
        storeState = VoiceSharingEnrollmentStore.State()
        epoch = "epoch-1"
    }

    private func openGate(enrolled: Bool) -> VoiceSharingPolicy {
        let policy = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { [weak self] in self?.storeState.effectiveEnrolled ?? false }
        )
        storeState.localOptIn = enrolled
        storeState.hasAuthoritativeProjection = enrolled
        if !enrolled { storeState.membership = .unavailable }
        if enrolled {
            storeState.membership = VoiceSharingMembership(
                membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09", withdrawalState: .active
            )
        }
        policy.identityBecameReadable()
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true,
                                                      fetchToken: policy.tokenForFetchStart()),
                        "premise: activation should install a lease")
        return policy
    }

    private func makeCollector(_ policy: VoiceSharingPolicy) -> VoiceSharingCollector {
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { "gen-A" },
            sink: { [weak self] e in self?.record(e) }
        )
        collector.deliversSynchronouslyForTesting = true
        return collector
    }

    /// Engine wired exactly as the service wires it, minus models and the real microphone. The segmenter gets
    /// a short silence timeout because its timeout is measured with `Date()` — production defaults to 500 ms,
    /// and waiting that long per emitted utterance would make the suite slow for no added coverage.
    private func makeEngine(collector: VoiceSharingCollector,
                            wake: WakeWordDetectorProtocol,
                            backend: EngineStubBackend,
                            silenceTimeoutMs: Int = 60) -> VoiceAsrEngine {
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(silenceTimeoutMs: silenceTimeoutMs),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: wake,
            gracePeriodSignal: GracePeriodSignal(),
            translationStage: nil
        )
        engine.contributionCollector = collector
        backend.engine = engine
        return engine
    }

    // MARK: - Production path: start/stop own the subscription

    /// `start()` must attach the three observation hooks to the segmenter the pipeline already drives, and
    /// `stop()` must release any partial it holds. Asserted through the engine's public lifecycle rather than
    /// by poking at the segmenter, which is private.
    func test_engineStartAttachesHooksAndStopReleasesThePartial() {
        let policy = openGate(enrolled: true)
        XCTAssertTrue(policy.permitsCollection, "premise: gate open")
        XCTAssertTrue(storeState.effectiveEnrolled, "premise: membership enrolled")

        let collector = makeCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)

        // Drive frames through the segmenter the same way `capture.onSamples` does in production: the engine
        // installs that closure inside start(), so we invoke whatever it installed.
        XCTAssertTrue(engine.start(), "premise: the engine should start with a stubbed capture")
        backend.emitSpeech(level: 0.6, totalSamples: 5 * 160)

        var kinds = recordedKinds()
        XCTAssertTrue(kinds.contains(.started),
                      "the engine's onSpeechStarted hook must reach the collector; got \(kinds)")
        XCTAssertEqual(collector.currentCaptureIDForTesting != nil, true,
                       "and the collector should hold an open capture while speech continues")

        // Closing listening releases it — through stop(), not a manual cancel.
        engine.stop()
        kinds = recordedKinds()
        XCTAssertEqual(kinds.last, .cancelled, "engine.stop() must cancel the open capture")
        XCTAssertNil(collector.currentCaptureIDForTesting, "and leave nothing dangling across a restart")
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0, "released means the buffer is actually gone")
    }

    /// An idle stop (no speech was ever open) must NOT be reported as a discarded example.
    func test_idleStop_producesNoCancellationEvent() {
        let policy = openGate(enrolled: true)
        let collector = makeCollector(policy)
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: EngineStubBackend())
        XCTAssertTrue(engine.start())

        engine.stop()
        XCTAssertEqual(recordedKinds(), [], "stopping an idle pipeline is not a rejected utterance")
    }

    // MARK: - Rejection branches observed inside the engine

    /// Wake-negative segments are collectable per spec, and observing them must add NO ASR/router/action work.
    /// The proof: recognition still returns at the wake branch, so no transcript reaches the router.
    func test_wakeNegativeBranch_isObserved_andRecognitionPathIsUnchanged() async {
        let policy = openGate(enrolled: true)
        let collector = makeCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)

        var routed: [String] = []
        engine.onRoutingInput = { routed.append($0.routerTranscript) }
        XCTAssertTrue(engine.start())

        // Real pipeline: speech, then silence long enough for the segmenter to emit an utterance, which the
        // engine routes into its own wake branch. Nothing here calls processUtterance by hand.
        await backend.emitSpeechThenSilence(level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let kinds = recordedKinds()
        XCTAssertTrue(kinds.contains(.rejectedWake),
                      "wake-negative must be observed as its own decision; got \(kinds)")
        XCTAssertFalse(kinds.contains(.completed), "a wake-rejected segment must never look like a completed one")
        XCTAssertEqual(routed, [], "control: recognizing the rejection added no routing work")
        XCTAssertEqual(backend.transcribeCalls, 0, "and no extra ASR either")
        engine.stop()
    }

    /// Bleed rejection is the other collectable branch. It requires an exposed-speaker route, which the engine
    /// reads from `isExposedSpeakerRoute`; the stub backend sets up the call so the branch is reachable.
    func test_bleedBranch_notifiesWithObservedDecision_whenRouteIsExposed() async {
        let policy = openGate(enrolled: true)
        let collector = makeCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        XCTAssertTrue(engine.start())
        engine.isExposedSpeakerRouteForTesting = true
        // The filter correlates mic against playback and requires a peak at a NON-ZERO lag — identical arrays
        // peak at delay 0, which it treats as "no evidence of echo". So build the mic frame as the playback
        // tail shifted by 8 samples, which is what speaker bleed actually looks like.
        let playback = stride(from: Float(-0.6), through: 0.6, by: 0.001).map { $0 }
        engine.playbackBufferForTesting = playback
        utteranceUnderTest = Array(repeating: 0, count: 8) + playback

        // Open a capture first so the rejection has a frozen identity to attach its decision to.
        backend.emitSpeech(level: 0.6, totalSamples: 5 * 160)
        await engine.processUtterance(utteranceUnderTest)

        let kinds = recordedKinds()
        XCTAssertTrue(kinds.contains(.rejectedBleed),
                      "bleed-rejected audio stays collectable and keeps its observed label; got \(kinds)")
        XCTAssertFalse(kinds.contains(.completed))
        XCTAssertEqual(backend.transcribeCalls, 0, "bleed drop still performs no ASR")
        engine.stop()
    }

    /// With the gate closed, the production path must retain nothing at all — including across a full
    /// utterance that runs through both rejection branches.
    func test_closedGate_producesZeroContributionThroughTheRealEngine() async {
        let policy = openGate(enrolled: false)
        XCTAssertFalse(policy.permitsCollection || storeState.effectiveEnrolled,
                       "premise: membership is unknown/off, so the gate is closed")

        let collector = makeCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        XCTAssertTrue(engine.start())

        backend.emitSpeech(level: 0.6, totalSamples: 5 * 160)
        await engine.processUtterance([Float](repeating: 0.6, count: 40 * 16))
        engine.stop()

        XCTAssertEqual(recordedKinds(), [], "no contribution work may be produced while the gate is closed")
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0, "and no PCM may be held for it")
    }

    /// Handoff must not run contribution work on the audio thread. A sink that blocks is exactly what a slow
    /// uploader or a stalled queue looks like in production, so this control drives the collector from a
    /// dedicated thread and asserts delivery happened SOMEWHERE ELSE. Without it, an implementation that calls
    /// the sink inline would pass every timing-based check while freezing capture callbacks whenever the
    /// consumer stalls.
    func test_sinkRunsOnADifferentThreadThanTheProducer() {
        let policy = openGate(enrolled: true)
        var deliveredOnMainThread = [Bool]()
        var deliveredFromAudioQueue = [Bool]()
        let lock = NSLock()
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { "gen-A" },
            sink: { _ in
                let rec = Thread.isMainThread
                // Identify the producer thread by a thread dictionary marker set below.
                let fromProducer = (Thread.current.threadDictionary["producer-marker"] as? Bool) == true
                lock.lock(); deliveredOnMainThread.append(rec); deliveredFromAudioQueue.append(fromProducer); lock.unlock()
            }
        )

        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.current.threadDictionary["producer-marker"] = true
            XCTAssertTrue(policy.permitsCollection, "premise: gate open")
            collector.speechStarted(confirmationFrameSamples: 320)
            collector.appendSamples([Float](repeating: 1, count: 640), reportedTotal: 640)
            collector.speechCompleted([Float](repeating: 1, count: 640),
                                      context: collector.currentCaptureContextForTesting)
            sem.signal()
        }
        XCTAssertEqual(sem.wait(timeout: .now() + 5), .success, "producer should finish")
        // Give the drain hops a chance to land before reading, then confirm the queue emptied.
        XCTAssertTrue(collector.waitForDrain(timeout: 5), "queued events should be delivered")

        lock.lock(); let mainFlags = deliveredOnMainThread; let producerFlags = deliveredFromAudioQueue; lock.unlock()
        XCTAssertFalse(mainFlags.isEmpty, "sink should have been invoked at all")
        XCTAssertFalse(producerFlags.contains(true),
                       "no event may be delivered on the producer thread — that would block capture")
    }

    // MARK: - Helpers

    private func recordedKinds() -> [VoiceSharingCollector.SignalKind] {
        recordLock.lock(); defer { recordLock.unlock() }
        return events.map(\.kind)
    }

    private func record(_ e: VoiceSharingCollector.SegmentEvent) {
        recordLock.lock(); events.append(e); recordLock.unlock()
    }
}

// MARK: - Stubs

/// Backend stand-in that also gives the test a handle on the engine's capture callback and the bleed verdict,
/// neither of which is otherwise reachable without a real audio session or playback tap.
private final class EngineStubBackend: AsrBackend {
    weak var engine: VoiceAsrEngine?
    private(set) var transcribeCalls = 0

    var requiredModel: ModelSpec { ModelSpec(id: "stub", files: [], targetDir: "stub") }
    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
    }
    func ensureReady() async -> Result<Void, Error> { .success(()) }
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        transcribeCalls += 1
        return AsrResult(text: "", detectedLanguage: nil)
    }
    func release() {}

    /// Feeds frames exactly the way `capture.onSamples` does in production: one callback per audio buffer,
    /// which is why the segmenter sees many small calls rather than one giant array.
    func emitSpeech(level: Float, totalSamples: Int, chunkSamples: Int = 160) {
        guard let feed = engine?.captureCallbackForTesting else { return }
        var fed = 0
        while fed < totalSamples {
            let n = min(chunkSamples, totalSamples - fed)
            feed([Float](repeating: level, count: n))
            fed += n
        }
    }

    /// Speech followed by silence, so the segmenter times out and emits a real utterance through
    /// `onUtterance` → the engine's own `processUtterance`. Silence uses wall-clock waiting because the
    /// segmenter measures it with `Date()`; the timeout is short to keep the suite fast.
    func emitSpeechThenSilence(level: Float, speechSamples: Int, silenceSamples: Int,
                               chunkSamples: Int = 160) async {
        emitSpeech(level: level, totalSamples: speechSamples, chunkSamples: chunkSamples)
        emitSilence(totalSamples: silenceSamples, chunkSamples: chunkSamples)
        // Give the Task that processUtterance is dispatched onto a chance to run.
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    func emitSilence(totalSamples: Int, chunkSamples: Int = 160) {
        guard let feed = engine?.captureCallbackForTesting else { return }
        var fed = 0
        while fed < totalSamples {
            let n = min(chunkSamples, totalSamples - fed)
            feed([Float](repeating: 0.0001, count: n))
            fed += n
            // Wall-clock advance between chunks, since the segmenter compares Date() values rather than sample
            // counts. With the short test timeout this stays fast.
            if fed % 320 == 0 { Thread.sleep(forTimeInterval: 0.02) }
        }
    }
}

private final class NotDetectedWake: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult { .notDetected(confidence: 0.05) }
    func release() {}
}
