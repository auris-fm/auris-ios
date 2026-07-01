import XCTest
@testable import podcasts

final class VoiceIntentExecutorTests: XCTestCase {

    var executor: VoiceIntentExecutor!
    var mockPlaybackSink: MockPlaybackSink!
    var mockEffectsSink: MockEffectsSink!
    var mockVolumeSink: MockVolumeSink!
    var mockSleepSink: MockSleepSink!
    var mockChapterSink: MockChapterSink!
    var mockBookmarkSink: MockBookmarkSink!
    var mockQueueSink: MockQueueSink!
    var mockPlaybackQuerySink: MockPlaybackQuerySink!
    var mockStatsQuerySink: MockStatsQuerySink!
    var mockCloudRouteSink: MockCloudRouteSink!
    var gracePeriodSignal: GracePeriodSignal!

    override func setUp() {
        super.setUp()
        mockPlaybackSink = MockPlaybackSink()
        mockEffectsSink = MockEffectsSink()
        mockVolumeSink = MockVolumeSink()
        mockSleepSink = MockSleepSink()
        mockChapterSink = MockChapterSink()
        mockBookmarkSink = MockBookmarkSink()
        mockQueueSink = MockQueueSink()
        mockPlaybackQuerySink = MockPlaybackQuerySink()
        mockStatsQuerySink = MockStatsQuerySink()
        mockCloudRouteSink = MockCloudRouteSink()
        gracePeriodSignal = GracePeriodSignal()
        executor = VoiceIntentExecutor(
            playbackSink: mockPlaybackSink,
            effectsSink: mockEffectsSink,
            volumeSink: mockVolumeSink,
            sleepSink: mockSleepSink,
            chapterSink: mockChapterSink,
            bookmarkSink: mockBookmarkSink,
            queueSink: mockQueueSink,
            playbackQuerySink: mockPlaybackQuerySink,
            statsQuerySink: mockStatsQuerySink,
            cloudRouteSink: mockCloudRouteSink,
            gracePeriodSignal: gracePeriodSignal
        )
    }

    func test_execute_pause_callsSinkPause() async {
        let response = await executor.execute(PlaybackIntent.pause)
        XCTAssertTrue(mockPlaybackSink.pauseCalled)
        XCTAssertEqual(response, .earcon(.success))
    }

    func test_execute_resume_returnsSilent() async {
        let response = await executor.execute(PlaybackIntent.resume)
        XCTAssertEqual(response, .silent)
    }

