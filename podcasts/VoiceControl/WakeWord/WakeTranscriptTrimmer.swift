import Foundation

enum WakeTranscriptTrimmer {
    static let padMs = 120

    static func ms(ofSample sample: Int, sampleRateHz: Int) -> Int {
        let rate = max(sampleRateHz, 1)
        return Int((Int64(sample) * 1000) / Int64(rate))
    }


    /// `commandText` for a real capture.
    ///
    /// The buffer is not consulted: without per-token timestamps the transcript is
    /// left unchanged (see below), and with them the trim is a *time* band, which
    /// needs no audio. The parameter is kept so the call site does not have to
    /// know which backend produced the result.
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
