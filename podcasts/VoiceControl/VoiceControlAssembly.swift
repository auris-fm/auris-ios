import AVFoundation
import Combine
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

class VoiceControlAssembly {
    /// Retains the route-scope subscription for the lifetime of the assembly. The
    /// service holds the engine, so the binding must live at least as long.
    private var cancellables = Set<AnyCancellable>()
    /// The client factory the assembly used, retained so the acceptance operator entry submits through
    /// the SAME client the sink was built with rather than constructing a second one. Set when the
    /// service is built; production and tests both flow through it.
    private var acceptanceClientFactory: (() -> CloudRouteClient) = CloudRouteSink.productionClientFactory()

    /// Returns nil when the wake-word deployment manifest is missing or
    /// mismatched (fail closed): voice control must not start without a valid
    /// deployment threshold and verified assets.
/// - Parameter injectedCapture: the microphone source. `nil` keeps the real one; a test
    ///   substitutes it so the service can be driven through its REAL assembly and start path
    ///   without opening the microphone. This is the only injection point — everything else is
    ///   built as the app does.
    /// Records the factory the sink is built with, so the acceptance entry uses the same one. This is
    /// the point that WIRES the entry: the same call that builds the sink's client retains its factory
    /// for acceptance, so the two cannot diverge.
    @discardableResult
    func acceptanceClientFactoryForBuild(_ injected: (() -> CloudRouteClient)? = nil) -> () -> CloudRouteClient {
        let factory = injected ?? CloudRouteSink.productionClientFactory()
        acceptanceClientFactory = factory
        return factory
    }

