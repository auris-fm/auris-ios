import Foundation
import PocketCastsUtils
import PocketCastsDataModel

protocol PlaybackContextProvider {
    func current() -> PlaybackContext?
}

protocol PlaybackStateProviding {
    var currentEpisode: BaseEpisode? { get }
    func currentTimeSeconds() -> TimeInterval
}

protocol FingerprintMappingProviding {
    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval?
    /// Reverse map: reference (transcript) time → playback time. Nil when unmapped.
    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval?
}

final class CloudPlaybackContextState {
    private static let recentReferenceLimit = 5
    private let lock = NSLock()
    private var recentReferencePositions: [Int64]
    private var previousReferencePositionMs: Int64?

    init(
        recentReferencePositions: [Int64] = [],
        previousReferencePositionMs: Int64? = nil
    ) {
        self.recentReferencePositions = recentReferencePositions
        self.previousReferencePositionMs = previousReferencePositionMs
    }

    func snapshot() -> (recentReferencePositions: [Int64], previousReferencePositionMs: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        return (recentReferencePositions, previousReferencePositionMs)
    }

    func record(referencePositionMs: Int64, previousReferencePositionMs: Int64?) {
        lock.lock()
        defer { lock.unlock() }

        if let previousReferencePositionMs {
            self.previousReferencePositionMs = previousReferencePositionMs
        }

        recentReferencePositions.append(referencePositionMs)
        if recentReferencePositions.count > Self.recentReferenceLimit {
            recentReferencePositions.removeFirst(recentReferencePositions.count - Self.recentReferenceLimit)
        }
    }
}

struct DefaultPlaybackContextProvider: PlaybackContextProvider {
    let playbackState: PlaybackStateProviding
    let fingerprintMapper: FingerprintMappingProviding
    let cloudPlaybackContextState: CloudPlaybackContextState

    func current() -> PlaybackContext? {
        guard let episode = playbackState.currentEpisode else { return nil }

        let currentTimeSeconds = playbackState.currentTimeSeconds()
        let clientPositionMs = Self.milliseconds(fromSeconds: currentTimeSeconds)
        guard clientPositionMs >= 0 else { return nil }

        let referencePositionMs = fingerprintMapper
            .matchedReferenceTime(forPlaybackTime: currentTimeSeconds)
            .map(Self.milliseconds(fromSeconds:))

        let state = cloudPlaybackContextState.snapshot()
        let podcastId = podcastId(for: episode)

        return PlaybackContext(
            episodeId: episode.uuid,
            podcastId: podcastId,
            referencePositionMs: referencePositionMs,
            clientPositionMs: clientPositionMs,
            recentReferencePositions: state.recentReferencePositions,
            previousReferencePositionMs: state.previousReferencePositionMs
        )
    }

    private func podcastId(for episode: BaseEpisode) -> String? {
        let parentIdentifier = episode.parentIdentifier()
        return parentIdentifier == DataConstants.userEpisodeFakePodcastId ? nil : parentIdentifier
    }

    private static func milliseconds(fromSeconds seconds: TimeInterval) -> Int64 {
        Int64((seconds * 1000).rounded())
    }
}

extension PlaybackManager: PlaybackStateProviding {
    func currentTimeSeconds() -> TimeInterval {
        currentTime()
    }
}

extension FingerprintTimingManager: FingerprintMappingProviding {}

class VoiceIntentExecutor {
    private let playbackSink: VoicePlaybackSink
    private let effectsSink: VoiceEffectsSink
    private let volumeSink: VoiceVolumeSink
    private let sleepSink: VoiceSleepSink
    private let chapterSink: VoiceChapterSink
    private let bookmarkSink: VoiceBookmarkSink
    private let queueSink: VoiceQueueSink
    private let playbackQuerySink: VoicePlaybackQuerySink
    private let statsQuerySink: VoiceStatsQuerySink
    private let cloudRouteSink: VoiceCloudRouteSink
    private let playbackContextProvider: PlaybackContextProvider
    private let gracePeriodSignal: GracePeriodSignal
    private let analytics: VoiceAnalytics?

