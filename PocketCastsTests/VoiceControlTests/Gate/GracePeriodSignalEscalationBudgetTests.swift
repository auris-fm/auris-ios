import XCTest
@testable import podcasts

/// OWNER DELTA 3484cbc/5eca874 (spec): there is NO separate grace-window dispatch budget.
/// Request ownership permits at most one logical dispatch PER UTTERANCE; each independent
/// utterance may dispatch its own request, including within the same grace window. These
/// controls assert the window signal no longer refuses a second, independent dispatch and
/// that only a closed/foreign window refuses.
final class GracePeriodSignalEscalationBudgetTests: XCTestCase {

    /// The delta's core: two independent utterances in ONE window each dispatch.
    @MainActor
    func testTwoUtterancesInOneWindowEachDispatch() async {
        let signal = GracePeriodSignal(timeout: 30)
        signal.onWakeWordDetected()
        let window = signal.currentGeneration()

        XCTAssertNotNil(
            signal.claimDispatchOwnership(capturedOrigin: window),
            "the first utterance in the window dispatches"
        )
        XCTAssertNotNil(
            signal.claimDispatchOwnership(capturedOrigin: window),
            "an INDEPENDENT second utterance in the same window must also dispatch (no window budget)"
        )
    }

    /// Refusal is by window identity, not by count: a turn whose captured origin is not the live
    /// window must be refused (that is request/window ownership, not a budget).
    @MainActor
    func testAForeignOriginIsRefusedRegardlessOfCount() async {
        let signal = GracePeriodSignal(timeout: 30)
        signal.onWakeWordDetected()
        let stale = signal.currentGeneration()
        signal.onWakeWordDetected() // a new window
        let live = signal.currentGeneration()

        XCTAssertNotNil(signal.claimDispatchOwnership(capturedOrigin: live), "the live window dispatches")
        XCTAssertNil(signal.claimDispatchOwnership(capturedOrigin: stale),
                     "a turn stamped under an ended window consumes nothing")
    }
    func testClosedWindowHasNoBudget() async {
        let signal = GracePeriodSignal(timeout: 5)
        XCTAssertNil(signal.claimDispatchOwnership(), "no user-initiated session ⇒ nothing escalates")
    }

