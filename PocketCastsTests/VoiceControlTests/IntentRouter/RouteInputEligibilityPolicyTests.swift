import XCTest
@testable import podcasts

/// The acoustic verdict must be able to close a turn on its own.
///
/// The text rule cannot: ASR renders the wake phrase freely ("Oace.", "oris", "hey aris"), so a
/// wake-only capture whose text is not one of the listed spellings reached classification and
/// spent the window's dispatch on nothing. These pin the seam that beats that.
final class RouteInputEligibilityPolicyTests: XCTestCase {
    func test_anAcousticWakeOnlyClosesTheTurnWhateverTheTranscriptSays() {
        // The whole point: a rendering no spelling list contains.
        XCTAssertEqual(
            RouteInputEligibilityPolicy.decide(transcript: "Oace.", acousticWakeOnly: true),
            .silentSessionStart)
        XCTAssertEqual(
            RouteInputEligibilityPolicy.decide(transcript: "oris", acousticWakeOnly: true),
            .silentSessionStart)
        // Even an empty transcript: the audio says the capture ended at the wake word, so this is a
        // session start, not "nothing survived capture".
        XCTAssertEqual(
            RouteInputEligibilityPolicy.decide(transcript: "", acousticWakeOnly: true),
            .silentSessionStart,
            "a wake-only capture must not be counted as blank")
    }

    /// The margin's absence is not evidence of a bare wake: routing stays exactly as it was.
    func test_withoutAnAcousticVerdictOnlyTheTextRuleApplies() {
        XCTAssertEqual(
            RouteInputEligibilityPolicy.decide(transcript: "Oace.", acousticWakeOnly: nil),
            .route,
            "no audio decision, and the spelling is not listed: route rather than guess")
        XCTAssertEqual(
            RouteInputEligibilityPolicy.decide(transcript: "auris", acousticWakeOnly: nil),
            .silentSessionStart,
            "the text rule still holds when no audio verdict exists")
        XCTAssertEqual(
            RouteInputEligibilityPolicy.decide(transcript: "   ", acousticWakeOnly: nil),
            .blank)
    }

    /// `false` is not a veto. The engine says only "the audio could not prove a bare wake", which
    /// is what it says about a loud room; it must not resurrect a turn the text rule already knows
    /// is silent, and it must not add anything of its own.
    func test_anInconclusiveVerdictNeitherVetoesNorOverrulesTheTextRule() {
        XCTAssertEqual(
            RouteInputEligibilityPolicy.decide(transcript: "auris", acousticWakeOnly: false),
            .silentSessionStart,
            "the text rule still closes a listed spelling")
        XCTAssertEqual(
            RouteInputEligibilityPolicy.decide(transcript: "play the news", acousticWakeOnly: false),
            .route)
    }

    /// The verdict must travel with the input, so every gate that asks the question gets the same
    /// answer — including the eager barge-in gate, which runs while an answer is still playing.
    ///
    /// The bug this pins: eligibility was re-decided from `routerTranscript` alone at that gate, so
    /// a misspelled bare wake stopped playback and was then submitted as a command, and the
    /// retained follow-up rebuilt its input without the verdict. Deciding from the input makes a
    /// gate that forgets a field impossible to write — there is nothing to forget.
    func test_eligibilityIsDecidedFromTheWholeInput() {
        let wakeOnly = IntentRoutingInput(
            sourceTranscript: "oris",
            sourceLanguage: "en",
            routerTranscript: "oris",
            translationKind: .none,
            selection: nil,
            utteranceId: "u-barge",
            acousticWakeOnly: true
        )
        XCTAssertEqual(
            RouteInputEligibilityPolicy.decide(wakeOnly),
            .silentSessionStart,
            "a bare wake over an answer must not barge in, whatever ASR called it")

        let command = IntentRoutingInput(
            sourceTranscript: "oris stop",
            sourceLanguage: "en",
            routerTranscript: "oris stop",
            translationKind: .none,
            selection: nil,
            utteranceId: "u-command",
            acousticWakeOnly: false
        )
        XCTAssertEqual(
            RouteInputEligibilityPolicy.decide(command),
            .route,
            "a measured continuation still routes and may interrupt")
    }
}
