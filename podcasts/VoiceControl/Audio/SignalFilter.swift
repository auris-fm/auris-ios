import Accelerate

class SignalFilter {
    private let threshold: Float = 0.7

    /// Fraction of the segment that must be present in the reference before the correlation
    /// is treated as decision-bearing.
    ///
    /// **A chosen policy, not a measured cutoff, and not a second safeguard.** The guard is
    /// `window >= Int(0.75 * mic) && Int(0.75 * mic) > 0`; the truncation makes the first
    /// term zero at `mic == 1`, where the second declines a segment that whole-segment
    /// coverage would accept. Verified in Swift: for every other length the fraction passes
    /// whenever coverage does. **Its only effect is on a single-sample segment**, which
    /// cannot be a VAD segment. No score threshold is derived from it, and it must not be
    /// relaxed to widen coverage.
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
        // Note for readers: the overlap-fraction check above is **not a second, independent
        // safeguard on this path**. It is not simply `window >= 0.75 * mic` either — it is
        // `window >= Int(0.75 * mic) && Int(0.75 * mic) > 0`, and the truncation makes
        // `Int(0.75 * mic)` zero at `mic == 1`, where the `> 0` clause declines a segment
        // coverage would accept. Verified in Swift: for every other length the fraction
        // passes whenever coverage does, and for `mic >= 2` it never binds. The fraction
        // guard therefore changes the outcome only for a **single-sample** segment, which
        // cannot be a VAD segment and so never occurs on a real input.
        //
        // It is kept as a clarity call, not as protection: removing it would widen nothing
        // and it is the only thing declining the degenerate case, but it protects nothing
        // on any real input. Neither guard may be relaxed to widen coverage.
        guard window.count >= mic.count else { return false }

        return isPlaybackBleed(mic: mic, playback: window)
    }

    /// Returns true if the mic signal is likely playback bleed.
    ///
    /// Compares arbitrary lengths, and takes both energies over the winning lag's paired
    /// samples so the score describes the match rather than the lengths. **That pairing is
    /// currently latent: the only production caller passes an equal-length window, where
    /// the correlation has one entry, `lag` is always zero and `paired` is the whole
    /// segment.** It is kept because taking the energies over the same support is correct
    /// for any caller, and a future caller comparing unequal spans would otherwise get an
    /// energy over audio the numerator did not examine. The aligned path does not depend on
    /// it. Only applied on the built-in speaker route (mic-to-playback alignment reliable).
    func isPlaybackBleed(mic: [Float], playback: [Float]) -> Bool {
        guard mic.count >= playback.count else { return false }
        var correlation = [Float](repeating: 0, count: mic.count - playback.count + 1)
        mic.withUnsafeBufferPointer { micPtr in
            playback.withUnsafeBufferPointer { pbPtr in
                vDSP_conv(micPtr.baseAddress!, 1, pbPtr.baseAddress!, 1,
                          &correlation, 1, vDSP_Length(correlation.count), vDSP_Length(playback.count))
            }
        }
        // Normalise EACH candidate lag by its own paired energies, then take the maximum
        // of those scores. Raw correlation is the right quantity to maximise and the wrong
        // one to select with: a loud portion of the segment can produce a larger raw sum at
        // a spurious alignment than the true match produces at lag 0, so selecting on the
        // raw value picks the wrong span and then judges that span. Scoring every lag on
        // the same criterion the decision uses removes that mismatch — one criterion for
        // choosing and judging.
        //
        // Energies are taken over the lag's own overlapping samples, so the score does not
        // depend on audio outside the overlap: energy beyond the window would raise the
        // microphone's energy without appearing in the numerator, making the result a
        // statement about lengths rather than about match.
        //
        // **Limits, stated rather than assumed absent.** This is a correlation over a
        // sliding window, so it inherits the usual caveats.
        //
        // A periodic or self-similar segment has several equally good alignments and any of
        // them may win; that is harmless here because each such alignment is genuinely the
        // same audio.
        //
        // One region is **known** and survives this normalisation: an anti-correlated span
        // scores at the negative end of the normalised range rather than the positive end,
        // so it is not rejected. That is the intended outcome rather than a gap — a span
        // that is our output *inverted* is not our emitted audio, so declining to reject it
        // is correct. It is recorded because the negative side of the range is reachable,
        // and a future rule that judged on magnitude alone would treat it as a match.
        let pbRms = rms(playback)
        guard pbRms > 0 else { return false }

        // A normalised score can be negative: a lag that sees anti-correlated audio scores
        // -1 — maximally wrong rather than merely unmatched. Starting the running maximum at
        // zero therefore cannot change the decision while the threshold is positive, since
        // any negative score also fails `> threshold`. It would matter if the rule ever
        // wanted the maximising lag rather than a verdict, because a clamped maximum would
        // report "none" instead of the true (negative) maximiser.
        var bestScore: Float = 0
        for (lag, corr) in correlation.enumerated() {
            let paired = mic[lag..<(lag + playback.count)]
            let micRms = rms(Array(paired))
            guard micRms > 0 else { continue }
            let score = corr / (micRms * pbRms * Float(playback.count))
            if score > bestScore { bestScore = score }
        }
        return bestScore > threshold
    }

    private func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        vDSP_measqv(samples, 1, &sum, vDSP_Length(samples.count))
        return sqrt(sum)
    }
}
