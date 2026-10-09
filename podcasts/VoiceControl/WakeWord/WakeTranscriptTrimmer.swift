import Foundation

/// Applies the spec's wake-positive time-band trim (recognition-pipeline.md,
/// "Wake-positive time band trim").
///
/// The spec's shape, and the reason each part is here:
/// - **Before intent routing, and only for a `Detected` utterance**: if timed
///   tokens are present, drop every token overlapping the completion band
///   (`[0, completionMs + 120 ms]`, `startMs < bandEndMs && endMs > 0`) and
///   concatenate the rest.
/// - **If timed tokens are absent**, leave the backend transcript unchanged:
///   *"Do not guess a spelling prefix. The LFM router is the backstop for an
///   unstripped wake rendering."*
/// - **`NotDetected` never applies the band**, even when tokens exist.
///
/// The pipeline *"never strips by spelling (exact phrase, homophone list, or edit
/// distance)"*, so no spelling heuristic belongs in this path.
///
/// On the selected iOS backends this is the absent-tokens case in practice:
/// SenseVoice-Small omits tokens and its config exposes no way to request them,
/// so the transcript reaches the router intact and the router is the backstop.
enum WakeTranscriptTrimmer {
    /// The spec's 120 ms pad, which covers detector hop jitter and a short trailing
    /// burst of the wake phrase; it is not a second word-boundary search.
    static let padMs = 120

    static func ms(ofSample sample: Int, sampleRateHz: Int) -> Int {
        let rate = max(sampleRateHz, 1)
        return Int((Int64(sample) * 1000) / Int64(rate))
    }

    /// The text to route for one capture.
    static func commandText(
        result: AsrResult,
        wakePositive: Bool,
        completionSample: Int,
        sampleRateHz: Int,
        utteranceDurationMs: Int
    ) -> String {
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `NotDetected` never applies the band.
        guard wakePositive else { return raw }
        // Absent tokens: the transcript is left unchanged.
        guard let tokens = result.tokens else { return raw }

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

    /// Convenience for a real capture: the buffer supplies the utterance length,
    /// which clamps the band so it cannot extend past what was said. The samples
    /// themselves are not inspected.
    static func commandText(
        result: AsrResult,
        wakePositive: Bool,
        completionSample: Int,
        sampleRateHz: Int,
        samples: [Float]
    ) -> String {
        commandText(
            result: result,
            wakePositive: wakePositive,
            completionSample: completionSample,
            sampleRateHz: sampleRateHz,
            utteranceDurationMs: samples.isEmpty ? 0 : ms(ofSample: samples.count - 1, sampleRateHz: sampleRateHz)
        )
    }
}
