import XCTest
@testable import podcasts

/// The spec's wake-positive time-band trim, clause by clause.
///
/// recognition-pipeline.md, "Wake-positive time band trim": timed tokens present ⇒
/// drop tokens overlapping the completion band; tokens absent ⇒ leave the
/// transcript unchanged (the router is the backstop); `NotDetected` ⇒ never apply
/// the band. The pipeline never strips by spelling.
final class WakeTranscriptTrimmerTests: XCTestCase {
    private func trim(
        _ text: String,
        wakePositive: Bool = true,
        tokens: [AsrToken]? = nil,
        completionSample: Int = 4000,      // 250 ms
        utteranceDurationMs: Int = 2000
    ) -> String {
        WakeTranscriptTrimmer.commandText(
            result: AsrResult(text: text, detectedLanguage: "en", tokens: tokens),
            wakePositive: wakePositive,
            completionSample: completionSample,
            sampleRateHz: 16000,
            utteranceDurationMs: utteranceDurationMs
        )
    }

    // MARK: - tokens absent ⇒ unchanged

    /// The shipped case: SenseVoice omits tokens, so the transcript is untouched.
    func test_noTokens_leavesTheTranscriptUnchanged() {
        XCTAssertEqual(trim("Oace."), "Oace.")
        XCTAssertEqual(trim("oris skip forward thirty seconds"), "oris skip forward thirty seconds")
    }

    /// No spelling is guessed at: a phonetic wake is not stripped, because the
    /// spec says the router is the backstop for an unstripped rendering.
    func test_noTokens_doesNotStripAPhoneticWake() {
        XCTAssertEqual(trim("hey aris, what did they say"), "hey aris, what did they say")
    }

    // MARK: - tokens present ⇒ band trim

    func test_tokensInsideTheBand_areDropped() {
        let tokens = [
            AsrToken(text: "Oace", startMs: 20, endMs: 240),     // band ends at 370 ms
            AsrToken(text: " skip forward", startMs: 520, endMs: 900),
        ]
        XCTAssertEqual(trim("Oace skip forward", tokens: tokens), "skip forward")
    }

    /// Every token inside the band leaves nothing, and the engine treats that as
    /// wake-only — the spec's own consequence of the permitted trim.
    func test_allTokensInsideTheBand_leaveNoText() {
        let tokens = [AsrToken(text: "Oace", startMs: 20, endMs: 240)]
        XCTAssertEqual(trim("Oace", tokens: tokens), "")
    }

    /// A token straddling the band edge is dropped, matching the spec's
    /// `startMs < bandEndMs && endMs > 0`.
    func test_tokenStraddlingTheBandEnd_isDropped() {
        let tokens = [AsrToken(text: "Oace", startMs: 100, endMs: 500)]
        XCTAssertEqual(trim("Oace", tokens: tokens, utteranceDurationMs: 800), "")
    }

    /// The band is clamped to the utterance, and this case fails without the
    /// clamp: a token that starts *after* the capture's own length but *inside*
    /// the unclamped band must survive.
    ///
    /// The clamp only matters when the two differ, so the fixture makes them
    /// differ — `completionSample` puts the unclamped band end at 5120 ms while
    /// the utterance is 600 ms.
    func test_bandIsClampedToTheUtterance() {
        let tokens = [AsrToken(text: "wake", startMs: 10, endMs: 400),   // inside either band
                      AsrToken(text: " sk", startMs: 700, endMs: 900)]   // inside the unclamped band only
        XCTAssertEqual(
            trim("wake sk", tokens: tokens, completionSample: 16000 * 5, utteranceDurationMs: 600),
            "sk",
            "the clamp keeps a token that the unclamped band would have eaten"
        )
    }

    // MARK: - NotDetected

    func test_notDetected_neverAppliesTheBand_evenWithTokens() {
        let tokens = [AsrToken(text: "Oace", startMs: 20, endMs: 240)]
        XCTAssertEqual(trim("Oace", wakePositive: false, tokens: tokens), "Oace")
    }

    // MARK: - the property the merge bar rests on

    /// Whatever the input, the trimmer never invents or explains away text: an
    /// empty result arises only from the permitted trim of timed tokens.
    func test_onlyThePermittedTrimCanProduceEmpty() {
        XCTAssertEqual(trim("something"), "something", "no tokens ⇒ never empty")
        XCTAssertEqual(trim("something", wakePositive: false), "something", "not detected ⇒ never empty")
    }
}
