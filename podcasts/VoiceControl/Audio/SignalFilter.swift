import Accelerate

class SignalFilter {
    private let threshold: Float = 0.7

    /// Returns true if the mic signal is likely playback bleed, using the segment's
    /// known position against the reference.
    ///
    /// The correlation window is the reference audio that was audible **when this
    /// segment was captured**, not the newest reference audio. Correlating against the
    /// newest window compares audio from two different moments: while a scheduled
    /// buffer is draining, the reference runs ahead of what the microphone can hear, so
    /// the match is against audio that has not left the speaker yet.
    ///
    /// - Parameters:
    ///   - mic: the captured segment at the pipeline rate.
    ///   - reference: the retained emitted audio at the pipeline rate.
    ///   - segmentStartOffset: where the segment begins, in pipeline samples from the
    ///     reference's start. Negative or beyond the retained window means the two do
    ///     not overlap, and no alignment claim can be made.
    func isPlaybackBleed(mic: [Float], reference: [Float], segmentStartOffset: Int) -> Bool {
        guard segmentStartOffset >= 0, segmentStartOffset < reference.count else { return false }
        let window = Array(reference[segmentStartOffset...])
        guard !window.isEmpty else { return false }
        return isPlaybackBleed(mic: mic, playback: window)
    }

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
