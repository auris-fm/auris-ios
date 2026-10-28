import AVFoundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

class VoiceControlAssembly {
    /// Returns nil when the wake-word deployment manifest is missing or
    /// mismatched (fail closed): voice control must not start without a valid
    /// deployment threshold and verified assets.
    func buildVoiceControlService(
        audioSession: AudioSessionControlling = RealAudioSession(),
        conditionMonitor: LiveConditionMonitor? = nil,
        capture: NativeAudioCapture? = nil,
        isPlaybackActive: @escaping () -> Bool = { PlaybackManager.shared.isAudioSessionInUse }
    ) -> VoiceControlService? {
        let gracePeriodSignal = GracePeriodSignal()

        let routeMonitor = IOSAudioRouteMonitor(gracePeriodSignal: gracePeriodSignal, audioSession: audioSession)
        let conditionMonitor = conditionMonitor ?? LiveConditionMonitor(gracePeriodSignal: gracePeriodSignal)
        let interruptionHandler = AudioSessionInterruptionHandler()
        let playbackManager = PlaybackManager.shared

        let locale = Locale.current
        guard let asrBackend = resolveAsrBackend(locale: locale) else {
            let lang = locale.language.languageCode?.identifier ?? "?"
            FileLog.shared.addMessage(
                "[VoicePipeline] unsupported locale \(lang) — voice control disabled (no Whisper product route)"
            )
            return nil
        }

        // Deployment threshold comes from the eval manifest (recognition-pipeline.md
        // "Threshold"). A missing manifest or hash mismatch disables voice control.
        let wakewordDir = bundleURL("melspectrogram.ort").deletingLastPathComponent()
        let manifestURL = wakewordDir.appendingPathComponent("auris_eval.json")
        let thresholdResult = WakeWordThresholdLoader.load(manifestURL: manifestURL, modelDirectory: wakewordDir)
        guard case .success(let threshold) = thresholdResult else {
            if case .failure(let error) = thresholdResult {
                FileLog.shared.addMessage("[VoicePipeline] Wake-word threshold load failed: \(error). Voice control disabled (fail closed).")
            }
            return nil
        }

        let wakeWordDetector = WakeWordDetector(
            melModel: bundleURL("melspectrogram.ort"),
            embedModel: bundleURL("embedding_model.ort"),
            classifierModel: bundleURL("auris.ort"),
            threshold: threshold
        )

        let asrEngine = VoiceAsrEngine(
            capture: capture ?? NativeAudioCapture(isPlaybackActive: isPlaybackActive),
            segmenter: NativeVadSegmenter(threshold: 0.020),
            backend: asrBackend,
            signalFilter: SignalFilter(),
            wakeWordDetector: wakeWordDetector,
            gracePeriodSignal: gracePeriodSignal,
            clock: SystemMonotonicClock(),
            wakeThreshold: threshold,
            translationStage: AppleTranslationTranslator()
        )
        // Voice-sharing composition (production). The collector observes the engine with production
        // defaults for membership/epoch/session; consent loss on the coordinator's gate — membership
        // withdrawal, sign-out, refresh observing the switch off, and the SCHEDULED LEASE-EXPIRY
        // TRIGGER — routes straight into the collector's purge. The feature itself stays disabled
        // until the owner approves activation; wiring exists so consent loss acts on real audio the
        // moment anything upstream produces it.
        // The queue-backed contribution sink (round 62/63): collector event → encoder → durable
        // queue entry. The gate reads the live policy on EVERY event and the remote switch
        // defaults to disabled, so no upload work is minted until owner-approved activation.
        // Encode/queue failures are logged (opaque IDs only) and dropped — never into the
        // recognition pipeline.
        let queueRoot = VoiceSharingUploadQueue.defaultRootDirectory()
        try? FileManager.default.createDirectory(at: queueRoot, withIntermediateDirectories: true)
        // PER-ENTRY IDENTITY BINDING (reviewer fd6b8036 / spec fe99ec96): the queue compares each
        // entry's own durable enrollment epoch against this LIVE read at admission, so a surviving
        // entry from a previous epoch cannot ride a newer process into an upload — and a new entry
        // is admitted without waiting for a rebuild. The reader is evaluated per admission, never
        // captured at construction.
        let contributionQueue = VoiceSharingUploadQueue(
            rootDirectory: queueRoot,
            // BOTH halves, structurally (reviewer 2b121320): an epoch value is opaque and can
            // collide across accounts, so the live identity pairs it with the account scope.
            currentIdentity: {
                VoiceSharingUploadIdentity(
                    accountScope: ServerSettings.userId,
                    enrollmentEpoch: VoiceSharingEnrollmentStore.shared.activeEnrollmentEpoch)
            })
        // PRODUCTION WIRE (spec 18:38Z): the real transport (bearer credential + the configured
        // endpoint, fail-closed on either) feeding the uploader feeding the serialized scheduler.
        // The whole chain sits behind the live authorization gate, so nothing here can mint a
        // request without eligibility AND a credential — and the surface itself is still compiled
        // OFF (VoiceSharingSettingsModel.surfaceEnabled == false): no caller invokes drains yet.
        // IDENTITY PIN (spec 724577f3 / reviewer d9e99a5e): `permitsCollection` answers "may this
        // account collect NOW", which is not the question a queued entry asks. An entry queued
        // under one enrollment epoch must not be uploaded after the account's epoch moves, even
        // when the new epoch also permits collection. The pin is sampled from the SAME store the
        // policy folds on, so account switch and re-enrollment both invalidate it.
        // The PER-ENTRY binding above owns the "may this entry go out" decision. A construction-time
        // pin must not also veto it: that froze identity at assembly time, blocking every new entry
        // after a re-enrollment and admitting stale entries after a rebuild (reviewer fd6b8036).
        let uploadAuthorized: () -> Bool = {
            VoiceSharingCoordinator.shared.policy.permitsCollection
        }
        // ONE identity reader for the whole upload path: queue, uploader and transport all
        // consult it, so the fence spans admission, credential acquisition and settlement.
        let uploadIdentity: () -> VoiceSharingUploadIdentity? = {
            VoiceSharingUploadIdentity(
                accountScope: ServerSettings.userId,
                enrollmentEpoch: VoiceSharingEnrollmentStore.shared.activeEnrollmentEpoch)
        }
        let uploadTrigger = makeVoiceSharingUploadTrigger(
            queue: contributionQueue, isAuthorized: uploadAuthorized, currentIdentity: uploadIdentity)
        // The settings MODEL is wired here, in production, with the real live reads (reviewer
        // 8ae2b980): the policy's effective permit, the enrollment store's effective enrollment,
        // and the store's local opt-in. Each returns `nil` when it cannot answer, which the model
        // renders as `unknown` rather than inventing an opt-out.
        let settingsModel = VoiceSharingSettingsModel(
            queue: contributionQueue,
            isCollectionPermitted: { VoiceSharingCoordinator.shared.policy.permitsCollection },
            // TRI-STATE: no authoritative projection yet ⇒ unknown, not "not enrolled".
            isAccountEnrolled: { VoiceSharingEnrollmentStore.shared.currentEnrollmentAnswer },
            isLocallyOptedIn: { VoiceSharingEnrollmentStore.shared.currentState.localOptIn },
            // Coherence stamps: the account the reads belong to and the enrollment generation that
            // moves when intent/membership changes. A read taken across a move is detected and the
            // whole snapshot degrades to `unknown` rather than mixing two moments.
            coherenceAccount: { ServerSettings.userId },
            coherenceGeneration: { VoiceSharingEnrollmentStore.shared.currentEnrollmentGeneration },
            coherenceVersion: { VoiceSharingEnrollmentStore.shared.activeEnrollmentEpoch },
            policyLeaseGeneration: { VoiceSharingCoordinator.shared.policy.currentLeaseGeneration },
            queueHoldGeneration: { contributionQueue.currentHoldGeneration })
        // Time-driven freshness: the queue's next age boundary and the policy's lease deadline.
        settingsModel.nextAgeBoundarySeconds = { [weak contributionQueue] in
            contributionQueue?.secondsUntilNextAgeBoundary()
        }
        settingsModel.nextLeaseExpirySeconds = {
            VoiceSharingCoordinator.shared.policy.secondsUntilLeaseExpiry
        }
        settingsModel.scheduleTimeDrivenRefresh = { delay, body in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
        }
        let contributionSink = VoiceSharingContributionSink(
            queue: contributionQueue,
            isEnabled: { VoiceSharingCoordinator.shared.policy.permitsCollection },
            encoderProvenance: {
                VoiceSharingContributionEncoder.Provenance(
                    platform: "ios",
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    captureSessionID: UUID().uuidString,
                    models: .init(vad: nil, wakeword: nil, asr: nil, translation: nil, router: nil),
                    conversionVersion: "v1") // spec ruling 2026-10-22: bounded string, not Int
            })
        let contributionCollector = VoiceSharingCollector(
            policy: VoiceSharingCoordinator.shared.policy,
            sink: { event in
                contributionSink.handle(event)
            }
        )
        asrEngine.contributionCollector = contributionCollector
        // The COLLECTOR owns its registration: a held sink or queued drain can keep the collector
        // alive after the engine is gone, and that collector must still be purged at consent loss.
        // Consent loss purges BOTH holders of retained contribution state: the collector's
        // in-memory capture/FIFO, and the durable queue (any entry prepared before the gate
        // closed, ready or not). Cleanup failures inside purge leave entries retained + charged.
        // AUTHORIZATION INVALIDATION goes through the REAL production path (reviewer 70e5fc58):
        // this handler is the coordinator's single gate-lost signal — withdrawal, sign-out, the
        // refresh observing the switch off, and the scheduled lease-expiry trigger. It must reach
        // the SINK's revocation generation, not just purge storage, or a queued event from the
        // superseded epoch could publish after the switch reads true again.
        // Re-login recovery (review 15a18d5d): identityBecameReadable must INITIATE the normal
        // refresh, not merely permit a later one. Wired here where Firebase is configured; the
        // coordinator's default is a no-op so tests can drive the sequence without Firebase.
        VoiceSharingCoordinator.shared.initiateIdentityRecoveryRefresh = {
            FirebaseManager.refreshRemoteConfig(expirationDuration: 0)
        }
        installVoiceSharingGateLoss(
            collector: contributionCollector, sink: contributionSink, uploadTrigger: uploadTrigger,
            queue: contributionQueue, coordinator: .shared)

        // ASR/LFM preload stays in VoiceControlService.startIfAllowed() (once),
        // not here — assembly must not download/init models before the service
        // arms (cellular + memory cost when voice is off).

        let intentRouter = LfmIntentRouter()

        let analyticsService = DefaultAnalyticsService()
        let voiceAnalytics = VoiceAnalytics(analytics: analyticsService)
        let cloudPlaybackContextState = CloudPlaybackContextState()
        let playbackContextProvider = DefaultPlaybackContextProvider(
            playbackState: playbackManager,
            fingerprintMapper: FingerprintTimingManager.shared,
            cloudPlaybackContextState: cloudPlaybackContextState
        )

        let playbackSink = PlaybackManagerSink(playbackManager: playbackManager)
        let executor = VoiceIntentExecutor(
            playbackSink: playbackSink,
            effectsSink: EffectsManagerSink(playbackManager: playbackManager),
            volumeSink: VolumeManagerSink(),
            sleepSink: SleepTimerSink(playbackManager: playbackManager),
            chapterSink: ChapterSink(playbackManager: playbackManager),
            bookmarkSink: BookmarkSink(playbackManager: playbackManager),
            queueSink: QueueSink(playbackManager: playbackManager, dataManager: .sharedManager),
            playbackQuerySink: PlaybackQuerySink(playbackManager: playbackManager),
            statsQuerySink: StatsQuerySink(dataManager: .sharedManager),
            cloudRouteSink: CloudRouteSink(
                audioPlayer: CloudAudioPlayer(),
                playbackManager: playbackManager,
                playbackSink: playbackSink,
                fingerprintMapper: FingerprintTimingManager.shared,
                playbackPositionMs: {
                    Int64((playbackManager.currentTime() * 1000).rounded())
                },
                cloudPlaybackContextState: cloudPlaybackContextState,
                analytics: voiceAnalytics
            ),
            playbackContextProvider: playbackContextProvider,
            gracePeriodSignal: gracePeriodSignal,
            analytics: voiceAnalytics
        )

        let audioEngine = AVAudioEngine()
        let earconPlayer = EarconPlayer(engine: audioEngine)
        let ttsEngine = AVSpeechTtsEngine()
        let audioRenderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: ttsEngine)

