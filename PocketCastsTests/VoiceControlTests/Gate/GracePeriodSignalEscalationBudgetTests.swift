import XCTest
@testable import podcasts

/// The bound lives in the grace-window signal itself, so it is falsifiable here:
/// one dispatch per window, restored by a wake or a recognised command.
final class GracePeriodSignalEscalationBudgetTests: XCTestCase {
    func testClosedWindowHasNoBudget() async {
        let signal = GracePeriodSignal(timeout: 5)
        XCTAssertFalse(signal.claimEscalationBudget(), "no user-initiated session ⇒ nothing escalates")
    }

    func testOneEscalationPerWindow() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }

        XCTAssertTrue(signal.claimEscalationBudget(), "first failure in the window escalates")
        XCTAssertFalse(signal.claimEscalationBudget(), "a second failure in the same window does not")
    }

    /// A fresh wake is a new deliberate act, so a user who says the wake word
    /// twice gets two attempts rather than one.
    func testAWakeResetsTheBudget() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertTrue(signal.claimEscalationBudget())

        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertTrue(signal.claimEscalationBudget(), "a wake inside the window opens a new act")
    }

    func testARecognisedCommandResetsTheBudget() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertTrue(signal.claimEscalationBudget())

        await MainActor.run { signal.onCommandRecognized() }
        XCTAssertTrue(signal.claimEscalationBudget(), "a recognised command is another deliberate act")
    }

    /// The fallback dispatch is a successful command, so the executor restarts the
    /// window when it returns. The window must continue without restoring the
    /// allowance, or a second unclear utterance in the same window dispatches again.
    func testTheFallbackDoesNotRestoreItsOwnAllowance() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertTrue(signal.claimEscalationBudget())

        // What the executor does when the fallback's dispatch returns non-error.
        await MainActor.run { signal.onCommandRecognized() }
        await MainActor.run { signal.markEscalationBudgetSpent() }

        XCTAssertTrue(signal.isActive, "the conversation window continues")
        XCTAssertFalse(signal.claimEscalationBudget(), "but the escalation allowance is not restored")
    }

    /// Privacy fail-closed: the window can close without expiring, and a closed
    /// window has no budget until something opens it again.
    func testClosingTheWindowWithdrawsTheBudget() async {
        let signal = GracePeriodSignal(timeout: 5)
        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertTrue(signal.claimEscalationBudget())

        await MainActor.run { signal.onAppBackgrounded() }
        XCTAssertFalse(signal.claimEscalationBudget(), "a closed session escalates nothing")

        await MainActor.run { signal.onWakeWordDetected() }
        XCTAssertTrue(signal.claimEscalationBudget(), "the next wake opens a fresh session")
    }
}
