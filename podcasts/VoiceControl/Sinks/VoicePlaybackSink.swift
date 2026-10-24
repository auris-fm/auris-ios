/// Direction for a relative seek. When the cloud route sends a direction-only
/// call (no delta), the sink applies its own configurable interval in this
/// direction; when a delta is present the sign carries the direction and this
/// parameter exists only for the request-stated-neither case (FORWARD).
enum SeekDirection: Int {
    case forward = 0
    case backward = 1
}

/// A sink's own structured fact about what its action actually did — the verdict channel
/// (spec: execution verdicts must be decision-site facts, not response classifications).
/// `state` uses the record's enumerated vocabulary; `reason` is an enumerated execution
/// reason, nil exactly when state is completed.
struct SinkActionFact {
    let state: String
    let reason: String?
}

protocol VoicePlaybackSink {
    /// Whether the host is playing right now. Read before taking the turn's
    /// hold: a pause of ours may only be released if it stopped playback that
    /// was already running.
    var isPlaying: Bool { get }
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
    /// THE FACT CHANNEL: pause with the sink's own structured fact. Protocol REQUIREMENT (with
    /// the default below) so overrides dispatch dynamically through the existential — a protocol
    /// extension alone would silently route every call to the default.
    func pauseWithFact() -> (response: VoiceResponse, fact: SinkActionFact?)
}

/// THE FACT CHANNEL, introduced one method at a time. The default reports NO fact — the
/// executor's bridge then keeps the verdict unknown, because a presentation cannot prove an
/// outcome. A sink that knows what its action did overrides the method and states the fact.
extension VoicePlaybackSink {
    /// Pause with the sink's own structured fact. Default: presentation only, no fact.
    func pauseWithFact() -> (response: VoiceResponse, fact: SinkActionFact?) {
        (pause(), nil)
    }
}