        // Pre-warm TTS engine so first speak() has no init penalty.
        // Language matches the device locale (same as ASR pipeline).
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        ttsEngine.warmUp(language: language)

        let service = VoiceControlService(
            conditionMonitor: conditionMonitor,
            routeMonitor: routeMonitor,
            interruptionHandler: interruptionHandler,
            asrEngine: asrEngine,
            wakeWordDetector: wakeWordDetector,
            intentRouter: intentRouter,
            executor: executor,
            dialogManager: VoiceDialogManager(),
            audioRenderer: audioRenderer,
            gracePeriodSignal: gracePeriodSignal,
            analytics: voiceAnalytics,
            contributionCollector: contributionCollector,
            isPlaybackActive: isPlaybackActive
        )
        return installVoiceSharingLifetime(
            on: service, settingsModel: settingsModel, uploadTrigger: uploadTrigger,
            enrollmentStore: .shared, policy: VoiceSharingCoordinator.shared.policy,
            queue: contributionQueue)
    }

    /// The production upload chain. Injection changes sources, not the wiring under test.
    func makeVoiceSharingUploadTrigger(
        queue: VoiceSharingUploadQueue,
        isAuthorized: @escaping () -> Bool,
        currentIdentity: @escaping () -> VoiceSharingUploadIdentity?,
        baseURLProvider: @escaping () -> String = { CloudConfig.shared.baseUrl },
        tokenProvider: CloudTokenProviding = CloudTokenProviderRouter.provider(),
        session: URLSession = .shared,
        clock: @escaping () -> Date = Date.init,
        retryPolicy: VoiceSharingRetryPolicy = VoiceSharingRetryPolicy(
            retryBaseDelay: VoiceSharingRetryPolicy.compiledInitialDelaySeconds,
            retryMaximumDelay: VoiceSharingRetryPolicy.compiledMaximumDelaySeconds,
            random: { Double.random(in: 0...1) }),
        surfaceEnabled: @escaping () -> Bool = { VoiceSharingSettingsModel.surfaceEnabled },
        networkGate: VoiceSharingUploadNetworkGate = VoiceSharingUploadNetworkGate(),
        beforeNetworkRetryForTesting: (() async -> Void)? = nil
    ) -> VoiceSharingUploadTrigger {
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: baseURLProvider, tokenProvider: tokenProvider, session: session)
        let uploader = VoiceSharingUploader(
            queue: queue, networkGate: networkGate, retryPolicy: retryPolicy, isAuthorized: isAuthorized,
            currentIdentity: currentIdentity, endpoint: { transport.endpoint }, clock: clock,
            networkFenceTransport: { [transport] request, admitted, fence, networkFence in
                return await transport.send(request: request, admittedIdentity: admitted, identityFence: fence,
                                            networkFence: networkFence, networkAllowance: networkGate.allowance)
            })
        uploader.beforeNetworkRetryForTesting = beforeNetworkRetryForTesting
        let scheduler = VoiceSharingUploadScheduler(queue: queue, uploader: uploader, isAuthorized: isAuthorized)
        return VoiceSharingUploadTrigger(
            scheduler: scheduler, surfaceEnabled: surfaceEnabled, isAuthorized: isAuthorized, networkGate: networkGate)
    }

    /// Keep revocation subscribed for as long as the collector can retain contribution audio.
    func installVoiceSharingGateLoss(
        collector: VoiceSharingCollector,
        sink: VoiceSharingContributionSink,
        uploadTrigger: VoiceSharingUploadTrigger,
        queue: VoiceSharingUploadQueue,
        coordinator: VoiceSharingCoordinator
    ) {
        collector.gateLostSubscription = coordinator.registerGateLostHandler {
            [weak collector, weak sink, weak uploadTrigger] in
            sink?.noteRevocation()
            collector?.gateLost()
            uploadTrigger?.stop()
            _ = queue.purgeAll()
        }
    }

    /// The service outlives this builder; subscriptions and their dependencies must do so too.
    @discardableResult
    func installVoiceSharingLifetime(
        on service: VoiceControlService,
        settingsModel: VoiceSharingSettingsModel,
        uploadTrigger: VoiceSharingUploadTrigger,
        enrollmentStore: VoiceSharingEnrollmentStore,
        policy: VoiceSharingPolicy,
        queue: VoiceSharingUploadQueue
    ) -> VoiceControlService {
        service.voiceSharingLifetime = nil
        service.voiceSharingLifetime = VoiceSharingLifetime(
            settingsModel: settingsModel, uploadTrigger: uploadTrigger,
            enrollmentStore: enrollmentStore, policy: policy, queue: queue)
        return service
    }

    /// Product ASR selection for assembly/tests. Nil = unsupported locale (fail closed).
    func resolveAsrBackend(locale: Locale) -> AsrBackend? {
        AsrBackendSelector().select(locale: locale)
    }

    private func bundleURL(_ filename: String) -> URL {
        // Run Script "Copy Wakeword Models" copies models into bundle/wakeword/
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "wakeword") else {
            // Log bundle path for diagnostics — the wakeword/ dir is injected post-build.
            let bundlePath = Bundle.main.bundlePath
            let wakewordDir = (bundlePath as NSString).appendingPathComponent("wakeword")
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: wakewordDir) {
                FileLog.shared.addMessage("[VoicePipeline] Missing model \(filename) in \(wakewordDir); contents: \(contents)")
            } else {
                FileLog.shared.addMessage("[VoicePipeline] Missing model \(filename) — wakeword dir not found at \(wakewordDir)")
            }
            fatalError("Missing wakeword model in bundle: wakeword/\(filename)")
        }
        return url
    }
}

