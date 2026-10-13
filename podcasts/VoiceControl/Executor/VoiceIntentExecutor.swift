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

extension PlaybackContext {
    /// A turn with no current episode: no id, no position. The cloud fields above are what
    /// carry the conversation identity, which is independent of episode availability.
    static let absent = PlaybackContext(
        episodeId: nil,
        podcastId: nil,
        referencePositionMs: nil,
        clientPositionMs: nil,
        recentReferencePositions: [],
        previousReferencePositionMs: nil
    )
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

    /// The handle to the cloud request most recently PREPARED, held on the executor rather than as
    /// a local in `execute`.
    ///
    /// A local dies when the call returns, so a later retry/recovery action would have nothing to
    /// name — the holder has to survive into the action that uses it. It is per-EXECUTOR rather
    /// than per-sink so a successor's turn cannot overwrite a handle belonging to an older one.
    /// Handles keyed by the LOGICAL REQUEST they belong to.
    ///
    /// A single "held" slot — on the sink first, then on the executor — is the same bug at a third
    /// level: a successor's turn overwrites the slot, so an action for turn A finds turn B's
    /// handle. Keying by the request id means an action can only reach the handle for the request
    /// it names, whatever else has been prepared since.
    private(set) var cloudPreparations: [String: CloudRouteSink.RetainedPreparation] = [:]

    /// The request text for each held handle, so an action can confirm it is retrying the request
    /// it believes it is.
    private(set) var cloudPreparationRequests: [String: String] = [:]

    /// The handle for a specific logical request, or nil when none is held for it.
    func heldCloudPreparation(forRequestId requestId: String) -> CloudRouteSink.RetainedPreparation? {
        cloudPreparations[requestId]
    }

    /// The sink this executor routes cloud playback through, so a test can reach the real
    /// producer the app built rather than constructing its own.
    var cloudRouteSinkForTesting: CloudRouteSink { cloudRouteSink as! CloudRouteSink }
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

    /// Re-drives the cloud request this executor last PREPARED, naming it by its held handle.
    ///
    /// This is the request-scoped retry action @spec asked for: it acts on the request the holder
    /// belongs to rather than on whatever the sink prepared most recently, so an older action
    /// cannot reach a successor's turn.
    ///
    /// **Eligibility is the caller's to establish.** The identity requirement does not authorize
    /// replaying a turn after an unknown outcome, and a transport error code is not evidence about
    /// the admission boundary — so this only re-drives what the holder names, and the sink itself
    /// refuses when the request's origin is no longer live.
    ///
    /// Returns nil when nothing is held, so an absent holder cannot be mistaken for a retry.
    func retryHeldCloudRequest(requestId: String) async -> CloudRouteResult? {
        // CLOSED BEFORE ANY TRANSPORT OR OUTPUT EFFECT (@spec).
        //
        // There is no producer that can establish eligibility: this transport cannot report a frame
        // as provably never submitted, so nothing is eligible to re-drive. An entry point that
        // keeps working in that state is an accessible replay path after possible admission, which
        // is precisely what must not exist. It therefore REFUSES UNCONDITIONALLY — no handle
        // lookup, no sink call, no cancel, no output registration — and the seam remains only so a
        // future producer has somewhere to attach.
        //
        // When that producer exists, this guard is the line to replace; until then it is the
        // boundary that keeps automatic turn retry unavailable by design.
        return nil
    }

    /// Drops every held preparation, called when the owning session ends.
    ///
    /// Still live and still meaningful even though nothing can retry: the HELD HANDLES are state a
    /// caller reads (`heldCloudPreparation(forRequestId:)`), so an ended session must not leave
    /// stale handles readable. This is lifecycle cleanup, not a replay path — it removes state and
    /// reaches no transport.
    func invalidateHeldCloudRequest() {
        for (_, held) in cloudPreparations {
            cloudRouteSink.invalidateRetained(held)
        }
        cloudPreparations.removeAll()
        cloudPreparationRequests.removeAll()
    }

