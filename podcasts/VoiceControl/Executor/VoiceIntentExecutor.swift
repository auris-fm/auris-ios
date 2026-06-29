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
        cloudRouteSink: VoiceCloudRouteSink
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
    }

    func execute(_ intent: any VoiceIntent) async -> VoiceResponse {
        switch intent {
        case let p as PlaybackIntent: return executePlayback(p)
        case let e as EffectsIntent: return executeEffects(e)
        case let v as VolumeIntent: return executeVolume(v)
        case let s as SleepIntent: return executeSleep(s)
        case let c as ChapterIntent: return executeChapter(c)
        case let b as BookmarkIntent: return executeBookmark(b)
        case let q as QueueIntent: return executeQueue(q)
        case let pq as PlaybackQueryIntent: return executePlaybackQuery(pq)
        case let sq as StatsQueryIntent: return executeStatsQuery(sq)
        case let cr as CloudRouteIntent:
            return await cloudRouteSink.routeToCloud(
                request: cr.request,
                tier: cr.tier,
                context: cr.context
            )
        default: return .earcon(.error)
        }
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
