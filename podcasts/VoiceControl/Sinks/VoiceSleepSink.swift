protocol VoiceSleepSink {
    func set(minutes: Int) -> VoiceResponse
    func endOfEpisode() -> VoiceResponse
    func endOfChapter() -> VoiceResponse
    func addTime(minutes: Int) -> VoiceResponse
    func cancel() -> VoiceResponse
    func query() -> VoiceResponse
}
