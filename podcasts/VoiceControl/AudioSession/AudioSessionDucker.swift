import AVFoundation
import MediaPlayer
import PocketCastsUtils

/// Ducking boundary so the renderer is testable without a live audio session.
protocol AudioSessionDucking {
    func duck()
    func unduck()
}

/// Lowers playback volume during TTS/earcon playback and restores it afterward.
///
/// Uses the system volume slider (MPVolumeView) to temporarily reduce output
/// volume so spoken responses are clearly audible over podcast audio.
/// When playback is not active, ducking is a no-op.
class AudioSessionDucker: AudioSessionDucking {
    /// Lazily create MPVolumeView to avoid side effects during VoiceControl init.
    private lazy var volumeView: MPVolumeView = MPVolumeView()
    private var originalVolume: Float?
    private var isDucked = false

    /// Fraction of original volume to use while ducked (0.0–1.0).
    /// 0.3 means volume is reduced to 30% of the original level.
    private let duckFraction: Float = 0.3

    /// Reduce playback volume to make TTS/earcon more audible.
    func duck() {
        onMain {
            guard !self.isDucked else { return }
            let currentVolume = AVAudioSession.sharedInstance().outputVolume
            guard currentVolume > 0.01 else { return } // Already effectively silent
            self.originalVolume = currentVolume
            let duckedVolume = currentVolume * self.duckFraction
            self.setSystemVolume(duckedVolume)
            self.isDucked = true
            FileLog.shared.addMessage("[VoiceControl/Ducker] Duck: \(String(format: "%.2f", currentVolume)) → \(String(format: "%.2f", duckedVolume))")
        }
    }

    /// Restore playback volume to its pre-duck level.
    func unduck() {
        onMain {
            guard self.isDucked, let original = self.originalVolume else { return }
            self.setSystemVolume(original)
            self.isDucked = false
            self.originalVolume = nil
            FileLog.shared.addMessage("[VoiceControl/Ducker] Unduck: restored to \(String(format: "%.2f", original))")
        }
    }

    /// MPVolumeView must be created and touched on the main thread.
    private func setSystemVolume(_ volume: Float) {
        guard let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider else {
            FileLog.shared.addMessage("[VoiceControl/Ducker] Volume slider not found")
            return
        }
        slider.value = volume
        slider.sendActions(for: .touchUpInside)
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }
}
