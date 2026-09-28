import XCTest
@testable import podcasts

/// The exclusion decides whether a bare wake spends the window's only dispatch, so
/// it is tested on both sides of the equality boundary rather than only where it
/// matches.
final class WakeWordPhraseSetTests: XCTestCase {
    /// The owner's exact case: `hey aris` was transcribed, classified `no_match`
    /// and dispatched to the service, which then consumed the window's allowance.
    /// The textual half is deliberately conservative: punctuation and casing are
    /// normalised, but renderings ASR invents are not enumerated — `WakeTranscriptTrimmer`
    /// decides those from the detector's timing instead, because no spelling
    /// tolerance separates `Oace.` from a short real word.
    func test_textRule_isConservative() {
        XCTAssertTrue(WakeWordPhraseSet.isWakeOnly("Hey Auris!"))
        XCTAssertTrue(WakeWordPhraseSet.isWakeOnly("auris"))
        XCTAssertFalse(WakeWordPhraseSet.isWakeOnly("hey aris。"), "a phonetic rendering is the timing rule's job")
    }

    /// `ok` is a prefix of `okay`, so a prefix match would remove the wrong number
    /// of characters and fail the case it exists for.
    func test_overlappingLeadingWords_areComparedAsWholeVariants() {
        XCTAssertTrue(WakeWordPhraseSet.isWakeOnly("okay auris"))
        XCTAssertTrue(WakeWordPhraseSet.isWakeOnly("ok auris"))
        XCTAssertFalse(WakeWordPhraseSet.isWakeOnly("okay auris, what did the guests say"))
    }

    /// The boundary: anything surviving the wake phrase follows the ordinary rules
    /// and escalates. Equality, not `starts-with`.
    func test_wakePhrasePlusAQuestion_isNotWakeOnly() {
        XCTAssertFalse(WakeWordPhraseSet.isWakeOnly("hey auris play the next episode"))
        XCTAssertFalse(WakeWordPhraseSet.isWakeOnly("what did the guests say about sleep"))
        XCTAssertFalse(WakeWordPhraseSet.isWakeOnly(""))
    }

    func test_theDecisionBoundary_beforeClassification() {
        XCTAssertEqual(RouteInputEligibilityPolicy.decide(transcript: "auris"), .silentSessionStart)
        XCTAssertEqual(RouteInputEligibilityPolicy.decide(transcript: "Hey Auris!"), .silentSessionStart)
        // A wake plus a question keeps the ordinary rule: it routes, and then the
        // reason decides (`no_match` escalates).
        XCTAssertEqual(RouteInputEligibilityPolicy.decide(transcript: "hey auris, recommend something"), .route)
        XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: RouterStageDiagnostic.reasonNoMatch), .escalate)
    }

    /// Review finding: a blank capture did not match the wake-only rule, so it
    /// reached `.none`, incremented the null counter, and the third one played the
    /// error earcon — against the silent rule. Repeats must all decide the same
    /// way, which is what keeps them out of the debounce.
    func test_blankCapturesAreSilentEveryTime() {
        XCTAssertEqual(RouteInputEligibilityPolicy.decide(transcript: ""), .blank)
        XCTAssertEqual(RouteInputEligibilityPolicy.decide(transcript: "   "), .blank)
        let decisions = (1...3).map { _ in RouteInputEligibilityPolicy.decide(transcript: "") }
        XCTAssertEqual(decisions, [.blank, .blank, .blank], "repeats stay silent and never reach the counter")
    }

    /// The phrase source is one place, so detection and exclusion cannot disagree.
    func test_variantsAreBuiltFromTheConfiguredPhraseSet() {
        let expected = ["auris"].flatMap { phrase -> [String] in
            ["", "hey", "hi", "ok", "okay"].map { $0 + phrase }
        }
        XCTAssertEqual(WakeWordPhraseSet.wakeOnlyVariants, Set(expected))
    }
}
