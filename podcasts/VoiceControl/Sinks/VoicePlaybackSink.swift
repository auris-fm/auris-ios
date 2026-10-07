protocol VoicePlaybackSink {
    /// Whether the host is playing right now. Read before taking the turn's
    /// hold: a pause of ours may only be released if it stopped playback that
    /// was already running.
    var isPlaying: Bool { get }
    func pause() -> VoiceResponse
    func resume() -> VoiceResponse
    func seekRelative(deltaSeconds: Int) -> VoiceResponse
    func seekTo(positionSeconds: Int) -> VoiceResponse
    func nextEpisode() -> VoiceResponse
}
