import Foundation
import PocketCastsDataModel

class StatsQuerySink: VoiceStatsQuerySink {
    private let dataManager: DataManager
    private let templates = SpokenTemplateResolver()

    init(dataManager: DataManager) { self.dataManager = dataManager }

    func listeningTime(period: String?) -> VoiceResponse {
        // TODO: Requires StatsRepository.listeningTime(period:) API
        .spoken(templates.resolve("stats.check_profile_listening_time"))
    }

    func topPodcasts(period: String?) -> VoiceResponse {
        // TODO: Requires StatsRepository.topPodcasts(period:) API
        .spoken(templates.resolve("stats.check_profile_top_podcasts"))
    }

    func episodesFinished(period: String?) -> VoiceResponse {
        // TODO: Requires StatsRepository.episodesFinished(period:) API
        .spoken(templates.resolve("stats.check_profile_completed"))
    }

    func listeningStreak() -> VoiceResponse {
        // TODO: Requires StatsRepository.listeningStreak() API
        .spoken(templates.resolve("stats.check_profile_streak"))
    }

    func subscriptionCount() -> VoiceResponse {
        let count = dataManager.allPodcasts(includeUnsubscribed: false).count
        return .spoken(templates.resolve("stats.subscription_count", count))
    }

    func unplayedTotal() -> VoiceResponse {
        // TODO: Requires DataManager.unplayedEpisodeCount or similar API
        .spoken(templates.resolve("stats.check_podcasts_unplayed"))
    }

    func downloadStats() -> VoiceResponse {
        let count = dataManager.downloadedEpisodeCount()
        return .spoken(templates.resolve("stats.downloaded_count", count))
    }

    func newEpisodes(timeframe: String?) -> VoiceResponse {
        // TODO: Requires DataManager.newEpisodes(timeframe:) or similar query
        .spoken(templates.resolve("stats.check_podcasts_new"))
    }

    func timeSinceLastListen() -> VoiceResponse {
        // TODO: Requires PlaybackManager.lastPlaybackEndTime or similar API
        .spoken(templates.resolve("stats.time_since_listen"))
    }
}
