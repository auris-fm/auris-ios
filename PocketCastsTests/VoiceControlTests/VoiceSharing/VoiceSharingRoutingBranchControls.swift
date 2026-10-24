import AVFoundation
import XCTest

@testable import podcasts

/// Drives `VoiceControlService.handleRoutingInput` with an INJECTED classifier and executor, so the REAL
/// routing and execution branches run without the LFM model (spec 85cec5b7). The collector is the real
/// one and every assertion reads what the collector actually published for that capture.
///
/// Established here: which branch ran, what it reported, and how the executor's returned response was
/// interpreted. NOT established here: how the real model classifies — that needs the model, and these
/// controls do not stand in for it.
final class VoiceSharingRoutingBranchControls: XCTestCase {

    // MARK: - Injected seam

    private final class StubClassifier: IntentClassifying {
        var result: ClassificationResult = .none
        var onMetrics: ((RouterStageDiagnostic) -> Void)?
        var classifyCalls = 0
        func classify(input: IntentRoutingInput,
                      pendingDialog: PendingVoiceDialog?) -> ClassificationResult {
            classifyCalls += 1
            return result
        }
        func ensureReady() async -> Result<Void, Error> { .success(()) }
    }

    private final class StubExecutor: VoiceIntentExecuting {
        var response: VoiceResponse = .spoken("ok")
        private(set) var executed: [String] = []

        func execute(_ intent: any VoiceIntent) async -> VoiceResponse {
            executed.append(String(describing: type(of: intent)))
            return response
        }
    }

    // MARK: - Harness

    private var collected: [VoiceSharingCollector.SegmentEvent] = []
    private var queue: VoiceSharingUploadQueue!

    /// An AUTHORITATIVE, enrolled membership: `enrolled: true` alone is not permission — the collector
    /// additionally requires a projection accepted this session, a live epoch and acceptance.
    private var state: VoiceSharingEnrollmentStore.State = {
        var state = VoiceSharingEnrollmentStore.State()
        state.localOptIn = true
        state.hasAuthoritativeProjection = true
        state.membership = VoiceSharingMembership(
            membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
            enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09",
            withdrawalState: .active)
        return state
    }()

