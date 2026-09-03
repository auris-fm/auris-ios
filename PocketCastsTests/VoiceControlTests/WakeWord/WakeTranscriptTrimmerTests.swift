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
}
