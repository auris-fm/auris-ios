import Foundation

class EffectsManagerSink: VoiceEffectsSink {
    private let playbackManager: PlaybackManager

    init(playbackManager: PlaybackManager) { self.playbackManager = playbackManager }

    func setSpeed(_ speed: Double) -> VoiceResponse {
        let clamped = max(0.5, min(3.0, speed))
        let effects = playbackManager.effects()
        effects.playbackSpeed = clamped
        playbackManager.changeEffects(effects)
        return .spoken("Speed set to \(clamped)x")
    }

    func adjustSpeed(delta: Double) -> VoiceResponse {
        let effects = playbackManager.effects()
        let newSpeed = max(0.5, min(3.0, effects.playbackSpeed + delta))
        effects.playbackSpeed = newSpeed
        playbackManager.changeEffects(effects)
        return .spoken("Speed \(delta > 0 ? "increased" : "decreased") to \(newSpeed)x")
    }

    func setTrimMode(_ mode: TrimMode) -> VoiceResponse {
        let effects = playbackManager.effects()
        effects.trimSilence = mapTrimMode(mode)
        playbackManager.changeEffects(effects)
        return .earcon(.success)
    }

    func setVolumeBoost(enabled: Bool) -> VoiceResponse {
        let effects = playbackManager.effects()
        effects.volumeBoost = enabled
        playbackManager.changeEffects(effects)
        return .earcon(.success)
    }

    func queryEffects() -> VoiceResponse {
        let effects = playbackManager.effects()
        let speed = effects.playbackSpeed
        let trim = effects.trimSilence.isEnabled() ? "on" : "off"
        let boost = effects.volumeBoost ? "on" : "off"
        return .spoken("Speed \(speed)x, trim \(trim), boost \(boost)")
    }

    private func mapTrimMode(_ mode: TrimMode) -> TrimSilenceAmount {
        switch mode {
        case .off: return .off
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}
