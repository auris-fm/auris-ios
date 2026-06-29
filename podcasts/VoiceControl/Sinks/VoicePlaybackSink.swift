protocol VoicePlaybackSink {
    func pause() -> VoiceResponse
    func resume() -> VoiceResponse
    func seekRelative(deltaSeconds: Int) -> VoiceResponse
    func seekTo(positionSeconds: Int) -> VoiceResponse
    func nextEpisode() -> VoiceResponse
}
