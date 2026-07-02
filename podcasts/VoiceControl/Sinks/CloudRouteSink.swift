class CloudRouteSink: VoiceCloudRouteSink {
    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> VoiceResponse {
        // Cloud routing will be wired when the cloud intent service is deployed
        .spoken("Cloud processing is coming soon")
    }
}
