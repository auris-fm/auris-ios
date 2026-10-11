import AVFoundation
import MediaPlayer

class VolumeManagerSink: VoiceVolumeSink {
    /// Lazily create MPVolumeView to avoid side effects during VoiceControl init.
    private lazy var volumeView = MPVolumeView()

    /// Resolves the volume slider, or nil when it cannot be reached.
    ///
    /// Injectable because the unreachable case is the one that matters and a live MPVolumeView
    /// does not let a test choose it: on this platform a freshly built view already exposes a
    /// slider whether or not it is in a window.
    private let resolveSlider: (() -> UISlider?)?

    init(resolveSlider: (() -> UISlider?)? = nil) {
        self.resolveSlider = resolveSlider
    }

    private func slider() -> UISlider? {
        if let resolveSlider { return resolveSlider() }
        return volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
    }

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
        let templates = SpokenTemplateResolver()
        return .spoken(templates.resolve("volume.current", percent))
    }

    /// Sets the system volume, reporting whether the attempt could be made.
    ///
    /// The slider lookup is the session-acquisition failure path for this operation: when it
    /// fails, nothing was set. Returning as if the work had happened would report a change
    /// that did not occur, so the outcome is carried rather than assumed.
    @discardableResult
    func setSystemVolume(_ volume: Float) -> Bool {
        guard let slider = slider() else {
            return false
        }
        DispatchQueue.main.async {
            slider.value = volume
            slider.sendActions(for: .touchUpInside)
        }
        return true
    }
}
