import XCTest
@testable import podcasts

/// The exclusion decides whether a bare wake spends the window's only dispatch, so
/// it is tested on both sides of the equality boundary rather than only where it
/// matches.
final class WakeWordPhraseSetTests: XCTestCase {
    /// The owner's exact case: `hey aris` was transcribed, classified `no_match`
    /// and dispatched to the service, which then consumed the window's allowance.
    func test_ownerCase_wakeWithTrailingPunctuation_isWakeOnly() {
        XCTAssertTrue(WakeWordPhraseSet.isWakeOnly("hey aris。"))
        XCTAssertTrue(WakeWordPhraseSet.isWakeOnly("Hey Auris!"))
        XCTAssertTrue(WakeWordPhraseSet.isWakeOnly("auris"))
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

    func test_aWakeOnlyTranscriptIsADeliberateLocalRejection() {
        XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: RouterStageDiagnostic.reasonNoMatch, transcript: "hey aris。"), .stayLocal)
        XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: nil, transcript: "auris"), .stayLocal)
        // And a wake plus a question keeps the ordinary rule, which for `no_match`
        // is escalation.
        XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: RouterStageDiagnostic.reasonNoMatch, transcript: "hey auris, recommend something"), .escalate)
    }

    /// The phrase source is one place, so detection and exclusion cannot disagree.
    func test_variantsAreBuiltFromTheConfiguredPhraseSet() {
        let expected = ["auris", "aris"].flatMap { phrase -> [String] in
            ["", "hey", "hi", "ok", "okay"].map { $0 + phrase }
        }
        XCTAssertEqual(WakeWordPhraseSet.wakeOnlyVariants, Set(expected))
    }
}
