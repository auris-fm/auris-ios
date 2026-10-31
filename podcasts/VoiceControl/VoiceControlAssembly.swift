import AVFoundation
import Combine
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

class VoiceControlAssembly {
    /// THE PRODUCTION APP-OPERATION DECLARATION (enablement slices, task67): pause + resume.
    /// ONE value with two consumers that must never disagree: the CloudRouteSink construction
    /// below wires it as the sink's `appOperationSupportProvider`, and the sink reads the
    /// provider ONCE per admitted turn — the same captured value serializes the authenticate
    /// frame (`app_operations_v1` + `app_operation_support`) and gates identified execution at
    /// the `.claimed` boundary. Every other operation stays ABSENT: an identified
    /// `seek_relative`/`seek_to`/quote request refuses `unsupported_operation`, durably,
    /// until its own enablement slice. ADVERTISEMENT IS NOT END-TO-END AVAILABILITY: server
    /// eligibility for resume is a separate Cloud slice, so this manifest alone must never be
    /// reported as resume being available end-to-end. The failable init stays: a malformed
    /// literal here must be nil (empty declaration), never a crash or a repaired shape. Tests
    /// bind THIS value by name (`VoiceControlAssembly.declaredAppOperations`) so behavior
    /// controls and the assembly cannot drift apart.
    static let declaredAppOperations = CloudAppOperationSupport(operations: ["playback.pause", "playback.resume"])

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
            wakeThreshold: threshold,
            translationStage: AppleTranslationTranslator()
        )
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
                admittedWorkAuthority: { gracePeriodSignal.admittedWorkAuthority },
                // APP-OPERATION ENABLEMENT (task67): the production declaration above, read by
                // the sink once per turn — the SAME snapshot advertises on the authenticate
                // frame and gates execution. Behavior controls bind the constant; the wiring
                // HERE is pinned by the assembly source-audit control.
                appOperationSupportProvider: { Self.declaredAppOperations }
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

        return VoiceControlService(
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
            isPlaybackActive: isPlaybackActive,
            onInputRoutingFinished: onInputRoutingFinished,
            testInputBarrier: testInputBarrier,
            onInputBarrierSettled: onInputBarrierSettled,
            onInputTerminal: onInputTerminal,
            parsedIntentObserverFactory: parsedIntentObserverFactory,
            preparedObserverFactory: preparedObserverFactory
        )
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
