import XCTest
@testable import podcasts

/// The trimmer keeps the transcript, matching Android.
final class WakeTranscriptTrimmerTests: XCTestCase {
    private func trim(
        _ text: String,
        wakePositive: Bool = true,
        tokens: [AsrToken]? = nil,
        completionSample: Int = 4000
    ) -> String {
        WakeTranscriptTrimmer.commandText(
            result: AsrResult(text: text, detectedLanguage: "en", tokens: tokens),
            wakePositive: wakePositive,
            completionSample: completionSample,
            sampleRateHz: 16000,
            utteranceDurationMs: 2000
        )
    }

    /// The property the sync is defined by: **no input loses text.**
    ///
    /// This is what makes "in sync with Android" checkable by reading one file —
    /// Android never strips the wake (`UtteranceFilter.kt` decides whether to
    /// process an utterance, not what the text says), so iOS must not either.
    func test_noInputIsDiscarded() {
        let wakeOnly = "Oace."
        let wakeThenCommand = "oris skip forward thirty seconds"
        let commandOnly = "skip forward"
        let phonetic = "hey aris, what did they say"

        for text in [wakeOnly, wakeThenCommand, commandOnly, phonetic] {
            XCTAssertEqual(
                trim(text), text,
                "'\(text)' must survive the trimmer — a client that discards text diverges from Android"
            )
        }
    }

    /// A bare wake keeps its text. It is bounded by the grace window's single
    /// dispatch, not by the trimmer guessing where the wake ended.
    func test_bareWakeKeepsItsText() {
        XCTAssertEqual(trim("Oace."), "Oace.")
    }

    /// The former timed-token branch was the only code that could delete text.
    /// Supplying timings that would have fallen inside the old band must change
    /// nothing: the tokens are not consulted at all.
    func test_timingsDoNotTrimAnything() {
        let inBand = [AsrToken(text: "Oace", startMs: 20, endMs: 240)]
        XCTAssertEqual(
            trim("Oace skip", tokens: inBand), "Oace skip",
            "timings inside the old band must not delete text either"
        )
    }

    /// Whitespace is normalised, which is the one transformation left. It is not
    /// a discard, and Android's router sees the same text shape.
    func test_whitespaceIsNormalised() {
        XCTAssertEqual(trim("  skip forward  "), "skip forward")
    }
}
