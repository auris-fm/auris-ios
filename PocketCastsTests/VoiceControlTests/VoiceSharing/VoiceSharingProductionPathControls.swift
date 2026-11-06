import XCTest
@testable import podcasts

/// PRODUCTION-PATH controls for the phase-2 record fields (reviewer 67ecb11e item 3).
///
/// These drive the REAL engine — real segmenter, real capture callback, real collector, real sink — and
/// assert on the segment events the collector actually emitted. Nothing here constructs a `SegmentEvent` or
/// a `StageOutcome` by hand, which is exactly the gap in the encoder-level controls: those proved my own
/// glue, not that the producer reports the value.
///
/// The boundary of each control is stated on it: engine → collector → emitted event. Encoding and binding
/// are covered separately (`VoiceSharingNameSchemaControls`), and the two together are the record.
final class VoiceSharingProductionPathControls: XCTestCase {
    private var storeState = VoiceSharingEnrollmentStore.State()
    private var gateOpen = false
    private let recordLock = NSLock()
    private var events: [VoiceSharingCollector.SegmentEvent] = []

    override func setUp() {
        super.setUp()
        recordLock.lock(); events = []; recordLock.unlock()
        storeState = VoiceSharingEnrollmentStore.State()
        storeState.localOptIn = true
        storeState.hasAuthoritativeProjection = true
        storeState.membership = VoiceSharingMembership(
            membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
            enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09", withdrawalState: .active
        )
        gateOpen = true
    }

