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

    init(
        resolveSlider: (() -> UISlider?)? = nil,
        volumeReader: (() -> Float)? = nil
    ) {
        self.resolveSlider = resolveSlider
        self.volumeReader = volumeReader ?? { AVAudioSession.sharedInstance().outputVolume }
    }

    private func slider() -> UISlider? {
        if let resolveSlider { return resolveSlider() }
        return volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
    }

    /// Reads the system's applied volume. Injectable for the same reason the slider is: the
    /// observation has to be checkable, and the live session only reflects a write after the
    /// main queue drains it.
    private let volumeReader: () -> Float

    /// The volume observed after the most recent main-thread write, and whether one was
    /// attempted. Written on the main queue, read by tests through the same queue.
    @MainActor private(set) var observedVolumeAfterLastWrite: Float?

    /// Reads the applied volume after the write lands, so the sink's answer can be checked
    /// against what the system actually reports rather than what was requested.
    private func observeAppliedVolume(on mainQueue: DispatchQueue = .main) {
        mainQueue.async { [weak self] in
            guard let self else { return }
            self.observedVolumeAfterLastWrite = self.volumeReader()
        }
    }

    func setVolume(_ volume: Int) -> VoiceResponse {
        let clamped = max(0, min(100, volume))
        return respond(to: setSystemVolume(Float(clamped) / 100.0))
    }

    func adjustVolume(delta: Int) -> VoiceResponse {
        let currentVol = Int(volumeReader() * 100)
        let newVol = max(0, min(100, currentVol + delta))
        return respond(to: setSystemVolume(Float(newVol) / 100.0))
    }

    /// Turns the attempt's outcome into the spoken answer.
    ///
    /// A failure is spoken, not silent: the listener asked for a volume and none was applied,
    /// and a success-shaped silence is exactly the report-everything-as-done failure this sink
    /// used to have.
    private func respond(to applied: Bool) -> VoiceResponse {
        guard applied else {
            return .spoken(SpokenTemplateResolver().resolve("volume.unavailable"))
        }
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
        DispatchQueue.main.async { [weak self] in
            slider.value = volume
            slider.sendActions(for: .touchUpInside)
            self?.observeAppliedVolume()
        }
        return true
    }
}
