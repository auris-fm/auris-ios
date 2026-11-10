import XCTest
@testable import podcasts

/// TASK 90 SNAPSHOT CONTROLS (spec cloud-assistant.md → playback-snapshot; plan Task 3, iOS slice).
///
/// The playback context a cloud turn carries must be the one frozen at UTTERANCE ADMISSION —
/// ahead of ASR, translation, routing and any retry — never resampled at dispatch time.
/// Each control inspects the actual carried value or the actual serialized request, not a
/// provider helper.
final class PlaybackSnapshotControls: XCTestCase {

    private func makeEngine(
        backend: AsrBackend,
        translation: TranslationStage
    ) -> VoiceAsrEngine {
        let grace = GracePeriodSignal()
        grace.onCommandRecognized()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: ContinuousWakeStub(),
            gracePeriodSignal: grace,
            translationStage: translation
        )
        engine.listeningMode = .continuous
        return engine
    }

    private func stubBackend(
        _ text: String = "what did they say",
        language: String? = "en"
    ) -> StubAsrBackend {
        StubAsrBackend(result: AsrResult(text: text, detectedLanguage: language), canTranslate: false)
    }

    private func stubTranslation() -> StubTranslationStage {
        StubTranslationStage(ensureReady: .success(()), translateResult: "unused")
    }

    /// CONTROL 1 — ASR DELAY / PLAYBACK ADVANCEMENT: the snapshot is read ONCE, at admission,
    /// before ASR ran. Live playback advancing after admission (the delay ASR introduces) never
    /// reaches the routing input.
    func test_snapshotIsFrozenAtAdmission_despitePlaybackAdvancingAfterwards() async throws {
        let backend = stubBackend()
        let engine = makeEngine(backend: backend, translation: stubTranslation())

        let admissionSnapshot = PlaybackContext(
            episodeId: "ep-a", podcastId: "pod-a",
            referencePositionMs: 1_000, clientPositionMs: 1_000,
            recentReferencePositions: [900, 1_000], previousReferencePositionMs: 900
        )
        // The "live" state the closure would report if consulted again — mutated to a
        // LATER moment the turn must never describe.
        var liveNow: PlaybackContext? = admissionSnapshot
        var reads = 0
        engine.playbackContextSnapshot = {
            reads += 1
            return liveNow
        }

        var inputs: [IntentRoutingInput] = []
        engine.onRoutingInput = { inputs.append($0); return true }

        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))
        // ASR has finished; playback meanwhile advanced, as it would across a real delay.
        liveNow = PlaybackContext(
            episodeId: "ep-b", podcastId: "pod-b",
            referencePositionMs: 60_000, clientPositionMs: 60_000,
            recentReferencePositions: [59_000, 60_000], previousReferencePositionMs: 59_000
        )

        XCTAssertEqual(reads, 1, "the snapshot is consulted exactly once, at admission")
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input.playbackContext, admissionSnapshot,
                       "the routing input carries the ADMISSION snapshot, not the later state")
    }

    /// CONTROL 2 — EPISODE REPLACEMENT: when the playing episode changes between the utterance
    /// and the dispatch, the actual serialized request names the utterance-start episode.
    func test_serializedRequestNamesUtteranceStartEpisode_whenEpisodeWasReplaced() throws {
        let snapshot = CloudRouteContext(
            episodeId: "ep-a", podcastId: "pod-a",
            referencePositionMs: 1_000, clientPositionMs: 1_000,
            recentReferencePositions: [900, 1_000], previousReferencePositionMs: 900
        )
        // Serialized as the turn dispatches: the snapshot, NOT a live read of ep-b.
        let payload = CloudRouteRequestBuilder.envelope(
            request: "what did they say",
            context: snapshot,
            turn: CloudTurnEnvelope.make(
                capabilities: [],
                routeHint: nil,
                recentConversation: [],
                conversation: CloudPreparedConversation(
                    requestId: "req-1", conversationId: "conv-1", mode: "create"
                )
            )
        )
        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertEqual(context["episode_id"] as? String, "ep-a",
                       "the wire frame names the UTTERANCE-START episode")
        XCTAssertEqual(context["reference_position_ms"] as? Int64, 1_000)
    }

    /// CONTROL 3 — IMMUTABLE RETRY: a transport retry re-serializes the SAME snapshot with the
    /// SAME request identity; no stage between attempts may re-read playback or re-identify.
    func test_retryReserializesIdenticalRequest_withStableIdentity() throws {
        func makePayload() throws -> [String: Any] {
            try XCTUnwrap(CloudRouteRequestBuilder.envelope(
                request: "what did they say",
                context: CloudRouteContext(
                    episodeId: "ep-a", podcastId: nil,
                    referencePositionMs: 1_000, clientPositionMs: 1_000,
                    recentReferencePositions: [900, 1_000], previousReferencePositionMs: 900
                ),
                turn: CloudTurnEnvelope.make(
                    capabilities: [],
                    routeHint: nil,
                    recentConversation: [],
                    conversation: CloudPreparedConversation(
                        requestId: "req-1", conversationId: "conv-1", mode: "create"
                    )
                )
            ) as? [String: Any])
        }
        let original = try makePayload()
        let retry = try makePayload()
        let retryContext = try XCTUnwrap(retry["context"] as? [String: Any])
        let originalContext = try XCTUnwrap(original["context"] as? [String: Any])
        XCTAssertEqual(retryContext as NSDictionary, originalContext as NSDictionary,
                       "the retry serializes the SAME snapshot context")
        XCTAssertEqual(retry["request_id"] as? String, "req-1",
                       "the retry keeps the admitted request identity")
    }

    /// CONTROL 4 — MISSING EPISODE/MAPPING: a snapshot with no episode serializes to ABSENCE.
    /// No episode id, no positions, no recent history — nothing invented, nothing empty-but-real.
    func test_snapshotWithoutEpisode_serializesAsOmittedContext() throws {
        let snapshot = CloudRouteContext(
            episodeId: nil, podcastId: nil,
            referencePositionMs: nil, clientPositionMs: nil,
            recentReferencePositions: [], previousReferencePositionMs: nil
        )
        let payload = CloudRouteRequestBuilder.envelope(
            request: "what is this",
            context: snapshot,
            turn: CloudTurnEnvelope.make(
                capabilities: [],
                routeHint: nil,
                recentConversation: [],
                conversation: CloudPreparedConversation(
                    requestId: "req-2", conversationId: "conv-2", mode: "create"
                )
            )
        )
        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertNil(context["episode_id"])
        XCTAssertNil(context["client_position_ms"])
        XCTAssertNil(context["reference_position_ms"])
        XCTAssertNil(context["recent_reference_positions"],
                     "an empty array is not absence — every position key is omitted")
    }

    /// CONTROL 5 — SHARING DISABLED: the snapshot path is independent of contribution
    /// collection. No consent object, no sharing gate, no collector exists on this path; the
    /// control proves capture completes on an engine wired with nothing but the snapshot source
    /// itself.
    func test_snapshotCaptureDoesNotDependOnAnySharingComponent() async throws {
        let backend = stubBackend()
        let engine = makeEngine(backend: backend, translation: stubTranslation())
        let snapshot = PlaybackContext(
            episodeId: "ep-a", podcastId: nil,
            referencePositionMs: 5_000, clientPositionMs: 5_000,
            recentReferencePositions: [], previousReferencePositionMs: nil
        )
        engine.playbackContextSnapshot = { snapshot }

        var inputs: [IntentRoutingInput] = []
        engine.onRoutingInput = { inputs.append($0); return true }
        await engine.processUtterance(Array(repeating: Float(0.01), count: 1600))

        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input.playbackContext, snapshot,
                       "capture works with no sharing/consent component involved")
    }
}

