import XCTest
import PocketCastsDataModel
@testable import podcasts

/// TASK 90 SNAPSHOT + PROVENANCE CONTROLS (spec cloud-assistant.md playback-snapshot;
/// spec 351dd308 same-reference source binding; corrections in review bcb42c49).
///
/// The playback context a cloud turn carries must be frozen at the SPEECH-START boundary and
/// dispatch verbatim — including a captured ABSENCE — and its reference version must travel
/// atomically with the mapped position that produced it. Each control drives the real
/// interleaving and inspects the actual carried value or the actual serialized request.
final class PlaybackSnapshotControls: XCTestCase {

    private func makeEngine(
        backend: AsrBackend,
        translation: TranslationStage,
        segmenter: NativeVadSegmenter = NativeVadSegmenter()
    ) -> VoiceAsrEngine {
        let grace = GracePeriodSignal()
        grace.onCommandRecognized()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: segmenter,
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: ContinuousWakeStub(),
            gracePeriodSignal: grace,
            translationStage: translation
        )
        engine.listeningMode = .continuous
        return engine
    }

    private func stubTranslation() -> StubTranslationStage {
        StubTranslationStage(ensureReady: .success(()), translateResult: "unused")
    }

    private func envelopePayload(context: CloudRouteContext, requestId: String = "req-1") throws -> [String: Any] {
        try XCTUnwrap(CloudRouteRequestBuilder.envelope(
            request: "what did they say",
            context: context,
            turn: CloudTurnEnvelope.make(
                capabilities: [],
                routeHint: nil,
                recentConversation: [],
                conversation: CloudPreparedConversation(
                    requestId: requestId, conversationId: "conv-1", mode: "create"
                )
            )
        ) as? [String: Any])
    }

    // MARK: - Speech-start capture through the segmenter

    /// CONTROL (review bcb42c49 #1): the segmenter fires the speech-start hook at the
    /// CONFIRMATION frame — before the utterance is emitted — so the engine's capture
    /// happens while the user is still speaking, not at admission after speech ends.
    func test_segmenterFiresSpeechStartBeforeEmission() {
        let segmenter = NativeVadSegmenter(silenceTimeoutMs: -1)
        var events: [String] = []
        segmenter.onSpeechStart = { events.append("start") }
        segmenter.onUtterance = { _, _ in events.append("emit") }

        let frame = [Float](repeating: 0.5, count: 320)
        // 5+ energetic frames confirm speech; one sub-threshold frame closes (timeout -1).
        for _ in 0..<6 { segmenter.process(frame, capturedAt: nil) }
        segmenter.process([Float](repeating: 0, count: 320), capturedAt: nil)

        XCTAssertEqual(events, ["start", "emit"],
                       "speech-start capture must precede emission, not accompany it")
    }

    /// CONTROL (review bcb42c49 #1 + #3; d815be4a #3): the REAL engine/segmenter wiring.
    /// Speech frames are fed through the engine's own segmenter with the production callbacks
    /// installed: `onSpeechStart` captures, the utterance is emitted and ASR runs gated —
    /// playback advances WHILE ASR is suspended — and the routing input still carries the
    /// speech-start value with exactly one capture consult.
    func test_productionWiring_speechStartSnapshotSurvivesGatedASR_andPlaybackAdvance() async throws {
        let gate = AsrGate()
        let backend = GatedAsrBackend(gate: gate, text: "what did they say", language: "en")
        let engine = makeEngine(
            backend: backend,
            translation: stubTranslation(),
            segmenter: NativeVadSegmenter(silenceTimeoutMs: -1)
        )
        engine.installCaptureCallbacksForTesting()

        let speechStartSnapshot = PlaybackContext(
            episodeId: "ep-at-start", podcastId: "pod-a",
            referencePositionMs: 1_000, clientPositionMs: 1_000,
            recentReferencePositions: [900, 1_000], previousReferencePositionMs: 900
        )
        var liveNow: PlaybackContext? = speechStartSnapshot
        var reads = 0
        engine.playbackContextSnapshot = {
            reads += 1
            return liveNow
        }

        var inputs: [IntentRoutingInput] = []
        engine.onRoutingInput = { inputs.append($0); return true }

        let frame = [Float](repeating: 0.5, count: 320)
        // Speech confirmed on the 5th energetic frame → onSpeechStart captures HERE.
        for _ in 0..<6 { engine.feedSyntheticSamplesForTesting(frame) }
        XCTAssertEqual(reads, 1, "capture ran at the speech-start confirmation frame")
        XCTAssertEqual(inputs.count, 0, "nothing has been emitted yet")

        // The user keeps "speaking"; playback advances in the real world.
        liveNow = PlaybackContext(
            episodeId: "ep-later", podcastId: "pod-later",
            referencePositionMs: 60_000, clientPositionMs: 60_000,
            recentReferencePositions: [59_000, 60_000], previousReferencePositionMs: 59_000
        )

        // One sub-threshold frame closes the utterance (timeout -1) → emission → gated ASR.
        engine.feedSyntheticSamplesForTesting([Float](repeating: 0, count: 320))
        await gate.waitEntered()
        XCTAssertEqual(inputs.count, 0, "ASR is still suspended mid-run")
        gate.release()

        // Bounded wait for the routing input.
        for _ in 0..<100 where inputs.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(reads, 1, "the suspended run never consulted playback again")
        let input = try XCTUnwrap(inputs.first, "no routing input arrived")
        XCTAssertEqual(input.playbackContext, speechStartSnapshot,
                       "the input carries the SPEECH-START snapshot even though playback "
                       + "advanced while ASR was suspended")
    }

    // MARK: - Provenance pairing (spec 351dd308)

    /// CONTROL: the cache load returns the digest of the EXACT reference bytes it validated,
    /// paired with the map — not a hash of another file or a recomputation at read time.
    func test_cacheLoadReturnsDigestOfExactReferenceBytes() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let referenceData = Data("reference-bytes-v1".utf8)
        let audioPath = try writeAudioFixture(to: dir, referenceData: referenceData)

        let referencePath = dir.appendingPathComponent("reference.json").path
        let result = try XCTUnwrap(loadCacheProducingResult(
            audioPath: audioPath, referenceFilePath: referencePath, referenceData: referenceData
        ))
        XCTAssertEqual(result.referenceAssetVersion, Self.sha256Hex(referenceData),
                       "the exposed version is the digest of the exact reference bytes")
        XCTAssertNotEqual(result.referenceAssetVersion, Self.sha256Hex(Data("other".utf8)))
    }

    /// CONTROL: position and version come from ONE provider call. The double proves the
    /// provider cannot produce a (position, version) pair across a map replacement: the two
    /// values arrive from the same atomic `matchedReferenceContext` read.
    func test_providerPairsPositionAndVersion_fromOneAtomicRead() {
        let mapper = PairedMapperDouble(position: 42.0, version: "abc123")
        let provider = DefaultPlaybackContextProvider(
            playbackState: AlwaysPlayingState(episodeId: "ep-a"),
            fingerprintMapper: mapper,
            cloudPlaybackContextState: CloudPlaybackContextState()
        )
        let context = provider.current()
        XCTAssertEqual(mapper.matchedReferenceContextCallCount, 1,
                       "position and version are resolved in ONE atomic read")
        XCTAssertEqual(context?.referenceAssetVersion, "abc123")
        XCTAssertEqual(context?.referencePositionMs, 42_000)
    }

    /// CONTROL (review d815be4a #1): the atomic read carries the mapped EPISODE, and the
    /// provider rejects a map that belongs to a different episode — a stale episode A map is
    /// never attached to newly playing episode B while a queued reset/reprepare has not run.
    func test_staleEpisodeMap_isRejectedForNewlyPlayingEpisode() {
        let mapper = PairedMapperDouble(position: 42.0, version: "abc123", episodeUuid: "ep-old")
        let provider = DefaultPlaybackContextProvider(
            playbackState: AlwaysPlayingState(episodeId: "ep-new"),
            fingerprintMapper: mapper,
            cloudPlaybackContextState: CloudPlaybackContextState()
        )
        let context = provider.current()
        XCTAssertEqual(mapper.matchedReferenceContextCallCount, 1)
        XCTAssertNil(context?.referencePositionMs,
                     "episode B must not inherit episode A's mapped position")
        XCTAssertNil(context?.referenceAssetVersion,
                     "episode B must not inherit episode A's reference version")
    }

    /// CONTROL (review d815be4a #1): a map whose episode is unknown still serves the position
    /// for the captured episode (providers that predate episode identity).
    func test_unknownEpisodeMap_stillServesPosition() {
        let mapper = PairedMapperDouble(position: 42.0, version: nil, episodeUuid: nil)
        let provider = DefaultPlaybackContextProvider(
            playbackState: AlwaysPlayingState(episodeId: "ep-a"),
            fingerprintMapper: mapper,
            cloudPlaybackContextState: CloudPlaybackContextState()
        )
        let context = provider.current()
        XCTAssertEqual(context?.referencePositionMs, 42_000)
    }

    /// CONTROL: unknown provenance preserves an otherwise valid mapped position — the version
    /// is omitted, never invented, and never blocks the turn.
    func test_unknownProvenance_preservesMappedPosition() {
        let mapper = PairedMapperDouble(position: 42.0, version: nil)
        let provider = DefaultPlaybackContextProvider(
            playbackState: AlwaysPlayingState(episodeId: "ep-a"),
            fingerprintMapper: mapper,
            cloudPlaybackContextState: CloudPlaybackContextState()
        )
        let context = provider.current()
        XCTAssertNotNil(context?.referencePositionMs, "the mapped position still serves")
        XCTAssertNil(context?.referenceAssetVersion, "unknown provenance stays omitted")
    }

    // MARK: - Serialized request

    /// CONTROL: the actual serialized request carries `reference_asset_version` WITH the
    /// position it belongs to.
    func test_serializedRequestCarriesVersionWithPosition() throws {
        let payload = try envelopePayload(context: CloudRouteContext(
            episodeId: "ep-a", podcastId: nil,
            referencePositionMs: 1_000, clientPositionMs: 1_000,
            recentReferencePositions: [], previousReferencePositionMs: nil,
            referenceAssetVersion: "abc123"
        ))
        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertEqual(context["reference_asset_version"] as? String, "abc123")
        XCTAssertEqual(context["reference_position_ms"] as? Int64, 1_000)
    }

    /// CONTROL: unknown provenance is OMITTED from the actual serialized request — and an
    /// episode-less snapshot omits every position key including any version.
    func test_serializedRequestOmitsUnknownProvenance() throws {
        let payload = try envelopePayload(context: CloudRouteContext(
            episodeId: "ep-a", podcastId: nil,
            referencePositionMs: 1_000, clientPositionMs: 1_000,
            recentReferencePositions: [], previousReferencePositionMs: nil,
            referenceAssetVersion: nil
        ))
        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertNil(context["reference_asset_version"],
                     "unknown provenance is omitted, not invented")
    }

    /// CONTROL (review d815be4a #2): the pairing invariant is ENFORCED at serialization —
    /// a version without its mapped position is omitted from the actual request, even if a
    /// caller supplied one.
    func test_serializedRequest_omitsVersionWithoutItsMappedPosition() throws {
        let payload = try envelopePayload(context: CloudRouteContext(
            episodeId: "ep-a", podcastId: nil,
            referencePositionMs: nil, clientPositionMs: 5_000,
            recentReferencePositions: [], previousReferencePositionMs: nil,
            referenceAssetVersion: "abc123"
        ))
        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertNil(context["reference_position_ms"])
        XCTAssertNil(context["reference_asset_version"],
                     "a version without its mapped position names nothing and is omitted")
    }

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("t90-prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a minimal audio fixture + a mapping cache produced from `referenceData`, so a
    /// subsequent `load` validates against those exact bytes.
    private func writeAudioFixture(to dir: URL, referenceData: Data) throws -> String {
        let audioURL = dir.appendingPathComponent("audio.m4b")
        try Data("audio-bytes".utf8).write(to: audioURL)
        let referenceURL = dir.appendingPathComponent("reference.json")
        try referenceData.write(to: referenceURL)
        let entries = [
            FingerprintTimingManager.TimeMappingEntry(playbackTime: 0, referenceTime: 0, score: 1),
            FingerprintTimingManager.TimeMappingEntry(playbackTime: 90, referenceTime: 100, score: 1)
        ]
        FingerprintMappingCache.save(
            entries,
            audioFilePath: audioURL.path,
            referenceFilePath: referenceURL.path,
            referenceData: referenceData,
            referenceDuration: 100
        )
        return audioURL.path
    }

    private func loadCacheProducingResult(audioPath: String, referenceFilePath: String, referenceData: Data)
        -> FingerprintMappingCache.LoadResult? {
        FingerprintMappingCache.load(
            audioFilePath: audioPath,
            referenceFilePath: referenceFilePath,
            referenceData: referenceData
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        FingerprintMappingCache.referenceAssetVersion(of: data)
    }
}

/// Gate that lets a control suspend the ASR run mid-`transcribe` and mutate the world before
/// releasing it.
final class AsrGate {
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false

    func waitEntered(timeout: TimeInterval = 5) {
        _ = entered.wait(timeout: .now() + timeout)
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
        proceed.signal()
    }

    func awaitRelease(timeout: TimeInterval = 5) -> Bool {
        lock.lock()
        let already = released
        lock.unlock()
        if already { return true }
        return proceed.wait(timeout: .now() + timeout) == .success
    }

    func signalEntered() { entered.signal() }
}

/// ASR backend whose `transcribe` blocks until the control releases it — the suspension point
/// where "playback advanced in the real world" is injected.
private final class GatedAsrBackend: AsrBackend {
    let gate: AsrGate
    let text: String
    let language: String?

    init(gate: AsrGate, text: String, language: String?) {
        self.gate = gate
        self.text = text
        self.language = language
    }

    var requiredModel: ModelSpec { ModelSpec(id: "gated", files: [], targetDir: "gated") }
    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
    }
    func ensureReady() async -> Result<Void, Error> { .success(()) }
    func release() {}

    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        gate.signalEntered()
        _ = await Task.detached { self.gate.awaitRelease() }.value
        return AsrResult(text: text, detectedLanguage: language)
    }
}

