protocol VoicePlaybackQuerySink {
    func whatsPlaying() -> VoiceResponse
    func position() -> VoiceResponse
    func timeRemaining() -> VoiceResponse
    func episodeDuration() -> VoiceResponse
    func publishDate() -> VoiceResponse
    func episodeDescription() -> VoiceResponse
    func downloadStatus() -> VoiceResponse
    func episodeTitle() -> VoiceResponse
}
