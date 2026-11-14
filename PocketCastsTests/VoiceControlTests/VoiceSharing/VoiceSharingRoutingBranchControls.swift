import AVFoundation
import Network
import XCTest

@testable import podcasts

/// Drives `VoiceControlService.handleRoutingInput` with an INJECTED classifier and executor, so the REAL
/// routing and execution branches run without the LFM model. The collector is the real
/// one and every assertion reads what the collector actually published for that capture.
///
/// Established here: which branch ran, what it reported, and how the executor's returned response was
/// interpreted. not established here: how the real model classifies — that needs the model, and these
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

    /// A scripted executor that keeps the PROTOCOL's own verdict bridge. The bridge is the production
    /// rule for `.earcon(.error)` (the executor's one concluded failure) and `.earcon(.confirmRequired)`
    /// (its one refusal); a stub that reported `failed` for every response would make an invented
    /// verdict indistinguishable from a real one, and a control asserting on that proves nothing.
    private final class StubExecutor: VoiceIntentExecuting {
        var response: VoiceResponse = .spoken("ok")
        /// When set, the verdict the executor reports — standing in for a real sink's structured
        /// action fact (e.g. a declined skip states not_run/precondition_failed) without
        /// re-implementing the sinks themselves.
        var verdictOverride: ExecutionVerdict?
        private(set) var executed: [String] = []

        func execute(_ intent: any VoiceIntent) async -> VoiceResponse {
            executed.append(String(describing: type(of: intent)))
            return response
        }

        // The protocol's OWN bridge: `execute`, then the presentation verdict it states.
        func executeWithVerdict(_ intent: any VoiceIntent) async -> (response: VoiceResponse, verdict: ExecutionVerdict) {
            let response = await execute(intent)
            if let verdictOverride {
                return (response, verdictOverride)
            }
            switch response {
            case .earcon(.error):
                return (response, ExecutionVerdict(state: "failed", reason: "action_failed", outcome: "failed"))
            case .earcon(.confirmRequired):
                return (response, ExecutionVerdict(state: "failed", reason: "client_refused", outcome: "refused"))
            default:
                return (response, ExecutionVerdict(state: "unknown", reason: "observation_unavailable"))
            }
        }
    }

    /// A CONFORMER WITHOUT A CLOUD SINK IS A SUPPORTED CASE, NOT A CRASH.
    ///
    /// The executor type is widened to `any VoiceIntentExecuting` and the protocol has more than one
    /// conformer, but production reached the cloud sink by force-downcasting to the concrete type at
    /// three live sites (barge-in and two suppression checks). Any other conformer reaching those
    /// sites trapped the process.
    ///
    /// The sink is now reached through an optional protocol member defaulting to nil. This control
    /// drives the PRODUCTION lookup — the service's `cloudRouteSink`, which reads the protocol
    /// member — over the full assembled service with a conformer that has no sink. A control that
    /// only read the protocol member directly could not fail if production went back to a
    /// downcast: the downcast lives in the service, not the protocol. Through the service, a
    /// restored `as!` traps on exactly this executor and the control fails.
    /// It deliberately does NOT claim to exercise the service's barge-in/suppression bodies, which
    /// need the full audio wiring; those are covered by source inspection, as review noted.
    @MainActor
    func test_anExecutorWithoutACloudSinkIsHandledRatherThanTrapped() {
        let plain: any VoiceIntentExecuting = StubExecutor()
        let sink = plain.cloudRouteSinkAccess
        XCTAssertNil(sink, "a conformer that declares no sink reports nil rather than trapping")

        // The REAL lookup path, assembled as the app assembles it. Traps if the optional member
        // is ever replaced by a downcast again.
        let service = VoiceControlAssembly().buildVoiceControlService(injectedExecutor: plain)
        XCTAssertNotNil(service, "the assembly must build a service around a conformer with no sink")
        XCTAssertNil(service?.cloudRouteSink,
                     "the service must read the sink through the protocol member, not a downcast")
    }

    // MARK: - Harness

    private var collected: [VoiceSharingCollector.SegmentEvent] = []
    private var queue: VoiceSharingQueue!
    /// Sink deliveries still running, so a control can wait for publication instead of sleeping.
    private var sinkWork: [Task<Void, Never>] = []

    /// Waits for every sink delivery started so far. The collector's sink is off-callback and the
    /// publication is a Task, so this is the barrier — the only thing that makes "nothing was
    /// published" a statement about consent rather than about how fast the machine was.
    private func settleSinkDeliveries() async {
        let outstanding = sinkWork
        sinkWork.removeAll()
        for task in outstanding { await task.value }
    }

    /// How many times the withdrawn pipeline's uploader tried to send. A count rather than a trap:
    /// the claim is that consent loss stops NEW requests, not that no code path is ever reached.
    private var withdrawnSendCount = 0

    /// An AUTHORITATIVE, enrolled membership: `enrolled: true` alone is not permission — the collector
    /// additionally requires a projection accepted this session, a live epoch and acceptance.
    private var state: VoiceSharingEnrollmentStore.State = {
        var state = VoiceSharingEnrollmentStore.State()
        state.localOptIn = true
        state.hasAuthoritativeProjection = true
        state.membership = VoiceSharingMembership(
            plan: .pro, voiceSharingEnrolled: true,
            enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09",
            withdrawalState: .active)
        return state
    }()

    /// SIMPLIFIED contract: the ONE consent decision is the shared closure. `state` stays
    /// as PROVENANCE (epoch / session stamped into emitted records), which is what it is here now.
    private var gateOpen = true
    private func isCollectionPermitted() -> Bool { gateOpen }

    override func setUp() {
        super.setUp()
        collected = []
        queue = nil
    }

    /// A REAL sink over a REAL durable queue: the record a control inspects is the one that would be
    /// uploaded, not an in-memory stand-in.
    private func makeSink() -> VoiceSharingDirectSink {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-controls-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = VoiceSharingQueue(root: root)
        self.queue = queue
        return VoiceSharingDirectSink(
            queue: queue,
            isEnabled: { true },
            encoderProvenance: { [self] in provenance },
            observations: { [:] },
            requestUploadDrain: {})
    }

    /// Only a segment that produced a recording may be published. A cancelled segment is a
    /// content-free disposal notice for this device; publishing it uploads an empty WAV. A started
    /// segment likewise carries no audio and no stages, so its record would compete with the real one.
    func test_onlyCompletedAndRejectedSegmentsArePublished() async throws {
        let sink = makeSink()
        let queue = try XCTUnwrap(self.queue)
        let audio: [Float] = [0, 0.2, -0.3, 0.4]
        func event(_ kind: VoiceSharingCollector.SignalKind) -> VoiceSharingCollector.SegmentEvent {
            VoiceSharingCollector.SegmentEvent(
                kind: kind, captureID: UUID(), enrollmentEpoch: "epoch-1",
                authorizationSession: "sess-1", retainedSamples: audio.count, truncated: false,
                droppedSpans: [], originalSampleCount: nil, audio: audio, isGateControl: false)
        }
        for kind in [VoiceSharingCollector.SignalKind.started, .cancelled] {
            await sink.handle(event(kind))
            let published = await queue.entries()
            XCTAssertTrue(published.isEmpty,
                          "\(kind) must not be published: it carries no recording to upload")
        }
        for kind in [VoiceSharingCollector.SignalKind.completed, .rejectedBleed, .rejectedWake] {
            let before = await queue.count()
            await sink.handle(event(kind))
            let after = await queue.count()
            XCTAssertEqual(after, before + 1, "\(kind) carries a real recording and must be published")
        }
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

    /// A collector whose gate and sink are the caller's. The default sink only RECORDS, which is
    /// fine for controls about the collector itself but is a trap for any control that asserts on
    /// what reaches the queue: a recording sink cannot create a queue entry, so its absence would
    /// prove nothing.
    private func makeCollector(
        isCollectionPermitted: @escaping () -> Bool = { true },
        sink: ((VoiceSharingCollector.SegmentEvent) -> Void)? = nil
    ) -> VoiceSharingCollector {
        let collector = VoiceSharingCollector(
            isCollectionPermitted: isCollectionPermitted,
            outcomeWaitLimit: .init(milliseconds: 60_000, ceilingMilliseconds: 60_000),
            membership: { [weak self] in self?.state ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { "epoch-1" },
            sessionIdentity: { "gen-A" },
            sink: sink ?? { [weak self] event in self?.collected.append(event) })
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
            liveOriginManager: CloudConversationManager(),
            analytics: VoiceAnalytics(analytics: BranchControlAnalytics()),
            contributionCollector: collector,
            isPlaybackActive: { false })
        return Harness(service: service, engine: engine, collector: collector)
    }

    /// Calls the production final composition step, then drops the builder and every local owner.
    /// Backend/router/audio are fixtures; no model loading, microphone or network is exercised.
    func test_serviceKeepsSharingAliveAfterTheAssemblyIsReleased() async throws {
        let suite = "sharing-lifetime-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VoiceSharingEnrollmentStore(defaults: defaults, accountScopeProvider: { "account-a" })
        store.setLocalOptIn(false)
        let collector = makeCollector()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); queue = nil }
        queue = VoiceSharingQueue(root: root)
        gateOpen = true
        var service: VoiceControlService?
        weak var weakAssembly: VoiceControlAssembly?
        weak var weakModel: VoiceSharingSettingsModel?
        weak var weakTrigger: VoiceSharingUploadTrigger?
        weak var weakLifetime: VoiceSharingLifetime?
        var published: [VoiceSharingSettingsModel.LiveState] = []
        do {
            let assembly = VoiceControlAssembly()
            weakAssembly = assembly
            let model = VoiceSharingSettingsModel(
                queue: queue, isCollectionPermitted: { false }, isAccountEnrolled: { false },
                isLocallyOptedIn: { store.currentState.localOptIn },
                coherenceAccount: { "account-a" })
            await model.refreshLiveState() // baseline only; no refresh after source mutation
            _ = model.addStateObserver { published.append($0.state) }
            weakModel = model
            let uploader = VoiceSharingUploader(
                queue: queue,
                send: { _, _ in XCTFail("no upload permitted"); return .noAnswer },
                refreshSignIn: { false },
                currentIdentity: { nil as (account: String, epoch: String)? },
                sharingEnabled: { false },
                now: Date.init)
            let trigger = VoiceSharingUploadTrigger(
                uploader: uploader, isAuthorized: { false })
            weakTrigger = trigger
            service = assembly.installVoiceSharingLifetime(
                on: makeService(router: StubClassifier(), executor: StubExecutor(), collector: collector).service,
                settingsModel: model, uploadTrigger: trigger,
                enrollmentStore: store, queue: queue)
            weakLifetime = service?.voiceSharingLifetime
        }
        XCTAssertNil(weakAssembly)
        XCTAssertNotNil(weakModel)
        XCTAssertNotNil(weakTrigger)
        XCTAssertNotNil(weakLifetime)
        // The surface flag follows the BUILD condition — a
        // STAGING build compiles it ON. Asserting one fixed value here contradicted the staging
        // configuration this suite runs under; the lifecycle claims below do not depend on the
        // surface either way, so the premise only pins the compilation condition.
        #if STAGING
        XCTAssertTrue(VoiceSharingSettingsModel.surfaceEnabled,
                      "premise: this suite runs under a STAGING build")
        #else
        XCTAssertFalse(VoiceSharingSettingsModel.surfaceEnabled)
        #endif
        store.setLocalOptIn(true)
        // The enrollment observer refreshes from a Task, so the publication is OWED rather than
        // synchronous. Waiting for it is the control; asserting straight after the mutation measured
        // the schedule, not the result.
        await waitUntil("the opt-in is published") { published.count == 1 }
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.last?.localOptIn, true)
        var retainedModel = weakModel
        service = nil
        XCTAssertNil(weakLifetime, "service must not cycle with its sharing dependencies")
        XCTAssertNil(weakTrigger)
        store.setLocalOptIn(false)
        // A leaked observer would publish here; give one the same chance it was given above.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(published.count, 1, "service teardown must remove the enrollment observer")
        XCTAssertNotNil(retainedModel, "retain the model so a leaked weak observer would still publish")
        retainedModel = nil
        XCTAssertNil(weakModel)
    }

    /// After consent loss through the real refresh → production registration path, nothing is
    /// retained and no request leaves the device.
    ///
    /// The claims are OUTCOMES, deliberately. Consent loss has two guards — the collector refuses to
    /// finalize a segment, and any pass that runs anyway deletes what it finds — and this control does
    /// not isolate either one: removing the collector's completion-time check leaves it green, because
    /// the second guard produces the same outcome. Isolation was tried and is not observable here; the
    /// spec accepts that, and defence in depth is intended, so the honest claim is the outcome rather
    /// than a mechanism this suite cannot name.
    ///
    /// The third outcome the spec names — an upload already in flight is CANCELLED — is not asserted
    /// here, because it needs a transfer genuinely in flight. It is covered by
    /// `VoiceSharingGateLossScopeControls.test_hActualLossCancelsARequestAlreadyOnTheWire`, which
    /// holds a real upload open at a URLProtocol until the transport cancels it and asserts that
    /// cancellation. (The older `test_f` proves only that an upload never STARTS: it stops at
    /// credential acquisition, and removing `cancelInFlight`'s `task?.cancel()` leaves it green.)
    func test_consentLossRetainsNoRecordingAndSendsNoRequest() async throws {
        let suite = "routing-lifetime-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "account-a" },
            sessionIdentityProvider: { "gen-A" })
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let samples: [Float] = [0, 0.25, -0.5, 0.5]
        let event = { VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(), enrollmentEpoch: "epoch-1",
            authorizationSession: "gen-A", retainedSamples: samples.count,
            truncated: false, droppedSpans: [], originalSampleCount: nil,
            audio: samples, isGateControl: false) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); queue = nil }
        queue = VoiceSharingQueue(root: root)
        var sink: VoiceSharingDirectSink!
        var trigger: VoiceSharingUploadTrigger?
        var collector: VoiceSharingCollector!
        var service: VoiceControlService?
        weak var weakLifetime: VoiceSharingLifetime?
        weak var weakTrigger: VoiceSharingUploadTrigger?
        weak var weakCollector: VoiceSharingCollector?
        weak var weakSink: VoiceSharingDirectSink?
        let seeded = try await AudioFixture.makeReadyEntry(in: queue)
        let seededDirectory = seeded.url
        let pendingCount = await queue.count()
        XCTAssertEqual(pendingCount, 1, "setup: one recording is retained")
        let registryBaseline = coordinator.gateLostHandlerCountForTesting

        do {
            let assembly = VoiceControlAssembly()
            let uploader = VoiceSharingUploader(
                queue: queue,
                send: { [weak self] _, _ in
                    // Counted, not asserted: the claim is an exact count of how many requests left,
                    // and a later one is expected after consent returns.
                    self?.withdrawnSendCount += 1
                    return .noAnswer
                },
                refreshSignIn: { true },
                currentIdentity: { ("account-a", "epoch-1") },
                sharingEnabled: { [weak self] in self?.gateOpen ?? false },
                now: Date.init)
            let t = VoiceSharingUploadTrigger(
                uploader: uploader, surfaceEnabled: { true },
                isAuthorized: { [weak self] in self?.gateOpen ?? false })
            trigger = t
            weakTrigger = t
            sink = VoiceSharingDirectSink(
                queue: queue, isEnabled: { [weak self] in self?.gateOpen ?? false },
                encoderProvenance: { self.provenance }, requestUploadDrain: {})
            weakSink = sink
            // The collector feeds the REAL sink and reads the same gate the rest of the pipeline
            // does. Without that connection a completed segment cannot reach the queue at all, so
            // "no queue entry" would hold whether or not consent was ever checked.
            collector = makeCollector(
                isCollectionPermitted: { [weak self] in self?.gateOpen ?? false },
                sink: { [weak self] event in
                    let capture: VoiceSharingDirectSink? = sink
                    // The Task is KEPT so the control can await it. A sleep would let a slow
                    // publication land after the assertion and make absence depend on timing.
                    self?.sinkWork.append(Task { await capture?.handle(event) })
                })
            weakCollector = collector
            let model = VoiceSharingSettingsModel(
                queue: queue, isCollectionPermitted: { [weak self] in self?.gateOpen ?? false },
                isAccountEnrolled: { true }, isLocallyOptedIn: { false },
                coherenceAccount: { "account-a" })
            assembly.installVoiceSharingGateLoss(
                collector: collector, uploadTrigger: t,
                queue: queue, coordinator: coordinator)
            service = assembly.installVoiceSharingLifetime(
                on: makeService(router: StubClassifier(), executor: StubExecutor(), collector: collector).service,
                settingsModel: model, uploadTrigger: t,
                enrollmentStore: store, queue: queue)
            weakLifetime = service?.voiceSharingLifetime
        }
        XCTAssertEqual(coordinator.gateLostHandlerCountForTesting, registryBaseline + 1)

        // A capture is opened while consent is still real, so the completion below has a genuine
        // in-progress segment to refuse. Opening it AFTER the loss would be refused at
        // `speechStarted` and would say nothing about the completion path.
        guard let openContext = collector.speechStarted(confirmationFrameSamples: 640) else {
            return XCTFail("setup: a permitted collector must open a capture")
        }


        // Consent ends through the PRODUCTION fan-out, exactly as a withdrawal or sign-out reaches
        // every pipeline owner.
        gateOpen = false
        coordinator.consentGateLostForTesting()
        XCTAssertFalse(isCollectionPermitted())
        await waitUntil("the retained bytes are purged") {
            !FileManager.default.fileExists(atPath: seededDirectory.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seededDirectory.path),
                       "retained bytes must be purged")
        let entriesAfterPurge = await queue.entries()
        XCTAssertTrue(entriesAfterPurge.isEmpty)
        await sink.handle(event())
        let entriesAfterDisable = await queue.entries()
        XCTAssertTrue(entriesAfterDisable.isEmpty, "new sink work must be refused after disable")
        // WHAT THE SPEC REQUIRES AFTER CONSENT LOSS IS BEHAVIOUR, NOT OBJECT LIFETIMES (:15, :146):
        // no new recording may be kept, no request may leave, and a request already in flight must be
        // cancelled. Whether an object is still resident is not a claim this suite can make — the
        // retention assertions here were measuring ARC and the build configuration, not consent.
        //
        // A segment opened before the loss and closed after it must be kept nowhere. The collector is
        // wired to the REAL sink here, so a segment that survived would become a QUEUE ENTRY — not
        // merely an in-memory event this suite happens to hold.
        //
        // The completion is refused at the first guard it meets, not at one in particular: consent
        // loss has already made the open capture terminal, so the late outcome is emitted as a
        // cancellation and the sink drops it. Isolation between those guards is not observable, and
        // the spec accepts the outcome instead of a named mechanism.
        collector.speechCompleted([Float](repeating: 0.4, count: 16_000), context: openContext)
        // Await the sink deliveries themselves. A late publication can otherwise land after this
        // assertion and the empty queue would be the scheduler's timing, not consent's decision.
        await settleSinkDeliveries()
        let entriesAfterConsentLoss = await queue.entries()
        XCTAssertTrue(entriesAfterConsentLoss.isEmpty,
                      "a segment completed after consent loss must be kept nowhere")

        // A trigger must produce no request — with work of its own to refuse, so a zero here is
        // authorization being checked and not an empty queue.
        let sentBefore = withdrawnSendCount
        _ = try await AudioFixture.makeReadyEntry(in: queue)
        let refusedWork = await queue.count()
        XCTAssertEqual(refusedWork, 1, "setup: the refusal below must have a recording to refuse")
        trigger?.trigger()
        await waitUntil("the post-consent-loss pass settles", timeout: 2) {
            !(trigger?.hasPendingOrRunningWorkForTesting ?? false)
        }
        XCTAssertEqual(withdrawnSendCount, sentBefore,
                       "no upload request may leave after consent loss")
        // The behaviour above is the contract. A registration or a resident object still being held
        // is NOT part of it: the spec asks what the app stops doing, not which objects ARC has yet to
        // free, and this suite has no way to distinguish a live owner from an unreleased one.
        service = nil
    }

    /// Actual enrollment completion feeds the production upload builder after assembly release.
    func test_enrollmentAndConfiguredUploadRetryThroughTheServiceOwnedComposition() async throws {
        let authority = try SharingLocalAuthority()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        addTeardownBlock {
            session.invalidateAndCancel()
            authority.stop()
            await self.fulfillment(of: [authority.stopped], timeout: 2)
        }
        await fulfillment(of: [authority.ready], timeout: 2)
        let endpoint = authority.baseURL
        XCTAssertFalse(endpoint.hasSuffix(":0"))
        let suite = "configured-sharing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "local-account" }, sessionIdentityProvider: { "local-session" })
        store.setLocalOptIn(true)
        _ = VoiceSharingCoordinator(enrollmentStore: store)
        let identity: () -> (account: String, epoch: String)? = {
            guard let epoch = store.activeEnrollmentEpoch else { return nil }
            return ("local-account", epoch)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("configured-sharing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); queue = nil }
        var now = Date()
        // The queue must read the SAME clock the uploader does. With the queue on the default clock,
        // its retry deadline is written in real time while the test advances only the injected clock,
        // so the entry never becomes due and the retry under test never happens.
        queue = VoiceSharingQueue(root: root, now: { now })
        let tokens = LocalSharingToken()
        let accountClient = VoiceSharingAccountClient(
            baseURLProvider: { endpoint }, tokenProvider: tokens, session: session,
            sessionIdentity: { "local-session" }, membershipStore: store)
        var service: VoiceControlService?
        weak var weakAssembly: VoiceControlAssembly?
        weak var weakTrigger: VoiceSharingUploadTrigger?
        do {
            let assembly = VoiceControlAssembly()
            weakAssembly = assembly
            let trigger = assembly.makeVoiceSharingUploadTrigger(
                queue: queue, isAuthorized: { [weak self] in self?.gateOpen ?? false }, currentIdentity: identity,
                baseURLProvider: { endpoint }, tokenProvider: tokens, session: session, clock: { now },
                surfaceEnabled: { true })
            weakTrigger = trigger
            let model = VoiceSharingSettingsModel(
                queue: queue, isCollectionPermitted: { [weak self] in self?.gateOpen ?? false },
                isAccountEnrolled: { store.currentEnrollmentAnswer },
                isLocallyOptedIn: { store.currentState.localOptIn }, coherenceAccount: { "local-account" })
            service = assembly.installVoiceSharingLifetime(
                on: makeService(router: StubClassifier(), executor: StubExecutor(), collector: makeCollector()).service,
                settingsModel: model, uploadTrigger: trigger, enrollmentStore: store,
                queue: queue)
        }
        defer { weakTrigger?.stop(); service = nil }
        XCTAssertNil(weakAssembly)
        XCTAssertNotNil(weakTrigger)
        XCTAssertEqual(tokens.value, "local-test-bearer")
        XCTAssertNil(store.currentEnrollmentAnswer)
        gateOpen = true
        await VoiceSharingCoordinator(enrollmentStore: store).refreshProjectionFromServer(accountClient: accountClient)
        XCTAssertTrue(store.currentEffectiveEnrolled)
        let entry = try await AudioFixture.makeReadyEntry(in: queue)
        let metadata = try Data(contentsOf: entry.metadataURL)
        let audio = try Data(contentsOf: entry.audioURL)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        let expectedCaptureID = try XCTUnwrap(record["capture_id"] as? String)
        // THE FIRST PASS UPLOADS. The upload gate is the ordinary session plus the sharing choice;
        // there is no lease and no second projection read to wait for, and the server's accept check
        // is what decides (spec :7). This control used to require a second refresh before any bytes
        // left, which is a precondition the contract no longer has — the app was right and the
        // assertion was stale.
        //
        // The claim is about THIS recording: the trigger is one shared loop, so the pass my trigger
        // joined may be serving an older recording entirely.
        weakTrigger?.trigger()
        await joinLocalSharingDrain(weakTrigger)
        await waitUntil("the first-pass attempt for this recording") {
            authority.received.contains { $0.captureID == expectedCaptureID }
        }
        XCTAssertEqual(authority.received.map(\.captureID), [expectedCaptureID],
                       "signed in and sharing on, this recording uploads on the first pass")
        // No second refresh was needed, so the projection was read once.
        XCTAssertEqual(authority.lookupCount, 1)
        XCTAssertEqual(try Data(contentsOf: entry.metadataURL), metadata, "503 retains exact immutable metadata")
        XCTAssertEqual(try Data(contentsOf: entry.audioURL), audio, "503 retains exact immutable WAV")
        let pendingEntries = await queue.entries()
        XCTAssertEqual(pendingEntries.count, 1)
        // Past the backoff the entry is due again. The wait is for the ATTEMPT, not for the pass
        // the join happened to cover: the trigger is one shared loop and its pass may already have
        // finished before this recording was due.
        now = now.addingTimeInterval(2)
        // Each refused attempt doubles the backoff (60s, then 120s), so the second deadline is
        // two minutes after the SECOND refusal. Advancing by a fixed small step here asserted a
        // number the backoff does not promise; the wait below advances the clock past whatever the
        // queue reports as the next deadline, which is what "past the backoff" actually means.
        if let remaining = await queue.secondsUntilNextRetry() {
            now = now.addingTimeInterval(remaining + 1)
        }
        // The pass that just finished may still hold the in-memory backoff it scheduled BEFORE the
        // clock moved, so a trigger landing on it is only REMEMBERED. Triggering through the loop
        // until the attempt is observed keeps the claim about the retry and not about how many
        // passes it took — each retry attempt is a real request over the wire.
        await waitUntil("the retry attempt") {
            weakTrigger?.trigger()
            return authority.received.count == 2
        }
        await joinLocalSharingDrain(weakTrigger)
        let attempts = authority.received
        XCTAssertEqual(attempts.count, 2)
        for attempt in attempts {
            XCTAssertEqual(attempt.metadata, metadata)
            XCTAssertEqual(attempt.audio, audio)
            XCTAssertEqual(attempt.captureID, expectedCaptureID)
            XCTAssertEqual(attempt.bearer, "Bearer local-test-bearer")
        }
        let entriesAfterSettle = await queue.entries()
        XCTAssertTrue(entriesAfterSettle.isEmpty, "matching received-body-derived receipt settles the entry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path))

        // The retry that just succeeded took its entry with it, so the refusal below needs work of
        // its own to refuse. Without a recording the pass would have nothing to send and the "nothing
        // was sent" claim would hold for the wrong reason — a negative explained by an empty queue.
        _ = try await AudioFixture.makeReadyEntry(in: queue)
        let refreshedEntries = await queue.entries()
        XCTAssertEqual(refreshedEntries.count, 1, "setup: one recording is waiting to be refused")
        let sendsBeforeWithdrawal = authority.received.count
        store.setLocalOptIn(false)
        XCTAssertFalse(store.consentAllowsCollection)
        weakTrigger?.trigger()
        await joinLocalSharingDrain(weakTrigger)
        XCTAssertEqual(authority.received.count, sendsBeforeWithdrawal,
                       "configured work cannot send after local withdrawal")
        // A refused recording is not kept for later: the uploader deletes it rather than uploading it
        // on some future pass. So the count goes DOWN, and the queue being empty here is evidence the
        // refusal was handled as the spec says — not the empty-queue artefact that would make the
        // send count meaningless.
        let entriesAfterWithdrawal = await queue.entries()
        XCTAssertTrue(entriesAfterWithdrawal.isEmpty,
                      "a recording refused for lack of consent is not retained")
        service = nil
        // `surfaceEnabled` follows the BUILD condition (a staging build compiles the surface ON), so
        // it says nothing about this control's subject. The claims above are about the upload path.
    }

    /// Waits for a condition that work OFF the calling thread is going to satisfy. The production
    /// paths this suite drives hand their writes to a Task, so a control that asserted immediately
    /// would be measuring the scheduler rather than the behaviour.
    @discardableResult
    private func waitUntil(
        _ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if !condition() { XCTFail("\(what) did not happen within \(timeout)s") }
        return condition()
    }

    private func joinLocalSharingDrain(_ trigger: VoiceSharingUploadTrigger?) async {
        // The simple trigger runs its pass on its own task and exposes no handle; wait for it to
        // become idle rather than reaching into it.
        guard let trigger else { return }
        for _ in 0..<80 where trigger.hasPendingOrRunningWorkForTesting {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(trigger.hasPendingOrRunningWorkForTesting, "the configured drain must finish")
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

    /// A RECORD IS BUILT FROM THE STAGES THAT ALREADY HAPPENED, SO EARLY PUBLICATION LOSES THEM.
    ///
    /// Routing and execution are reported onto the capture's context, and the honest record is whatever
    /// the collector holds when the segment closes. A control that closed the segment first and called
    /// the service afterwards would be asserting on an empty record for its own sequencing reasons —
    /// which is why every branch control here routes and executes first, then finishes the capture.
    /// This control pins that order itself: one segment closes the collection while the capture is
    /// still open and ASR is still working, and that record must carry NO routing or execution yet. If
    /// the collector published either earlier, the stage order of the pipeline would be an illusion.
    func test_aRecordPublishedBeforeRoutingCarriesNoRoutingOrExecutionStage() async {
        collected = []
        let router = StubClassifier()
        let executor = StubExecutor()
        let collector = makeCollector()
        let harness = makeService(router: router, executor: executor, collector: collector)
        guard let context = await openRealCapture(harness) else {
            return XCTFail("a real open capture is required")
        }
        harness.collector.speechCompleted(
            [Float](repeating: 0.4, count: 16_000), context: context, deferEmission: true)
        harness.collector.finalizeDeferredCompletion(context: context)
        let stages = publishedStages(for: context.id)
        XCTAssertEqual(router.classifyCalls, 0,
                       "a control that expected nothing would also pass on a classification that ran anyway")
        for stage in ["routing", "execution"] {
            XCTAssertNil(stages[stage],
                         "a record closed before the turn routed must not carry a \(stage) stage, got "
                         + "\(String(describing: stages[stage]?.state))")
        }
    }

    /// EVERY NAME THE MAPPING EMITS MUST PARSE BACK THROUGH THE APP'S OWN FORWARD MAPPER.
    ///
    /// A representative test per family passes while an individual name is wrong — that is exactly
    /// how the Android lane shipped three invented action names past its family coverage. This walks
    /// the whole emitted set, feeds each name back through `ToolCallMapper` as the tool call the model
    /// would have produced, and requires the same tool and action to come out. A name the forward
    /// mapper cannot produce is not part of the vocabulary every other consumer uses, so it is not a
    /// name this app may record. `cloud_route` is the one exception the spec names explicitly.
    func test_everyEmittedIntentNameParsesBackThroughTheForwardMapper() {
        let mapper = ToolCallMapper()
        // A representative instance of every case, so the emitted set is the mapping's real range.
        let intents: [any VoiceIntent] = [
            PlaybackIntent.pause, PlaybackIntent.resume,
            PlaybackIntent.seekRelative(deltaSeconds: 15, direction: .forward),
            PlaybackIntent.seekTo(positionSeconds: 60), PlaybackIntent.nextEpisode,
            EffectsIntent.setSpeed(1), EffectsIntent.adjustSpeed(delta: 0.1),
            EffectsIntent.setTrimMode(.low), EffectsIntent.setVolumeBoost(enabled: true), EffectsIntent.query,
            VolumeIntent.setVolume(1), VolumeIntent.adjustVolume(delta: 1), VolumeIntent.query,
            SleepIntent.set(minutes: 1), SleepIntent.endOfEpisode, SleepIntent.endOfChapter,
            SleepIntent.addTime(minutes: 1), SleepIntent.cancel, SleepIntent.query,
            ChapterIntent.next, ChapterIntent.previous, ChapterIntent.byIndex(1),
            ChapterIntent.byTitle("t"), ChapterIntent.openLink(index: nil, query: nil),
            ChapterIntent.queryList, ChapterIntent.queryCurrent, ChapterIntent.queryCount, ChapterIntent.queryNext,
            BookmarkIntent.add(title: nil), BookmarkIntent.rename(ref: "r", title: "t"),
            BookmarkIntent.play(ref: "r"), BookmarkIntent.delete(ref: "r"), BookmarkIntent.deleteAll,
            BookmarkIntent.queryList, BookmarkIntent.queryCount, BookmarkIntent.queryNearby,
            QueueIntent.addTop(episode: "e"), QueueIntent.addBottom(episode: "e"), QueueIntent.remove(episode: "e"),
            QueueIntent.moveToTop(episode: "e"), QueueIntent.moveToBottom(episode: "e"), QueueIntent.clear,
            QueueIntent.removeByPodcast(podcast: "p"), QueueIntent.sort(sortOrder: .newestFirst),
            QueueIntent.queryContents, QueueIntent.queryNext, QueueIntent.queryLength,
            QueueIntent.queryIsQueued(episode: "e"),
            PlaybackQueryIntent.whatsPlaying, PlaybackQueryIntent.position, PlaybackQueryIntent.timeRemaining,
            PlaybackQueryIntent.episodeDuration, PlaybackQueryIntent.publishDate,
            PlaybackQueryIntent.episodeDescription, PlaybackQueryIntent.downloadStatus,
            PlaybackQueryIntent.episodeTitle,
            StatsQueryIntent.listeningTime(period: nil), StatsQueryIntent.topPodcasts(period: nil),
            StatsQueryIntent.episodesFinished(period: nil), StatsQueryIntent.listeningStreak,
            StatsQueryIntent.subscriptionCount, StatsQueryIntent.unplayedTotal,
            StatsQueryIntent.downloadStats, StatsQueryIntent.newEpisodes(timeframe: nil),
            StatsQueryIntent.timeSinceLastListen,
            CloudRouteIntent(request: "anything", tier: .unknown),
        ]
        for intent in intents {
            guard let name = VoiceAnalytics.predictedIntentName(from: intent) else {
                return XCTFail("\(type(of: intent)): a routed intent must be named")
            }
            if name == "cloud_route" {
                XCTAssertTrue(intent is CloudRouteIntent, "cloud_route is the cloud route's whole name")
                continue
            }
            let parts = name.split(separator: ".", maxSplits: 1)
            XCTAssertEqual(parts.count, 2, "\(name): a routed name is <tool>.<action>")
            guard parts.count == 2 else { continue }
            // Arguments a REAL call of this action carries. Supplying none where the mapper requires
            // one would fail the parse for the fixture's sake, not the name's — `seek_to` needs a
            // position, and a control that omitted it would call a valid name invented.
            let requiredArguments: [String: Any]
            switch (String(parts[0]), String(parts[1])) {
            case ("playback", "seek_to"): requiredArguments = ["position_seconds": 60]
            case ("effects", "set_speed"): requiredArguments = ["speed": 1.5]
            case ("effects", "set_trim_mode"): requiredArguments = ["mode": "low"]
            case ("effects", "set_volume_boost"): requiredArguments = ["enabled": true]
            case ("volume", "set_volume"): requiredArguments = ["volume": 70]
            case ("sleep", "set"), ("sleep", "add_time"): requiredArguments = ["minutes": 10]
            case ("chapter", "by_index"): requiredArguments = ["index": 1]
            case ("chapter", "by_title"): requiredArguments = ["query": "chapter two"]
            case ("bookmark", "rename"): requiredArguments = ["ref": "r", "title": "t"]
            case ("bookmark", "play"), ("bookmark", "delete"): requiredArguments = ["ref": "r"]
            case ("queue", "add_top"), ("queue", "add_bottom"), ("queue", "remove"),
                 ("queue", "move_to_top"), ("queue", "move_to_bottom"),
                 ("queue", "query_is_queued"): requiredArguments = ["episode": "e"]
            case ("queue", "remove_by_podcast"): requiredArguments = ["podcast": "p"]
            case ("queue", "sort"): requiredArguments = ["sort_order": "newestFirst"]
            default: requiredArguments = [:]
            }
            let call = ToolCall(name: String(parts[0]),
                                arguments: requiredArguments.merging(["action": String(parts[1])]) { $1 })
            guard let parsed = mapper.map(call) else {
                return XCTFail("\(name): the forward mapper cannot produce this name — it is invented")
            }
            XCTAssertEqual(VoiceAnalytics.predictedIntentName(from: parsed), name,
                           "\(name): the name does not survive a round trip through the mapper")
        }
    }

    /// An intent the canonical mapping does not recognise. It exists only to stand for the
    /// no-routed-intent case in the control below.
    private struct UnroutableProbe: VoiceIntent {}

    /// A NAME FIELD CARRIES NAMES, NOT THE USER'S WORDS.
    ///
    /// `routing.predicted_intent` is a name the spec uses to build `route-<intent>` (`:126`), and a
    /// cloud route's `request` is "the complete user utterance or resolved multi-turn request"
    /// (`ToolSchema.cloudRouteTool`). Naming a route by its request therefore writes the transcript
    /// into the record's name field — and a routing-failure fallback carries it verbatim. The control
    /// drives a model-chosen route whose utterance is distinctive, so any content leak is visible
    /// rather than merely possible.
    func test_aCloudRouteIsNamedByItsActionAndNeverByItsRequest() async {
        collected = []
        let router = StubClassifier()
        let executor = StubExecutor()
        let collector = makeCollector()
        let harness = makeService(router: router, executor: executor, collector: collector)
        let service = harness.service
        guard let context = await openRealCapture(harness) else {
            return XCTFail("a real open capture is required")
        }
        let utterance = "queue three episodes about otters for my sister in law"
        service.enterListeningStateForTesting()
        router.result = .intent(CloudRouteIntent(request: utterance, tier: .unknown))
        executor.response = .spoken("ok")
        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: utterance, utteranceId: UUID().uuidString, acousticWakeOnly: nil),
            captureContext: context)
        finishCapture(harness, context)

        let routing = publishedStages(for: context.id)["routing"]
        XCTAssertEqual(routing?.predictedIntent, "cloud_route",
                       "a cloud route is the whole value, alone — not with an action")
        XCTAssertEqual(routing?.predictedTool, "cloud_route")
        // The claim that matters: no part of what the user said reaches a name field.
        for word in utterance.split(separator: " ").map(String.init) where word.count > 3 {
            XCTAssertFalse(routing?.predictedIntent?.contains(word) ?? false,
                           "the name field must not carry request content (\(word))")
        }
    }

    /// EVERY intent family is named, not just playback. The mapping used to handle `PlaybackIntent`
    /// alone, so effects, volume, sleep, chapter, bookmark, queue and both query families all
    /// reported `unknown` — and a nonempty check accepted `unknown` as coverage.
    func test_everyIntentFamilyReportsItsOwnCanonicalActionName() {
        let cases: [(any VoiceIntent, String, String)] = [
            (PlaybackIntent.pause, "playback", "pause"),
            (PlaybackIntent.seekRelative(deltaSeconds: 30, direction: .backward), "playback", "seek_relative"),
            (EffectsIntent.setSpeed(1.5), "effects", "set_speed"),
            (EffectsIntent.query, "effects", "query"),
            // A data-carrying case: the value is an argument and must not appear in the name.
            (VolumeIntent.setVolume(70), "volume", "set_volume"),
            (SleepIntent.addTime(minutes: 10), "sleep", "add_time"),
            (ChapterIntent.byTitle("Chapter Two"), "chapter", "by_title"),
            (BookmarkIntent.rename(ref: "jumping", title: "my bookmark"), "bookmark", "rename"),
            (QueueIntent.addTop(episode: "the last one"), "queue", "add_top"),
            (PlaybackQueryIntent.timeRemaining, "playback_query", "time_remaining"),
            (StatsQueryIntent.listeningTime(period: "this week"), "stats_query", "listening_time"),
            // A cloud route is the whole value ALONE — never `<tool>.<action>`, never request text.
            (CloudRouteIntent(request: "anything at all", tier: .unknown), "cloud_route", ""),
        ]
        var seen = Set<String>()
        for (intent, tool, action) in cases {
            let expected = action.isEmpty ? tool : "\(tool).\(action)"
            // The EXACT recorded value: dotted, schema spelling, and nothing else in it.
            XCTAssertEqual(VoiceAnalytics.predictedIntentName(from: intent), expected,
                           "\(expected): wrong predicted_intent")
            XCTAssertEqual(VoiceAnalytics.predictedToolName(from: intent), tool,
                           "\(expected): wrong predicted_tool")
            // The server adds the `route-` prefix to the folder name; a value that already carries it
            // produces `route-route-...`.
            XCTAssertFalse(expected.hasPrefix("route-"), "\(expected): the server owns the prefix")
            seen.insert(expected)
        }
        XCTAssertEqual(seen.count, cases.count, "each case must name a distinct value")

        // A routed name is derived from the TYPE and ACTION only. The data-carrying cases above
        // already prove the name ignores their arguments; this pins the one member that is free-form
        // request text.
        let named = VoiceAnalytics.predictedIntentName(from: CloudRouteIntent(request: "anything", tier: .unknown))
        XCTAssertEqual(named, "cloud_route")
        // A turn that was not routed names nothing: absence is the contract, not a placeholder.
        XCTAssertNil(VoiceAnalytics.predictedIntentName(from: UnroutableProbe()),
                     "a turn with no canonical name must leave the member absent")
    }

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
            /// Whether this turn reaches the executor at all. The router-declined case is refused by
            /// policy BEFORE execution, so nothing was executed and nothing can state a verdict.
            var executed: Bool = true
        }
        let cases: [Case] = [
            // RESTORED after a withdrawn first cut: my intermediate version
            // reported a success tone as completed — but a success-shaped presentation cannot
            // prove action completion, so the honest verdict stays unknown until sinks report
            // structured facts from their action results. stands: only the
            // executor's own error verdict concludes anything today.
            Case(label: "intent succeeded, result unobserved", result: .intent(PlaybackIntent.pause),
                 response: .earcon(.success), routingDisposition: "pending",
                 executionState: "unknown", executionReason: "observation_unavailable"),
            // The executor's OWN failure verdict: it logs "Command failed" and withholds the grace
            // period on exactly this value, so this one conclusion comes from the executor.
            Case(label: "intent action failed", result: .intent(PlaybackIntent.pause),
                 response: .earcon(.error), routingDisposition: "failed",
                 executionState: "failed", executionReason: "action_failed"),
            // `.silent` is a PRESENTATION choice (resume succeeds silently), so it must not be
            // read as a refusal either — and not as a completion, for the same reason.
            Case(label: "silent response, result unobserved", result: .intent(PlaybackIntent.pause),
                 response: .silent, routingDisposition: "pending",
                 executionState: "unknown", executionReason: "observation_unavailable"),
            // The router declined: nothing to execute.
            // The router declined, and this window has no escalation budget, so the dispatch the service
            // would otherwise make is refused by policy: nothing executed, and the reason says which
            // precondition failed rather than blaming the user.
            Case(label: "no intent", result: .none,
                 response: .spoken("unused"), routingDisposition: "not_run",
                 executionState: "not_run", executionReason: "client_refused",
                 executed: false),
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
                IntentRoutingInput.english(transcript: "skip back thirty seconds", utteranceId: UUID().uuidString, acousticWakeOnly: nil),
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
            // PRODUCER bindings: the classification names come from the SAME
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
            // The verdict is a CLOSED set, and an ABSENT verdict is its own honest claim: the
            // encoder states `unknown`/`observation_unavailable` for a listed stage it was never told
            // about, so an executed turn with nothing to conclude must OMIT the member rather than
            // leave it empty. An execution the app itself skipped has no verdict to give either — a
            // reason saying why it did not run is its whole statement.
            if testCase.executionState == "unknown" || !testCase.executed {
                XCTAssertNil(execution.outcome,
                             "\(testCase.label): no verdict is possible, so the member must be omitted")
            } else {
                XCTAssertFalse(execution.outcome?.isEmpty ?? true,
                               "\(testCase.label): a concluded execution must state its verdict")
            }
        }
    }

    /// A DECLINED ACTION IS AN OBSERVED OUTCOME, NOT A GAP.
    ///
    /// The sink's structured fact for a declined skip is `not_run`/`precondition_failed` — the
    /// executor observed the decision and can state exactly what happened. The service used to
    /// substitute `unknown`/`observation_unavailable` for every verdict without a wire token,
    /// discarding that observation: the record claimed nothing could be seen when the app had in
    /// fact declined. The substitution is owed only to a verdict that states nothing
    /// (`state == "unknown"`); an observed not_run passes through as itself.
    func test_aDeclinedSkipPublishesItsObservedVerdictRatherThanUnobserved() async {
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
        router.result = .intent(PlaybackIntent.pause)
        executor.response = .spoken("Playback: nothing queued")
        // The real sink's declined fact, stated at the executor's verdict seam.
        executor.verdictOverride = ExecutionVerdict(state: "not_run", reason: "precondition_failed")
        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "skip to the next episode", utteranceId: UUID().uuidString, acousticWakeOnly: nil),
            captureContext: context)
        finishCapture(harness, context)

        let execution = publishedStages(for: id)["execution"]
        guard let execution else {
            return XCTFail("the record must carry the execution stage")
        }
        XCTAssertEqual(execution.state, "not_run",
                       "a declined action is observed: the record states the decline")
        XCTAssertEqual(execution.reason, "precondition_failed",
                       "the decline's own reason survives, not a claim that nothing was seen")
        XCTAssertNil(execution.outcome,
                     "not_run carries no wire token: the member is omitted, not invented")
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
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "skip back", utteranceId: UUID().uuidString, acousticWakeOnly: nil),
                                         captureContext: context)
        finishCapture(harness, context)

        let stages = publishedStages(for: id)
        XCTAssertNotNil(stages["execution"],
                        "the capture must still publish its execution observation, got "
                            + "\(stages.keys.sorted())")
        XCTAssertNotNil(stages["routing"], "routing must be on the record")
    }

    /// #2: the debounce skip must settle the capture with an ENUMERATED reason. The
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
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "pause", utteranceId: UUID().uuidString, acousticWakeOnly: nil),
                                         captureContext: first)
        finishCapture(harness, first)
        let firstStages = publishedStages(for: first.id)
        // RESTORED premise: the first turn's verdict is the executor's, and a non-error
        // presentation is still unobserved — completed was withdrawn.
        XCTAssertEqual(firstStages["execution"]?.state, "unknown",
                       "premise: the first turn ran and its result is unobserved")
        XCTAssertEqual(executor.executed.count, 1, "premise: the first turn reached the executor")

        // Second identical turn inside the debounce window: suppressed, and must still PUBLISH.
        guard let second = await openRealCapture(harness) else {
            return XCTFail("a real open capture is required")
        }
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "pause", utteranceId: UUID().uuidString, acousticWakeOnly: nil),
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

    /// A blank or wake-only transcript is a session start, not a failed question: routing is not run and
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
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "   ", utteranceId: UUID().uuidString, acousticWakeOnly: nil),
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
/// Loopback-only account/intake authority. All network state lives on one serial queue.
private final class SharingLocalAuthority {
    struct Upload {
        let metadata: Data
        let audio: Data
        let captureID: String
        let bearer: String?
    }
    let ready = XCTestExpectation(description: "local authority listening")
    let stopped = XCTestExpectation(description: "local authority stopped and connections joined")
    private let listener: NWListener
    private let work = DispatchQueue(label: "sharing-local-authority")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var cancelled = false
    private var stopReported = false
    private var uploads: [Upload] = []
    private var gets = 0
    private var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.port = self.listener.port?.rawValue ?? 0
                self.ready.fulfill()
            }
            if case .cancelled = state { self.cancelled = true; self.reportStop() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: work)
    }

    var baseURL: String { work.sync { "http://127.0.0.1:\(port)" } }
    var received: [Upload] { work.sync { uploads } }
    var lookupCount: Int { work.sync { gets } }

    func stop() {
        work.async {
            self.listener.cancel()
            for connection in self.connections.values { connection.cancel() }
            self.reportStop()
        }
    }

    private func reportStop() {
        if cancelled && connections.isEmpty && !stopReported {
            stopReported = true
            stopped.fulfill()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            if case .ready = state, let connection { self.receive(connection, accumulated: Data()) }
            if case .cancelled = state { self.connections[id] = nil; self.reportStop() }
            if case .failed = state { connection?.cancel() }
        }
        connection.start(queue: work)
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak connection] bytes, _, complete, error in
            guard let self, let connection else { return }
            var raw = accumulated
            if let bytes { raw.append(bytes) }
            guard raw.count <= 2 << 20 else { connection.cancel(); return }
            if let split = raw.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
                let isGet = head.hasPrefix("GET ")
                if isGet || (VoiceSharingAttemptedIdentity.declaredContentLength(raw).map { raw.count >= $0 } ?? false) {
                    let response = self.respond(head: head, body: Data(raw[split.upperBound...]))
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if complete || error != nil { connection.cancel() }
            else { self.receive(connection, accumulated: raw) }
        }
    }

    private func respond(head: String, body: Data) -> Data {
        do {
            func header(_ name: String) -> String? {
                head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                    .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
            }
            guard header("Authorization") == "Bearer local-test-bearer" else {
                return try response(401, object: [:])
            }
            if head.hasPrefix("GET /api/v1/account/voice-sharing ") {
                gets += 1
                return try response(200, object: [
                    "schema_version": 1, "plan": "pro",
                    "voice_sharing_enrolled": true, "enrollment_epoch": "epoch-1",
                    // BOTH members are required by the schema. Serving only the first made the
                    // decoder reject the whole body as an impossible combination, so no authority
                    // was ever applied — and every assertion after it was reading a client that had
                    // correctly declined to trust an incomplete answer.
                    "accepted_disclosure_version": "voice-sharing-v1",
                    "disclosure_version": "voice-sharing-v1", "withdrawal_state": "active"
                ])
            }
            guard head.hasPrefix("POST /api/v1/voice-recordings ") else { return try response(404, object: [:]) }
            let contentType = try XCTUnwrap(header("Content-Type"))
            let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
            let delimiter = Data("\r\n--\(boundary)".utf8)
            var parts: [String: Data] = [:]
            var cursor = Data("--\(boundary)\r\n".utf8).count
            while cursor < body.count, let headerEnd = body.range(of: Data("\r\n\r\n".utf8), in: cursor..<body.count),
                  let end = body.range(of: delimiter, in: headerEnd.upperBound..<body.count) {
                let partHead = String(decoding: body[cursor..<headerEnd.lowerBound], as: UTF8.self)
                let name = partHead.contains("name=\"metadata\"") ? "metadata" : "audio"
                guard parts[name] == nil else { throw URLError(.cannotParseResponse) }
                parts[name] = Data(body[headerEnd.upperBound..<end.lowerBound])
                cursor = end.upperBound
                if body[cursor...].starts(with: Data("--".utf8)) { break }
                cursor += 2 // CRLF after the boundary
            }
            let metadata = try XCTUnwrap(parts["metadata"])
            let audio = try XCTUnwrap(parts["audio"])
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
            let captureID = try XCTUnwrap(record["capture_id"] as? String)
            // Reuse the strict existing multipart identity extractor as an independent identity check.
            // The record itself is the identity: read it the way the server does.
            uploads.append(Upload(metadata: metadata, audio: audio,
                                  captureID: captureID, bearer: header("Authorization")))
            if uploads.count == 1 { return try response(503, object: [:]) }
            return try response(201, object: ["capture_id": captureID])
        } catch {
            XCTFail("local authority rejected request: \(error)")
            return Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
    }
    private var baseURLForRequest: String { "http://127.0.0.1:\(port)/api/v1/voice-recordings" }
    private func response(_ code: Int, object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object)
        var response = Data("HTTP/1.1 \(code) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        return response
    }
}

private final class LocalSharingToken: CloudTokenProviding {
    let value = "local-test-bearer"
    func token() async -> String? { value }
    func prepare() async {}
    func handleUnauthorized(rejectedToken: String?) async {}
}
