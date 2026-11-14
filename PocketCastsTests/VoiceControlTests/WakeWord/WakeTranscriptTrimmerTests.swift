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

    // MARK: - the audio wake-only rule (when timed tokens are absent)

    /// Decides one capture through the rule, in the spec's own terms: a completion offset, a
    /// margin, and where the segment's speech actually ended.
    private func audioRule(
        completionSample: Int,
        marginMs: Int?,
        speechEndMs: Int?,
        transcript: String = "oris",
        wakePositive: Bool = true
    ) -> WakeTranscriptTrimmer.WakeOnlyDecision {
        WakeTranscriptTrimmer.wakeOnlyDecision(
            wakePositive: wakePositive,
            completionSample: completionSample,
            speechEndSample: speechEndMs.map { $0 * 16 },   // 16 kHz, so ms * 16 = samples
            sampleRateHz: 16_000,
            marginMs: marginMs
        )
    }

    /// A capture of the wake word ALONE is wake-only when its speech ends at or before
    /// `completionMs - wakeOnlyMarginMs`, whatever ASR spelled it.
    ///
    /// This is the rule that decides `'oris'`: it reads the acoustics, not the spelling, so a
    /// mispronounced or mis-transcribed wake is recognised as a wake and dropped silently instead
    /// of being escalated to the cloud as a question.
    func test_audioRule_aWakeAloneIsWakeOnly() {
        // 250 ms completion, 80 ms margin => boundary at 170 ms.
        XCTAssertEqual(
            audioRule(completionSample: 4_000, marginMs: 80, speechEndMs: 170),
            .wakeOnly,
            "speech that stops exactly at the boundary leaves nothing after the wake word")
        XCTAssertEqual(
            audioRule(completionSample: 4_000, marginMs: 80, speechEndMs: 120),
            .wakeOnly,
            "speech ending well before the boundary is the wake word and nothing else")
    }

    /// A mis-SPELLED rendering is still wake-only: the rule never looks at the text, so no
    /// spelling tolerance is needed and none is guessed.
    func test_audioRule_aMisspelledRenderingIsStillWakeOnly() {
        for spelling in ["oris", "Oace.", "aris", "auris"] {
            XCTAssertEqual(
                audioRule(completionSample: 4_000, marginMs: 80, speechEndMs: 150, transcript: spelling),
                .wakeOnly,
                "'\(spelling)' is decided by when the speech ended, not how it was spelled")
        }
    }

    /// A short command attached WITHOUT a pause still routes: its speech runs past the boundary.
    ///
    /// This is why the rule uses its own measured margin rather than the completion band: the
    /// band's end sits 280-520 ms after the wake word, so a fast "Auris stop" would be swallowed.
    func test_audioRule_aShortCommandWithoutAPauseStillRoutes() {
        XCTAssertEqual(
            audioRule(completionSample: 4_000, marginMs: 80, speechEndMs: 420, transcript: "auris stop"),
            .continuation,
            "speech continuing past the boundary is MEASURED evidence of a continuation")
        XCTAssertEqual(
            audioRule(completionSample: 4_000, marginMs: 80, speechEndMs: 171, transcript: "auris stop"),
            .continuation,
            "one millisecond past the boundary is still past it")
    }

    /// No usable margin means the rule is OFF, so routing is exactly as it is today.
    ///
    /// The margin ships with the wake model; until a model publishes one there is no measured
    /// boundary to apply, and guessing one would silently swallow real commands.
    func test_audioRule_withoutAMarginTheRuleIsOff() {
        for margin in [nil, -5] {
            XCTAssertEqual(
                audioRule(completionSample: 4_000, marginMs: margin, speechEndMs: 100),
                .noEvidence,
                "a missing or negative margin (\(String(describing: margin))) disables the rule")
        }
    }

    /// A zero margin is VALID, not absent: the boundary is the completion offset itself.
    func test_audioRule_aZeroMarginIsAValidBoundary() {
        XCTAssertEqual(
            audioRule(completionSample: 4_000, marginMs: 0, speechEndMs: 250),
            .wakeOnly,
            "with no margin the boundary is the completion offset, and speech ends exactly there")
        XCTAssertEqual(
            audioRule(completionSample: 4_000, marginMs: 0, speechEndMs: 251),
            .continuation)
    }

    /// `NotDetected` never applies the audio rule, even when the acoustics look wake-only.
    func test_audioRule_neverAppliesWithoutAPositiveWake() {
        XCTAssertEqual(
            audioRule(completionSample: 4_000, marginMs: 80, speechEndMs: 100, wakePositive: false),
            .noEvidence,
            "a grace-period capture is not gated by a wake result at all")
    }

    /// An unknown speech end cannot decide anything, so the capture routes.
    ///
    /// Routing is the safe direction: it costs at most one dispatch, while a wrong wake-only
    /// decision silently discards a question the user actually asked.
    func test_audioRule_anUnknownSpeechEndRoutes() {
        XCTAssertEqual(
            audioRule(completionSample: 4_000, marginMs: 80, speechEndMs: nil),
            .noEvidence,
            "without a speech-end offset the rule has no evidence and must not drop the capture")
    }

    /// "The rule did not run" must never reach a consumer as "the audio proved a continuation".
    ///
    /// Both route, so the routing outcome cannot tell them apart — but a downstream gate that
    /// treats `false` as evidence would interpret a loud room as a measured command. Only
    /// `.continuation` is a measurement; every no-evidence case maps to `nil`.
    func test_audioRule_noEvidenceIsNeverReportedAsAMeasuredContinuation() {
        XCTAssertNil(WakeTranscriptTrimmer.WakeOnlyDecision.noEvidence.acousticVerdict)
        XCTAssertEqual(WakeTranscriptTrimmer.WakeOnlyDecision.wakeOnly.acousticVerdict, true)
        XCTAssertEqual(WakeTranscriptTrimmer.WakeOnlyDecision.continuation.acousticVerdict, false)

        XCTAssertNil(
            audioRule(completionSample: 4_000, marginMs: nil, speechEndMs: 100).acousticVerdict,
            "no margin is no evidence, not a measured continuation")
        XCTAssertNil(
            audioRule(completionSample: 4_000, marginMs: 80, speechEndMs: nil).acousticVerdict,
            "an unknown speech end is no evidence")
        XCTAssertNil(
            audioRule(completionSample: 4_000, marginMs: 80, speechEndMs: 100, wakePositive: false).acousticVerdict,
            "a capture with no wake gate is no evidence")
        XCTAssertEqual(
            audioRule(completionSample: 4_000, marginMs: 80, speechEndMs: 420).acousticVerdict,
            false,
            "a measured continuation IS false, and only this case may report it")
    }
}
