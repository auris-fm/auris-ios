protocol VoiceStatsQuerySink {
    func listeningTime(period: String?) -> VoiceResponse
    func topPodcasts(period: String?) -> VoiceResponse
    func episodesFinished(period: String?) -> VoiceResponse
    func listeningStreak() -> VoiceResponse
    func subscriptionCount() -> VoiceResponse
    func unplayedTotal() -> VoiceResponse
    func downloadStats() -> VoiceResponse
    func newEpisodes(timeframe: String?) -> VoiceResponse
    func timeSinceLastListen() -> VoiceResponse
}
