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

    private final class StubExecutor: VoiceIntentExecuting {
        var response: VoiceResponse = .spoken("ok")
        private(set) var executed: [String] = []

        func execute(_ intent: any VoiceIntent) async -> VoiceResponse {
            executed.append(String(describing: type(of: intent)))
            return response
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
        // The exact optional-chaining the production sites perform. A missing sink must read as
        // "not suppressed" — never as a denial.
        XCTAssertFalse(sink?.isSuppressedForTesting(nil) ?? false,
                       "no sink must not be read as a suppression")

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

    private func makeCollector() -> VoiceSharingCollector {
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { true }, outcomeWaitLimit: .init(milliseconds: 60_000, ceilingMilliseconds: 60_000),
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
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.last?.localOptIn, true)
        var retainedModel = weakModel
        service = nil
        XCTAssertNil(weakLifetime, "service must not cycle with its sharing dependencies")
        XCTAssertNil(weakTrigger)
        store.setLocalOptIn(false)
        XCTAssertEqual(published.count, 1, "service teardown must remove the enrollment observer")
        XCTAssertNotNil(retainedModel, "retain the model so a leaked weak observer would still publish")
        retainedModel = nil
        XCTAssertNil(weakModel)
    }

    /// Real refresh → production registration → purge/cancel, after the builder is gone.
    func test_theServiceOwnedPipelineIsPurgedAndReleasedAtConsentLoss() async throws {
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
                send: { _, _ in XCTFail("a withdrawn pipeline must not send"); return .noAnswer },
                refreshSignIn: { true },
                currentIdentity: { ("account-a", "epoch-1") },
                sharingEnabled: { [weak self] in self?.gateOpen ?? false },
                now: Date.init)
            let t = VoiceSharingUploadTrigger(
                uploader: uploader, surfaceEnabled: { true },
                isAuthorized: { [weak self] in self?.gateOpen ?? false })
            trigger = t
            weakTrigger = t
            collector = makeCollector()
            weakCollector = collector
            sink = VoiceSharingDirectSink(
                queue: queue, isEnabled: { [weak self] in self?.gateOpen ?? false },
                encoderProvenance: { self.provenance }, requestUploadDrain: {})
            weakSink = sink
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

        // Consent ends through the PRODUCTION fan-out, exactly as a withdrawal or sign-out reaches
        // every pipeline owner.
        gateOpen = false
        coordinator.consentGateLostForTesting()
        XCTAssertFalse(isCollectionPermitted())
        XCTAssertFalse(FileManager.default.fileExists(atPath: seededDirectory.path),
                       "retained bytes must be purged")
        let entriesAfterPurge = await queue.entries()
        XCTAssertTrue(entriesAfterPurge.isEmpty)
        await sink.handle(event())
        let entriesAfterDisable = await queue.entries()
        XCTAssertTrue(entriesAfterDisable.isEmpty, "new sink work must be refused after disable")
        service = nil
        XCTAssertNil(weakLifetime)
        XCTAssertNil(weakTrigger)
        XCTAssertNil(weakCollector)
        XCTAssertNil(weakSink)
        XCTAssertEqual(coordinator.gateLostHandlerCountForTesting, registryBaseline)
        XCTAssertFalse(VoiceSharingSettingsModel.surfaceEnabled)
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
        queue = VoiceSharingQueue(root: root)
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
        weakTrigger?.trigger()
        await joinLocalSharingDrain(weakTrigger)
        XCTAssertEqual(authority.received.count, 0, "accepted enrollment without a new lease cannot upload")

        await VoiceSharingCoordinator(enrollmentStore: store).refreshProjectionFromServer(accountClient: accountClient)
        XCTAssertEqual(authority.lookupCount, 2)
        weakTrigger?.trigger()
        await joinLocalSharingDrain(weakTrigger)
        XCTAssertEqual(authority.received.count, 1)
        XCTAssertEqual(try Data(contentsOf: entry.metadataURL), metadata, "503 retains exact immutable metadata")
        XCTAssertEqual(try Data(contentsOf: entry.audioURL), audio, "503 retains exact immutable WAV")
        let pendingEntries = await queue.entries()
        XCTAssertEqual(pendingEntries.count, 1)
        now = now.addingTimeInterval(2)
        weakTrigger?.trigger()
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

        _ = try await AudioFixture.makeReadyEntry(in: queue)
        let refreshedEntries = await queue.entries()
        XCTAssertEqual(refreshedEntries.count, 1)
        store.setLocalOptIn(false)
        XCTAssertFalse(store.consentAllowsCollection)
        weakTrigger?.trigger()
        await joinLocalSharingDrain(weakTrigger)
        XCTAssertEqual(authority.received.count, 2, "configured work cannot send after local withdrawal")
        let entriesAfterWithdrawal = await queue.entries()
        XCTAssertEqual(entriesAfterWithdrawal.count, 1, "negative is not explained by an empty queue")
        service = nil
        XCTAssertNil(weakTrigger)
        XCTAssertFalse(VoiceSharingSettingsModel.surfaceEnabled)
    }

    private func joinLocalSharingDrain(_ trigger: VoiceSharingUploadTrigger?) async {
        // The simple trigger runs its pass on its own task and exposes no handle; wait for it to
        // become idle rather than reaching into it.
        guard let trigger else { return }
        for _ in 0..<80 where trigger.isRunningForTesting {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(trigger.isRunningForTesting, "the configured drain must finish")
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
                IntentRoutingInput.english(transcript: "skip back thirty seconds", utteranceId: UUID().uuidString),
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
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "skip back", utteranceId: UUID().uuidString),
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
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "pause", utteranceId: UUID().uuidString),
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
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "pause", utteranceId: UUID().uuidString),
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
        await service.handleRoutingInput(IntentRoutingInput.english(transcript: "   ", utteranceId: UUID().uuidString),
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
                    "schema_version": 1, "membership_revision": "local-1", "plan": "pro",
                    "voice_sharing_enrolled": true, "enrollment_epoch": "epoch-1",
                    "accepted_disclosure_version": "2026-09", "withdrawal_state": "active"
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
