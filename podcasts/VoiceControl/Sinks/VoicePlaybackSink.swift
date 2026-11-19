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
struct SinkActionFact: Equatable {
    let state: String
    let reason: String?
}

protocol VoicePlaybackSink {
    /// Whether the host is playing right now. Read before taking the turn's
    /// hold: a pause of ours may only be released if it stopped playback that
    /// was already running.
    var isPlaying: Bool { get }
    /// A post-action playback observation for the identified app-operation path
    /// (voice-intents.md @ 818c8f75): `nil` = no current engine reading could be produced
    /// (unavailable), `.some(false)` = observed not playing (an already-paused engine
    /// included), `.some(true)` = observed playing. Unlike `isPlaying`, this keeps
    /// unavailable separate from observed-paused.
    var observedPlaying: Bool? { get }
    func pause() -> VoiceResponse
    func resume() -> VoiceResponse
    /// Seek relative to the current position.
    ///
    /// `deltaSeconds` is nil when the request stated no amount — the sink
    /// applies its own interval in `direction`. `direction` is `forward` when
    /// the request stated neither an amount nor a direction.
    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse
    /// ADDITIVE REQUIREMENT (task67 seek_relative slice): identified relative seek. Declared as
    /// a REQUIREMENT so conformers that implement it dispatch dynamically; the extension below
    /// supplies the fail-closed nil default for conformers that do not.
    func seekRelativeIdentified(deltaSeconds: Int?, direction: SeekDirection, invocationToken: UUID, deadlineNs: UInt64?, typedCompletion: @escaping (SeekExecutionOutcome) -> Void) -> SeekIdentity?
    /// ADDITIVE REQUIREMENT: the LIVE engine objects for replacement detection at settlement.
    func identifiedEngineIdentity() -> SeekIdentity?
    func seekTo(positionSeconds: Int) -> VoiceResponse
    /// A negative `positionSeconds` is an offset back from the episode end.
    /// The sink resolves and bounds it against the episode; callers must not
    /// clamp.
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse
    func nextEpisode() -> VoiceResponse
    /// THE fact channel: pause with the sink's own structured fact. Protocol REQUIREMENT (with
    /// the default below) so overrides dispatch dynamically through the existential — a protocol
    /// extension alone would silently route every call to the default.
    func pauseWithFact() -> (response: VoiceResponse, fact: SinkActionFact?)
    /// Next-episode skip with the sink's own structured fact: completed only when a skip
    /// actually happened; a declined skip (nothing queued) states not_run/precondition_failed.
    func nextEpisodeWithFact() -> (response: VoiceResponse, fact: SinkActionFact?)
}

/// THE fact channel, introduced one method at a time. The default reports NO fact — the
/// executor's bridge then keeps the verdict unknown, because a presentation cannot prove an
/// outcome. A sink that knows what its action did overrides the method and states the fact.
extension VoicePlaybackSink {
    /// Pause with the sink's own structured fact. Default: presentation only, no fact.
    func pauseWithFact() -> (response: VoiceResponse, fact: SinkActionFact?) {
        (pause(), nil)
    }
    /// Default: presentation only, no fact.
    func nextEpisodeWithFact() -> (response: VoiceResponse, fact: SinkActionFact?) {
        (nextEpisode(), nil)
    }
}

/// ADDITIVE (task67 seek_relative slice): the identified relative seek. Default nil = this
/// sink cannot produce completion evidence; the identified path settles `unknown` WITHOUT
/// releasing any effect (fail-closed) — the legacy `seekRelative` stays fire-and-forget.
extension VoicePlaybackSink {
    /// Fail-closed default: no completion evidence, no effect. Declared as a requirement so
    /// conformer overrides dispatch dynamically; this default satisfies non-implementers.
    func seekRelativeIdentified(deltaSeconds: Int?, direction: SeekDirection, invocationToken: UUID, deadlineNs: UInt64?, typedCompletion: @escaping (SeekExecutionOutcome) -> Void) -> SeekIdentity? { nil }
    /// ADDITIVE REQUIREMENT: the LIVE engine objects for replacement detection at settlement.
    func identifiedEngineIdentity() -> SeekIdentity? { nil }
}
