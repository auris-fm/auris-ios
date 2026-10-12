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
        selection: CloudConversationSelection?
    ) async -> CloudRouteResult

    /// Re-drives the last prepared logical request, preserving its ids. Only for a transport that
    /// dropped BEFORE admission — never a blanket replay after an unknown outcome.
    func retryLastPreparedRequest(requestId: String) async -> CloudRouteResult?

    /// Drops a retained request when its owning lifecycle ends.
    func invalidateRetained(_ handle: CloudRouteSink.RetainedPreparation)
}
