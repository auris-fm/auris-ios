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
    /// The window passed to the positional check is the reference audio that was audible
    /// while the segment was being captured: a span of the segment's own length **ending**
    /// at the segment's end, because the segment just captured is the newest audio.
    ///
    /// Getting this backwards is not a near miss. Anchoring the window at the segment's
    /// start and running forward leaves almost nothing when the segment sits at the end
    /// of the reference, and the normalised correlation — `maxCorr / (micRms * pbRms *
    /// count)`, with `count` in the denominator — then approaches 1 for unrelated signals,
    /// so genuine user speech is rejected as bleed.
    ///
    /// - Parameters:
    ///   - mic: the captured segment at the pipeline rate.
    ///   - reference: the retained emitted audio at the pipeline rate.
    ///   - segmentEndOffset: where the segment's capture ends, in pipeline samples from
    ///     the reference's start. Negative means the segment cannot be placed, so no
    ///     alignment claim is made.
    func isPlaybackBleed(mic: [Float], reference: [Float], segmentEndOffset: Int) -> Bool {
        guard segmentEndOffset >= 0, segmentEndOffset <= reference.count else { return false }
        let start = max(0, segmentEndOffset - mic.count)
        let window = Array(reference[start..<segmentEndOffset])
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