/// Mapper double that serves position+version from ONE call, counting calls so the pairing
/// control can prove atomic resolution.
private final class PairedMapperDouble: FingerprintMappingProviding {
    let position: TimeInterval
    let version: String?
    let episodeUuid: String?
    private(set) var matchedReferenceContextCallCount = 0

    init(position: TimeInterval, version: String?, episodeUuid: String? = nil) {
        self.position = position
        self.version = version
        self.episodeUuid = episodeUuid
    }

    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { position }

    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? { nil }

    func matchedReferenceContext(forPlaybackTime playbackTime: TimeInterval)
        -> (position: TimeInterval, referenceAssetVersion: String?, episodeUuid: String?)? {
        matchedReferenceContextCallCount += 1
        return (position, version, episodeUuid)
    }
}

/// Playback state double: one episode, always current.
private struct AlwaysPlayingState: PlaybackStateProviding {
    let episode: Episode
    let currentTime: TimeInterval = 42.0

    init(episodeId: String) {
        episode = Episode()
        episode.uuid = episodeId
        episode.podcastUuid = "pod-parent"
    }

    var currentEpisode: BaseEpisode? { episode }
    func currentTimeSeconds() -> TimeInterval { currentTime }
}

// MARK: - Per-file stubs (duplicated by suite convention)

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
