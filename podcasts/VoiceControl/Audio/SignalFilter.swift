import Accelerate

class SignalFilter {
    private let threshold: Float = 0.7

    /// Returns true if the mic signal is likely playback bleed.
    /// Only applied on the built-in speaker route (Exposed, mic-to-playback alignment reliable).
    func isPlaybackBleed(mic: [Float], playback: [Float]) -> Bool {
        guard mic.count >= playback.count else { return false }
        var correlation = [Float](repeating: 0, count: mic.count - playback.count + 1)
        mic.withUnsafeBufferPointer { micPtr in
            playback.withUnsafeBufferPointer { pbPtr in
                vDSP_conv(micPtr.baseAddress!, 1, pbPtr.baseAddress!, 1,
                          &correlation, 1, vDSP_Length(correlation.count), vDSP_Length(playback.count))
            }
        }
        guard let maxCorr = correlation.max() else { return false }
        let micRms = rms(mic)
        let pbRms = rms(playback)
        guard micRms > 0, pbRms > 0 else { return false }
        let normalizedCorr = maxCorr / (micRms * pbRms * Float(playback.count))
        return normalizedCorr > threshold
    }

    private func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        vDSP_measqv(samples, 1, &sum, vDSP_Length(samples.count))
        return sqrt(sum)
    }
}