    /// NO window budget (owner delta 3484cbc/5eca874): a run of independent utterances in one
    /// window each dispatch. Only the request-ownership layer prevents a duplicate wire request.
    func testManyIndependentUtterancesInOneWindowEachDispatch() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }

        for i in 1...3 {
            XCTAssertNotNil(signal.claimDispatchOwnership(), "utterance \(i) in the window dispatches")
        }
    }

    /// A fresh wake opens a new window, which still dispatches.
    func testAWakeKeepsTheWindowDispatching() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertNotNil(signal.claimDispatchOwnership())

        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertNotNil(signal.claimDispatchOwnership(), "a new window dispatches")
    }

    /// A fallback dispatch extends the window; dispatch availability does not depend on a budget,
    /// so an independent utterance still dispatches afterwards.
    func testFallbackExtensionStillAllowsAnIndependentDispatch() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        let generation = signal.claimDispatchOwnership()
        XCTAssertNotNil(generation)

        await MainActor.run { signal.extendWindowKeepingEscalationSpent(underGeneration: generation!) }

        XCTAssertTrue(signal.isActive, "the conversation window continues")
        XCTAssertNotNil(signal.claimDispatchOwnership(), "no window budget: an independent utterance still dispatches")
    }

    /// The case state alone cannot express, and the one where a wrong answer is
    /// invisible in the budget: a dispatch belonging to a window that has since
    /// ended must not **extend** whatever window is current. The old completion is
    /// applied at the moment the new window would otherwise expire, so a guard that
    /// only checked liveness would keep the session alive past its own timeout.
    func testAnEndedWindowsCompletionCannotExtendTheCurrentOne() async {
        let signal = GracePeriodSignal(timeout: 0.3)
        await MainActor.run { signal.onWakeWordDetected() }
        let oldGeneration = signal.claimDispatchOwnership()
        XCTAssertNotNil(oldGeneration)

        // The window ends for privacy reasons, then a new one opens.
        await MainActor.run { signal.onAppBackgrounded() }
        await MainActor.run { signal.onWakeWordDetected() }
        let newGeneration = signal.claimDispatchOwnership()
        XCTAssertNotNil(newGeneration)
        XCTAssertNotEqual(oldGeneration, newGeneration, "a fresh wake is a new generation")

        // The old request lands just before the new window would expire.
        try? await Task.sleep(nanoseconds: 200_000_000)
        await MainActor.run { signal.extendWindowKeepingEscalationSpent(underGeneration: oldGeneration!) }
        XCTAssertTrue(signal.isActive, "the old completion is dropped, so the window is still running")

        // It must expire on its own schedule rather than on the old dispatch's.
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(signal.isActive, "an ended window's completion must not extend the current one")
    }

    /// A recognised command is a new deliberate act; a following refusal in its window is new
    /// information and must be audible.
    func testARecognisedCommandMakesTheNextRefusalAudibleAgain() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertTrue(signal.claimRefusalTone(), "the first refusal speaks")

        await MainActor.run { signal.onCommandRecognized() }   // a new act

        XCTAssertTrue(signal.claimRefusalTone(), "a refusal in the new act is new information")
    }

    /// Privacy fail-closed: a closed window dispatches nothing until something opens it again.
    func testClosingTheWindowRefusesDispatch() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertNotNil(signal.claimDispatchOwnership())

        await MainActor.run { signal.onAppBackgrounded() }
        XCTAssertNil(signal.claimDispatchOwnership(), "a closed session dispatches nothing")

        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertNotNil(signal.claimDispatchOwnership(), "the next wake opens a fresh session")
    }

    /// A fallback completing must not release the refusal-tone claim.
    ///
    /// The fallback keeps the escalation spent (`extendWindowKeepingEscalationSpent`),
    /// so the allowance that produced the refusal is *still* spent when its own
    /// answer lands. If the reset clears the tone claim, the next refusal in the
    /// same window beeps again for that same spent allowance — two tones for one
    /// fact, which is what the claim exists to prevent.
    func testFallbackCompletionKeepsTheRefusalToneClaim() async {
        let signal = GracePeriodSignal(timeout: 30)
        await MainActor.run { signal.onWakeWordDetected() }

        // Spend the window's allowance, then announce its refusal: the tone claim
        // is now held for this generation.
        guard let generation = signal.claimDispatchOwnership() else {
            return XCTFail("the first failure in an open window escalates")
        }
        XCTAssertTrue(signal.claimRefusalTone(), "the refusal is announced once")
        XCTAssertFalse(signal.claimRefusalTone(), "and not twice in the same window")

        // The fallback's own answer lands: the window extends, the allowance stays spent.
        signal.extendWindowKeepingEscalationSpent(underGeneration: generation)

        XCTAssertFalse(
            signal.claimRefusalTone(),
            "the allowance from that refusal is still spent, so a later refusal in the same window is not new information"
        )
    }

    /// Refusal tone is per ACT, not per window budget: after a recognised command, a refusal is
    /// new information again and must speak, even in the same generation.
    func testARecognisedCommandRearmsTheRefusalTone() async {
        let signal = GracePeriodSignal(timeout: 30)
        await MainActor.run { signal.onWakeWordDetected() }

        guard signal.claimDispatchOwnership() != nil else { return XCTFail("Q1 dispatches") }
        XCTAssertTrue(signal.claimRefusalTone(), "Q2's refusal speaks")
        XCTAssertFalse(signal.claimRefusalTone(), "Q2 again would not — same announced fact")

        await MainActor.run { signal.onCommandRecognized() }

        guard signal.claimDispatchOwnership() != nil else { return XCTFail("a new act dispatches") }
        XCTAssertTrue(signal.claimRefusalTone(), "Q4's refusal is a new act, so it speaks")
    }
}
