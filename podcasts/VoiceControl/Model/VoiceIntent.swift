import Foundation

protocol VoiceIntent {}

enum PlaybackIntent: VoiceIntent, Equatable {
    case pause
    case resume
    case seekRelative(deltaSeconds: Int)
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
    let context: PlaybackContext
}

enum CloudTier: String, Equatable {
    case free
    case premium
    case unknown
}

struct PlaybackContext: Equatable {
    let episodeId: String
    let positionMs: Int64
    let recentTimestamps: [Int64]
}
