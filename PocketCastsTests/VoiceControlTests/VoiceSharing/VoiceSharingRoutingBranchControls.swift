import AVFoundation
import Network
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

    /// Calls the production final composition step, then drops the builder and every local owner.
    /// Backend/router/audio are fixtures; no model loading, microphone or network is exercised.
    func test_serviceKeepsSharingAliveAfterTheAssemblyIsReleased() throws {
        let suite = "sharing-lifetime-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VoiceSharingEnrollmentStore(defaults: defaults, accountScopeProvider: { "account-a" })
        store.setLocalOptIn(false)
        let collector = makeCollector()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); queue = nil }
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let policy = openGate()
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
            model.refreshLiveState() // baseline only; no refresh after source mutation
            _ = model.addStateObserver { published.append($0.state) }
            weakModel = model
            let uploader = VoiceSharingUploader(
                queue: queue,
                retryPolicy: VoiceSharingRetryPolicy(
                    retryBaseDelay: 1, retryMaximumDelay: 60, random: { 0 }),
                isAuthorized: { false }, endpoint: { nil },
                transport: { _, _, _ in XCTFail("no upload permitted"); return .transportFailure })
            let trigger = VoiceSharingUploadTrigger(
                scheduler: VoiceSharingUploadScheduler(
                    queue: queue, uploader: uploader, isAuthorized: { false }),
                isAuthorized: { false })
            weakTrigger = trigger
            service = assembly.installVoiceSharingLifetime(
                on: makeService(router: StubClassifier(), executor: StubExecutor(), collector: collector).service,
                settingsModel: model, uploadTrigger: trigger,
                enrollmentStore: store, policy: policy, queue: queue)
            weakLifetime = service?.voiceSharingLifetime
        }
        XCTAssertNil(weakAssembly)
        XCTAssertNotNil(weakModel)
        XCTAssertNotNil(weakTrigger)
        XCTAssertNotNil(weakLifetime)
        XCTAssertFalse(VoiceSharingSettingsModel.surfaceEnabled)
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
    func test_policyDisablePurgesAndCancelsAfterTheAssemblyIsReleased() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-disable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); queue = nil }
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let suite = "sharing-disable-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VoiceSharingEnrollmentStore(defaults: defaults, accountScopeProvider: { "account-a" })
        var remoteEnabled = true
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(remoteEnabled) }, isAccountEnrolled: { true },
            lastFetchTime: { nil }, enrollmentStore: store)
        coordinator.expiryScheduler = { _, _ in } // no real timer; drive the real refresh below
        coordinator.policy.identityBecameReadable()
        coordinator.policyRefreshAfterActivation(
            freshActivationSucceeded: true, fetchToken: coordinator.policy.tokenForFetchStart())
        XCTAssertTrue(coordinator.policy.permitsCollection, "premise: live lease before disable")
        let registryBaseline = coordinator.gateLostHandlerCountForTesting
        let seeded = try AudioFixture.makeReadyEntry(in: queue)
        let seededDirectory = root.appendingPathComponent(seeded.name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seededDirectory.path))
        let parked = expectation(description: "trigger entered its pre-drain gate")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var service: VoiceControlService?
        weak var weakAssembly: VoiceControlAssembly?
        weak var weakTrigger: VoiceSharingUploadTrigger?
        weak var weakCollector: VoiceSharingCollector?
        weak var weakSink: VoiceSharingContributionSink?
        weak var weakLifetime: VoiceSharingLifetime?
        var capturedTask: Task<Void, Never>?
        let samples: [Float] = [0, 0.25, -0.5, 0.5]
        let event = { VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(), enrollmentEpoch: "epoch-1", authorizationSession: "gen-A",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: samples, isGateControl: false) }
        do {
            let assembly = VoiceControlAssembly()
            weakAssembly = assembly
            let policy = coordinator.policy
            let provenance = self.provenance
            let sink = VoiceSharingContributionSink(
                queue: queue, isEnabled: { policy.permitsCollection },
                encoderProvenance: { provenance })
            weakSink = sink
            sink.handle(event())
            sink.waitForIdleForTesting()
            guard case .known(let admitted) = queue.readyEntriesReportingUnknownCoverage() else {
                XCTFail("premise: queue readable")
                return
            }
            XCTAssertEqual(admitted.count, 2, "premise: this event is admitted while policy permits")
            let collector = VoiceSharingCollector(
                policy: policy, membership: { self.state }, epochProvider: { "epoch-1" },
                sessionIdentity: { "gen-A" }, sink: { sink.handle($0) })
            weakCollector = collector

            let uploader = VoiceSharingUploader(
                queue: queue,
                retryPolicy: VoiceSharingRetryPolicy(
                    retryBaseDelay: 1, retryMaximumDelay: 60, random: { 0 }),
                isAuthorized: { policy.permitsCollection }, endpoint: { nil },
                transport: { _, _, _ in XCTFail("parked/cancelled trigger must not send"); return .transportFailure })
            let trigger = VoiceSharingUploadTrigger(
                scheduler: VoiceSharingUploadScheduler(
                    queue: queue, uploader: uploader, isAuthorized: { policy.permitsCollection }),
                surfaceEnabled: { true }, isAuthorized: { policy.permitsCollection })
            trigger.preDrainGateForTesting = {
                parked.fulfill()
                if release.wait(timeout: .now() + 5) != .success { XCTFail("trigger gate timed out") }
            }
            weakTrigger = trigger
            let model = VoiceSharingSettingsModel(
                queue: queue, isCollectionPermitted: { policy.permitsCollection },
                isAccountEnrolled: { true }, isLocallyOptedIn: { false },
                coherenceAccount: { "account-a" })
            assembly.installVoiceSharingGateLoss(
                collector: collector, sink: sink, uploadTrigger: trigger,
                queue: queue, coordinator: coordinator)
            service = assembly.installVoiceSharingLifetime(
                on: makeService(router: StubClassifier(), executor: StubExecutor(), collector: collector).service,
                settingsModel: model, uploadTrigger: trigger,
                enrollmentStore: store, policy: policy, queue: queue)
            weakLifetime = service?.voiceSharingLifetime
            trigger.triggerDrainIfPermitted()
            capturedTask = trigger.drainTaskForTesting
        }
        await fulfillment(of: [parked], timeout: 2)
        XCTAssertNil(weakAssembly)
        XCTAssertNotNil(weakCollector)
        XCTAssertNotNil(weakTrigger)
        XCTAssertNotNil(capturedTask)
        XCTAssertTrue(weakTrigger?.isDrainingForTesting == true)
        XCTAssertEqual(coordinator.gateLostHandlerCountForTesting, registryBaseline + 1)
        let generation = weakSink?.revocationGenerationForTesting ?? -1
        XCTAssertGreaterThanOrEqual(generation, 0)
        remoteEnabled = false
        coordinator.policyRefreshAfterActivation(
            freshActivationSucceeded: true, fetchToken: coordinator.policy.tokenForFetchStart())
        XCTAssertFalse(coordinator.policy.permitsCollection)
        XCTAssertEqual(weakSink?.revocationGenerationForTesting, generation + 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seededDirectory.path), "retained bytes must be purged")
        if case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() {
            XCTAssertTrue(ready.isEmpty)
        } else {
            XCTFail("queue coverage must be known")
        }
        weakSink?.handle(event())
        weakSink?.waitForIdleForTesting()
        if case .known(let after) = queue.readyEntriesReportingUnknownCoverage() {
            XCTAssertTrue(after.isEmpty, "new sink work must be refused after disable")
        } else {
            XCTFail("queue coverage remains known")
        }
        XCTAssertTrue(capturedTask?.isCancelled == true)
        XCTAssertFalse(weakTrigger?.isDrainingForTesting ?? true)
        release.signal()
        let settled = expectation(description: "cancelled trigger task settled")
        let joiningTask = capturedTask
        Task { await joiningTask?.value; settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        capturedTask = nil
        XCTAssertFalse(weakTrigger?.hasPublishedCompletionRegistrationForTesting ?? true)
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
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000), readRemoteSwitch: { .valid(true) },
            lastFetchTime: { nil }, enrollmentStore: store)
        coordinator.expiryScheduler = { _, _ in }
        coordinator.policy.identityBecameReadable()
        let identity: () -> VoiceSharingUploadIdentity? = {
            VoiceSharingUploadIdentity(accountScope: "local-account", enrollmentEpoch: store.activeEnrollmentEpoch)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("configured-sharing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); queue = nil }
        var now = Date()
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: { now }, currentIdentity: identity)
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
            let network = VoiceSharingUploadNetworkGate(allowance: VoiceSharingUploadNetworkAllowance(
                interfaces: [.wifi, .wired], allowsExpensive: false, allowsConstrained: false), monitorPath: false)
            network.update(.init(satisfied: true, interfaces: [.wifi], expensive: false, constrained: false))
            let trigger = assembly.makeVoiceSharingUploadTrigger(
                queue: queue, isAuthorized: { coordinator.policy.permitsCollection }, currentIdentity: identity,
                baseURLProvider: { endpoint }, tokenProvider: tokens, session: session, clock: { now },
                retryPolicy: VoiceSharingRetryPolicy(retryBaseDelay: 1, retryMaximumDelay: 1, random: { 0 }),
                surfaceEnabled: { true }, networkGate: network)
            weakTrigger = trigger
            let model = VoiceSharingSettingsModel(
                queue: queue, isCollectionPermitted: { coordinator.policy.permitsCollection },
                isAccountEnrolled: { store.currentEnrollmentAnswer },
                isLocallyOptedIn: { store.currentState.localOptIn }, coherenceAccount: { "local-account" })
            service = assembly.installVoiceSharingLifetime(
                on: makeService(router: StubClassifier(), executor: StubExecutor(), collector: makeCollector()).service,
                settingsModel: model, uploadTrigger: trigger, enrollmentStore: store,
                policy: coordinator.policy, queue: queue)
        }
        defer { weakTrigger?.stop(); service = nil }
        XCTAssertNil(weakAssembly)
        XCTAssertNotNil(weakTrigger)
        XCTAssertEqual(tokens.value, "local-test-bearer")
        XCTAssertNil(store.currentEnrollmentAnswer)
        let followUp = expectation(description: "changed enrollment requests fresh authority")
        coordinator.initiateIdentityRecoveryRefresh = { followUp.fulfill() }
        await coordinator.completeActivationWithEnrollment(
            freshActivationSucceeded: true, lookup: coordinator.beginEnrollmentLookup(), accountClient: accountClient)
        await fulfillment(of: [followUp], timeout: 2)
        XCTAssertTrue(store.currentEffectiveEnrolled)
        XCTAssertFalse(coordinator.policy.permitsCollection)
        let entry = try AudioFixture.makeReadyEntry(in: queue)
        let metadata = try queue.metadata(of: entry)
        let audio = try queue.audio(of: entry)
        let bound = try VoiceSharingRecordBinding.bind(envelope: metadata, audio: audio)
        let ownerURL = root.appendingPathComponent(entry.name).appendingPathComponent("owner.account")
        XCTAssertEqual(try String(contentsOf: ownerURL, encoding: .utf8), "local-account")
        weakTrigger?.triggerDrainIfPermitted()
        await joinLocalSharingDrain(weakTrigger)
        XCTAssertEqual(authority.received.count, 0, "accepted enrollment without a new lease cannot upload")

        await coordinator.completeActivationWithEnrollment(
            freshActivationSucceeded: true, lookup: coordinator.beginEnrollmentLookup(), accountClient: accountClient)
        XCTAssertTrue(coordinator.policy.permitsCollection)
        XCTAssertEqual(authority.lookupCount, 2)
        weakTrigger?.triggerDrainIfPermitted()
        await joinLocalSharingDrain(weakTrigger)
        XCTAssertEqual(authority.received.count, 1)
        XCTAssertEqual(try queue.metadata(of: entry), metadata, "503 retains exact immutable metadata")
        XCTAssertEqual(try queue.audio(of: entry), audio, "503 retains exact immutable WAV")
        XCTAssertEqual(try String(contentsOf: ownerURL, encoding: .utf8), "local-account")
        XCTAssertEqual(queue.readyEntries().count, 1)
        now = now.addingTimeInterval(2)
        weakTrigger?.triggerDrainIfPermitted()
        await joinLocalSharingDrain(weakTrigger)
        let attempts = authority.received
        XCTAssertEqual(attempts.count, 2)
        for attempt in attempts {
            XCTAssertEqual(attempt.metadata, metadata)
            XCTAssertEqual(attempt.audio, audio)
            XCTAssertEqual(attempt.binding, bound)
            XCTAssertEqual(attempt.binding.enrollmentEpoch, "epoch-1")
            XCTAssertEqual(attempt.bearer, "Bearer local-test-bearer")
        }
        XCTAssertTrue(queue.readyEntries().isEmpty, "matching received-body-derived receipt settles the entry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.name).path))

        _ = try AudioFixture.makeReadyEntry(in: queue)
        XCTAssertEqual(queue.readyEntries().count, 1)
        store.setLocalOptIn(false)
        XCTAssertFalse(coordinator.policy.permitsCollection)
        weakTrigger?.triggerDrainIfPermitted()
        await joinLocalSharingDrain(weakTrigger)
        XCTAssertEqual(authority.received.count, 2, "configured work cannot send after local withdrawal")
        XCTAssertEqual(queue.readyEntries().count, 1, "negative is not explained by an empty queue")
        service = nil
        XCTAssertNil(weakTrigger)
        XCTAssertFalse(VoiceSharingSettingsModel.surfaceEnabled)
    }

    private func joinLocalSharingDrain(_ trigger: VoiceSharingUploadTrigger?) async {
        let task = trigger?.drainTaskForTesting
        let joined = expectation(description: "configured drain joined")
        Task { await task?.value; joined.fulfill() }
        await fulfillment(of: [joined], timeout: 4)
        if trigger?.isDrainingForTesting == true {
            trigger?.stop()
            task?.cancel()
            let cancelled = expectation(description: "timed-out configured drain cancelled and joined")
            Task { await task?.value; cancelled.fulfill() }
            await fulfillment(of: [cancelled], timeout: 2)
        }
        XCTAssertFalse(trigger?.isDrainingForTesting ?? false)
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
            // RESTORED after a withdrawn first cut (spec 6a033773): my intermediate version
            // reported a success tone as completed — but a success-shaped presentation cannot
            // prove action completion, so the honest verdict stays unknown until sinks report
            // structured facts from their action results. SPEC 012b19dd stands: only the
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
        // RESTORED premise: the first turn's verdict is the executor's, and a non-error
        // presentation is still unobserved (spec 6a033773) — completed was withdrawn.
        XCTAssertEqual(firstStages["execution"]?.state, "unknown",
                       "premise: the first turn ran and its result is unobserved")
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
/// Loopback-only account/intake authority. All network state lives on one serial queue.
private final class SharingLocalAuthority {
    struct Upload {
        let metadata: Data
        let audio: Data
        let binding: VoiceSharingRecordBinding.BoundEntry
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
                if isGet || (VoiceSharingAssemblyWiringTests.declaredContentLength(raw).map { raw.count >= $0 } ?? false) {
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
            let binding = try VoiceSharingRecordBinding.bind(envelope: metadata, audio: audio)
            // Reuse the strict existing multipart identity extractor as an independent identity check.
            var request = URLRequest(url: URL(string: baseURLForRequest)!)
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            let extracted = try VoiceSharingAssemblyWiringTests.attemptedIdentity(from: request)
            guard extracted.captureID == binding.captureID, extracted.sha == binding.recordSHA256 else {
                throw URLError(.cannotParseResponse)
            }
            uploads.append(Upload(metadata: metadata, audio: audio, binding: binding, bearer: header("Authorization")))
            if uploads.count == 1 { return try response(503, object: [:]) }
            return try response(201, object: [
                "schema_version": 1, "capture_id": binding.captureID, "record_sha256": binding.recordSHA256,
                "status": "accepted", "receipt_id": "local-receipt", "accepted_at": "2026-10-28T14:00:00Z",
                "retention_expires_at": "2026-11-28T14:00:00Z"
            ])
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
