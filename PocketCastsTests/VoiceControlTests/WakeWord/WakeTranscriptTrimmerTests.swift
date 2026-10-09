import XCTest
@testable import podcasts

final class WakeTranscriptTrimmerTests: XCTestCase {
    /// The index of the last frame at or above the wired speech level, which is
    /// what the segmenter reports for a capture — the trimmer no longer derives
    /// it, because a sub-threshold command sits *after* the last loud frame and
    /// an energy test would place the end at the wake.
    private func producerSpeechEnd(of samples: [Float], level: Float = 0.020) -> Int {
        var last = -1
        for (index, value) in samples.enumerated() where value >= level { last = index }
        return last
    }

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
    /// Without timed tokens the transcript is left **unchanged**.
    ///
    /// The spec is explicit (recognition-pipeline.md, "Wake-positive time band
    /// trim"): with no token timings, keep the transcript and let the router
    /// handle the unstripped wake phrase. The classifier's completion window is
    /// not a word-boundary estimator, so a capture ending near it does not prove
    /// the transcript holds only the wake — a quietly spoken command sits inside
    /// exactly that window, and discarding on the band would drop it.
    func test_noTokens_leavesTranscriptUnchanged() {
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "Oace.", detectedLanguage: "en"),
                wakePositive: true,
                completionSample: 4000,
                sampleRateHz: 16000,
                utteranceDurationMs: 300
            ),
            "Oace.",
            "no timings: the router handles the unstripped wake phrase"
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
    /// A quietly spoken command survives: it is in the transcript, so it routes.
    ///
    /// This is the case the band rule got wrong. The word is below the
    /// segmenter's level, so a capture ending near the classifier's window was
    /// read as a bare wake and the transcript — which ASR had already produced —
    /// was discarded: no answer, no earcon, no escalation, allowance unspent.
    /// The spec bounds a bare wake by the *permitted trim* (timed tokens plus the
    /// 120 ms pad), not by acoustics, so nothing here discards it.
    func test_quietCommand_isNotDiscarded() {
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "hey aris skip", detectedLanguage: "en"),
                wakePositive: true,
                completionSample: 250 * 16,
                sampleRateHz: 16000,
                utteranceDurationMs: 299
            ),
            "hey aris skip",
            "a transcribed command is not discarded on an acoustic guess"
        )
    }

    /// Timed tokens are trimmed by the **time band**: tokens overlapping the
    /// detector's completion plus 120 ms are the wake and go; the rest stays.
    /// This is the only trimming the spec permits, and it needs real timings.
    func test_timedTokens_trimInsideTheBandOnly() {
        let tokens = [
            AsrToken(text: "Oace", startMs: 40, endMs: 200),
            AsrToken(text: " skip", startMs: 520, endMs: 700),
        ]
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "Oace skip", detectedLanguage: "en", tokens: tokens),
                wakePositive: true,
                completionSample: 250 * 16,      // 250 ms; band ends at 370 ms
                sampleRateHz: 16000,
                utteranceDurationMs: 700
            ),
            "skip",
            "the wake token is inside the band; the command token survives"
        )
    }

    /// Every token inside the band leaves no text, and the spec says skip routing
    /// silently in that case — it does not say play an error.
    func test_allTimedTokensInsideTheBand_leaveNoText() {
        let tokens = [AsrToken(text: "Oace", startMs: 40, endMs: 200)]
        XCTAssertEqual(
            WakeTranscriptTrimmer.commandText(
                result: AsrResult(text: "Oace", detectedLanguage: "en", tokens: tokens),
                wakePositive: true,
                completionSample: 250 * 16,
                sampleRateHz: 16000,
                utteranceDurationMs: 200
            ),
            "",
            "nothing survives the permitted trim, so nothing is routed"
        )
    }
}
