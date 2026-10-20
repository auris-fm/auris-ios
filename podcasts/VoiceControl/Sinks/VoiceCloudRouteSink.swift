/// The disposition of one dispatch admission. `owner(token)` is the ONLY disposition that may
/// run the wire turn and repeat the turn's effects; the others join or observe without acting.
enum CloudDispatchOwnership: Equatable {
    /// This caller owns the dispatch, identified by an immutable token.
    case owner(DispatchToken)
    /// Another caller owns a dispatch that has NOT settled: await it.
    case join
    /// The dispatch already settled in this window: observe its retained result.
    case settled(CloudRouteResult)
    /// No dispatch may start for this caller in this window (stale origin, or a retired record).
    case refused

    struct DispatchToken: Equatable, Hashable {
        let utteranceId: String
        let instance: UUID
    }

    var ownsDispatch: Bool { if case .owner = self { return true }; return false }
}

protocol VoiceCloudRouteSink {
    /// - Parameter origin: the grace-window generation this turn was DISPATCHED under, or nil
    ///   when it was not stamped. The captured value is what the conversation bound needs: a
    ///   live read at turn time can belong to a different window than the turn does, and a
    ///   follow-up must not resume a conversation it never belonged to.
    /// - Parameter selection: what selected this turn, captured with the input. Nil when the
    ///   caller did not capture it; the sink then falls back to a live reading, which is the
    ///   behaviour that misattributes a queued turn, so a production caller should always supply
    ///   it.
    func routeToCloud(
        request: String,
        tier: CloudTier,
        context: PlaybackContext,
        origin: Int?,
        selection: CloudConversationSelection?,
        utteranceId: String?,
        preparedObserver: CloudRouteSink.PreparedObserver?,
        sourceTranscript: String?,
        sourceLanguage: String?,
        ownership: CloudDispatchOwnership?
    ) async -> CloudRouteResult

    /// Admits a dispatch for an utterance and returns its ownership TOKEN in ONE atomic step,
    /// fenced by the LIVE origin. Only the owner of the returned token may dispatch and repeat
    /// effects; a duplicate, a settled replay, a stale caller and a caller whose origin is not
    /// live all receive a non-owner disposition. The token is passed back to `routeToCloud`, so
    /// the same admission decides both wire and effect ownership (reviewer b2c09394).
    func beginDispatch(utteranceId: String?, origin: Int?) -> CloudDispatchOwnership


}
