import Foundation

enum WakeTranscriptTrimmer {
    static let padMs = 120

    /// The level at which a frame counts as speech, when the caller does not
    /// supply the producing segmenter's own.
    ///
    /// Callers that have the segmenter must pass `segmenter.threshold`: a default
    /// is only right if the wiring uses it, and the app does not (it builds the
    /// segmenter with 0.020, ten times this). Sitting *below* the producer is as
    /// wrong as sitting above it — everything the segmenter appended as hangover
    /// is below its threshold by construction, so a lower trimmer level reads
    /// room ambience as speech, pushes `speechEnd` to the buffer end, and lets a
    /// bare wake escalate.
    static let speechThreshold = NativeVadSegmenter.defaultThreshold

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


    /// Sample index of the last frame whose energy is above `threshold`, i.e. the
    /// end of the speech in a capture. `-1` when the capture has no speech.
    ///
    /// The segmenter always appends trailing silence before emitting (it waits
    /// `silenceTimeoutMs`), so the buffer's end is *not* where the user stopped
    /// speaking. Timing the wake against the buffer end makes every real capture
    /// look long and the wake-only case unreachable.
    static func lastSpeechSample(
        samples: [Float],
        sampleRateHz: Int,
        frameMs: Int = 10,
        threshold: Float = speechThreshold
    ) -> Int {
        guard !samples.isEmpty, sampleRateHz > 0 else { return -1 }
        let frame = max(sampleRateHz * frameMs / 1000, 1)
        var last = -1
        var index = 0
        while index < samples.count {
            let end = min(index + frame, samples.count)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            let rms = (sum / Float(end - index)).squareRoot()
            if rms >= threshold { last = end - 1 }
            index = end
        }
        return last
    }

    static func ms(ofSample sample: Int, sampleRateHz: Int) -> Int {
        let rate = max(sampleRateHz, 1)
        return Int((Int64(sample) * 1000) / Int64(rate))
    }


    /// `commandText` for a real capture: the band test is made against the end of
    /// the *speech* in the capture, not the end of the buffer, because the
    /// segmenter's trailing silence is not something the user said.
    static func commandText(
        result: AsrResult,
        wakePositive: Bool,
        completionSample: Int,
        sampleRateHz: Int,
        samples: [Float],
        speechLevel: Float
    ) -> String {
        let speechEnd = lastSpeechSample(samples: samples, sampleRateHz: sampleRateHz, threshold: speechLevel)
        // Nothing in the capture reached speech level: the wake is the only thing
        // that was said, whatever ASR spelled it as. Deciding this before the band
        // test covers the capture whose speech sits below the segmenter's own
        // threshold — `lastSpeechSample` finds nothing there, and the band test
        // would otherwise answer "cannot tell" and escalate, spending the window's
        // one dispatch on an utterance that asked nothing.
        if wakePositive, speechEnd < 0 { return "" }
        return commandText(
            result: result,
            wakePositive: wakePositive,
            completionSample: completionSample,
            sampleRateHz: sampleRateHz,
            utteranceDurationMs: ms(ofSample: max(speechEnd, 0), sampleRateHz: sampleRateHz)
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
