protocol VoiceEffectsSink {
    func setSpeed(_ speed: Double) -> VoiceResponse
    func adjustSpeed(delta: Double) -> VoiceResponse
    func setTrimMode(_ mode: TrimMode) -> VoiceResponse
    func setVolumeBoost(enabled: Bool) -> VoiceResponse
    func queryEffects() -> VoiceResponse
}
