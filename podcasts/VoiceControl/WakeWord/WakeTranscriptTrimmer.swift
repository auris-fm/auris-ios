import Foundation

enum WakeTranscriptTrimmer {
    static let padMs = 120

    /// Whether the capture ended inside the wake band (the detector's own end
    /// sample plus pad), i.e. the user woke the assistant and said nothing else.
    ///
    /// Derived from the detector's timing rather than from how ASR spelled the
    /// wake, so a phonetic rendering such as `Oace.` still counts as the wake while
    /// the same words inside a longer capture do not.
    static func endsWithinWakeBand(
        completionSample: Int,
        sampleRateHz: Int,
        utteranceDurationMs: Int
    ) -> Bool {
        guard utteranceDurationMs > 0 else { return false }
        let rate = max(sampleRateHz, 1)
        let completionMs = Int((Int64(completionSample) * 1000) / Int64(rate))
        return utteranceDurationMs <= completionMs + padMs
    }

    static func commandText(
        result: AsrResult,
        wakePositive: Bool,
        completionSample: Int,
        sampleRateHz: Int,
        utteranceDurationMs: Int
    ) -> String {
        if !wakePositive { return result.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Backends without per-token timestamps cannot locate the wake *in the
        // text*, so the raw transcript is kept and wake+command still reaches the
        // classifier. But the wake can be located in *time*: if the capture ends
        // inside the wake band, the user woke us and said nothing else, whatever
        // ASR wrote for the wake — which matters because ASR guesses phonetically
        // at a name (the observed `Oace.`), and no spelling tolerance separates
        // that from a short real word (`iris`/`oris` are nearer `auris` than
        // `Oace` is). Emptiness here means "wake-only" to the engine.
        guard let tokens = result.tokens else {
            if endsWithinWakeBand(
                completionSample: completionSample,
                sampleRateHz: sampleRateHz,
                utteranceDurationMs: utteranceDurationMs
            ) {
                return ""
            }
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rate = max(sampleRateHz, 1)
        let completionMs = Int((Int64(completionSample) * 1000) / Int64(rate))
        let rawEnd = completionMs + padMs
        let bandEndMs = utteranceDurationMs > 0 ? min(max(rawEnd, 0), utteranceDurationMs) : max(rawEnd, 0)
        return tokens
            .filter { !($0.startMs < bandEndMs && $0.endMs > 0) }
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
