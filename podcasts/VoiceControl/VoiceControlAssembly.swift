import AVFoundation
import PocketCastsDataModel

class VoiceControlAssembly {
    func buildVoiceControlService() -> VoiceControlService {
        let attendedSignal = AttendedSignal()
        let gracePeriodSignal = GracePeriodSignal()
        let playbackRecencySignal = PlaybackRecencySignal()

        let routeMonitor = IOSAudioRouteMonitor(gracePeriodSignal: gracePeriodSignal)
        let conditionMonitor = LiveConditionMonitor(gracePeriodSignal: gracePeriodSignal)
        let playbackManager = PlaybackManager.shared

        let asrBackend = AsrBackendSelector().select(
            locale: .current,
            hasNPU: hasNeuralEngine(),
            senseVoiceShipped: false
        )
        let asrEngine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: asrBackend,
            signalFilter: SignalFilter()
        )

        let wakeWordDetector = WakeWordDetector(
            melModel: bundleURL("melspectrogram.onnx"),
            embedModel: bundleURL("embedding_model.onnx"),
            classifierModel: bundleURL("auris.onnx"),
            threshold: 0.5
        )

        let intentRouter = FunctionGemmaIntentRouter()

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
            gracePeriodSignal: gracePeriodSignal
        )

        let audioEngine = AVAudioEngine()
        let earconPlayer = EarconPlayer(engine: audioEngine)
        let ttsEngine = AVSpeechTtsEngine()
        let audioRenderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: ttsEngine)

        return VoiceControlService(
            conditionMonitor: conditionMonitor,
            routeMonitor: routeMonitor,
            asrEngine: asrEngine,
            wakeWordDetector: wakeWordDetector,
            intentRouter: intentRouter,
            executor: executor,
            dialogManager: VoiceDialogManager(),
            audioRenderer: audioRenderer,
            attendedSignal: attendedSignal,
            gracePeriodSignal: gracePeriodSignal,
            playbackRecencySignal: playbackRecencySignal
        )
    }

    private func bundleURL(_ filename: String) -> URL {
        Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "oww")!
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

// MARK: - Remaining Sink Implementations

private class PlaybackQuerySink: VoicePlaybackQuerySink {
    private let playbackManager: PlaybackManager

    init(playbackManager: PlaybackManager) { self.playbackManager = playbackManager }

    func whatsPlaying() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() else {
            return .spoken("Nothing is playing")
        }
        return .spoken("Playing \(episode.displayableTitle())")
    }

    func position() -> VoiceResponse {
        let time = playbackManager.currentTime()
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return .spoken("\(minutes) minutes \(seconds) seconds")
    }

    func timeRemaining() -> VoiceResponse {
        let remaining = playbackManager.duration() - playbackManager.currentTime()
        let minutes = Int(remaining) / 60
        return .spoken("\(minutes) minutes remaining")
    }

    func episodeDuration() -> VoiceResponse {
        let duration = playbackManager.duration()
        let minutes = Int(duration) / 60
        return .spoken("\(minutes) minutes total")
    }

    func publishDate() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() as? Episode,
              let date = episode.publishedDate else {
            return .spoken("Unknown publish date")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return .spoken("Published \(formatter.string(from: date))")
    }

    func episodeDescription() -> VoiceResponse {
        return .spoken("Episode description unavailable")
    }

    func downloadStatus() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() else {
            return .spoken("Nothing playing")
        }
        let downloaded = episode.downloaded(pathFinder: DownloadManager.shared)
        return .spoken(downloaded ? "Downloaded" : "Streaming")
    }

    func episodeTitle() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() else {
            return .spoken("Nothing playing")
        }
        return .spoken(episode.displayableTitle())
    }
}

private class StatsQuerySink: VoiceStatsQuerySink {
    private let dataManager: DataManager

    init(dataManager: DataManager) { self.dataManager = dataManager }

    func listeningTime(period: String?) -> VoiceResponse {
        .spoken("Check Stats in the Profile tab for detailed listening time")
    }

    func topPodcasts(period: String?) -> VoiceResponse {
        .spoken("Check Stats in the Profile tab for your top podcasts")
    }

    func episodesFinished(period: String?) -> VoiceResponse {
        .spoken("Check Stats in the Profile tab for completed episodes")
    }

    func listeningStreak() -> VoiceResponse {
        .spoken("Check Stats in the Profile tab for your listening streak")
    }

    func subscriptionCount() -> VoiceResponse {
        let count = dataManager.allPodcasts(includeUnsubscribed: false).count
        return .spoken("\(count) subscriptions")
    }

    func unplayedTotal() -> VoiceResponse {
        return .spoken("Check the Podcasts tab for unplayed episodes")
    }

    func downloadStats() -> VoiceResponse {
        let count = dataManager.downloadedEpisodeCount()
        return .spoken("\(count) downloaded episodes")
    }

    func newEpisodes(timeframe: String?) -> VoiceResponse {
        .spoken("Check the Podcasts tab for new episodes")
    }

    func timeSinceLastListen() -> VoiceResponse {
        .spoken("Check Stats in the Profile tab")
    }
}

private class CloudRouteSink: VoiceCloudRouteSink {
    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> VoiceResponse {
        // Cloud routing will be wired when the cloud intent service is deployed
        .spoken("Cloud processing is coming soon")
    }
}
