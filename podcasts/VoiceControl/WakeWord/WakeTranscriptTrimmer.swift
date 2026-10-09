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
    /// Whether the capture ended inside the wake band: the detector's own
    /// completion plus `padMs`, plus whatever trailing silence the *segmenter*
    /// added before emitting.
    ///
    /// The hangover is the producer's latency, not something the user said: the
    /// segmenter waits `silenceTimeoutMs` after the last speech before it emits,
    /// so every capture — bare wake or full command — carries it. Without this
    /// allowance the band can never fire against a buffer length (which is why
    /// comparing against an energy-derived "speech end" looked necessary), and
    /// with the allowance a bare wake is legible from the *timing* alone. That
    /// matters because the alternative — deciding from a level — cannot tell a
    /// softly spoken word from room noise, and would discard a transcript the
    /// pipeline already holds.
    static func endsWithinWakeBand(
        completionSample: Int,
        sampleRateHz: Int,
        utteranceDurationMs: Int,
        hangoverMs: Int = NativeVadSegmenter.defaultSilenceTimeoutMs
    ) -> Bool {
        guard utteranceDurationMs > 0 else { return false }
        let rate = max(sampleRateHz, 1)
        let completionMs = Int((Int64(completionSample) * 1000) / Int64(rate))
        return utteranceDurationMs <= completionMs + padMs + hangoverMs
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


    /// `commandText` for a real capture.
    ///
    /// The band test is made against the end of the **buffer**, not against an
    /// energy-derived "speech end". The producer's threshold decides where an
    /// utterance starts and stops; it is not a test of whether anything was said.
    /// Once the segmenter is active it appends every frame regardless of level
    /// (`NativeVadSegmenter.process`), so a quietly spoken command is in the
    /// buffer and ASR has already transcribed it. Reading "nothing above the level
    /// after the wake" as "the user said nothing" therefore discards a transcript
    /// the pipeline holds — no answer, no earcon, no escalation, and the window's
    /// allowance not even spent, because the turn never routes.
    ///
    /// What bounds a bare wake is that its capture *ends* at the wake: the
    /// segmenter emits on its own silence timeout, so a real command runs past the
    /// band however quietly it was spoken. `completionSample` already carries that
    /// budget (the detector's completion plus `padMs`), so the band is the honest
    /// test for it, and no energy level can substitute — a level cannot separate a
    /// soft word from room noise, which is the case it would have to decide.
    static func commandText(
        result: AsrResult,
        wakePositive: Bool,
        completionSample: Int,
        sampleRateHz: Int,
        samples: [Float],
        speechLevel: Float
    ) -> String {
        _ = samples
        _ = speechLevel
        // The capture's own length is the only duration the pipeline can trust:
        // the segmenter's hangover means the buffer always runs past the user's
        // last word, and no energy level separates a soft word from room noise.
        // A bare wake is therefore identified by the *detector*, not by level:
        // the engine's wake completion already bounds where the wake ended, and
        // the band is measured from there.
        return commandText(
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
