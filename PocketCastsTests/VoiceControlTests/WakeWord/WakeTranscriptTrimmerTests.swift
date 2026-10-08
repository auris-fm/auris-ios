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
                samples: samples
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
                samples: samples
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
            samples: samples
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
            WakeTranscriptTrimmer.lastSpeechSample(samples: samples, sampleRateHz: 16000),
            200 * 16 + 200 * 16 - 1
        )
    }
}