    init(
        playbackSink: VoicePlaybackSink,
        effectsSink: VoiceEffectsSink,
        volumeSink: VoiceVolumeSink,
        sleepSink: VoiceSleepSink,
        chapterSink: VoiceChapterSink,
        bookmarkSink: VoiceBookmarkSink,
        queueSink: VoiceQueueSink,
        playbackQuerySink: VoicePlaybackQuerySink,
        statsQuerySink: VoiceStatsQuerySink,
        cloudRouteSink: VoiceCloudRouteSink,
        playbackContextProvider: PlaybackContextProvider,
        gracePeriodSignal: GracePeriodSignal,
        analytics: VoiceAnalytics? = nil
    ) {
        self.playbackSink = playbackSink
        self.effectsSink = effectsSink
        self.volumeSink = volumeSink
        self.sleepSink = sleepSink
        self.chapterSink = chapterSink
        self.bookmarkSink = bookmarkSink
        self.queueSink = queueSink
        self.playbackQuerySink = playbackQuerySink
        self.statsQuerySink = statsQuerySink
        self.cloudRouteSink = cloudRouteSink
        self.playbackContextProvider = playbackContextProvider
        self.gracePeriodSignal = gracePeriodSignal
        self.analytics = analytics
    }

    func execute(_ intent: any VoiceIntent) async -> VoiceResponse {
        let response: VoiceResponse
        switch intent {
        case let p as PlaybackIntent: response = executePlayback(p)
        case let e as EffectsIntent: response = executeEffects(e)
        case let v as VolumeIntent: response = executeVolume(v)
        case let s as SleepIntent: response = executeSleep(s)
        case let c as ChapterIntent: response = executeChapter(c)
        case let b as BookmarkIntent: response = executeBookmark(b)
        case let q as QueueIntent: response = executeQueue(q)
        case let pq as PlaybackQueryIntent: response = executePlaybackQuery(pq)
        case let sq as StatsQueryIntent: response = executeStatsQuery(sq)
        case let cr as CloudRouteIntent:
            guard let context = playbackContextProvider.current() else {
                response = .earcon(.error)
                break
            }
            response = await cloudRouteSink.routeToCloud(
                request: cr.request,
                tier: cr.tier,
                context: context
            )
        default: response = .earcon(.error)
        }

        // Record analytics after every command
        analytics?.recordCommand(intent, response: response)

        // Start grace period after any successful (non-error) command
        if case .earcon(.error) = response {
            FileLog.shared.addMessage("[VoicePipeline] Command failed — no grace period")
        } else {
            FileLog.shared.addMessage("[VoicePipeline] Command succeeded — grace period")
            gracePeriodSignal.onCommandRecognized()
        }

        return response
    }

    private func executePlayback(_ intent: PlaybackIntent) -> VoiceResponse {
        switch intent {
        case .pause: return playbackSink.pause()
        case .resume: return playbackSink.resume()
        case .seekRelative(let delta): return playbackSink.seekRelative(deltaSeconds: delta)
        case .seekTo(let pos): return playbackSink.seekTo(positionSeconds: pos)
        case .nextEpisode: return playbackSink.nextEpisode()
        }
    }

    private func executeEffects(_ intent: EffectsIntent) -> VoiceResponse {
        switch intent {
        case .setSpeed(let speed): return effectsSink.setSpeed(speed)
        case .adjustSpeed(let delta): return effectsSink.adjustSpeed(delta: delta)
        case .setTrimMode(let mode): return effectsSink.setTrimMode(mode)
        case .setVolumeBoost(let enabled): return effectsSink.setVolumeBoost(enabled: enabled)
        case .query: return effectsSink.queryEffects()
        }
    }

    private func executeVolume(_ intent: VolumeIntent) -> VoiceResponse {
        switch intent {
        case .setVolume(let volume): return volumeSink.setVolume(volume)
        case .adjustVolume(let delta): return volumeSink.adjustVolume(delta: delta)
        case .query: return volumeSink.queryVolume()
        }
    }