    func execute(_ intent: any VoiceIntent) async -> VoiceResponse {
        let response: VoiceResponse
        // Set only by the cloud branch. Every other intent leaves it nil, so the generic
        // response-shape rule below is untouched for them.
        var cloudOutcome: CloudRouteOutcome?
        /// The handle to the request THIS execute call prepared, if any. Held per call so a retry
        /// names the request the caller actually made.

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
            // An absent context is a representable turn, not a refusal: the app's normal first
            // interaction has nothing playing, and the contract describes that as absent
            // context rather than as an invented episode and position. Refusing here is what
            // made the discovery turn unreachable on the client.
            let context = playbackContextProvider.current() ?? PlaybackContext.absent
            let result = await cloudRouteSink.routeToCloud(
                request: cr.request,
                tier: cr.tier,
                context: context,
                // The captured origin and selection, not live ones: the turn belongs to the
                // window and the selection it was issued under.
                origin: cr.generation,
                selection: cr.selection
            )
            response = result.response
            // Carried out of the switch rather than inferred from `response` below: the
            // rendered feedback cannot say what happened (a spoken error and a silent
            // success are both "no earcon"), and reading it as the outcome is how a
            // failed turn was recorded as a completed cloud route.
            cloudOutcome = result.outcome
            // The handle for THIS call's preparation, taken from the result rather than from a
            // published slot: a slot could have been replaced by a successor by the time this
            // line runs, and the caller would then retry a request it never made.
            if let handle = result.retainedPreparation {
                cloudPreparations[handle.requestId] = handle
                cloudPreparationRequests[handle.requestId] = cr.request
            }
        default: response = .earcon(.error)
        }

        // Record analytics after every command
        analytics?.recordCommand(intent, response: response)

        // Start grace period after any successful (non-error) command
        if let outcome = cloudOutcome {
            // The cloud turn's outcome decides this, not the response it rendered.
            switch outcome {
            case .completed:
                break   // falls through to the window decision below
            case .failed, .earlyClose, .refused:
                FileLog.shared.addMessage("[VoicePipeline] Cloud turn did not complete — no grace period")
                return response
            }
            guard let route = intent as? CloudRouteIntent else { return response }
            // Only a turn the server completed reaches the window decision. A window
            // without a generation cannot be attributed to any session, so it changes
            // no grace state rather than falling through to the generic reset.
            guard let generation = route.generation else {
                FileLog.shared.addMessage("[VoicePipeline] Cloud completion without a window identity — grace state untouched")
                return response
            }
            switch route.origin {
            case .modelCall:
                // Restores the allowance, but only inside its own window. One atomic
                // operation: checking then resetting separately leaves a gap in which
                // a privacy close could be undone.
                if gracePeriodSignal.recognizeCommandIfCurrentWindow(generation) {
                    FileLog.shared.addMessage("[VoicePipeline] Cloud turn completed — grace period")
                } else {
                    FileLog.shared.addMessage("[VoicePipeline] Cloud turn completed for an ended window — ignored")
                }
            case .routingFailure:
                // The conversation continues, but only for the window that issued
                // this dispatch, and without restoring the allowance that permitted
                // it (shared contract with Android).
                FileLog.shared.addMessage("[VoicePipeline] Fallback dispatch — grace period extended, budget kept spent")
                gracePeriodSignal.extendWindowKeepingEscalationSpent(underGeneration: generation)
            }
            return response
        } else if case .earcon(.error) = response {
            FileLog.shared.addMessage("[VoicePipeline] Command failed — no grace period")
        } else if let route = intent as? CloudRouteIntent {
            // A cloud completion may only touch the window it was issued under, so
            // it must carry that window's identity. One without a generation cannot
            // be attributed to any window — falling through to the generic reset
            // would let it reopen a session it never belonged to — so it changes no
            // grace state at all.
            guard let generation = route.generation else {
                FileLog.shared.addMessage("[VoicePipeline] Cloud completion without a window identity — grace state untouched")
                return response   // analytics already recorded above
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

        return response
    }

    private func executePlayback(_ intent: PlaybackIntent) -> VoiceResponse {
        switch intent {
        case .pause: return playbackSink.pause()
        case .resume: return playbackSink.resume()
        case .seekRelative(let delta, let direction):
            return playbackSink.seekRelative(deltaSeconds: delta, direction: direction)
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