// MARK: - Analytics Service Bridge

/// Bridges the VoiceControl analytics protocol to the app's real `Analytics`
/// pipeline. Event names map to `AnalyticsEvent` cases (camelCase raw values are
/// emitted as snake_case via `eventName`).
private class DefaultAnalyticsService: AnalyticsService {
    func track(_ event: String, properties: [String: Any]) {
        FileLog.shared.addMessage("[VoicePipeline] event=\(event) properties=\(properties)")
        let analyticsEvent: AnalyticsEvent?
        switch event {
        case "voice_command_executed": analyticsEvent = .voiceCommandExecuted
        case "voice_router_latency": analyticsEvent = .voiceRouterLatency
        case "voice_recognition_latency": analyticsEvent = .voiceRecognitionLatency
        case "cloud_assistant_turn": analyticsEvent = .cloudAssistantTurn
        default: analyticsEvent = nil
        }
        guard let analyticsEvent else { return }
        let sendableProperties: [String: any Sendable] = properties.mapValues { value in
            if let string = value as? String { return string }
            if let double = value as? Double { return double }
            if let int = value as? Int { return int }
            if let bool = value as? Bool { return bool }
            return String(describing: value)
        }
        Analytics.track(analyticsEvent, properties: sendableProperties)
    }
}

/// Keeps the existing sharing objects and their source registrations alive with the service.
final class VoiceSharingLifetime {
    let settingsModel: VoiceSharingSettingsModel
    let uploadTrigger: VoiceSharingUploadTrigger
    private let enrollmentStore: VoiceSharingEnrollmentStore
    private let policy: VoiceSharingPolicy
    private let queue: VoiceSharingUploadQueue
    private let enrollmentObserver: UUID
    private let policyObserver: UUID
    private let queueObserver: UUID

    init(settingsModel: VoiceSharingSettingsModel,
         uploadTrigger: VoiceSharingUploadTrigger,
         enrollmentStore: VoiceSharingEnrollmentStore,
         policy: VoiceSharingPolicy,
         queue: VoiceSharingUploadQueue) {
        self.settingsModel = settingsModel
        self.uploadTrigger = uploadTrigger
        self.enrollmentStore = enrollmentStore
        self.policy = policy
        self.queue = queue
        enrollmentObserver = enrollmentStore.addObserver { [weak settingsModel] _ in
            settingsModel?.refreshLiveState()
        }
        policyObserver = policy.addChangeObserver { [weak settingsModel] in
            settingsModel?.refreshLiveState()
        }
        queueObserver = queue.addContentObserver { [weak settingsModel] in
            settingsModel?.refreshLiveState()
        }
    }

    deinit {
        enrollmentStore.removeObserver(enrollmentObserver)
        policy.removeChangeObserver(policyObserver)
        queue.removeContentObserver(queueObserver)
    }
}
