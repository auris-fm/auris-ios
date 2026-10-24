protocol VoiceCloudRouteSink {
    /// The cloud turn WITH the sink's own decision fact, stated at the turn
    /// loop's actual branches (done / error / superseded / not-configured
    /// guard) — the response template alone proves nothing.
    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> (response: VoiceResponse, fact: SinkActionFact?)
}
