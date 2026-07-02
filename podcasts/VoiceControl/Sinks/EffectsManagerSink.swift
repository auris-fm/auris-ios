import Foundation
import PocketCastsDataModel
import PocketCastsUtils

class EffectsManagerSink: VoiceEffectsSink {
    private let playbackManager: PlaybackManager
    private let templates = SpokenTemplateResolver()

    init(playbackManager: PlaybackManager) { self.playbackManager = playbackManager }

    func setSpeed(_ speed: Double) -> VoiceResponse {
        let clamped = max(0.5, min(3.0, speed))
        FileLog.shared.addMessage("[VoiceControl/Effects] SetSpeed: \(clamped)x")
        let effects = playbackManager.effects()
        effects.playbackSpeed = clamped
        playbackManager.changeEffects(effects)
        return .spoken(templates.resolve("effects.set_speed", clamped))
    }

    func adjustSpeed(delta: Double) -> VoiceResponse {
        let effects = playbackManager.effects()
        let newSpeed = max(0.5, min(3.0, effects.playbackSpeed + delta))
        FileLog.shared.addMessage("[VoiceControl/Effects] AdjustSpeed: \(delta >= 0 ? "+" : "")\(delta) → \(newSpeed)x")
        effects.playbackSpeed = newSpeed
        playbackManager.changeEffects(effects)
        let key = delta > 0 ? "effects.speed_increased" : "effects.speed_decreased"
        return .spoken(templates.resolve(key, newSpeed))
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
        return .spoken(templates.resolve("effects.query", speed, trim, boost))
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
