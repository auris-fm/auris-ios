import XCTest
@testable import podcasts

final class WakeTranscriptTrimmerTests: XCTestCase {
    private let skipForward = AsrResult(
        text: "Auris skip forward",
        detectedLanguage: "en",
        tokens: [
            AsrToken(text: "Auris", startMs: 0, endMs: 300),
            AsrToken(text: " skip", startMs: 500, endMs: 800),
            AsrToken(text: " forward", startMs: 800, endMs: 1200),
        ]
    )

    func test_wakePositive_dropsOverlappingTokens() {
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: skipForward,
                wakePositive: true,
                completionSample: 4000,
                sampleRateHz: 16000,
                utteranceDurationMs: 2000
            ),
            "skip forward"
        )
    }

    /// The observed case: ASR heard the wake as `Oace.` and gave no tokens. It is
    /// wake-only because the capture ends inside the band, not because the text
    /// resembles the wake word.
    func test_noTokens_captureEndingInWakeBand_isWakeOnlyWhateverASRWrote() {
        let oace = AsrResult(text: "Oace.", detectedLanguage: "en")
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: oace,
                wakePositive: true,
                completionSample: 4000,      // 250 ms at 16 kHz
                sampleRateHz: 16000,
                utteranceDurationMs: 300     // ends inside the band (250 + 120 pad)
            ),
            "",
            "a capture that ends in the wake band carries no command"
        )
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: oace,
                wakePositive: true,
                completionSample: 4000,
                sampleRateHz: 16000,
                utteranceDurationMs: 1800    // the user kept talking
            ),
            "Oace.",
            "the same text inside a longer capture is a real utterance"
        )
    }

    func test_wakeNegative_leavesTranscript() {
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: skipForward,
                wakePositive: false,
                completionSample: 4000,
                sampleRateHz: 16000,
                utteranceDurationMs: 2000
            ),
            "Auris skip forward"
        )
    }

    func test_missingTokens_leaveUnstripped() {
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "Auris skip forward", detectedLanguage: "en"),
                wakePositive: true,
                completionSample: 4000,
                sampleRateHz: 16000,
                utteranceDurationMs: 2000
            ),
            "Auris skip forward"
        )
    }

    func test_allOverlappingTokens_areWakeOnly() {
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(
                    text: "Auris",
                    detectedLanguage: "en",
                    tokens: [AsrToken(text: "Auris", startMs: 0, endMs: 400)]
                ),
                wakePositive: true,
                completionSample: 4000,
                sampleRateHz: 16000,
                utteranceDurationMs: 2000
            ),
            ""
        )
    }

    func test_zeroGapCommandWordStartingInsidePad_isDropped() {
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(
                    text: "Auris skip forward",
                    detectedLanguage: "en",
                    tokens: [
                        AsrToken(text: "Auris", startMs: 0, endMs: 250),
                        AsrToken(text: " skip", startMs: 300, endMs: 500),
                        AsrToken(text: " forward", startMs: 500, endMs: 900),
                    ]
                ),
                wakePositive: true,
                completionSample: 4000,
                sampleRateHz: 16000,
                utteranceDurationMs: 2000
            ),
            "forward"
        )
    }

    // MARK: - Real-capture timing (the segmenter's trailing silence)

    /// A real wake-only capture always carries the segmenter's trailing silence
    /// (`NativeVadSegmenter` emits only after `silenceTimeoutMs = 500`), so the
    /// capture's total duration is ~500 ms longer than the wake's end. The band
    /// test must therefore be made against the last speech, not the buffer end:
    /// with the buffer end, a real wake-only capture can never be inside a
    /// 120 ms pad and the `Oace.` bug survives on device.
    func test_realCapture_wakeThenSilence_isWakeOnly() {
        // 300 ms of speech (the wake), then 500 ms of silence appended by the
        // segmenter: 800 ms total, last speech at 300 ms, wake completion 250 ms.
        var samples = [Float](repeating: 0.05, count: 300 * 16)
        samples += [Float](repeating: 0.0001, count: 500 * 16)
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "Oace.", detectedLanguage: "en"),
                wakePositive: true,
                completionSample: 4000,          // 250 ms
                sampleRateHz: 16000,
                samples: samples,
                speechLevel: 0.020,
            ),
            "",
            "a wake followed only by silence is wake-only, however long the trailing silence"
        )
    }

    /// The same capture with real words after the wake is not wake-only.
    func test_realCapture_wakeThenCommand_isNotWakeOnly() {
        var samples = [Float](repeating: 0.05, count: 300 * 16)
        samples += [Float](repeating: 0.0001, count: 200 * 16)
        samples += [Float](repeating: 0.05, count: 400 * 16)   // "skip"
        samples += [Float](repeating: 0.0001, count: 500 * 16)
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "Oace. skip", detectedLanguage: "en"),
                wakePositive: true,
                completionSample: 4000,
                sampleRateHz: 16000,
                samples: samples,
                speechLevel: 0.020,
            ),
            "Oace. skip",
            "speech after the wake band is a command"
        )
    }

    /// Without samples the previous behaviour is kept.
    func test_noSamples_usesTotalDuration() {
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "Oace.", detectedLanguage: "en"),
                wakePositive: true,
                completionSample: 4000,
                sampleRateHz: 16000,
                utteranceDurationMs: 300
            ),
            ""
        )
    }

    /// The negative half of the wake-only rule, asserted where it is observable:
    /// a wake-only capture carries no command and must not be treated as one.
    func test_wakeOnlyCapture_producesNoCommandText() {
        var samples = [Float](repeating: 0.05, count: 250 * 16)   // the wake itself
        samples += [Float](repeating: 0.0001, count: 500 * 16)    // segmenter trailing silence
        let text = WakeTranscriptTrimmer.commandText(
            result: AsrResult(text: "Oace.", detectedLanguage: "en"),
            wakePositive: true,
            completionSample: 3840,      // 240 ms — the wake's end
            sampleRateHz: 16000,
            samples: samples,
            speechLevel: 0.020,
        )
        XCTAssertEqual(text, "", "wake-only is silence, not a command")
    }

    /// Silence before the wake is not speech after it: leading quiet frames must
    /// not be mistaken for the user continuing.
    func test_leadingSilence_doesNotExtendSpeechEnd() {
        var samples = [Float](repeating: 0.0001, count: 200 * 16)
        samples += [Float](repeating: 0.05, count: 200 * 16)
        samples += [Float](repeating: 0.0001, count: 400 * 16)
        XCTAssertEqual(
            WakeTranscriptTrimmer.lastSpeechSample(samples: samples, sampleRateHz: 16000, threshold: 0.020),
            200 * 16 + 200 * 16 - 1
        )
    }

    // MARK: - the trimmer's notion of speech matches the segmenter's

    /// A command quieter than the wake is still a command — *when the producer
    /// counted it as speech*.
    ///
    /// The level is the segmenter's own (the app wires 0.020). What matters is
    /// that the trimmer and the producer agree: a frame the segmenter treated as
    /// speech must be speech here, or a real command is trimmed away as silence.
    /// A frame the segmenter did *not* treat as speech never reaches this code at
    /// all — the segmenter emits a buffer only once it holds speech — so the
    /// trimmer cannot resurrect it, and must not try.
    func test_quieterCommand_theProducerCalledSpeech_isStillACommand() {
        var samples = [Float](repeating: 0.05, count: 300 * 16)    // the wake
        samples += [Float](repeating: 0.0001, count: 200 * 16)
        samples += [Float](repeating: 0.025, count: 400 * 16)      // "skip", below the wake, above 0.020
        samples += [Float](repeating: 0.0001, count: 500 * 16)     // segmenter trailing silence

        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "auris skip", detectedLanguage: "en"),
                wakePositive: true,
                completionSample: 250 * 16,
                sampleRateHz: 16000,
                samples: samples,
                speechLevel: 0.020
            ),
            "auris skip",
            "a frame the producer counted as speech is a command here"
        )
    }

    /// A wake spoken *quietly* is still a bare wake, not a question.
    ///
    /// If nothing in the capture reaches speech level, the wake is the only thing
    /// that was said. Reading "no speech found" as "cannot tell" escalates and
    /// spends the window's one dispatch on an utterance that carried no request —
    /// the exact case this trimmer exists to catch.
    func test_quietWakeOnlyCapture_isWakeOnlyNotAnEscalation() {
        let samples = [Float](repeating: 0.0005, count: 250 * 16)  // a soft "auris"
            + [Float](repeating: 0.0001, count: 500 * 16)

        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "auris", detectedLanguage: "en", tokens: nil),
                wakePositive: true,
                completionSample: 250 * 16,
                sampleRateHz: 16000,
                samples: samples,
                speechLevel: 0.020,
            ),
            "",
            "nothing in the capture was speech, so nothing was asked"
        )
    }

    /// A bare wake in a room with audible ambience is still a bare wake.
    ///
    /// The segmenter appends its 500 ms hangover by construction, so every frame
    /// it appends sits *below its own threshold* — but room ambience is far above
    /// -80 dBFS. If the trimmer reasons at a level below the producer's, that
    /// hangover reads as speech, `speechEnd` moves to the buffer end, the band
    /// test fails, and the raw rendering of the wake is kept: a phonetic `Oace.`
    /// then reaches `no_match` and escalates, spending the window's single
    /// dispatch on nothing. (Level here is the wired one, 0.020.)
    func test_quietRoomAmbienceInTheHangover_isStillAWakeOnlyCapture() {
        let ambience: Float = 0.006   // ordinary room noise, ~-44 dBFS
        var samples = [Float](repeating: 0.05, count: 250 * 16)    // the wake itself
        samples += [Float](repeating: ambience, count: 500 * 16)   // segmenter hangover

        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "Oace.", detectedLanguage: "en"),
                wakePositive: true,
                completionSample: 250 * 16,
                sampleRateHz: 16000,
                samples: samples,
                speechLevel: 0.020
            ),
            "",
            "ambience below the producer's speech level is not a command"
        )
    }

    /// A soft word after the wake is a command, not silence.
    ///
    /// The producer's threshold decides when an utterance *starts and ends*; once
    /// it is active the segmenter appends every frame regardless of level
    /// (`NativeVadSegmenter.process`), so a quietly spoken command is in the buffer
    /// and ASR transcribed it. Reading "no frame above the level after the wake" as
    /// "the user said nothing" therefore throws away a transcript the pipeline
    /// already has: no answer, no earcon, and no escalation — the allowance is not
    /// even spent, because the turn never routes.
    func test_softWordAfterTheWake_isACommandNotSilence() {
        var samples = [Float](repeating: 0.05, count: 300 * 16)    // the wake
        samples += [Float](repeating: 0.006, count: 400 * 16)      // "skip", spoken softly
        samples += [Float](repeating: 0.0001, count: 500 * 16)     // segmenter trailing silence

        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "hey aris skip", detectedLanguage: "en"),
                wakePositive: true,
                completionSample: 250 * 16,
                sampleRateHz: 16000,
                samples: samples,
                speechLevel: 0.020
            ),
            "hey aris skip",
            "a transcribed word is a command however quietly it was spoken"
        )
    }
}
