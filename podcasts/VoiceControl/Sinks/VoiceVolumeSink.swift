protocol VoiceVolumeSink {
    func setVolume(_ volume: Int) -> VoiceResponse
    func adjustVolume(delta: Int) -> VoiceResponse
    func queryVolume() -> VoiceResponse
}