    private func makeCollector() -> VoiceSharingCollector {
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { [weak self] in self?.gateOpen ?? false },
            outcomeWaitLimit: .init(milliseconds: 60_000, ceilingMilliseconds: 60_000),
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { "epoch-1" },
            sessionIdentity: { "gen-A" },
            sink: { [weak self] event in
                guard let self else { return }
                self.recordLock.lock(); self.events.append(event); self.recordLock.unlock()
            }
        )
        collector.deliversSynchronouslyForTesting = true
        return collector
    }

    private func makeEngine(collector: VoiceSharingCollector, wake: WakeWordDetectorProtocol,
                            backend: EngineStubBackend,
                            grace: GracePeriodSignal = GracePeriodSignal(),
                            mode: ListeningMode = .wakeWord) -> VoiceAsrEngine {
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(silenceTimeoutMs: 60),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: wake,
            gracePeriodSignal: grace,
            translationStage: nil
        )
        engine.contributionCollector = collector
        engine.listeningMode = mode
        backend.engine = engine
        return engine
    }

    private func snapshot() -> [VoiceSharingCollector.SegmentEvent] {
        recordLock.lock(); defer { recordLock.unlock() }
        return events
    }

    /// The wake outcome the collector actually recorded for the capture that reached segmentation.
    private func wakeOutcome() -> VoiceSharingContributionEncoder.StageOutcome? {
        // The collector reports the wake stage through `engineReported`; the segment event carries the
        // frozen state, and the collector's own ring is what the sink ultimately encodes. Here we read the
        // observation the collector attached, not a value the test supplied.
        snapshot().compactMap { $0.reportedStages["wake"] }.first
    }

    private func asrOutcome() -> VoiceSharingContributionEncoder.StageOutcome? {
        snapshot().compactMap { $0.reportedStages["asr"] }.first
    }

    private func emitAndWait(_ backend: EngineStubBackend, engine: VoiceAsrEngine) async -> Bool {
        XCTAssertTrue(engine.start(), "premise: engine started with stubbed capture")
        backend.emitSpeech(level: 0.6, totalSamples: 6 * 160)
        backend.emitSilence(totalSamples: 24 * 160)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !snapshot().isEmpty, snapshot().contains(where: { $0.kind == .completed || $0.kind == .rejectedWake }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    // MARK: - empty ASR result carries the recogniser's language

    /// The REAL empty-result branch (`VoiceAsrEngine`, the `else` of `rawText.isEmpty`). The stub backend
    /// returns no text but DOES report a detected language, which is what a recogniser that heard speech and
    /// produced nothing usable actually returns. The emitted observation must carry that language.
    ///
    /// Boundary: engine → collector → emitted segment event. This is the control the encoder-level test could
    /// not be: the language is set by the PRODUCER, not supplied by the test.
    func test_realEmptyAsrResultStillReportsTheRecognizerLanguage() async {
        let collector = makeCollector()
        let backend = EngineStubBackend()
        backend.stubTranscript = ""
        backend.stubLanguage = "ja"
        // Recognition only runs for a wake-positive segment without grace, so the detector must hit;
        // otherwise the control would assert about a segment ASR never saw.
        let engine = makeEngine(collector: collector, wake: ProductionPathDetectedWake(), backend: backend)
        defer { engine.stop() }

        let emitted = await emitAndWait(backend, engine: engine)
        XCTAssertTrue(emitted, "premise: the engine emitted an outcome for the segment")

        guard let asr = asrOutcome() else {
            return XCTFail("premise: the engine reported an ASR observation")
        }
        XCTAssertEqual(asr.reason, "empty_result", "an empty transcript is a completed empty result")
        XCTAssertEqual(asr.sourceLanguage, "ja",
                       "the recogniser reported a language; an empty transcript must not erase it")
    }

    /// The non-empty branch still carries its language, so the control above is a comparison between the two
    /// real branches rather than a one-off.
    func test_realNonEmptyAsrResultReportsTheSameLanguageField() async {
        let collector = makeCollector()
        let backend = EngineStubBackend()
        backend.stubTranscript = "play the news"
        backend.stubLanguage = "en"
        let engine = makeEngine(collector: collector, wake: ProductionPathDetectedWake(), backend: backend)
        defer { engine.stop() }

        _ = await emitAndWait(backend, engine: engine)
        guard let asr = asrOutcome() else {
            return XCTFail("premise: the engine reported an ASR observation")
        }
        XCTAssertEqual(asr.text, "play the news")
        XCTAssertEqual(asr.sourceLanguage, "en")
    }

    // MARK: - wake_required comes from the real grace state

    /// WAKE-WORD mode with no grace: the speech that began needed a wake word, and the frozen flag says so.
    /// The flag is set by the engine's `onSpeechStarted` closure from its own mode and grace signal — not by
    /// the test, which only chooses the mode and grace state the engine runs under.
    func test_wakeRequiredIsTrueWhenSpeechStartsInWakeWordModeWithoutGrace() async {
        let collector = makeCollector()
        let backend = EngineStubBackend()
        backend.stubTranscript = "play the news"
        let engine = makeEngine(collector: collector, wake: ProductionPathNotDetectedWake(), backend: backend)
        defer { engine.stop() }

        _ = await emitAndWait(backend, engine: engine)
        let starts = snapshot().filter { $0.kind == .started }
        guard let start = starts.first else { return XCTFail("premise: a capture started") }
        XCTAssertTrue(start.wakeRequired, "wake-word mode without grace requires the wake word")
    }

    /// The SAME engine in grace (wake word not required): the frozen flag says so. Together with the control
    /// above this is the both-modes requirement, driven through the producer.
    func test_wakeRequiredIsFalseWhenSpeechStartsUnderGrace() async {
        let collector = makeCollector()
        let backend = EngineStubBackend()
        backend.stubTranscript = "play the news"
        let grace = GracePeriodSignal()
        // The production entry that opens a window: a wake detection. Grace active is what the engine
        // reads at segment start, so the flag under test must come from that, not from a test setter.
        grace.onWakeWordDetected()
        let engine = makeEngine(collector: collector, wake: ProductionPathNotDetectedWake(), backend: backend, grace: grace)
        defer { engine.stop() }

        _ = await emitAndWait(backend, engine: engine)
        let starts = snapshot().filter { $0.kind == .started }
        guard let start = starts.first else { return XCTFail("premise: a capture started") }
        XCTAssertFalse(start.wakeRequired, "grace is active, so no wake word was required at segment start")
    }

    /// A detector that RAN and measured must put its score and threshold on the observation the collector
    /// recorded. `DetectedWake` reports a fixed score; the threshold is the engine's own configured value, so
    /// both numbers come from the producer.
    func test_measuredWakeScoreAndThresholdReachTheEmittedObservation() async {
        let collector = makeCollector()
        let backend = EngineStubBackend()
        backend.stubTranscript = "play the news"
        let engine = makeEngine(collector: collector, wake: ProductionPathDetectedWake(), backend: backend)
        defer { engine.stop() }

        _ = await emitAndWait(backend, engine: engine)
        guard let wake = wakeOutcome() else { return XCTFail("premise: the engine reported a wake observation") }
        XCTAssertNotNil(wake.score, "the detector ran and measured a score; the record must carry it")
        XCTAssertNotNil(wake.threshold, "the threshold it was judged against must travel with the score")
    }
}
// MARK: - Detector stubs (file-local; the engine-suite equivalents are private to that file)

/// Reports a real measurement: the detector RAN and produced a score. The engine turns this into the
/// recorded `score`/`threshold` pair, which is what these controls read back.
private final class ProductionPathDetectedWake: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        .detected(confidence: 0.95, completionSample: 1600)
    }
    func release() {}
}

/// Reports no detection — still a real measurement the detector made.
private final class ProductionPathNotDetectedWake: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult { .notDetected(confidence: 0.05) }
    func release() {}
}
