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

    /// CORRECTED CONTRACT (spec 6a033773 — my first cut inferred verdicts from presentation
    /// classes; withdrawn). Only the executor's OWN decisions are verdicts: the error earcon is
    /// the failure the executor itself logs and acts on (spec 012b19dd); confirm-required is its
    /// own decision not to act without confirmation. Every other presentation stays UNKNOWN —
    /// a success-shaped presentation cannot prove action completion.
    func test_executeWithVerdictReportsTheExecutorStructuredVerdict() async {
        typealias Outcome = VoiceSharingContributionEncoder.StageOutcome

        // The executor's own failure verdict — on an intent whose sink has NO fact channel, so
        // this is the bridge (nextEpisode's channel would otherwise answer first).
        mockEffectsSink.nextAdjustResponse = .earcon(.error)
        let (_, failedVerdict) = await executor.executeWithVerdict(
            EffectsIntent.adjustSpeed(delta: 0.5))
        XCTAssertEqual(failedVerdict.state, "failed")
        XCTAssertEqual(failedVerdict.reason, "action_failed")
        XCTAssertEqual(failedVerdict.outcome, "failed")

        // The executor's own decision not to act without confirmation.
        mockEffectsSink.nextAdjustResponse = .earcon(.confirmRequired)
        let (_, refusedVerdict) = await executor.executeWithVerdict(
            EffectsIntent.adjustSpeed(delta: 0.5))
        XCTAssertEqual(refusedVerdict.state, "not_run")
        XCTAssertEqual(refusedVerdict.reason, "client_refused")
        XCTAssertEqual(refusedVerdict.outcome, "refused")
        _ = Outcome.self
    }

    /// THE DISCRIMINATING CONTROL (spec 6a033773), now with a REAL fact channel: pause presents
    /// the SAME `.earcon(.success)` whether or not anything was playing — the presentation cannot
    /// discriminate. The SINK'S FACT does: pausing from playing is a completed action; pausing
    /// while already paused is a no-op with its precondition absent (not_run/precondition_failed).
    /// RED until the fact channel lands; the sleep half (below) pins the world where NO fact
    /// channel exists — unknown in both worlds.
    func test_samePresentationDifferentActionOutcome_verdictFollowsTheSinkFactNotThePresentation() async {
        // The skip happened: the action handed back the title it played.
        mockPlaybackSink.skipResult = "Episode B"
        let (_, skipped) = await executor.executeWithVerdict(PlaybackIntent.nextEpisode)
        XCTAssertEqual(skipped.state, "completed",
                       "the sink fact (an actual skip) must conclude the turn, not the "
                           + "success-shaped template")
        XCTAssertNil(skipped.reason)
        XCTAssertEqual(skipped.outcome, "executed")

        // The IDENTICAL template with nothing queued: the sink declined — nothing moved.
        mockPlaybackSink.skipResult = nil
        let (_, declined) = await executor.executeWithVerdict(PlaybackIntent.nextEpisode)
        XCTAssertEqual(declined.state, "not_run",
                       "with no episode to skip to, nothing happened; the identical template "
                           + "must not read as a completed action")
        XCTAssertEqual(declined.reason, "precondition_failed")
        XCTAssertEqual(declined.outcome, "refused")

        // Pause: idempotent success per the existing contract — completed from either state.
        let (_, pausedFromPlaying) = await executor.executeWithVerdict(PlaybackIntent.pause)
        XCTAssertEqual(pausedFromPlaying.state, "completed")
        let (_, pausedWhilePaused) = await executor.executeWithVerdict(PlaybackIntent.pause)
        XCTAssertEqual(pausedWhilePaused.state, "completed",
                       "a prior paused state alone does not turn an idempotent pause into a refusal")
    }

    /// The NO-CHANNEL half: the sleep sink has no fact channel yet, so its identical
    /// presentations in both worlds stay unknown — the verdict must not follow presentation
    /// where no structured fact exists.
    func test_withoutAFactChannel_identicalPresentationsStayUnknown() async {
        mockSleepSink.armedFact = true
        let (_, armed) = await executor.executeWithVerdict(SleepIntent.set(minutes: 30))
        XCTAssertEqual(armed.state, "unknown",
                       "no sink fact channel exists for this sink; unknown, not completed")
        mockSleepSink.armedFact = false
        let (_, notArmed) = await executor.executeWithVerdict(SleepIntent.set(minutes: 30))
        XCTAssertEqual(notArmed.state, "unknown",
                       "identical presentation, no fact channel — unknown, not refused")
    }

    /// The origin branch is what decides whether a dispatch re-arms the allowance
    /// that permitted it. A fallback pays for its permission; a cloud route the
    /// model chose is a deliberate act and does restore it. Asserting the pair is
    /// what makes this a distinction rather than a blanket rule — and it fails if
    /// the origin branch is removed.
    func test_execute_fallbackCloudRouteKeepsTheAllowanceSpent() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        let generation = gracePeriodSignal.claimEscalationBudget()
        XCTAssertNotNil(generation)

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            origin: .routingFailure,
            generation: generation
        ))

        XCTAssertTrue(mockCloudRouteSink.routeToCloudCalled, "the fallback still dispatches")
        XCTAssertNil(gracePeriodSignal.claimEscalationBudget(),
                     "a fallback must not re-arm the allowance that let it happen")
    }

    /// RED: the cloud sink states its own fact at its decision sites; the
    /// verdict follows the fact, not the (identical) success-shaped template.
    func test_cloudVerdict_followsTheSinkFact_notThePresentation() async {
        mockPlaybackContextProvider.context = Self.context

        // The turn completed at the sink's `done` branch.
        mockCloudRouteSink.cloudFactToReturn = SinkActionFact(state: "completed", reason: nil)
        let (_, doneVerdict) = await executor.executeWithVerdict(CloudRouteIntent(
            request: "what did they say", tier: .unknown, generation: nil))
        XCTAssertEqual(doneVerdict.state, "completed")
        XCTAssertEqual(doneVerdict.outcome, "executed")

        // The IDENTICAL template at the sink's `.error` branch: the turn failed.
        mockCloudRouteSink.cloudFactToReturn = SinkActionFact(state: "failed", reason: "action_failed")
        let (_, failedVerdict) = await executor.executeWithVerdict(CloudRouteIntent(
            request: "what did they say", tier: .unknown, generation: nil))
        XCTAssertEqual(failedVerdict.state, "failed")
        XCTAssertEqual(failedVerdict.reason, "action_failed")

        // Superseded mid-turn: the user spoke over it — the turn did not run.
        mockCloudRouteSink.cloudFactToReturn = SinkActionFact(state: "not_run", reason: "cancelled_by_user")
        let (_, cancelledVerdict) = await executor.executeWithVerdict(CloudRouteIntent(
            request: "what did they say", tier: .unknown, generation: nil))
        XCTAssertEqual(cancelledVerdict.state, "not_run")
        XCTAssertEqual(cancelledVerdict.reason, "cancelled_by_user")
    }

    func test_execute_modelChosenCloudRouteRestoresTheAllowance() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        // Stamped the way the service stamps it: a completion must carry the window
        // it ran under, so this test supplies one rather than relying on a default.
        let generation = gracePeriodSignal.currentGeneration()
        XCTAssertNotNil(gracePeriodSignal.claimEscalationBudget())

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            generation: generation
        ))

        XCTAssertTrue(mockCloudRouteSink.routeToCloudCalled)
        XCTAssertNotNil(gracePeriodSignal.claimEscalationBudget(),
                        "a cloud route the model chose is a deliberate act, so the window is refreshed")
    }

    /// A model-chosen cloud route resets the allowance, but only inside the window
    /// it was issued under. Completing after a privacy close and a new wake must
    /// not reset whatever window is current — that would re-arm a session this
    /// turn never belonged to.
    func test_execute_modelChosenRouteFromAnEndedWindowCannotResetTheNewOne() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        let oldGeneration = gracePeriodSignal.claimEscalationBudget()
        XCTAssertNotNil(oldGeneration)

        await MainActor.run { gracePeriodSignal.onAppBackgrounded() }
        gracePeriodSignal.onWakeWordDetected()
        XCTAssertNotNil(gracePeriodSignal.claimEscalationBudget(), "the new window's allowance is spent here")

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            generation: oldGeneration
        ))

        XCTAssertNil(gracePeriodSignal.claimEscalationBudget(),
                     "the ended window's completion must not reset the current one")
    }

    /// A cloud completion with no window identity cannot be attributed to any
    /// window, so it must not change grace state: falling through to the generic
    /// reset would let it reopen a session it never belonged to.
    func test_execute_cloudCompletionWithoutAWindowLeavesGraceStateUntouched() async {
        mockPlaybackContextProvider.context = Self.context
        gracePeriodSignal.onWakeWordDetected()
        XCTAssertNotNil(gracePeriodSignal.claimEscalationBudget(), "this window's allowance is spent")

        _ = await executor.execute(CloudRouteIntent(
            request: "what did they say",
            tier: .unknown,
            origin: .routingFailure
        ))

        XCTAssertTrue(mockCloudRouteSink.routeToCloudCalled, "the dispatch itself still happened")
        XCTAssertNil(gracePeriodSignal.claimEscalationBudget(),
                     "an unattributable completion must not restore the allowance")
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
        // The mock builds its spoken text from the skip's returned title — the
        // same single-result seam the real sink uses.
        mockPlaybackSink.skipResult = "The Daily"
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

    /// REVIEW 8bc80b2b regression control: the verdict path must ride the ONE shared execution
    /// path — the first cut duplicated the dispatch switch and silently skipped the shared
    /// post-execute effects (analytics.recordCommand, grace restore). The grace effect is the
    /// observable half asserted here; the verdict must not cost the turn its side effects.
    func test_executeWithVerdict_preservesTheSharedGraceEffect() async {
        XCTAssertFalse(gracePeriodSignal.isActive)
        _ = await executor.executeWithVerdict(PlaybackIntent.pause)
        // GracePeriodSignal.startOrReset hops to the main queue (Timer must bind
        // to the main run loop), so activation lands asynchronously. Drain the
        // main queue before asserting, otherwise this test races the hop.
        let mainQueueDrained = expectation(description: "main queue drained")
        DispatchQueue.main.async { mainQueueDrained.fulfill() }
        await fulfillment(of: [mainQueueDrained], timeout: 2)
        XCTAssertTrue(gracePeriodSignal.isActive,
                      "the verdict path must preserve the shared grace restore")
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

    /// Pause is idempotent success (spec 32305c22): the fact is completed in both worlds —
    /// stated at the sink, not inferred from the earcon.
    func pause() -> VoiceResponse { pauseCalled = true; return .earcon(.success) }
    func pauseWithFact() -> (response: VoiceResponse, fact: SinkActionFact?) {
        pauseCalled = true
        return (.earcon(.success), SinkActionFact(state: "completed", reason: nil))
    }
    /// The skip's fact mirrors the REAL sink's outcome seam: it follows the
    /// action's own decision (`skipResult` non-nil models the manager's
    /// `.played` outcome; nil models `.declined`). The real manager contract —
    /// earlier candidate title vs declined action, shuffle attribution — is
    /// pinned separately in PlaybackManagerSinkTests (reviewer 50103ef9).
    var skipResult: String? = "Episode A"
    func nextEpisode() -> VoiceResponse { nextEpisodeWithFact().response }
    func nextEpisodeWithFact() -> (response: VoiceResponse, fact: SinkActionFact?) {
        let response = VoiceResponse.spoken("Playback: \(skipResult ?? "next episode")")
        return skipResult != nil
            ? (response, SinkActionFact(state: "completed", reason: nil))
            : (response, SinkActionFact(state: "not_run", reason: "precondition_failed"))
    }
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
}

private final class MockEffectsSink: VoiceEffectsSink {
    var lastSetSpeed: Double?
    var lastDelta: Double?
    var lastTrimMode: TrimMode?
    var lastVolumeBoostEnabled: Bool?

    func setSpeed(_ speed: Double) -> VoiceResponse { lastSetSpeed = speed; return .silent }
    var nextAdjustResponse: VoiceResponse?
    func adjustSpeed(delta: Double) -> VoiceResponse {
        lastDelta = delta; return nextAdjustResponse ?? .silent
    }
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
    /// The structured fact a sink-side verdict channel must carry: whether the timer actually
    /// armed. The presentation is identical in both worlds (see the discriminating control).
    var armedFact = true

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
    /// RED: the cloud sink's own fact channel. Identical success-shaped spoken
    /// template in every world; only the sink's stated fact differs.
    var cloudFactToReturn: SinkActionFact? = SinkActionFact(state: "completed", reason: nil)
    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> (response: VoiceResponse, fact: SinkActionFact?) {
        routeToCloudCalled = true
        lastRequest = request
        lastContext = context
        return (.spoken("Here's what I found"), cloudFactToReturn)
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
