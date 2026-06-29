import XCTest
@testable import podcasts

final class VoiceIntentExecutorIntegrationTests: XCTestCase {

    func test_execute_seekRelative_clampsToBounds() async {
        let sink = IntegrationPlaybackSink(currentPosition: 10, episodeDuration: 60)
        let executor = makeExecutor(playbackSink: sink)
        _ = await executor.execute(PlaybackIntent.seekRelative(deltaSeconds: -30))
        // Position should be clamped to 0
        XCTAssertEqual(sink.lastSeekPosition, 0)
    }

    func test_execute_seekTo_convertsToAppropriateUnit() async {
        let sink = IntegrationPlaybackSink(currentPosition: 0, episodeDuration: 600)
        let executor = makeExecutor(playbackSink: sink)
        _ = await executor.execute(PlaybackIntent.seekTo(positionSeconds: 120))
        XCTAssertEqual(sink.lastSeekPosition, 120)
    }

    func test_execute_seekTo_beyondEnd_clampsToDuration() async {
        let sink = IntegrationPlaybackSink(currentPosition: 0, episodeDuration: 60)
        let executor = makeExecutor(playbackSink: sink)
        _ = await executor.execute(PlaybackIntent.seekTo(positionSeconds: 999))
        XCTAssertEqual(sink.lastSeekPosition, 60)
    }

    func test_execute_allPlaybackIntents_noCrash() async {
        let executor = makeExecutor()
        let intents: [PlaybackIntent] = [.pause, .resume, .seekRelative(deltaSeconds: 15), .seekTo(positionSeconds: 60), .nextEpisode]
        for intent in intents {
            let response = await executor.execute(intent)
            switch response {
            case .silent, .earcon, .spoken: break // all valid
            }
        }
    }

    func test_execute_allEffectsIntents_noCrash() async {
        let executor = makeExecutor()
        let intents: [EffectsIntent] = [.setSpeed(1.5), .adjustSpeed(delta: 0.25), .setTrimMode(.medium), .setVolumeBoost(enabled: true), .query]
        for intent in intents {
            let response = await executor.execute(intent)
            switch response {
            case .silent, .earcon, .spoken: break
            }
        }
    }

    func test_execute_cloudRoute_asyncCompletion() async {
        let cloudSink = IntegrationCloudRouteSink()
        let executor = makeExecutor(cloudRouteSink: cloudSink)
        let context = PlaybackContext(episodeId: "ep1", positionMs: 0, recentTimestamps: [])
        let response = await executor.execute(CloudRouteIntent(request: "test", tier: .premium, context: context))
        XCTAssertEqual(response, .spoken("Cloud response"))
    }

    // MARK: - Helpers

    private func makeExecutor(
        playbackSink: VoicePlaybackSink = IntegrationPlaybackSink(currentPosition: 0, episodeDuration: 0),
        cloudRouteSink: VoiceCloudRouteSink = IntegrationCloudRouteSink()
    ) -> VoiceIntentExecutor {
        VoiceIntentExecutor(
            playbackSink: playbackSink,
            effectsSink: NoOpEffectsSink(),
            volumeSink: NoOpVolumeSink(),
            sleepSink: NoOpSleepSink(),
            chapterSink: NoOpChapterSink(),
            bookmarkSink: NoOpBookmarkSink(),
            queueSink: NoOpQueueSink(),
            playbackQuerySink: NoOpPlaybackQuerySink(),
            statsQuerySink: NoOpStatsQuerySink(),
            cloudRouteSink: cloudRouteSink
        )
    }
}

// MARK: - Integration Sinks

private final class IntegrationPlaybackSink: VoicePlaybackSink {
    let currentPosition: Int
    let episodeDuration: Int
    var lastSeekPosition: Int?

    init(currentPosition: Int, episodeDuration: Int) {
        self.currentPosition = currentPosition
        self.episodeDuration = episodeDuration
    }

    func pause() -> VoiceResponse { .earcon(.success) }
    func resume() -> VoiceResponse { .silent }
    func seekRelative(deltaSeconds: Int) -> VoiceResponse {
        let newPos = max(0, min(episodeDuration, currentPosition + deltaSeconds))
        lastSeekPosition = newPos
        return .silent
    }
    func seekTo(positionSeconds: Int) -> VoiceResponse {
        lastSeekPosition = min(episodeDuration, max(0, positionSeconds))
        return .silent
    }
    func nextEpisode() -> VoiceResponse { .spoken("Playing next episode") }
}

