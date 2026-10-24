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

/// The single entry point `VoiceControlService` needs from the executor. Extracted (spec 85cec5b7) so the
/// service's routing branches can be driven with a chosen RESULT — including a failure — without
/// constructing every sink.
/// The executor's own structured verdict for a turn (spec: `execution.outcome` must be a
/// structured executor verdict, not a response-derived unknown). The states/reasons are the
/// record's enumerated vocabulary; `outcome` is the executor's settled disposition.
typealias ExecutionVerdict = VoiceSharingContributionEncoder.StageOutcome

protocol VoiceIntentExecuting: AnyObject {
    func execute(_ intent: any VoiceIntent) async -> VoiceResponse
    /// The executor's decision site: returns the presentation AND the executor's own verdict
    /// for the same turn. A returned response alone is a presentation choice; this is the fact.
    func executeWithVerdict(_ intent: any VoiceIntent) async -> (response: VoiceResponse, verdict: ExecutionVerdict)
}

extension VoiceIntentExecuting {
    /// Default bridge for conformers that have not adopted structured verdicts. CORRECTION (spec
    /// 6a033773): only the executor's OWN decisions are stated here — the error earcon is the
    /// failure the executor itself logs and acts on, and confirm-required is the executor's own
    /// decision not to act without confirmation. Every OTHER response is a presentation choice:
    /// a success-shaped presentation alone cannot prove action completion, so the verdict stays
    /// unknown until sinks report structured facts from their action results.
    func executeWithVerdict(_ intent: any VoiceIntent) async -> (response: VoiceResponse, verdict: ExecutionVerdict) {
        let response = await execute(intent)
        switch response {
        case .earcon(.error):
            return (response, ExecutionVerdict(state: "failed", reason: "action_failed", outcome: "failed"))
        case .earcon(.confirmRequired):
            return (response, ExecutionVerdict(state: "not_run", reason: "client_refused", outcome: "refused"))
        default:
            return (response, ExecutionVerdict(state: "unknown", reason: "observation_unavailable"))
        }
    }
}

