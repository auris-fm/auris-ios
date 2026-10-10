import Accelerate

class SignalFilter {
    private let threshold: Float = 0.7

    /// Fraction of the segment that must be present in the reference before the correlation
    /// is treated as decision-bearing.
    ///
    /// **This is a chosen policy, not a measured cutoff.** It is **dominated by the
    /// whole-segment coverage requirement** wherever that applies (coverage implies this
    /// fraction), so it is not a second safeguard on the aligned path; its role is to bound
    /// the positional overload, which has no coverage requirement of its own. No score
    /// threshold is derived from it, and it must not be relaxed to widen coverage.
    static let minimumOverlapFraction: Double = 0.75

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

        // Require a substantial overlap before deciding. Asking for a segment-length span
        // does not guarantee one exists: with the segment near the window's start, `start`
        // clamps to zero and the overlap is a fraction of the segment. A short overlap can
        // produce a high normalised score on a partial match — the score divides by the
        // window length, so it stays in range on far fewer samples than the segment has —
        // and the decision is then made on too little evidence to be right either way.
        // Declining here is the honest outcome: it is "not enough reference to decide",
        // not "not bleed".
        let minimumOverlap = Int(Double(mic.count) * Self.minimumOverlapFraction)
        guard window.count >= minimumOverlap, minimumOverlap > 0 else { return false }

        // **This is the guard that constrains rejection.** A match inside the overlap cannot
        // license rejecting the WHOLE segment: the score establishes that the compared
        // portion matches, and audio the comparison never saw — samples beyond the window —
        // could be the user speaking. Only a segment fully covered by the reference can be
        // rejected as echo, because only then does every sample have evidence against it.
        //
        // Note for readers: this requirement strictly implies the overlap-fraction check
        // above (`window.count >= mic.count` implies `>= 0.75 * mic.count`), so the fraction
        // guard is **dominated on this path** and is not a second, independent safeguard. It
        // is kept because it also bounds the positional overload, which has no coverage
        // requirement; on the aligned path the binding constraint is this one. Neither guard
        // may be relaxed to widen coverage.
        guard window.count >= mic.count else { return false }

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
        // Compare the three quantities over the SAME sample pairs: the numerator comes
        // from the winning lag, so the energies must be taken over that lag's overlapping
        // span rather than over the full microphone segment and the full window. Mixing
        // supports lets the score depend on how much audio sits outside the overlap —
        // energy in the segment beyond the window raises `micRms` without appearing in the
        // numerator, and the result is then a statement about lengths rather than about
        // match.
        guard let maxCorr = correlation.max(),
              let lag = correlation.firstIndex(of: maxCorr) else { return false }

        let paired = Array(mic[lag..<(lag + playback.count)])
        let micRms = rms(paired)
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
