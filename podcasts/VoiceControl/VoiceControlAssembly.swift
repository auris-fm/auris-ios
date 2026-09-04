import AVFoundation
import PocketCastsDataModel
import PocketCastsUtils

class VoiceControlAssembly {
    /// Returns nil when the wake-word deployment manifest is missing or
    /// mismatched (fail closed): voice control must not start without a valid
    /// deployment threshold and verified assets.
    func buildVoiceControlService() -> VoiceControlService? {
        let gracePeriodSignal = GracePeriodSignal()

        let routeMonitor = IOSAudioRouteMonitor(gracePeriodSignal: gracePeriodSignal)
        let conditionMonitor = LiveConditionMonitor(gracePeriodSignal: gracePeriodSignal)
        let interruptionHandler = AudioSessionInterruptionHandler()
        let playbackManager = PlaybackManager.shared

        let asrBackend = AsrBackendSelector().select(locale: .current)

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
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(threshold: 0.020),
            backend: asrBackend,
            signalFilter: SignalFilter(),
            wakeWordDetector: wakeWordDetector,
            gracePeriodSignal: gracePeriodSignal,
            clock: SystemMonotonicClock(),
            wakeThreshold: threshold,
            translationStage: AppleTranslationTranslator()
        )
        // Start SenseVoice/Canary download+init immediately so first wake isn't
        // blocked behind a multi-minute silent await after listening starts.
        asrEngine.preloadBackend()

        let intentRouter = LfmIntentRouter()
        // Same for LFM — don't wait until startIfAllowed to begin download/load.
        Task {
            _ = await intentRouter.ensureReady()
        }

        let analyticsService = DefaultAnalyticsService()
        let voiceAnalytics = VoiceAnalytics(analytics: analyticsService)

        let executor = VoiceIntentExecutor(
            playbackSink: PlaybackManagerSink(playbackManager: playbackManager),
            effectsSink: EffectsManagerSink(playbackManager: playbackManager),
            volumeSink: VolumeManagerSink(),
            sleepSink: SleepTimerSink(playbackManager: playbackManager),
            chapterSink: ChapterSink(playbackManager: playbackManager),
            bookmarkSink: BookmarkSink(playbackManager: playbackManager),
            queueSink: QueueSink(playbackManager: playbackManager, dataManager: .sharedManager),
            playbackQuerySink: PlaybackQuerySink(playbackManager: playbackManager),
            statsQuerySink: StatsQuerySink(dataManager: .sharedManager),
            cloudRouteSink: CloudRouteSink(),
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
            analytics: voiceAnalytics
        )
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
