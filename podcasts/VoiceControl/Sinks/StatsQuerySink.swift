import Foundation
import PocketCastsDataModel

class StatsQuerySink: VoiceStatsQuerySink {
    private let dataManager: DataManager

    init(dataManager: DataManager) { self.dataManager = dataManager }

    func listeningTime(period: String?) -> VoiceResponse {
        // TODO: Requires StatsRepository.listeningTime(period:) API
        .spoken("Check Stats in the Profile tab for detailed listening time")
    }

    func topPodcasts(period: String?) -> VoiceResponse {
        // TODO: Requires StatsRepository.topPodcasts(period:) API
        .spoken("Check Stats in the Profile tab for your top podcasts")
    }

    func episodesFinished(period: String?) -> VoiceResponse {
        // TODO: Requires StatsRepository.episodesFinished(period:) API
        .spoken("Check Stats in the Profile tab for completed episodes")
    }

    func listeningStreak() -> VoiceResponse {
        // TODO: Requires StatsRepository.listeningStreak() API
        .spoken("Check Stats in the Profile tab for your listening streak")
    }

    func subscriptionCount() -> VoiceResponse {
        let count = dataManager.allPodcasts(includeUnsubscribed: false).count
        return .spoken("\(count) subscriptions")
    }

    func unplayedTotal() -> VoiceResponse {
        let count = dataManager.allUnplayedEpisodes().count
        return .spoken("\(count) unplayed episodes")
    }

    func downloadStats() -> VoiceResponse {
        let count = dataManager.downloadedEpisodeCount()
        return .spoken("\(count) downloaded episodes")
    }

    func newEpisodes(timeframe: String?) -> VoiceResponse {
        // TODO: Requires DataManager.newEpisodes(timeframe:) or similar query
        // to filter episodes by publish date within the given timeframe
        .spoken("Check the Podcasts tab for new episodes")
    }

    func timeSinceLastListen() -> VoiceResponse {
        // TODO: Requires PlaybackManager.lastPlaybackEndTime or similar API
        // to compute the elapsed time since the last playback session ended
        .spoken("Check Stats in the Profile tab")
    }
}
