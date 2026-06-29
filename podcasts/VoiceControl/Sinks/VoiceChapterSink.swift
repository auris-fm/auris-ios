protocol VoiceChapterSink {
    func next() -> VoiceResponse
    func previous() -> VoiceResponse
    func byIndex(_ index: Int) -> VoiceResponse
    func byTitle(_ title: String) -> VoiceResponse
    func openLink(index: Int?, query: String?) -> VoiceResponse
    func queryList() -> VoiceResponse
    func queryCurrent() -> VoiceResponse
    func queryCount() -> VoiceResponse
    func queryNext() -> VoiceResponse
}