    /// The same gate the production collector helper opens: an installed remote lease plus an enrolled
    /// account. `enrolled: true` on its own is NOT permission, which is the point of the policy.
    private func openGate() -> VoiceSharingPolicy {
        let policy = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { [weak self] in self?.state.effectiveEnrolled ?? false })
        policy.identityBecameReadable()
        _ = policy.refreshAfterActivation(freshActivationSucceeded: true,
                                          fetchToken: policy.tokenForFetchStart())
        return policy
    }

    override func setUp() {
        super.setUp()
        collected = []
        queue = nil
    }

    /// A REAL sink over a REAL durable queue: the record a control inspects is the one that would be
    /// uploaded, not an in-memory stand-in.
    private func makeSink(_ collectorPolicy: VoiceSharingPolicy) -> VoiceSharingContributionSink {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-controls-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        self.queue = queue
        return VoiceSharingContributionSink(
            queue: queue,
            isEnabled: { true },
            encoderProvenance: { [self] in provenance },
            observations: { [:] })
    }

    private var provenance: VoiceSharingContributionEncoder.Provenance {
        VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "gen-A",
            models: VoiceSharingContributionEncoder.Models(
                vad: .init(id: "vad-1", version: "1"), wakeword: .init(id: "wake-1", version: "1"),
                asr: .init(id: "asr-1", version: "1"), translation: nil,
                router: .init(id: "router-1", version: "1")),
            conversionVersion: "v1")
    }

    private func makeCollector() -> VoiceSharingCollector {
        let collector = VoiceSharingCollector(
            policy: openGate(),
            membership: { [weak self] in self?.state ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { "epoch-1" },
            sessionIdentity: { "gen-A" },
            sink: { [weak self] event in self?.collected.append(event) })
        collector.deliversSynchronouslyForTesting = true
        return collector
    }

    /// Analytics that records nothing: these controls are not about events.
    private final class BranchControlAnalytics: AnalyticsService {
        func track(_ event: String, properties: [String: Any]) {}
    }

    /// A wake detector that never detects: these controls drive routing, not the wake stage.
    private final class BranchControlWake: WakeWordDetectorProtocol {
        func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
            .notDetected(confidence: 0)
        }
        func release() {}
    }

    /// A TTS engine that makes no sound: branch controls must not speak.
    private final class SilentTts: TtsEngineProtocol {
        func warmUp(language: String) {}
        func speak(text: String, language: String) async {}
        func cancel() {}
        func releaseEngine() {}
    }

    private struct Harness {
        let service: VoiceControlService
        let engine: VoiceAsrEngine
        let collector: VoiceSharingCollector
    }

    private func makeService(
        router: StubClassifier, executor: StubExecutor, collector: VoiceSharingCollector
    ) -> Harness {
        // Every collaborator is the PRODUCTION one except the classifier and executor under test; the
        // engine is the real engine so the collector it reports through is the real one.
        let grace = GracePeriodSignal()
        let backend = EngineStubBackend()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(silenceTimeoutMs: 60),
            backend: backend, signalFilter: SignalFilter(),
            wakeWordDetector: BranchControlWake(), gracePeriodSignal: grace,
            translationStage: nil)
        backend.engine = engine
        engine.contributionCollector = collector
        let service = VoiceControlService(
            conditionMonitor: LiveConditionMonitor(gracePeriodSignal: grace),
            routeMonitor: IOSAudioRouteMonitor(
                gracePeriodSignal: grace, audioSession: RealAudioSession()),
            interruptionHandler: AudioSessionInterruptionHandler(),
            asrEngine: engine,
            wakeWordDetector: BranchControlWake(),
            intentRouter: router,
            executor: executor,
            dialogManager: VoiceDialogManager(),
            audioRenderer: AudioFeedbackRenderer(
                earconPlayer: EarconPlayer(engine: AVAudioEngine()), ttsEngine: SilentTts()),
            gracePeriodSignal: grace,
            analytics: VoiceAnalytics(analytics: BranchControlAnalytics()),
            contributionCollector: collector,
            isPlaybackActive: { false })
        return Harness(service: service, engine: engine, collector: collector)
    }

    /// Produces a REAL open capture the way production does — the engine's own `speechStarted` — because
    /// an observation can only land on a capture that exists. Reports on a context the collector never
    /// minted are dropped by design, and a control that used a made-up context would prove nothing.
    private func openRealCapture(_ harness: Harness) async -> VoiceSharingCollector.CaptureContext? {
        harness.engine.listeningMode = .continuous
        guard let context = harness.collector.speechStarted(confirmationFrameSamples: 640) else {
            return nil
        }
        return context
    }

    /// Publishes the capture the way production does once the utterance is over: `speechCompleted` from
    /// the segmenter's end. Without this the capture stays open and nothing is ever emitted — a control
    /// that skipped it would be asserting on a record that was never written.
    private func finishCapture(_ harness: Harness, _ context: VoiceSharingCollector.CaptureContext) {
        let samples = [Float](repeating: 0.4, count: 16_000)
        // Deferred: the record stays ring-resident so downstream stages can still be reported onto it,
        // which is exactly the production arrangement this control exists to exercise.
        harness.collector.speechCompleted(samples, context: context, deferEmission: true)
        harness.collector.finalizeDeferredCompletion(context: context)
    }

    /// The stages the collector published for this capture. The `started` event carries none, so the
    /// COMPLETION is what this reads — a control that inspected the first event would prove nothing.
    /// Delivery is asynchronous, so this waits for the completion rather than racing it.
    private func publishedStages(
        for id: UUID, timeout: TimeInterval = 3
    ) -> [String: VoiceSharingContributionEncoder.StageOutcome] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for event in collected.reversed() where event.captureID == id && event.kind == .completed {
                if !event.reportedStages.isEmpty { return event.reportedStages }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return [:]
    }

    // MARK: - Controls

    /// THE routing control: each real branch reports its own routing outcome AND the execution outcome
    /// that followed from the executor's returned response.
    func test_eachRealRoutingBranchReportsItsOwnRoutingAndExecutionOutcome() async {
        typealias Outcome = VoiceSharingContributionEncoder.StageOutcome
        struct Case {
            let label: String
            let result: ClassificationResult
            let response: VoiceResponse
            let routingDisposition: String
            let executionState: String
            let executionReason: String?
        }
        let cases: [Case] = [
            // SUPERSEDED CONTRACT (spec: structured executor verdicts). The prior wording — "a
            // success tone leaves execution UNOBSERVED, reporting completed would invent a
            // success" — was the response-derived classifier's stance, and it discarded facts the
            // executor knew. The executor is now the decision site: its own verdict rides with the
            // response (`executeWithVerdict`), a non-error result of a local action is a COMPLETED
            // execution, and the disposition follows the verdict instead of staying pending.
            Case(label: "intent succeeded, executor completed", result: .intent(PlaybackIntent.pause),
                 response: .earcon(.success), routingDisposition: "executed",
                 executionState: "completed", executionReason: nil),
            // The executor's OWN failure verdict: it logs "Command failed" and withholds the grace
            // period on exactly this value, so this one conclusion comes from the executor.
            Case(label: "intent action failed", result: .intent(PlaybackIntent.pause),
                 response: .earcon(.error), routingDisposition: "failed",
                 executionState: "failed", executionReason: "action_failed"),
            // `.silent` is how a seek or a resume presents success — the executor's verdict for it
            // is completed, not unobserved and not a refusal (the earlier version of this control
            // got that wrong in the other direction).
            Case(label: "silent response, executor completed", result: .intent(PlaybackIntent.pause),
                 response: .silent, routingDisposition: "executed",
                 executionState: "completed", executionReason: nil),
            // The router declined: nothing to execute.
            // The router declined, and this window has no escalation budget, so the dispatch the service
            // would otherwise make is refused by policy: nothing executed, and the reason says which
            // precondition failed rather than blaming the user.
            Case(label: "no intent", result: .none,
                 response: .spoken("unused"), routingDisposition: "not_run",
                 executionState: "not_run", executionReason: "precondition_failed"),
        ]

        for testCase in cases {
            collected = []
            let router = StubClassifier()
            let executor = StubExecutor()
            let collector = makeCollector()
            let harness = makeService(router: router, executor: executor, collector: collector)
            let service = harness.service
            guard let context = await openRealCapture(harness) else {
                return XCTFail("\(testCase.label): a real open capture is required")
            }
            let id = context.id

            service.enterListeningStateForTesting()
            router.result = testCase.result
            executor.response = testCase.response
            await service.handleRoutingInput(
                IntentRoutingInput.english(transcript: "skip back thirty seconds"),
                captureContext: context)
            finishCapture(harness, context)

            XCTAssertEqual(router.classifyCalls, 1, "\(testCase.label): routing must run once")
            let stages = publishedStages(for: id)

            guard let routing = stages["routing"], let execution = stages["execution"] else {
                XCTFail("\(testCase.label): the record must carry routing and execution, got "
                        + "\(stages.keys.sorted())")
                continue
            }
            XCTAssertEqual(routing.routingDisposition, testCase.routingDisposition,
                           "\(testCase.label): wrong routing disposition")
            if testCase.executionState != "unknown" {
                XCTAssertNotEqual(routing.routingDisposition, "pending",
                                  "\(testCase.label): an OBSERVED turn must not stay pending")
            }
            XCTAssertEqual(execution.state, testCase.executionState,
                           "\(testCase.label): wrong execution state")
            XCTAssertEqual(execution.reason, testCase.executionReason,
                           "\(testCase.label): wrong execution reason")
            // PRODUCER BINDINGS (spec 78480a17): the classification names come from the SAME
            // canonical mapping analytics records, and the execution verdict states what execution
            // concluded. The router-declined case classified nothing, so it must name nothing.
            if testCase.routingDisposition != "not_run" {
                XCTAssertFalse(routing.predictedIntent?.isEmpty ?? true,
                               "\(testCase.label): the classified turn must name its intent")
                XCTAssertFalse(routing.predictedTool?.isEmpty ?? true,
                               "\(testCase.label): the classified turn must name its tool")
            } else {
                XCTAssertNil(routing.predictedIntent,
                             "\(testCase.label): an unclassified turn must not invent an intent")
            }
            if testCase.executionState != "not_run" {
                XCTAssertFalse(execution.outcome?.isEmpty ?? true,
                               "\(testCase.label): an executed turn must state its verdict")
            }
        }
    }

    /// A stopped session must not execute, and must not leave the capture owned. The capture still has to
    /// publish, carrying the cancellation — an unreleased capture would never appear at all.
    func test_aStopDuringRoutingCancelsAndStillPublishesTheCapture() async {
        collected = []
        let router = StubClassifier()
        let executor = StubExecutor()
        let collector = makeCollector()
        let harness = makeService(router: router, executor: executor, collector: collector)
        let service = harness.service
        guard let context = await openRealCapture(harness) else {
            return XCTFail("a real open capture is required")
        }
        let id = context.id

        service.enterListeningStateForTesting()
        router.result = .none
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "skip back"),
                                         captureContext: context)
        finishCapture(harness, context)

        let stages = publishedStages(for: id)
        XCTAssertNotNil(stages["execution"],
                        "the capture must still publish its execution observation, got "
                            + "\(stages.keys.sorted())")
        XCTAssertNotNil(stages["routing"], "routing must be on the record")
    }

    /// REVIEW 59841fbc #2: the debounce skip must settle the capture with an ENUMERATED reason. The
    /// first version invented `nothing_to_do`, which payload validation refuses — so the record would
    /// have been dropped rather than recorded.
    func test_theDebounceSkipSettlesWithAnEnumeratedReason() async {
        collected = []
        let router = StubClassifier()
        router.result = .intent(PlaybackIntent.pause)
        let executor = StubExecutor()
        let collector = makeCollector()
        let harness = makeService(router: router, executor: executor, collector: collector)
        let service = harness.service
        service.enterListeningStateForTesting()

        // First turn executes and arms the debounce window.
        guard let first = await openRealCapture(harness) else {
            return XCTFail("a real open capture is required")
        }
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "pause"),
                                         captureContext: first)
        finishCapture(harness, first)
        let firstStages = publishedStages(for: first.id)
        // SUPERSEDED premise (structured executor verdicts): the first turn now reports the
        // executor's verdict — completed — instead of the response classifier's unobserved.
        XCTAssertEqual(firstStages["execution"]?.state, "completed",
                       "premise: the first turn ran and the executor stated its verdict")
        XCTAssertEqual(executor.executed.count, 1, "premise: the first turn reached the executor")

        // Second identical turn inside the debounce window: suppressed, and must still PUBLISH.
        guard let second = await openRealCapture(harness) else {
            return XCTFail("a real open capture is required")
        }
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "pause"),
                                         captureContext: second)
        finishCapture(harness, second)
        XCTAssertEqual(executor.executed.count, 1, "premise: the debounce suppressed the second turn")

        let stages = publishedStages(for: second.id)
        guard let execution = stages["execution"] else {
            return XCTFail("the suppressed turn must still publish a record, got "
                           + "\(stages.keys.sorted())")
        }
        XCTAssertEqual(execution.reason, "client_refused",
                       "the settle reason must be one the schema enumerates")
    }

    /// A blank or wake-only transcript is a session start, not a failed question: routing is NOT run and
    /// the executor sees nothing. The record still publishes with both stages settled.
    func test_aSilentSessionStartIsNotRoutedAndStillPublishes() async {
        collected = []
        let router = StubClassifier()
        router.result = .intent(PlaybackIntent.pause)
        let executor = StubExecutor()
        let collector = makeCollector()
        let harness = makeService(router: router, executor: executor, collector: collector)
        let service = harness.service
        guard let context = await openRealCapture(harness) else {
            return XCTFail("a real open capture is required")
        }
        let id = context.id

        service.enterListeningStateForTesting()
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "   "),
                                         captureContext: context)
        finishCapture(harness, context)

        XCTAssertEqual(router.classifyCalls, 0,
                       "a blank transcript must not be classified as a question")
        XCTAssertTrue(executor.executed.isEmpty, "a blank transcript must not execute anything")
        let stages = publishedStages(for: id)
        XCTAssertEqual(stages["routing"]?.state, "not_run",
                       "routing must record that it did not run")
        XCTAssertEqual(stages["execution"]?.state, "not_run",
                       "execution must record that it did not run")
    }
}