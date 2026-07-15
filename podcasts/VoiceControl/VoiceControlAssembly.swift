import AVFoundation
import PocketCastsDataModel
import PocketCastsUtils

class VoiceControlAssembly {
    func buildVoiceControlService() -> VoiceControlService {
        let gracePeriodSignal = GracePeriodSignal()

        let routeMonitor = IOSAudioRouteMonitor(gracePeriodSignal: gracePeriodSignal)
        let conditionMonitor = LiveConditionMonitor(gracePeriodSignal: gracePeriodSignal)
        let interruptionHandler = AudioSessionInterruptionHandler()
        let playbackManager = PlaybackManager.shared

        let asrBackend = AsrBackendSelector().select(
            locale: .current,
            hasNPU: hasNeuralEngine(),
            senseVoiceShipped: false
        )
        let wakeWordDetector = WakeWordDetector(
            melModel: bundleURL("melspectrogram.onnx"),
            embedModel: bundleURL("embedding_model.onnx"),
            classifierModel: bundleURL("auris.onnx"),
            // Balanced threshold (elbow of recall-vs-FPPH curve): 86.0% recall, 10.0 FPPH.
            // From auris_medium eval — update when retraining.
            threshold: 0.54
        )

        let commandWindow = CommandWindowManager()

        let asrEngine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: asrBackend,
            signalFilter: SignalFilter(),
            wakeWordDetector: wakeWordDetector,
            commandWindow: commandWindow
        )

        let intentRouter = FunctionGemmaIntentRouter()

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
            gracePeriodSignal: gracePeriodSignal
        )
    }

    private func bundleURL(_ filename: String) -> URL {
        Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "wakeword")!
    }

    private func hasNeuralEngine() -> Bool {
        // A12+ (iPhone XS/XR and newer) have Apple Neural Engine
        var systemInfo = utsname()
        uname(&systemInfo)
        let modelCode = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0)
            }
        }
        // iPhone XS = iPhone11,x, XR = iPhone11,8 — all iPhone11+ have ANE
        guard let model = modelCode, model.hasPrefix("iPhone") else { return true }
        let components = model.components(separatedBy: ",")
        guard let majorStr = components.first?.replacingOccurrences(of: "iPhone", with: ""),
              let major = Int(majorStr) else { return true }
        return major >= 11
    }
}

// MARK: - Analytics Service Bridge

private class DefaultAnalyticsService: AnalyticsService {
    func track(_ event: String, properties: [String: Any]) {
        FileLog.shared.addMessage("[VoiceControl/Analytics] event=\(event) properties=\(properties)")
        // TODO: Wire to Analytics shared instance when a public API for raw event
        // names is exposed. Currently Analytics.track() requires an AnalyticsEvent
        // enum case, but voice events use dynamic string names.
    }
}

