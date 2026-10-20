import XCTest
import PocketCastsDataModel
@testable import podcasts

final class VoiceIntentExecutorTests: XCTestCase {

    var executor: VoiceIntentExecutor!
    fileprivate var mockPlaybackSink: MockPlaybackSink!
    fileprivate var mockEffectsSink: MockEffectsSink!
    fileprivate var mockVolumeSink: MockVolumeSink!
    fileprivate var mockSleepSink: MockSleepSink!
    fileprivate var mockChapterSink: MockChapterSink!
    fileprivate var mockBookmarkSink: MockBookmarkSink!
    fileprivate var mockQueueSink: MockQueueSink!
    fileprivate var mockPlaybackQuerySink: MockPlaybackQuerySink!
    fileprivate var mockStatsQuerySink: MockStatsQuerySink!
    fileprivate var mockCloudRouteSink: MockCloudRouteSink!
    fileprivate var mockPlaybackContextProvider: MockPlaybackContextProvider!
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
        mockPlaybackContextProvider = MockPlaybackContextProvider()
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
            playbackContextProvider: mockPlaybackContextProvider,
            gracePeriodSignal: gracePeriodSignal
        )
    }

    /// The origin branch decides whether a completion RENEWS the window. Observable without a
    /// window budget (owner delta 3484cbc/5eca874): announce a refusal (holding the tone claim for
    /// this generation), run the completion, then check whether the window was renewed — only a
    /// renewing completion clears the claim. A fallback pays for its permission; a model-chosen
    /// cloud route is a deliberate act. Asserting the pair is what makes this a distinction rather
    /// than a blanket rule, and it fails if the origin branch is removed.
    func test_execute_fallbackCloudRouteDoesNotRenewTheWindow() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        let generation = gracePeriodSignal.currentGeneration()
        // A refusal in this window is announced once, holding the tone claim for this generation.
        XCTAssertTrue(gracePeriodSignal.claimRefusalTone(), "the refusal is announced")
        XCTAssertFalse(gracePeriodSignal.windowIsRenewedForTesting(), "the window is not renewed while spent")

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            origin: .routingFailure,
            generation: generation
        ))

        XCTAssertTrue(mockCloudRouteSink.routeToCloudCalled, "the fallback still dispatches")
        XCTAssertFalse(
            gracePeriodSignal.windowIsRenewedForTesting(),
            "a fallback extends the window WITHOUT renewing it"
        )
    }

    func test_execute_modelChosenCloudRouteRenewsTheWindow() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        // Stamped the way the service stamps it: a completion must carry the window
        // it ran under, so this test supplies one rather than relying on a default.
        let generation = gracePeriodSignal.currentGeneration()
        XCTAssertTrue(gracePeriodSignal.claimRefusalTone(), "a refusal is announced")
        XCTAssertFalse(gracePeriodSignal.windowIsRenewedForTesting(), "spent before the completion")

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            generation: generation
        ))

        XCTAssertTrue(mockCloudRouteSink.routeToCloudCalled)
        XCTAssertTrue(
            gracePeriodSignal.windowIsRenewedForTesting(),
            "a cloud route the model chose is a deliberate act, so the window is RENEWED"
        )
    }

    /// A model-chosen cloud route resets the allowance, but only inside the window
    /// it was issued under. Completing after a privacy close and a new wake must
    /// not reset whatever window is current — that would re-arm a session this
    /// turn never belonged to.
    /// QUIET DUPLICATES (reviewer 0c546ce5 item 4): a duplicate of an utterance the executor
    /// already completed — the joined or settled copy the sink hands back — observes completion
    /// WITHOUT repeating the owner's effects. The grace renewal happens exactly once (the
    /// duplicate cannot restore a spent allowance), the duplicate's response renders nothing,
    /// and analytics record the command once. Two independent utterances both count.
    func test_execute_duplicateUtteranceIsQuietToGraceAndAnalytics() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        let generation = gracePeriodSignal.currentGeneration()
        XCTAssertTrue(gracePeriodSignal.claimRefusalTone(), "a refusal is announced (spent)")

        let owner = CloudRouteIntent(
            request: "play something", tier: .unknown,
            utteranceId: "utterance-dup", origin: .modelCall, generation: generation
        )
        _ = await executor.execute(owner)
        XCTAssertTrue(gracePeriodSignal.windowIsRenewedForTesting(), "the OWNER's completion renews the window")
        // Re-arm the observable: the owner's renewal cleared the refusal-tone claim, so holding
        // it again gives the duplicate a detectable renewal to (NOT) perform.
        XCTAssertTrue(gracePeriodSignal.claimRefusalTone(), "the re-armed refusal is announced")

        // The duplicate: identical captured intent (same utterance id + generation).
        let duplicate = await executor.execute(owner)
        XCTAssertEqual(duplicate, .silent, "a duplicate renders nothing")
        XCTAssertFalse(
            gracePeriodSignal.windowIsRenewedForTesting(),
            "the duplicate must NOT renew the window again (a joined copy cannot re-arm a spent allowance)"
        )

        // An INDEPENDENT utterance in the same window still gets its effects.
        let independent = CloudRouteIntent(
            request: "skip forward", tier: .unknown,
            utteranceId: "utterance-ind", origin: .modelCall, generation: generation
        )
        _ = await executor.execute(independent)
        XCTAssertTrue(
            gracePeriodSignal.windowIsRenewedForTesting(),
            "an independent utterance is not quieted by the duplicate rule"
        )
    }

    func test_execute_modelChosenRouteFromAnEndedWindowCannotResetTheNewOne() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        let oldGeneration = gracePeriodSignal.currentGeneration()
        XCTAssertNotNil(oldGeneration)

        await MainActor.run { gracePeriodSignal.onAppBackgrounded() }
        gracePeriodSignal.onWakeWordDetected()
        let newGeneration = gracePeriodSignal.currentGeneration()
        XCTAssertNotEqual(oldGeneration, newGeneration, "a fresh wake opens a new window")
        // Mark the NEW window spent so a stray reset would be visible.
        XCTAssertTrue(gracePeriodSignal.claimRefusalTone(), "the new window's refusal is announced")

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            generation: oldGeneration
        ))

        XCTAssertEqual(
            gracePeriodSignal.currentGeneration(), newGeneration,
            "the ended window's completion must not reset the current one"
        )
        XCTAssertFalse(
            gracePeriodSignal.windowIsRenewedForTesting(),
            "the ended window's completion must not renew the current one"
        )
    }

    /// A cloud completion with no window identity cannot be attributed to any
    /// window, so it must not change grace state: falling through to the generic
    /// reset would let it reopen a session it never belonged to.
    func test_execute_cloudCompletionWithoutAWindowLeavesGraceStateUntouched() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        XCTAssertTrue(gracePeriodSignal.claimRefusalTone(), "this window is spent")

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            origin: .routingFailure
        ))

        XCTAssertTrue(mockCloudRouteSink.routeToCloudCalled, "the dispatch itself still happened")
        XCTAssertFalse(
            gracePeriodSignal.windowIsRenewedForTesting(),
            "an unattributable completion must not renew the window"
        )
    }

    /// A cloud turn that failed but reports itself by SPEAKING must not restore the
    /// allowance. A spoken error and a silent success are both "no earcon", so the old
    /// response-shape rule read this exact turn as a completion and reopened the window
    /// for a turn that never happened.
    func test_execute_spokenCloudErrorDoesNotRenewTheWindow() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        let generation = gracePeriodSignal.currentGeneration()
        XCTAssertTrue(gracePeriodSignal.claimRefusalTone(), "this window is spent")

        mockCloudRouteSink.response = .spoken("Connection lost. Please try again.")
        mockCloudRouteSink.outcome = .failed(code: "connection_lost")

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            generation: generation
        ))

        XCTAssertFalse(gracePeriodSignal.windowIsRenewedForTesting(),
                       "a spoken cloud error was treated as a completed turn")
    }

    /// The coming-soon refusal is the same shape: it renders as `.spoken` and must not
    /// be recorded as a completed cloud route.
    func test_execute_cloudRefusalDoesNotRenewTheWindow() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        let generation = gracePeriodSignal.currentGeneration()
        XCTAssertTrue(gracePeriodSignal.claimRefusalTone(), "this window is spent")

        mockCloudRouteSink.response = .spoken("Cloud processing is coming soon.")
        mockCloudRouteSink.outcome = .refused

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            generation: generation
        ))

        XCTAssertFalse(gracePeriodSignal.windowIsRenewedForTesting(),
                       "the coming-soon refusal was recorded as a completed cloud turn")
    }

    /// The executor must hand the sink the origin the turn was DISPATCHED under. Without
    /// this the sink can only default, and a default makes the conversation bound inert: the
    /// origin is then a constant, so no turn can ever be stale and every turn reads as a
    /// fresh `create`. Asserting the captured value reaches the sink is what keeps that
    /// property real rather than described.
    func test_execute_passesTheCapturedOriginToTheCloudSink() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        let generation = gracePeriodSignal.currentGeneration()
        XCTAssertNotNil(gracePeriodSignal.claimDispatchOwnership())

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            generation: generation
        ))

        XCTAssertEqual(
            mockCloudRouteSink.lastOrigin, generation,
            "the sink did not receive the turn's captured origin, so the conversation bound "
                + "cannot distinguish a live dispatc from a stale one"
        )
    }

    /// With nothing playing — the app's normal first interaction — the cloud turn must still be
    /// dispatched with an ABSENT context, not refused locally. Refusing here is what made the
    /// discovery turn unreachable on the client while the server had already been corrected.
    func test_execute_dispatchesTheCloudTurnWithNoCurrentEpisode() async {
        mockPlaybackContextProvider.context = nil
        gracePeriodSignal.onWakeWordDetected()
        let generation = gracePeriodSignal.currentGeneration()

        _ = await executor.execute(CloudRouteIntent(
            request: "what should I listen to",
            tier: .unknown,
            generation: generation
        ))

        XCTAssertTrue(
            mockCloudRouteSink.routeToCloudCalled,
            "the turn was refused locally instead of being dispatched with absent context"
        )
        XCTAssertNil(
            mockCloudRouteSink.lastContext?.episodeId,
            "an episode id was invented for a turn with nothing playing"
        )
        XCTAssertNil(
            mockCloudRouteSink.lastContext?.clientPositionMs,
            "a position was invented for a turn with nothing playing"
        )
    }

    /// The selection the turn was created with must reach the sink, not be re-read there. A
    /// re-read happens after routing, so a queued turn would be classified by whatever the
    /// window looks like later rather than by what selected it.
    func test_execute_forwardsTheCapturedSelectionToTheCloudSink() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        let generation = gracePeriodSignal.currentGeneration()
        XCTAssertNotNil(gracePeriodSignal.claimDispatchOwnership())

        _ = await executor.execute(CloudRouteIntent(
            request: "and then",
            tier: .unknown,
            generation: generation,
            selection: .followUp
        ))

        XCTAssertEqual(
            mockCloudRouteSink.lastSelection, .followUp,
            "the sink did not receive the selection captured with the input"
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

    func test_execute_seekRelative_withDelta_forwardsDeltaAndDirection() async {
        _ = await executor.execute(PlaybackIntent.seekRelative(deltaSeconds: 30, direction: .forward))
        XCTAssertEqual(mockPlaybackSink.lastSeekRelativeDelta, 30)
        XCTAssertEqual(mockPlaybackSink.lastSeekRelativeDirection, .forward)
    }

    func test_execute_seekRelative_directionOnly() async {
        _ = await executor.execute(PlaybackIntent.seekRelative(deltaSeconds: nil, direction: .backward))
        XCTAssertNil(mockPlaybackSink.lastSeekRelativeDelta)
        XCTAssertEqual(mockPlaybackSink.lastSeekRelativeDirection, .backward)
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

    private static let context = PlaybackContext(
        episodeId: "ep1",
        podcastId: "pod1",
        referencePositionMs: 4_000,
        clientPositionMs: 5_000,
        recentReferencePositions: [1_000, 2_000],
        previousReferencePositionMs: 3_000
    )

    func test_execute_cloudRoute_callsCloudSink() async {
        let context = PlaybackContext(
            episodeId: "ep1",
            podcastId: "pod1",
            referencePositionMs: 4_000,
            clientPositionMs: 5_000,
            recentReferencePositions: [1_000, 2_000],
            previousReferencePositionMs: 3_000
        )
        mockPlaybackContextProvider.context = context
        let intent = CloudRouteIntent(request: "find similar", tier: .premium)
        _ = await executor.execute(intent)
        XCTAssertTrue(mockCloudRouteSink.routeToCloudCalled)
        XCTAssertEqual(mockCloudRouteSink.lastRequest, "find similar")
        XCTAssertEqual(mockCloudRouteSink.lastContext, context)
    }








    func test_execute_success_activatesGracePeriod() async {
        XCTAssertFalse(gracePeriodSignal.isActive)
        _ = await executor.execute(PlaybackIntent.pause)
        // GracePeriodSignal.startOrReset hops to the main queue (Timer must bind
        // to the main run loop), so activation lands asynchronously. Drain the
        // main queue before asserting, otherwise this test races the hop.
        let mainQueueDrained = expectation(description: "main queue drained")
        DispatchQueue.main.async { mainQueueDrained.fulfill() }
        await fulfillment(of: [mainQueueDrained], timeout: 2)
        XCTAssertTrue(gracePeriodSignal.isActive)
    }

    func test_runtimePlaybackContextProvider_populatesPlaybackAndReferenceContext() {
        let episode = Episode()
        episode.uuid = "episode-1"
        episode.podcastUuid = "podcast-1"

        let provider = DefaultPlaybackContextProvider(
            playbackState: MockPlaybackState(episode: episode, currentTime: 123.456),
            fingerprintMapper: MockFingerprintMapper(referenceTime: 111.222),
            cloudPlaybackContextState: CloudPlaybackContextState(
                recentReferencePositions: [11_000, 22_000],
                previousReferencePositionMs: 33_000
            )
        )

        guard let context = provider.current() else {
            XCTFail("Expected playback context")
            return
        }

        XCTAssertEqual(context.episodeId, "episode-1")
        XCTAssertEqual(context.podcastId, "podcast-1")
        XCTAssertEqual(context.clientPositionMs, 123_456)
        XCTAssertEqual(context.referencePositionMs, 111_222)
        XCTAssertEqual(context.recentReferencePositions, [11_000, 22_000])
        XCTAssertEqual(context.previousReferencePositionMs, 33_000)
    }

    func test_runtimePlaybackContextProvider_nilReferencePositionWhenFingerprintMappingUnavailable() {
        let episode = Episode()
        episode.uuid = "episode-2"
        episode.podcastUuid = "podcast-2"

        let provider = DefaultPlaybackContextProvider(
            playbackState: MockPlaybackState(episode: episode, currentTime: 87.65),
            fingerprintMapper: MockFingerprintMapper(referenceTime: nil),
            cloudPlaybackContextState: CloudPlaybackContextState()
        )

        guard let context = provider.current() else {
            XCTFail("Expected playback context")
            return
        }

        XCTAssertEqual(context.episodeId, "episode-2")
        XCTAssertEqual(context.clientPositionMs, 87_650)
        XCTAssertNil(context.referencePositionMs)
    }
}

// MARK: - Mock Sinks

private final class MockPlaybackSink: VoicePlaybackSink {
    /// Host playing at the moment the turn reads it. Tests set this to
    /// false to model a user who paused before speaking.
    var isPlaying = true
    var pauseCalled = false
    var lastSeekRelativeDelta: Int?
    var lastSeekRelativeDirection: SeekDirection = .forward
    var lastSeekToPosition: Int?
    var nextEpisodeResponse: VoiceResponse = .earcon(.nextEpisode)

    func pause() -> VoiceResponse { pauseCalled = true; return .earcon(.success) }
    func resume() -> VoiceResponse { .silent }
    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse {
        lastSeekRelativeDelta = deltaSeconds
        lastSeekRelativeDirection = direction
        return .silent
    }
    func seekTo(positionSeconds: Int) -> VoiceResponse { lastSeekToPosition = positionSeconds; return .silent }
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse {
        lastSeekToPosition = positionSeconds
        return .silent
    }
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
    func sort(sortOrder: podcasts.SortOrder) -> VoiceResponse { .earcon(.success) }
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
    var lastContext: PlaybackContext?

    /// Overridable so a case can drive a non-completing turn: the executor's grace
    /// decision now depends on this, not on the rendered response.
    var outcome: CloudRouteOutcome = .completed
    var response: VoiceResponse = .spoken("Here's what I found")

    /// The captured origin the executor passed, so a case can assert the turn carries the
    /// window it was dispatched under rather than a live one.
    var lastOrigin: Int?
    /// The selection the executor captured, so a case can assert the turn carries what selected
    /// it rather than whatever the window looks like later.
    var lastSelection: CloudConversationSelection?
    /// The request ids a retry named, in order.
    var retriedRequestIds: [String] = []

    func routeToCloud(
        request: String, tier: CloudTier, context: PlaybackContext, origin: Int?,
        selection: CloudConversationSelection?,
        utteranceId: String?,
        preparedObserver: CloudRouteSink.PreparedObserver?,
        sourceTranscript: String?, sourceLanguage: String?
    ) async -> CloudRouteResult {
        routeToCloudCalled = true
        lastRequest = request
        lastContext = context
        lastOrigin = origin
        lastSelection = selection
        return CloudRouteResult(response: response, outcome: outcome)
    }

}

private final class MockPlaybackContextProvider: PlaybackContextProvider {
    var context: PlaybackContext?

    func current() -> PlaybackContext? {
        context
    }
}

private struct MockPlaybackState: PlaybackStateProviding {
    let episode: BaseEpisode?
    let currentTime: TimeInterval

    var currentEpisode: BaseEpisode? {
        episode
    }

    func currentTimeSeconds() -> TimeInterval {
        currentTime
    }
}

private struct MockFingerprintMapper: FingerprintMappingProviding {
    let referenceTime: TimeInterval?
    var playbackTimeForReference: TimeInterval?

    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? {
        referenceTime
    }

    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? {
        playbackTimeForReference ?? referenceTime
    }
}