    private func executeSleep(_ intent: SleepIntent) -> VoiceResponse {
        switch intent {
        case .set(let minutes): return sleepSink.set(minutes: minutes)
        case .endOfEpisode: return sleepSink.endOfEpisode()
        case .endOfChapter: return sleepSink.endOfChapter()
        case .addTime(let minutes): return sleepSink.addTime(minutes: minutes)
        case .cancel: return sleepSink.cancel()
        case .query: return sleepSink.query()
        }
    }

    private func executeChapter(_ intent: ChapterIntent) -> VoiceResponse {
        switch intent {
        case .next: return chapterSink.next()
        case .previous: return chapterSink.previous()
        case .byIndex(let index): return chapterSink.byIndex(index)
        case .byTitle(let title): return chapterSink.byTitle(title)
        case .openLink(let index, let query): return chapterSink.openLink(index: index, query: query)
        case .queryList: return chapterSink.queryList()
        case .queryCurrent: return chapterSink.queryCurrent()
        case .queryCount: return chapterSink.queryCount()
        case .queryNext: return chapterSink.queryNext()
        }
    }

    private func executeBookmark(_ intent: BookmarkIntent) -> VoiceResponse {
        switch intent {
        case .add(let title): return bookmarkSink.add(title: title)
        case .rename(let ref, let title): return bookmarkSink.rename(ref: ref, title: title)
        case .play(let ref): return bookmarkSink.play(ref: ref)
        case .delete(let ref): return bookmarkSink.delete(ref: ref)
        case .deleteAll: return bookmarkSink.deleteAll()
        case .queryList: return bookmarkSink.queryList()
        case .queryCount: return bookmarkSink.queryCount()
        case .queryNearby: return bookmarkSink.queryNearby()
        }
    }

    private func executeQueue(_ intent: QueueIntent) -> VoiceResponse {
        switch intent {
        case .addTop(let episode): return queueSink.addTop(episode: episode)
        case .addBottom(let episode): return queueSink.addBottom(episode: episode)
        case .remove(let episode): return queueSink.remove(episode: episode)
        case .moveToTop(let episode): return queueSink.moveToTop(episode: episode)
        case .moveToBottom(let episode): return queueSink.moveToBottom(episode: episode)
        case .clear: return queueSink.clear()
        case .removeByPodcast(let podcast): return queueSink.removeByPodcast(podcast: podcast)
        case .sort(let sortOrder): return queueSink.sort(sortOrder: sortOrder)
        case .queryContents: return queueSink.queryContents()
        case .queryNext: return queueSink.queryNext()
        case .queryLength: return queueSink.queryLength()
        case .queryIsQueued(let episode): return queueSink.queryIsQueued(episode: episode)
        }
    }

    private func executePlaybackQuery(_ intent: PlaybackQueryIntent) -> VoiceResponse {
        switch intent {
        case .whatsPlaying: return playbackQuerySink.whatsPlaying()
        case .position: return playbackQuerySink.position()
        case .timeRemaining: return playbackQuerySink.timeRemaining()
        case .episodeDuration: return playbackQuerySink.episodeDuration()
        case .publishDate: return playbackQuerySink.publishDate()
        case .episodeDescription: return playbackQuerySink.episodeDescription()
        case .downloadStatus: return playbackQuerySink.downloadStatus()
        case .episodeTitle: return playbackQuerySink.episodeTitle()
        }
    }

    private func executeStatsQuery(_ intent: StatsQueryIntent) -> VoiceResponse {
        switch intent {
        case .listeningTime(let period): return statsQuerySink.listeningTime(period: period)
        case .topPodcasts(let period): return statsQuerySink.topPodcasts(period: period)
        case .episodesFinished(let period): return statsQuerySink.episodesFinished(period: period)
        case .listeningStreak: return statsQuerySink.listeningStreak()
        case .subscriptionCount: return statsQuerySink.subscriptionCount()
        case .unplayedTotal: return statsQuerySink.unplayedTotal()
        case .downloadStats: return statsQuerySink.downloadStats()
        case .newEpisodes(let timeframe): return statsQuerySink.newEpisodes(timeframe: timeframe)
        case .timeSinceLastListen: return statsQuerySink.timeSinceLastListen()
        }
    }
}
