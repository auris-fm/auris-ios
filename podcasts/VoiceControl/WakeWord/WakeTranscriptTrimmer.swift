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
    /// Whether a `Detected` capture said anything after the wake word.
    ///
    /// Decided from ACOUSTICS, never from the transcript. That is the whole point: ASR renders the
    /// wake phrase however it likes (`Oace.`, `oris`, `hey aris`), so a spelling match can never
    /// decide this, and no tolerance list is needed or guessed at.
    enum WakeOnlyDecision: Equatable {
        /// Nothing was said after the wake word: drop silently, no routing, no earcon.
        case wakeOnly
        /// Something may follow the wake word: route it and let the router decide.
        case route
    }

    /// Decides a `Detected` capture from the audio alone, when the backend supplies no timed
    /// tokens (recognition-pipeline.md, "Wake-positive time band trim").
    ///
    /// The boundary is `completionMs - marginMs`, NOT the completion band's end. The winning
    /// classifier window's endpoint sits 280-520 ms past the end of the wake word, so the band
    /// covers a short command attached without a pause, and using it here would silently swallow
    /// a fast "Auris stop". The margin is measured on validation data for exactly that separation.
    ///
    /// Fails SAFE — towards `.route` — in every case where the rule has no evidence or is switched
    /// off. A wrong `.route` costs at most one dispatch; a wrong `.wakeOnly` silently discards a
    /// question the user actually asked.
    static func wakeOnlyDecision(
        wakePositive: Bool,
        completionSample: Int,
        /// The sample index of the first frame of the silence run that closed the segment, in the
        /// original VAD segment. `nil` when the capture ended on speech, so nothing is known.
        speechEndSample: Int?,
        sampleRateHz: Int,
        /// From `wake_only_margin_ms`. Absent or negative disables the rule.
        marginMs: Int?
    ) -> WakeOnlyDecision {
        // `NotDetected` (including grace) is not gated by a wake result at all.
        guard wakePositive else { return .route }
        // The margin ships with the wake model. Until a model publishes a usable one there is no
        // measured boundary to apply, so the rule is off and routing is unchanged.
        guard let marginMs, marginMs >= 0 else { return .route }
        // Ended on speech: the segment never closed on silence, so there is no speech end to weigh.
        guard let speechEndSample else { return .route }
        let completionMs = ms(ofSample: completionSample, sampleRateHz: sampleRateHz)
        let speechEndMs = ms(ofSample: speechEndSample, sampleRateHz: sampleRateHz)
        // `<=`, not `<`: speech that stops exactly at the boundary left nothing after the wake word.
        return speechEndMs <= completionMs - marginMs ? .wakeOnly : .route
    }

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