class VoiceIntentExecutor: VoiceIntentExecuting {
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
        await executeCollectingFact(intent).response
    }

    /// THE SHARED DISPATCH, threading each sink's fact invocation-locally — no executor-wide
    /// field spans an await, so overlapping invocations cannot attribute one turn's fact to
    /// another (reviewer 6133f187). `execute` is exactly this, dropping the fact.
    private func executeCollectingFact(_ intent: any VoiceIntent) async -> (response: VoiceResponse, fact: SinkActionFact?) {
        var response: (response: VoiceResponse, fact: SinkActionFact?)
        switch intent {
        case let p as PlaybackIntent: response = executePlayback(p)
        case let e as EffectsIntent: response = (executeEffects(e), nil)
        case let v as VolumeIntent: response = (executeVolume(v), nil)
        case let s as SleepIntent: response = (executeSleep(s), nil)
        case let c as ChapterIntent: response = (executeChapter(c), nil)
        case let b as BookmarkIntent: response = (executeBookmark(b), nil)
        case let q as QueueIntent: response = (executeQueue(q), nil)
        case let pq as PlaybackQueryIntent: response = (executePlaybackQuery(pq), nil)
        case let sq as StatsQueryIntent: response = (executeStatsQuery(sq), nil)
        case let cr as CloudRouteIntent:
            guard let context = playbackContextProvider.current() else {
                response = (.earcon(.error), nil)
                break
            }
            // The cloud sink states its own decision fact at its turn-loop
            // branches; the executor consumes it invocation-locally like every
            // other fact channel.
            response = await cloudRouteSink.routeToCloud(
                request: cr.request,
                tier: cr.tier,
                context: context
            )
        default: response = (.earcon(.error), nil)
        }

        let voiceResponse = response.response
        // Record analytics after every command
        analytics?.recordCommand(intent, response: voiceResponse)

        // Start grace period after any successful (non-error) command
        if case .earcon(.error) = voiceResponse {
            FileLog.shared.addMessage("[VoicePipeline] Command failed — no grace period")
        } else if let route = intent as? CloudRouteIntent {
            // A cloud completion may only touch the window it was issued under, so
            // it must carry that window's identity. One without a generation cannot
            // be attributed to any window — falling through to the generic reset
            // would let it reopen a session it never belonged to — so it changes no
            // grace state at all.
            guard let generation = route.generation else {
                FileLog.shared.addMessage("[VoicePipeline] Cloud completion without a window identity — grace state untouched")
                return (voiceResponse, response.fact)   // analytics already recorded above
            }
            switch route.origin {
            case .modelCall:
                // Restores the allowance, but only inside its own window. One
                // atomic operation: checking then resetting separately leaves a gap
                // in which a privacy close could be undone.
                if gracePeriodSignal.recognizeCommandIfCurrentWindow(generation) {
                    FileLog.shared.addMessage("[VoicePipeline] Cloud route completed — grace period")
                } else {
                    FileLog.shared.addMessage("[VoicePipeline] Cloud route completed for an ended window — ignored")
                }
            case .routingFailure:
                // The conversation continues, but only for the window that issued
                // this dispatch, and without restoring the allowance that permitted
                // it (shared contract with Android).
                FileLog.shared.addMessage("[VoicePipeline] Fallback dispatch — grace period extended, budget kept spent")
                gracePeriodSignal.extendWindowKeepingEscalationSpent(underGeneration: generation)
            }
        } else {
            FileLog.shared.addMessage("[VoicePipeline] Command succeeded — grace period")
            gracePeriodSignal.onCommandRecognized()
        }

        return (voiceResponse, response.fact)
    }

    /// The verdict rides the ONE shared execution path: `executeCollectingFact` performs the
    /// turn exactly once (analytics + grace effects, reviewer 8bc80b2b) and threads the sink's
    /// own fact invocation-locally; where the channel is silent the verdict is the TEMPORARY
    /// presentation bridge (labeled at its definition).
    func executeWithVerdict(_ intent: any VoiceIntent) async -> (response: VoiceResponse, verdict: ExecutionVerdict) {
        let (response, fact) = await executeCollectingFact(intent)
        guard let fact else {
            return (response, Self.presentationBridgeVerdict(response))
        }
        return (response, ExecutionVerdict(
            state: fact.state, reason: fact.reason,
            outcome: fact.state == "completed" ? "executed"
                : fact.state == "failed" ? "failed" : "refused"))
    }

    private func executeWithVerdictViaBridge(_ intent: any VoiceIntent) async -> (response: VoiceResponse, verdict: ExecutionVerdict) {
        let response = await execute(intent)
        return (response, Self.presentationBridgeVerdict(response))
    }

    /// TEMPORARY BRIDGE (reviewer 03593972/7b09ce42, spec cac5e28b): the error earcon and
    /// confirm-required earcon are PRESENTATION classifications, kept only because they are the
    /// conclusions the executor itself currently acts on (it logs "Command failed" and withholds
    /// grace on exactly this value). They are NOT decision-site facts; the sink-side fact channel
    /// (SinkActionFact) replaces them as it reaches each sink. Everything else stays unknown.
    static func presentationBridgeVerdict(_ response: VoiceResponse) -> ExecutionVerdict {
        switch response {
        case .earcon(.error):
            return ExecutionVerdict(state: "failed", reason: "action_failed", outcome: "failed")
        case .earcon(.confirmRequired):
            return ExecutionVerdict(state: "not_run", reason: "client_refused", outcome: "refused")
        default:
            return ExecutionVerdict(state: "unknown", reason: "observation_unavailable")
        }
    }

    private func executePlayback(_ intent: PlaybackIntent) -> (response: VoiceResponse, fact: SinkActionFact?) {
        switch intent {
        case .pause:
            return playbackSink.pauseWithFact()
        case .nextEpisode:
            return playbackSink.nextEpisodeWithFact()
        case .resume:
            return (playbackSink.resume(), nil)
        case .seekRelative(let delta, let direction):
            return (playbackSink.seekRelative(deltaSeconds: delta, direction: direction), nil)
        case .seekTo(let pos): return (playbackSink.seekTo(positionSeconds: pos), nil)
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