    func buildVoiceControlService(
        audioSession: AudioSessionControlling = RealAudioSession(),
        conditionMonitor: LiveConditionMonitor? = nil,
        capture injectedCapture: (any AudioCaptureSource)? = nil,
        inference injectedInference: (any LfmInference)? = nil,
        modelManager injectedModelManager: ModelManager? = nil,
        clientFactory injectedClientFactory: (() -> CloudRouteClient)? = nil,
        playbackSink injectedPlaybackSink: VoicePlaybackSink? = nil,
        graceTimeout injectedGraceTimeout: TimeInterval? = nil,
        cloudConfig injectedCloudConfig: CloudConfig? = nil,
        asrBackend injectedBackend: (() -> AsrBackend?)? = nil,
        onInputRoutingFinished: (@MainActor (IntentRoutingInput) -> Void)? = nil,
        testInputBarrier: (@Sendable (IntentRoutingInput) async throws -> Void)? = nil,
        onInputBarrierSettled: (@Sendable (IntentRoutingInput, VoiceControlService.InputBarrierOutcome) -> Void)? = nil,
        onInputTerminal: (@Sendable (IntentRoutingInput, VoiceControlService.InputTerminalOutcome) -> Void)? = nil,
        parsedIntentObserverFactory: (@Sendable (IntentRoutingInput) -> VoiceControlService.ParsedIntentObserver?)? = nil,
        preparedObserverFactory: (@Sendable (IntentRoutingInput) -> CloudRouteSink.PreparedObserver?)? = nil,
        isPlaybackActive: @escaping () -> Bool = { PlaybackManager.shared.isAudioSessionInUse },
        // Test-only injection: a control replaces the MODEL's decision while keeping the rest of
        // the pipeline (capture registration, routing, provenance) real. Without this a control
        // must supply audio the real model happens to classify as speech, which makes the test
        // depend on an external recording that a clean checkout does not have.
        injectedSpeechClassifier: SpeechFrameClassifier? = nil
    ) -> VoiceControlService? {
        // Test-only injection: a controlled (short) clock lets a control hold actual playback
        // PAST the grace timeout without real sleeps of 30s.
        let gracePeriodSignal = GracePeriodSignal(timeout: injectedGraceTimeout ?? 30.0)
        let conversationManager = CloudConversationManager()
        // Keep the manager's live origin in step with the window that actually opens. The
        // sink reads the origin from the INTENT (captured at dispatch), so this only supplies
        // the value that decides whether a captured origin is still live.
        // The live-origin binding is owned by the SERVICE (see `wireLiveOriginBinding`): a
        // subscription stored here would be cancelled the moment this build call returns, leaving
        // the manager unaware of every window that opens.

        let routeMonitor = IOSAudioRouteMonitor(gracePeriodSignal: gracePeriodSignal, audioSession: audioSession)
        let playbackManager = PlaybackManager.shared
        // REAL playback context (an eligible episode exists, playing or paused) — the independent
        // source both the gate's context and the grace signal's backgrounding decision consult.
        // A cloud/grace hold is never a context source (spec 3893cd55).
        let playbackContextAvailable: () -> Bool = { [weak playbackManager] in
            guard let playbackManager else { return false }
            let context = DefaultPlaybackContextProvider(
                playbackState: playbackManager,
                fingerprintMapper: FingerprintTimingManager.shared,
                cloudPlaybackContextState: CloudPlaybackContextState()
            ).current()
            return context != nil
        }
        gracePeriodSignal.playbackContextAvailable = playbackContextAvailable
        let conditionMonitor = conditionMonitor ?? LiveConditionMonitor(
            gracePeriodSignal: gracePeriodSignal,
            // Real context changes through the SHARED production publisher: a track change
            // (episode loaded/cleared) or playback ending re-samples the ACTUAL provider rather
            // than assuming a direction.
            playbackContextPublisher: PlaybackContextConditionSource
                .production(provider: playbackContextAvailable).publisher
        )
        let interruptionHandler = AudioSessionInterruptionHandler()

        let locale = Locale.current
        guard let asrBackend = resolveAsrBackend(locale: locale, override: injectedBackend) else {
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
        let thresholdResult = WakeWordThresholdLoader.loadDeployment(manifestURL: manifestURL, modelDirectory: wakewordDir)
        guard case .success(let deployment) = thresholdResult else {
            if case .failure(let error) = thresholdResult {
                FileLog.shared.addMessage("[VoicePipeline] Wake-word threshold load failed: \(error). Voice control disabled (fail closed).")
            }
            return nil
        }

        let wakeWordDetector = WakeWordDetector(
            melModel: bundleURL("melspectrogram.ort"),
            embedModel: bundleURL("embedding_model.ort"),
            classifierModel: bundleURL("auris.ort"),
            threshold: deployment.threshold,
            verifiedModelIdentity: deployment.identity
        )

        let cloudAudioPlayer = CloudAudioPlayer()

        // Classified speech, not a fixed energy level. A room whose ambient noise sits above
        // 0.020 makes every frame "speech" under the energy rule, so no silence endpoint arrives
        // and the utterance never closes — measured as a single utterance growing without limit.
        //
        // No fallback: if the model cannot be loaded the segmenter is told so and dispatches
        // nothing, because the energy rule is precisely the failure being removed. Reporting
        // normal listening while running it would hide the defect behind a working-looking UI.
        let speechClassifier = injectedSpeechClassifier ?? SileroSpeechFrameClassifier.bundled()
        let vadSegmenter = NativeVadSegmenter(
            threshold: 0.020,
            classifier: speechClassifier
        )
        if speechClassifier == nil {
            vadSegmenter.reportClassifierUnavailable("silero_vad.onnx could not be loaded from the app bundle")
        } else if injectedSpeechClassifier != nil {
            FileLog.shared.addMessage("[VoicePipeline] speech classifier injected by a control")
        }
        let asrEngine = VoiceAsrEngine(
            capture: injectedCapture ?? NativeAudioCapture(isPlaybackActive: isPlaybackActive),
            segmenter: vadSegmenter,
            backend: asrBackend,
            signalFilter: SignalFilter(),
            wakeWordDetector: wakeWordDetector,
            gracePeriodSignal: gracePeriodSignal,
            clock: SystemMonotonicClock(),
            wakeThreshold: deployment.threshold,
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
        // ACTIVATION SLICE (2026-11-03): configure the NAMED secondary Firebase app so the
        // policy's remote scalar reads from the dedicated auris-fm registration. The default
        // app and its consumers are untouched; a missing/invalid bundled plist degrades to
        // nil and the coordinator falls back to the default-app read (existing behavior).
        _ = VoiceSharingFirebaseApp.configure()
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
        let allowanceRoot = queueRoot.deletingLastPathComponent().appendingPathComponent("CaptureUsage", isDirectory: true)
        // CONNECTED CAPTURE ENTRY (scope correction 2026-11-03): the collector's admission
        // authority comes from ONE real allowance request provisioned after the policy gate
        // installs. Memory-only; absent a valid installed response admission fails closed.
        let allowanceProvisioner = VoiceSharingCaptureAllowanceProvisioner(
            client: VoiceSharingCaptureAllowanceClient(tokenProvider: CloudTokenProviderRouter.provider()),
            accountProvider: { ServerSettings.userId },
            enrollmentEpochProvider: { VoiceSharingEnrollmentStore.shared.activeEnrollmentEpoch },
            stampProvider: {
                guard let session = VoiceSharingSessionGeneration.shared.currentGeneration(),
                      let epoch = VoiceSharingEnrollmentStore.shared.activeEnrollmentEpoch else { return nil }
                return VoiceSharingCaptureStamp(
                    session: session,
                    epoch: epoch,
                    policyGeneration: VoiceSharingCoordinator.shared.policy.currentLeaseGeneration)
            })
        let captureAllowance = VoiceSharingCaptureAllowance(
            ledger: VoiceSharingCaptureLedger(root: allowanceRoot),
            currentAuthorization: { allowanceProvisioner.currentAuthorization() })
        let contributionCollector = VoiceSharingCollector(
            policy: VoiceSharingCoordinator.shared.policy,
            captureAllowance: captureAllowance,
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
        // ACTIVATION SLICE (reviewer 45479ac1): the named secondary policy refresh is a
        // PRODUCTION-connected entry — identity recovery runs the named fetch→activate→value
        // path (with failure reporting); the default-app refresh above stays for its own consumers.
        VoiceSharingFirebaseApp.connectIdentityRecoveryRefresh()
        // LAUNCH ENTRY (reviewer 0c3168fe): a process that is already signed in has neither a
        // recovery event nor an expiring lease — run one named exchange now so the policy
        // lease installs at launch. Failure reports through the exchange's own path.
        VoiceSharingFirebaseApp.performPolicyExchange(coordinator: .shared) { [weak allowanceProvisioner] installed in
            // The gate installed: fetch the REAL capture allowance now so a consented
            // capture admits against a server-issued batch. Failure is surfaced by the
            // provisioner itself; capture stays closed either way.
            guard installed else { return }
            Task { await allowanceProvisioner?.provision() }
        }
        installVoiceSharingGateLoss(
            collector: contributionCollector, sink: contributionSink, uploadTrigger: uploadTrigger,
            queue: contributionQueue, coordinator: .shared)


        // One emitted-PCM reference for the whole session: the cloud-answer renderer
        // feeds it, and the engine correlates against it. Without a producer the
        // reference stays empty and the filter cannot fire.
        let echoReference = PlaybackEchoReference()
        cloudAudioPlayer.emittedPCMReference = echoReference
        asrEngine.setEchoReference(echoReference)

        // One handoff serves every producer whose audio the microphone can hear. It exists
        // because the reference's append drops old samples with a memmove inside its lock,
        // and a producer that appends from a deadline-bound callback can wait on that. The
        // capacity is in blocks: at this size a saturated handoff drops rather than blocks,
        // which leaves a visible gap in the reference instead of stalling the producer.
        let echoHandoff = EchoReferenceHandoff(reference: echoReference, capacity: 8)
        // The cloud player's render positions travel through the SAME mapping as every other
        // producer's. Its samples are appended directly — it is not on a deadline callback —
        // but an anchor must still be matched to the block that contains it, or queue lead puts
        // second-turn audio at a position its own earlier blocks occupy (PR #49 review comment
        // 4305981528). Set here because the assembly holds both sides.
        cloudAudioPlayer.echoReferenceHandoff = echoHandoff
        // The episode renderer publishes what it emits into this handoff. Set from here
        // because the assembly holds both sides: the reference belongs to the voice layer and
        // the renderer to playback. The renderer reads it inside `#if !APPCLIP`, since the
        // App Clip compiles that file and has no voice layer to publish to.
        EffectsPlayer.echoReferenceHandoff = echoHandoff

        // ASR/LFM preload stays in VoiceControlService.startIfAllowed() (once),
        // not here — assembly must not download/init models before the service
        // arms (cellular + memory cost when voice is off).

        let intentRouter = injectedInference == nil && injectedModelManager == nil
            ? LfmIntentRouter()
            : LfmIntentRouter(modelManager: injectedModelManager ?? ModelManager(),
                              inference: injectedInference ?? LfmNativeInference())

        let analyticsService = DefaultAnalyticsService()
        let voiceAnalytics = VoiceAnalytics(analytics: analyticsService)
        let cloudPlaybackContextState = CloudPlaybackContextState()
        let playbackContextProvider = DefaultPlaybackContextProvider(
            playbackState: playbackManager,
            fingerprintMapper: FingerprintTimingManager.shared,
            cloudPlaybackContextState: cloudPlaybackContextState
        )

        // Test-only injection: a control that must observe ACTUAL local execution (e.g. a pause
        // the router classified from an English utterance) supplies a recording sink. Nil in
        // production — the real manager-backed sink is used unchanged.
        let playbackSink = injectedPlaybackSink ?? PlaybackManagerSink(playbackManager: playbackManager)
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
                clientFactory: acceptanceClientFactoryForBuild(injectedClientFactory),
                // Grace contract: expiry holds while the answer is actually draining/playing and
                // resumes exactly once at the real stop — identity-bound to the turn's window.
                isConfigured: { !(injectedCloudConfig ?? CloudConfig.shared).baseUrl.isEmpty },
                audioPlayer: cloudAudioPlayer,
                playbackManager: playbackManager,
                playbackSink: playbackSink,
                fingerprintMapper: FingerprintTimingManager.shared,
                playbackPositionMs: {
                    Int64((playbackManager.currentTime() * 1000).rounded())
                },
                cloudPlaybackContextState: cloudPlaybackContextState,
                analytics: voiceAnalytics,
                // The live origin is the grace window's generation: a turn dispatched under
                // an older window is refused rather than given a replacement conversation.
                // Exactly-once records for server-identified operations (wire contract rev
                // da327e624): durable before effect. A nil store (no Application Support) simply
                // leaves the sink without a journal — refusals still report through the transport.
                operationJournal: {
                    let store = FileOperationRecordStore(
                        url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("cloud-operation-journal.json")
                    )
                    let journal = OperationJournal(store: store)
                    // PRODUCTION RESTART RECOVERY: any operation a previous process left in
                    // progress is reconstructed as typed `unknown` (persisted, never re-executed)
                    // at assembly time, so the first claim of that id after restart replays the
                    // recorded unknown rather than re-running the effect.
                    for operationID in journal.interruptedOperationIDs() {
                        journal.reconstructInterrupted(operationID)
                    }
                    return journal
                }(),
                conversationManager: conversationManager,
                conversationSelectionProvider: { [weak gracePeriodSignal] in
                    // A wake opens a window; a recognised command continues the current one.
                    (gracePeriodSignal?.isActive ?? false) ? .followUp : .wakeWord
                },
                // Grace contract: expiry holds from the turn's ADMITTED DISPATCH through done
                // and the actual drain/stop; token ownership — each hold releases only itself,
                // and the last release resumes the interval exactly once.
                onGracePlaybackHoldBegin: { origin in
                    gracePeriodSignal.beginPlaybackHold(forGeneration: origin ?? -1)
                },
                onGracePlaybackHoldEnd: { token in
                    gracePeriodSignal.endPlaybackHold(token)
                },
                // Eligibility survives the window it was admitted under (voice-control-core.md:270),
                // so the dispatch fence must admit a claimed-but-expired origin. This is the
                // PRODUCTION registration path; the authority reads the live admission state.
                admittedWorkAuthority: { gracePeriodSignal.admittedWorkAuthority }
            ),
            playbackContextProvider: playbackContextProvider,
            gracePeriodSignal: gracePeriodSignal,
            analytics: voiceAnalytics
        )

        let audioEngine = AVAudioEngine()
        let earconPlayer = EarconPlayer(engine: audioEngine)
        // The earcon player is the second producer of emitted audio, after the cloud
        // renderer. An earcon is audible to the microphone, so it belongs in the same
        // reference; without it, a chime played while the user speaks forms a segment the
        // filter cannot recognise as our output and the utterance is transcribed as if
        // the user had said it.
        earconPlayer.emittedPCMReference = echoReference
        earconPlayer.handoff = echoHandoff
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
            liveOriginManager: conversationManager,
            analytics: voiceAnalytics,
            contributionCollector: contributionCollector,
            isPlaybackActive: isPlaybackActive,
            onInputRoutingFinished: onInputRoutingFinished,
            testInputBarrier: testInputBarrier,
            onInputBarrierSettled: onInputBarrierSettled,
            onInputTerminal: onInputTerminal,
            parsedIntentObserverFactory: parsedIntentObserverFactory,
            preparedObserverFactory: preparedObserverFactory
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
    /// - Parameter override: PER-ASSEMBLY substitution; `nil` keeps the product selector, so
    ///   production is unchanged. A per-instance parameter rather than a global static, so one
    ///   fixture's substitution cannot leak into a concurrently running case.
    func resolveAsrBackend(locale: Locale, override: (() -> AsrBackend?)? = nil) -> AsrBackend? {
        if let override { return override() }
        return AsrBackendSelector().select(locale: locale)
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

    // MARK: - Acceptance operator entry

    /// THE OPERATOR INVOCATION for authenticated acceptance. It builds the SAME client the sink uses
    /// (`injectedClientFactory` when a test supplied one, else the production factory), so the harness
    /// submits through the app's real credential path, and it exports only the allowlisted fields.
    ///
    /// Reachable rather than merely callable: a caller that already holds the assembly invokes this with
    /// a nonce; nothing here reads a credential, and no authenticated request is issued unless a caller
    /// invokes it against a signed-in client.
    func runAcceptance(nonce: String, context: CloudRouteContext? = nil) async -> CloudAcceptanceHarness.Export {
        let client = acceptanceClientFactory()
        let routeContext = context ?? CloudRouteContext(episodeId: nil, clientPositionMs: nil)
        return await CloudAcceptanceHarness.run(nonce: nonce, client: client, context: routeContext)
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
