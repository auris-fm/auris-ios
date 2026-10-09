import Foundation

enum WakeTranscriptTrimmer {
    static let padMs = 120

    static func ms(ofSample sample: Int, sampleRateHz: Int) -> Int {
        let rate = max(sampleRateHz, 1)
        return Int((Int64(sample) * 1000) / Int64(rate))
    }


    /// `commandText` for a real capture.
    ///
    /// The buffer supplies only the capture's length, which clamps the band to the
    /// utterance: a band end past the end of what the user actually said would
    /// otherwise be compared against token times that cannot exist. The samples
    /// themselves are not inspected — no level, energy or boundary is derived from
    /// them, because the spec's trim is a token-time rule and the buffer cannot
    /// substitute for missing timings.
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
            utteranceDurationMs: ms(ofSample: samples.count - 1, sampleRateHz: sampleRateHz)
        )
    }

    static func commandText(
        result: AsrResult,
        wakePositive: Bool,
        completionSample: Int,
        sampleRateHz: Int,
        utteranceDurationMs: Int
    ) -> String {
        if !wakePositive { return result.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Without per-token timestamps the spec is explicit: **leave the
        // transcript unchanged** and let the router handle the unstripped wake
        // phrase (recognition-pipeline.md, "Wake-positive time band trim").
        //
        // A time-band rule cannot stand in for the missing tokens. The
        // classifier's completion window is not a word-boundary estimator — a
        // capture that ends near it does not prove its transcript contains only
        // the wake, and a quietly spoken command sits inside exactly that window.
        // Discarding on the band would therefore drop a command ASR already
        // transcribed, so it is not done here, and no acoustic rule is introduced
        // implicitly; that would need its own spec change and evidence.
        guard let tokens = result.tokens else {
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
