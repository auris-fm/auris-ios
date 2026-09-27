import XCTest
@testable import podcasts

/// The bound lives in the grace-window signal itself, so it is falsifiable here:
/// one dispatch per window, restored by a wake or a recognised command.
final class GracePeriodSignalEscalationBudgetTests: XCTestCase {
    func testClosedWindowHasNoBudget() async {
        let signal = GracePeriodSignal(timeout: 5)
        XCTAssertNil(signal.claimEscalationBudget(), "no user-initiated session ⇒ nothing escalates")
    }

    func testOneEscalationPerWindow() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }

        XCTAssertNotNil(signal.claimEscalationBudget(), "first failure in the window escalates")
        XCTAssertNil(signal.claimEscalationBudget(), "a second failure in the same window does not")
    }

    /// A fresh wake is a new deliberate act, so a user who says the wake word
    /// twice gets two attempts rather than one.
    func testAWakeResetsTheBudget() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertNotNil(signal.claimEscalationBudget())

        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertNotNil(signal.claimEscalationBudget(), "a wake inside the window opens a new act")
    }

    func testARecognisedCommandResetsTheBudget() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertNotNil(signal.claimEscalationBudget())

        await MainActor.run { signal.onCommandRecognized() }
        XCTAssertNotNil(signal.claimEscalationBudget(), "a recognised command is another deliberate act")
    }

    /// A fallback dispatch is not a command the user gave, so handling it extends
    /// the window without restoring the allowance that permitted it. The ordinary
    /// command path is asserted alongside, so the two behaviours are distinguished
    /// rather than assumed apart.
    func testFallbackExtendsTheWindowWithoutRestoringItsOwnAllowance() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        let generation = signal.claimEscalationBudget()
        XCTAssertNotNil(generation)

        await MainActor.run { signal.extendWindowKeepingEscalationSpent(underGeneration: generation!) }

        XCTAssertTrue(signal.isActive, "the conversation window continues")
        XCTAssertNil(signal.claimEscalationBudget(), "a fallback does not re-arm its own allowance")
    }

    /// The contrast case: a command the user actually gave does restore it, which
    /// is what makes the fallback path a distinction rather than a blanket rule.
    func testAChosenCommandRestoresTheAllowanceUnlikeAFallback() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertNotNil(signal.claimEscalationBudget())

        await MainActor.run { signal.onCommandRecognized() }

        XCTAssertNotNil(signal.claimEscalationBudget(), "a deliberate command is a new act")
    }

    /// The case state alone cannot express, and the one where a wrong answer is
    /// invisible in the budget: a dispatch belonging to a window that has since
    /// ended must not **extend** whatever window is current. The old completion is
    /// applied at the moment the new window would otherwise expire, so a guard that
    /// only checked liveness would keep the session alive past its own timeout.
    func testAnEndedWindowsCompletionCannotExtendTheCurrentOne() async {
        let signal = GracePeriodSignal(timeout: 0.3)
        await MainActor.run { signal.onWakeWordDetected() }
        let oldGeneration = signal.claimEscalationBudget()
        XCTAssertNotNil(oldGeneration)

        // The window ends for privacy reasons, then a new one opens.
        await MainActor.run { signal.onAppBackgrounded() }
        await MainActor.run { signal.onWakeWordDetected() }
        let newGeneration = signal.claimEscalationBudget()
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

    /// A recognised command restores the allowance, so a refusal that follows it
    /// is new information and must be audible. Leaving the tone claim marked from
    /// the previous allowance makes that first refusal silent.
    func testARecognisedCommandMakesTheNextRefusalAudibleAgain() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertTrue(signal.claimRefusalTone(), "the first refusal speaks")

        await MainActor.run { signal.onCommandRecognized() }   // restores the allowance

        XCTAssertTrue(signal.claimRefusalTone(), "a refusal against a restored allowance is new information")
    }

    /// Privacy fail-closed: the window can close without expiring, and a closed
    /// window has no budget until something opens it again.
    func testClosingTheWindowWithdrawsTheBudget() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertNotNil(signal.claimEscalationBudget())

        await MainActor.run { signal.onAppBackgrounded() }
        XCTAssertNil(signal.claimEscalationBudget(), "a closed session escalates nothing")

        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertNotNil(signal.claimEscalationBudget(), "the next wake opens a fresh session")
    }
}
