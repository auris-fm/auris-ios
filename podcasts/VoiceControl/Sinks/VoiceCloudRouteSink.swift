protocol VoiceCloudRouteSink {
    /// - Parameter origin: the grace-window generation this turn was DISPATCHED under, or nil
    ///   when it was not stamped. The captured value is what the conversation bound needs: a
    ///   live read at turn time can belong to a different window than the turn does, and a
    ///   follow-up must not resume a conversation it never belonged to.
    func routeToCloud(
        request: String,
        tier: CloudTier,
        context: PlaybackContext,
        origin: Int?
    ) async -> CloudRouteResult
}
