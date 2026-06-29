protocol VoiceBookmarkSink {
    func add(title: String?) -> VoiceResponse
    func rename(ref: String, title: String) -> VoiceResponse
    func play(ref: String) -> VoiceResponse
    func delete(ref: String) -> VoiceResponse
    func deleteAll() -> VoiceResponse
    func queryList() -> VoiceResponse
    func queryCount() -> VoiceResponse
    func queryNearby() -> VoiceResponse
}
