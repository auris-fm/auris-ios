import Foundation

enum WakeTranscriptTrimmer {
    static let padMs = 120

    static func ms(ofSample sample: Int, sampleRateHz: Int) -> Int {
        let rate = max(sampleRateHz, 1)
        return Int((Int64(sample) * 1000) / Int64(rate))
    }

    /// The text to route for a capture the detector fired on.
    ///
    /// **The transcript is never trimmed.** iOS keeps the wake word in the text and
    /// lets the router handle it, which is what Android has always done — Android
    /// has no wake-stripping at all (`UtteranceFilter.kt` decides *whether* to
    /// process an utterance; it does not touch the text). A client that trims and
    /// one that does not is the divergence this removes.
    ///
    /// A time band cannot substitute for word boundaries in any case: the
    /// classifier's completion window is not a boundary estimator, so a capture
    /// ending near it does not prove the transcript holds only the wake, and a
    /// quietly spoken command sits inside exactly that window. The former
    /// timed-token branch deleted tokens on that assumption, so it could discard a
    /// command ASR had already transcribed. With it gone there is **no branch here
    /// that can discard text** — the same property Android has by construction,
    /// checkable by reading this file rather than comparing two languages.
    ///
    /// A bare wake is bounded by the grace window's single dispatch, not by an
    /// acoustic or timing guess.
    ///
    /// The parameters are accepted so the call site does not have to know which
    /// backend produced the result; none of them is consulted.
    static func commandText(
        result: AsrResult,
        wakePositive: Bool,
        completionSample: Int,
        sampleRateHz: Int,
        utteranceDurationMs: Int
    ) -> String {
        result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convenience for a real capture. The buffer is not consulted either.
    static func commandText(
        result: AsrResult,
        wakePositive: Bool,
        completionSample: Int,
        sampleRateHz: Int,
        samples: [Float]
    ) -> String {
        _ = samples
        return commandText(
            result: result,
            wakePositive: wakePositive,
            completionSample: completionSample,
            sampleRateHz: sampleRateHz,
            utteranceDurationMs: 0
        )
    }
}