private final class IntegrationCloudRouteSink: VoiceCloudRouteSink {
    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> VoiceResponse {
        .spoken("Cloud response")
    }
}

private final class NoOpEffectsSink: VoiceEffectsSink {
    func setSpeed(_ speed: Double) -> VoiceResponse { .silent }
    func adjustSpeed(delta: Double) -> VoiceResponse { .silent }
    func setTrimMode(_ mode: TrimMode) -> VoiceResponse { .silent }
    func setVolumeBoost(enabled: Bool) -> VoiceResponse { .silent }
    func queryEffects() -> VoiceResponse { .silent }
}

private final class NoOpVolumeSink: VoiceVolumeSink {
    func setVolume(_ volume: Int) -> VoiceResponse { .silent }
    func adjustVolume(delta: Int) -> VoiceResponse { .silent }
    func queryVolume() -> VoiceResponse { .silent }
}

private final class NoOpSleepSink: VoiceSleepSink {
    func set(minutes: Int) -> VoiceResponse { .silent }
    func endOfEpisode() -> VoiceResponse { .silent }
    func endOfChapter() -> VoiceResponse { .silent }
    func addTime(minutes: Int) -> VoiceResponse { .silent }
    func cancel() -> VoiceResponse { .silent }
    func query() -> VoiceResponse { .silent }
}

private final class NoOpChapterSink: VoiceChapterSink {
    func next() -> VoiceResponse { .silent }
    func previous() -> VoiceResponse { .silent }
    func byIndex(_ index: Int) -> VoiceResponse { .silent }
    func byTitle(_ title: String) -> VoiceResponse { .silent }
    func openLink(index: Int?, query: String?) -> VoiceResponse { .silent }
    func queryList() -> VoiceResponse { .silent }
    func queryCurrent() -> VoiceResponse { .silent }
    func queryCount() -> VoiceResponse { .silent }
    func queryNext() -> VoiceResponse { .silent }
}

private final class NoOpBookmarkSink: VoiceBookmarkSink {
    func add(title: String?) -> VoiceResponse { .silent }
    func rename(ref: String, title: String) -> VoiceResponse { .silent }
    func play(ref: String) -> VoiceResponse { .silent }
    func delete(ref: String) -> VoiceResponse { .silent }
    func deleteAll() -> VoiceResponse { .silent }
    func queryList() -> VoiceResponse { .silent }
    func queryCount() -> VoiceResponse { .silent }
    func queryNearby() -> VoiceResponse { .silent }
}

private final class NoOpQueueSink: VoiceQueueSink {
    func addTop(episode: String) -> VoiceResponse { .silent }
    func addBottom(episode: String) -> VoiceResponse { .silent }
    func remove(episode: String) -> VoiceResponse { .silent }
    func moveToTop(episode: String) -> VoiceResponse { .silent }
    func moveToBottom(episode: String) -> VoiceResponse { .silent }
    func clear() -> VoiceResponse { .silent }
    func removeByPodcast(podcast: String) -> VoiceResponse { .silent }
    func sort(sortOrder: SortOrder) -> VoiceResponse { .silent }
    func queryContents() -> VoiceResponse { .silent }
    func queryNext() -> VoiceResponse { .silent }
    func queryLength() -> VoiceResponse { .silent }
    func queryIsQueued(episode: String) -> VoiceResponse { .silent }
}

private final class NoOpPlaybackQuerySink: VoicePlaybackQuerySink {
    func whatsPlaying() -> VoiceResponse { .silent }
    func position() -> VoiceResponse { .silent }
    func timeRemaining() -> VoiceResponse { .silent }
    func episodeDuration() -> VoiceResponse { .silent }
    func publishDate() -> VoiceResponse { .silent }
    func episodeDescription() -> VoiceResponse { .silent }
    func downloadStatus() -> VoiceResponse { .silent }
    func episodeTitle() -> VoiceResponse { .silent }
}

private final class NoOpStatsQuerySink: VoiceStatsQuerySink {
    func listeningTime(period: String?) -> VoiceResponse { .silent }
    func topPodcasts(period: String?) -> VoiceResponse { .silent }
    func episodesFinished(period: String?) -> VoiceResponse { .silent }
    func listeningStreak() -> VoiceResponse { .silent }
    func subscriptionCount() -> VoiceResponse { .silent }
    func unplayedTotal() -> VoiceResponse { .silent }
    func downloadStats() -> VoiceResponse { .silent }
    func newEpisodes(timeframe: String?) -> VoiceResponse { .silent }
    func timeSinceLastListen() -> VoiceResponse { .silent }
}
