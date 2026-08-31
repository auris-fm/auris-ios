import AVFoundation
import PocketCastsUtils

class NativeAudioCapture {
    let engine = AVAudioEngine()
    private let sampleRate = 16000.0
    private var energyLogged = false
    var onSamples: (([Float]) -> Void)?

    func start() throws {
        let session = AVAudioSession.sharedInstance()

        // defaultToSpeaker: ensure audio plays through the main speaker, not the
        // earpiece, so podcast playback isn't silenced when VoiceControl is active.
        // mixWithOthers: allow other app audio to play alongside wake-word listening.
        // allowBluetooth: support Bluetooth headsets with built-in mics.
        try session.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setMode(.default)
        // NOTE: Do NOT call setPreferredSampleRate — it locks the hardware to one
        // rate and breaks playback at other rates. The resample below handles any
        // rate mismatch between hardware input and the model's 16kHz requirement.
        try session.setActive(true)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let formatDescription = inputFormat.description  // includes commonFormat, sampleRate, channelCount

        // Tap receives audio on the real-time audio thread. Copy samples off
        // immediately and dispatch to a processing queue — Swift Task {} and
        // FileLog silently fail on the real-time thread.
        let bufferSize: AVAudioFrameCount = 1024
        let processingQueue = DispatchQueue(label: "fm.auris.audio.processing", qos: .userInitiated)

        // On real iOS devices the input format is always Float32, but the simulator
        // may deliver Int16 PCM from the Mac's audio hardware. When floatChannelData
        // is nil (non-float format), fall back to int16ChannelData and convert.
        var formatWarningLogged = false
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            let frameLength = Int(buf.frameLength)
            let nativeRate = buf.format.sampleRate

            let rawSamples: [Float]
            if let channelData = buf.floatChannelData {
                rawSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            } else if let channelData = buf.int16ChannelData {
                // Simulator / Mac hardware often delivers Int16. Convert to float
                // normalized to [-1, 1] and warn once so the format is visible in logs.
                rawSamples = UnsafeBufferPointer(start: channelData[0], count: frameLength).map { Float($0) / Float(Int16.max) }
                if !formatWarningLogged {
                    formatWarningLogged = true
                    processingQueue.async {
                        FileLog.shared.addMessage("[VoiceControl/Capture] Input format is Int16 (not Float32) — converting. Format: \(formatDescription)")
                    }
                }
            } else {
                // Unknown / unsupported format — log once and drop this buffer.
                if !formatWarningLogged {
                    formatWarningLogged = true
                    processingQueue.async {
                        FileLog.shared.addMessage("[VoiceControl/Capture] Unsupported audio format — dropping buffers. Format: \(formatDescription)")
                    }
                }
                return
            }

            processingQueue.async { [weak self] in
                guard let self else { return }
                let converted: [Float]
                if nativeRate == self.sampleRate {
                    converted = rawSamples
                } else {
                    converted = self.resample(rawSamples, from: nativeRate, to: self.sampleRate)
                }
                // Log first buffer to confirm tap is delivering audio
                if !self.energyLogged {
                    self.energyLogged = true
                    let maxVal = converted.max() ?? 0
                    let minVal = converted.min() ?? 0
                    FileLog.shared.addMessage("[VoiceControl/Capture] First buffer: \(converted.count) samples, min=\(String(format: "%.6f", minVal)) max=\(String(format: "%.6f", maxVal))")
                    FileLog.shared.forceFlush()
                }
                self.onSamples?(converted)
            }
        }

        engine.prepare()
        try engine.start()
        FileLog.shared.addMessage("[VoiceControl/Capture] Audio engine started (input: \(formatDescription) → \(sampleRate)Hz)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let session = AVAudioSession.sharedInstance()
        // Restore playback-friendly category so podcast playback works normally.
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Downsample from `from` Hz to `to` Hz using linear interpolation.
    private func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        let outputCount = Int(Double(samples.count) * to / from)
        guard outputCount > 1 else { return [] }
        var result = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let pos = Double(i) * (Double(samples.count) - 1) / Double(outputCount - 1)
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = samples[min(idx, samples.count - 1)]
            let b = samples[min(idx + 1, samples.count - 1)]
            result[i] = a + (b - a) * frac
        }
        return result
    }
}
