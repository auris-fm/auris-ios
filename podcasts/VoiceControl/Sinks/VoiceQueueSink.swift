protocol VoiceQueueSink {
    func addTop(episode: String) -> VoiceResponse
    func addBottom(episode: String) -> VoiceResponse
    func remove(episode: String) -> VoiceResponse
    func moveToTop(episode: String) -> VoiceResponse
    func moveToBottom(episode: String) -> VoiceResponse
    func clear() -> VoiceResponse
    func removeByPodcast(podcast: String) -> VoiceResponse
    func sort(sortOrder: SortOrder) -> VoiceResponse
    func queryContents() -> VoiceResponse
    func queryNext() -> VoiceResponse
    func queryLength() -> VoiceResponse
    func queryIsQueued(episode: String) -> VoiceResponse
}
