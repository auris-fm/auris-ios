import Foundation

protocol VoiceIntent {}

enum PlaybackIntent: VoiceIntent, Equatable {
    case pause
    case resume
    /// Relative seek. `deltaSeconds` is nil when the request stated no amount
    /// — the sink applies its own configurable interval in `direction`.
    case seekRelative(deltaSeconds: Int?, direction: SeekDirection)
    case seekTo(positionSeconds: Int)
    case nextEpisode
}

enum EffectsIntent: VoiceIntent, Equatable {
    case setSpeed(Double)
    case adjustSpeed(delta: Double)
    case setTrimMode(TrimMode)
    case setVolumeBoost(enabled: Bool)
    case query
}

enum TrimMode: String, Equatable {
    case off
    case low
    case medium
    case high
}

enum VolumeIntent: VoiceIntent, Equatable {
    case setVolume(Int)
    case adjustVolume(delta: Int)
    case query
}

enum SleepIntent: VoiceIntent, Equatable {
    case set(minutes: Int)
    case endOfEpisode
    case endOfChapter
    case addTime(minutes: Int)
    case cancel
    case query
}

enum ChapterIntent: VoiceIntent, Equatable {
    case next
    case previous
    case byIndex(Int)
    case byTitle(String)
    case openLink(index: Int?, query: String?)
    case queryList
    case queryCurrent
    case queryCount
    case queryNext
}

enum BookmarkIntent: VoiceIntent, Equatable {
    case add(title: String?)
    case rename(ref: String, title: String)
    case play(ref: String)
    case delete(ref: String)
    case deleteAll
    case queryList
    case queryCount
    case queryNearby
}

enum QueueIntent: VoiceIntent, Equatable {
    case addTop(episode: String)
    case addBottom(episode: String)
    case remove(episode: String)
    case moveToTop(episode: String)
    case moveToBottom(episode: String)
    case clear
    case removeByPodcast(podcast: String)
    case sort(sortOrder: SortOrder)
    case queryContents
    case queryNext
    case queryLength
    case queryIsQueued(episode: String)
}

enum SortOrder: String, Equatable {
    case newestFirst
    case oldestFirst
}

enum PlaybackQueryIntent: VoiceIntent, Equatable {
    case whatsPlaying
    case position
    case timeRemaining
    case episodeDuration
    case publishDate
    case episodeDescription
    case downloadStatus
    case episodeTitle
}

enum StatsQueryIntent: VoiceIntent, Equatable {
    case listeningTime(period: String?)
    case topPodcasts(period: String?)
    case episodesFinished(period: String?)
    case listeningStreak
    case subscriptionCount
    case unplayedTotal
    case downloadStats
    case newEpisodes(timeframe: String?)
    case timeSinceLastListen
}

struct CloudRouteIntent: VoiceIntent, Equatable {
    let request: String
    let tier: CloudTier
    /// The complete wake-trimmed SOURCE utterance, when one exists (platform translate kept the
    /// native text; backend translate exposes English only and leaves this nil). The runtime
    /// cloud `request` carries this original — the English routing translation selects the
    /// action but never replaces the original the model answers.
    var sourceTranscript: String? = nil
    /// The ASR pipeline's actual detected language (LID). Unknown stays nil and is OMITTED on
    /// the wire — never the OS locale, never a default. Preserves yue vs zh.
    var sourceLanguage: String? = nil
    /// REQUEST OWNERSHIP (owner delta 3484cbc/5eca874): the captured utterance's identity, so
    /// duplicate preparation/callbacks join one wire request instead of minting another.
    /// `nil` keeps the legacy per-call identity for constructions without an utterance.
    var utteranceId: String? = nil
    /// Why this dispatch exists. A dispatch from a routing failure is a *fallback*
    /// rather than a command the user gave, and the two must not be treated alike
    /// by the grace window: handling a fallback continues the window but must not
    /// restore the escalation allowance that permitted it, or one window could
    /// dispatch repeatedly. Mirrors Android's origin marker on the intent.
    let origin: CloudRouteOrigin
    /// The grace-window generation this dispatch was issued under.
    ///
    /// Set for both origins: a fallback carries the generation whose allowance it
    /// spent, and a model-chosen route carries the generation it was issued under
    /// so its completion can be attributed to *that* window rather than to
    /// whatever is current when the network returns. Its completion may only
    /// affect the window it belonged to: a request that returns after a privacy
    /// close and a new wake must not extend the new window or restore its
    /// allowance. `nil` means "change no grace state at all", so a construction
    /// site that omits it silently loses the check rather than failing.
    let generation: Int?

    /// What selected this turn, captured with the input. A wake word always opens a new
    /// conversation; only a wake-free follow-up continues one. Captured rather than read at
    /// dispatch time for the same reason as `generation`: the answer is a property of the input,
    /// not of whatever the window looks like after routing.
    let selection: CloudConversationSelection?

    init(
        request: String,
        tier: CloudTier,
        sourceTranscript: String? = nil,
        sourceLanguage: String? = nil,
        utteranceId: String? = nil,
        origin: CloudRouteOrigin = .modelCall,
        generation: Int? = nil,
        selection: CloudConversationSelection? = nil
    ) {
        self.request = request
        self.tier = tier
        self.sourceTranscript = sourceTranscript
        self.sourceLanguage = sourceLanguage
        self.utteranceId = utteranceId
        self.origin = origin
        self.generation = generation
        self.selection = selection
    }
}

enum CloudRouteOrigin: Equatable {
    /// The model chose `cloud_route` itself.
    case modelCall
    /// The local router produced no answer, so the client escalated.
    case routingFailure
}

enum CloudTier: String, Equatable {
    case free
    case premium
    case unknown
}

struct PlaybackContext: Equatable {
    /// Absent when no current episode exists. Nil rather than empty: the contract forbids
    /// inventing an ID, and the discovery turn — nothing playing — must represent that as
    /// absence rather than as an id that names nothing.
    let episodeId: String?
    let podcastId: String?
    let referencePositionMs: Int64?
    /// Absent when there is no current episode to hold a position in.
    let clientPositionMs: Int64?
    let recentReferencePositions: [Int64]
    let previousReferencePositionMs: Int64?
}
