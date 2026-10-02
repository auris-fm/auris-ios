/// Direction for a relative seek. When the cloud route sends a direction-only
/// call (no delta), the sink applies its own configurable interval in this
/// direction; when a delta is present the sign carries the direction and this
/// parameter exists only for the request-stated-neither case (FORWARD).
enum SeekDirection: Int {
    case forward = 0
    case backward = 1
}

protocol VoicePlaybackSink {
    func pause() -> VoiceResponse
    func resume() -> VoiceResponse
    /// Seek relative to the current position.
    ///
    /// `deltaSeconds` is nil when the request stated no amount — the sink
    /// applies its own interval in `direction`. `direction` is `forward` when
    /// the request stated neither an amount nor a direction.
    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse
    func seekTo(positionSeconds: Int) -> VoiceResponse
    /// A negative `positionSeconds` is an offset back from the episode end.
    /// The sink resolves and bounds it against the episode; callers must not
    /// clamp.
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse
    func nextEpisode() -> VoiceResponse
}