    func test_execute_nextEpisode_returnsSpokenWithTitle() async {
        mockPlaybackSink.nextEpisodeResponse = .spoken("Playing The Daily")
        let response = await executor.execute(PlaybackIntent.nextEpisode)
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("The Daily"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_execute_seekRelative_forwardsDelta() async {
        _ = await executor.execute(PlaybackIntent.seekRelative(deltaSeconds: 30))
        XCTAssertEqual(mockPlaybackSink.lastSeekRelativeDelta, 30)
    }

    func test_execute_setSpeed_forwardsSpeed() async {
        _ = await executor.execute(EffectsIntent.setSpeed(1.5))
        XCTAssertEqual(mockEffectsSink.lastSetSpeed, 1.5)
    }

    func test_execute_setVolume_forwardsVolume() async {
        _ = await executor.execute(VolumeIntent.setVolume(80))
        XCTAssertEqual(mockVolumeSink.lastSetVolume, 80)
    }

    func test_execute_sleepSet_forwardsMinutes() async {
        _ = await executor.execute(SleepIntent.set(minutes: 45))
        XCTAssertTrue(mockSleepSink.setCalled)
        XCTAssertEqual(mockSleepSink.lastMinutes, 45)
    }

    func test_execute_chapterByIndex_forwardsIndex() async {
        _ = await executor.execute(ChapterIntent.byIndex(3))
        XCTAssertEqual(mockChapterSink.lastIndex, 3)
    }

    func test_execute_bookmarkAdd_forwardsTitle() async {
        _ = await executor.execute(BookmarkIntent.add(title: "Great quote"))
        XCTAssertEqual(mockBookmarkSink.lastTitle, "Great quote")
    }

    func test_execute_queueAddTop_forwardsEpisode() async {
        _ = await executor.execute(QueueIntent.addTop(episode: "ep123"))
        XCTAssertEqual(mockQueueSink.lastEpisode, "ep123")
    }

    func test_execute_cloudRoute_callsCloudSink() async {
        let context = PlaybackContext(episodeId: "ep1", positionMs: 5000, recentTimestamps: [])
        let intent = CloudRouteIntent(request: "find similar", tier: .premium, context: context)
        _ = await executor.execute(intent)
        XCTAssertTrue(mockCloudRouteSink.routeToCloudCalled)
        XCTAssertEqual(mockCloudRouteSink.lastRequest, "find similar")
    }

    func test_execute_success_activatesGracePeriod() async {
        XCTAssertFalse(gracePeriodSignal.isActive)
        _ = await executor.execute(PlaybackIntent.pause)
        XCTAssertTrue(gracePeriodSignal.isActive)
    }
}

// MARK: - Mock Sinks

private final class MockPlaybackSink: VoicePlaybackSink {
    var pauseCalled = false
    var lastSeekRelativeDelta: Int?
    var lastSeekToPosition: Int?
    var nextEpisodeResponse: VoiceResponse = .earcon(.nextEpisode)

    func pause() -> VoiceResponse { pauseCalled = true; return .earcon(.success) }
    func resume() -> VoiceResponse { .silent }
    func seekRelative(deltaSeconds: Int) -> VoiceResponse { lastSeekRelativeDelta = deltaSeconds; return .silent }
    func seekTo(positionSeconds: Int) -> VoiceResponse { lastSeekToPosition = positionSeconds; return .silent }
    func nextEpisode() -> VoiceResponse { nextEpisodeResponse }
}

private final class MockEffectsSink: VoiceEffectsSink {
    var lastSetSpeed: Double?
    var lastDelta: Double?
    var lastTrimMode: TrimMode?
    var lastVolumeBoostEnabled: Bool?

    func setSpeed(_ speed: Double) -> VoiceResponse { lastSetSpeed = speed; return .silent }
    func adjustSpeed(delta: Double) -> VoiceResponse { lastDelta = delta; return .silent }
    func setTrimMode(_ mode: TrimMode) -> VoiceResponse { lastTrimMode = mode; return .earcon(.success) }
    func setVolumeBoost(enabled: Bool) -> VoiceResponse { lastVolumeBoostEnabled = enabled; return .earcon(.success) }
    func queryEffects() -> VoiceResponse { .spoken("Speed is 1x") }
}

private final class MockVolumeSink: VoiceVolumeSink {
    var lastSetVolume: Int?
    var lastAdjustDelta: Int?

    func setVolume(_ volume: Int) -> VoiceResponse { lastSetVolume = volume; return .silent }
    func adjustVolume(delta: Int) -> VoiceResponse { lastAdjustDelta = delta; return .silent }
    func queryVolume() -> VoiceResponse { .spoken("Volume is 80") }
}

private final class MockSleepSink: VoiceSleepSink {
    var setCalled = false
    var lastMinutes: Int?

    func set(minutes: Int) -> VoiceResponse { setCalled = true; lastMinutes = minutes; return .earcon(.success) }
    func endOfEpisode() -> VoiceResponse { .earcon(.success) }
    func endOfChapter() -> VoiceResponse { .earcon(.success) }
    func addTime(minutes: Int) -> VoiceResponse { .earcon(.success) }
    func cancel() -> VoiceResponse { .earcon(.success) }
    func query() -> VoiceResponse { .spoken("30 minutes remaining") }
}

private final class MockChapterSink: VoiceChapterSink {
    var lastIndex: Int?
    var lastTitle: String?

    func next() -> VoiceResponse { .earcon(.success) }
    func previous() -> VoiceResponse { .earcon(.success) }
    func byIndex(_ index: Int) -> VoiceResponse { lastIndex = index; return .earcon(.success) }
    func byTitle(_ title: String) -> VoiceResponse { lastTitle = title; return .earcon(.success) }
    func openLink(index: Int?, query: String?) -> VoiceResponse { .spoken("Opening link") }
    func queryList() -> VoiceResponse { .spoken("5 chapters") }
    func queryCurrent() -> VoiceResponse { .spoken("Chapter 3") }
    func queryCount() -> VoiceResponse { .spoken("5 chapters") }
    func queryNext() -> VoiceResponse { .spoken("Chapter 4: The Plot Thickens") }
}

private final class MockBookmarkSink: VoiceBookmarkSink {
    var lastTitle: String?
    var lastRef: String?

    func add(title: String?) -> VoiceResponse { lastTitle = title; return .earcon(.success) }
    func rename(ref: String, title: String) -> VoiceResponse { lastRef = ref; lastTitle = title; return .earcon(.success) }
    func play(ref: String) -> VoiceResponse { .earcon(.success) }
    func delete(ref: String) -> VoiceResponse { .earcon(.success) }
    func deleteAll() -> VoiceResponse { .earcon(.success) }
    func queryList() -> VoiceResponse { .spoken("3 bookmarks") }
    func queryCount() -> VoiceResponse { .spoken("3 bookmarks") }
    func queryNearby() -> VoiceResponse { .spoken("No nearby bookmarks") }
}

private final class MockQueueSink: VoiceQueueSink {
    var lastEpisode: String?

    func addTop(episode: String) -> VoiceResponse { lastEpisode = episode; return .earcon(.success) }
    func addBottom(episode: String) -> VoiceResponse { lastEpisode = episode; return .earcon(.success) }
    func remove(episode: String) -> VoiceResponse { .earcon(.success) }
    func moveToTop(episode: String) -> VoiceResponse { .earcon(.success) }
    func moveToBottom(episode: String) -> VoiceResponse { .earcon(.success) }
    func clear() -> VoiceResponse { .earcon(.success) }
    func removeByPodcast(podcast: String) -> VoiceResponse { .earcon(.success) }
    func sort(sortOrder: SortOrder) -> VoiceResponse { .earcon(.success) }
    func queryContents() -> VoiceResponse { .spoken("5 episodes in queue") }
    func queryNext() -> VoiceResponse { .spoken("Next: The Daily") }
    func queryLength() -> VoiceResponse { .spoken("2 hours remaining") }
    func queryIsQueued(episode: String) -> VoiceResponse { .spoken("Yes") }
}

private final class MockPlaybackQuerySink: VoicePlaybackQuerySink {
    func whatsPlaying() -> VoiceResponse { .spoken("Currently playing The Daily") }
    func position() -> VoiceResponse { .spoken("5:30") }
    func timeRemaining() -> VoiceResponse { .spoken("10 minutes remaining") }
    func episodeDuration() -> VoiceResponse { .spoken("15 minutes") }
    func publishDate() -> VoiceResponse { .spoken("Published June 1") }
    func episodeDescription() -> VoiceResponse { .spoken("Today we discuss...") }
    func downloadStatus() -> VoiceResponse { .spoken("Downloaded") }
    func episodeTitle() -> VoiceResponse { .spoken("The Daily") }
}

private final class MockStatsQuerySink: VoiceStatsQuerySink {
    func listeningTime(period: String?) -> VoiceResponse { .spoken("10 hours this week") }
    func topPodcasts(period: String?) -> VoiceResponse { .spoken("Your top podcast is...") }
    func episodesFinished(period: String?) -> VoiceResponse { .spoken("15 episodes this month") }
    func listeningStreak() -> VoiceResponse { .spoken("5 day streak") }
    func subscriptionCount() -> VoiceResponse { .spoken("12 subscriptions") }
    func unplayedTotal() -> VoiceResponse { .spoken("50 unplayed") }
    func downloadStats() -> VoiceResponse { .spoken("5 downloads pending") }
    func newEpisodes(timeframe: String?) -> VoiceResponse { .spoken("20 new episodes") }
    func timeSinceLastListen() -> VoiceResponse { .spoken("2 hours ago") }
}

private final class MockCloudRouteSink: VoiceCloudRouteSink {
    var routeToCloudCalled = false
    var lastRequest: String?

    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> VoiceResponse {
        routeToCloudCalled = true
        lastRequest = request
        return .spoken("Here's what I found")
    }
}
