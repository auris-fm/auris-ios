protocol VoiceCloudRouteSink {
    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> VoiceResponse
}
