class CloudRouteSink: VoiceCloudRouteSink {
    private let templates = SpokenTemplateResolver()

    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> VoiceResponse {
        // Cloud routing will be wired when the cloud intent service is deployed
        .spoken(templates.resolve("general.cloud_coming_soon"))
    }
}