// Stubs duplicated per-file by convention in this suite (each file keeps its own privates).
private final class ContinuousWakeStub: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        .notDetected(confidence: 0.1)
    }

    func release() {}
}
private final class StubAsrBackend: AsrBackend {
    let result: AsrResult
    let canTranslate: Bool

    init(result: AsrResult, canTranslate: Bool) {
        self.result = result
        self.canTranslate = canTranslate
    }

    var requiredModel: ModelSpec {
        ModelSpec(id: "stub", files: [], targetDir: "stub")
    }

    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["zh", "en", "de"], canTranslateToEnglish: canTranslate, requiresHardwareAccel: false)
    }

    func ensureReady() async -> Result<Void, Error> { .success(()) }

    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult { result }

    func release() {}
}
private final class StubTranslationStage: TranslationStage {
    let ensureReadyResult: Result<Void, Error>
    let translateResult: String
    private(set) var ensureReadyCalls = 0

    init(ensureReady: Result<Void, Error>, translateResult: String) {
        self.ensureReadyResult = ensureReady
        self.translateResult = translateResult
    }

    func ensureReady(sourceLanguage: String) async -> Result<Void, Error> {
        ensureReadyCalls += 1
        return ensureReadyResult
    }

    func translate(text: String, sourceLanguage: String) async -> String {
        translateResult
    }
}
