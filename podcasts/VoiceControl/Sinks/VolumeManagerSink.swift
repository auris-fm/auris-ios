import AVFoundation
import MediaPlayer

class VolumeManagerSink: VoiceVolumeSink {
    private let volumeView = MPVolumeView()

    func setVolume(_ volume: Int) -> VoiceResponse {
        let clamped = max(0, min(100, volume))
        setSystemVolume(Float(clamped) / 100.0)
        return .silent
    }

    func adjustVolume(delta: Int) -> VoiceResponse {
        let currentVol = Int(AVAudioSession.sharedInstance().outputVolume * 100)
        let newVol = max(0, min(100, currentVol + delta))
        setSystemVolume(Float(newVol) / 100.0)
        return .silent
    }

    func queryVolume() -> VoiceResponse {
        let percent = Int(AVAudioSession.sharedInstance().outputVolume * 100)
        return .spoken("Volume is \(percent)%")
    }

    private func setSystemVolume(_ volume: Float) {
        guard let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider else { return }
        DispatchQueue.main.async {
            slider.value = volume
            slider.sendActions(for: .touchUpInside)
        }
    }
}
