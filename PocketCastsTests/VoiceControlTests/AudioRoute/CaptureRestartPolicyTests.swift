import XCTest
@testable import podcasts

/// Unit tests for the bounded automatic capture restart rule (core spec
/// "Automatic capture restarts"): one automatic restart per autonomous end; a
/// restart that dies within 60 s (or fails to start) withholds further
/// restarts; a 60 s+ run is healthy and re-arms the budget; a new trigger
/// re-arms after a withhold.
final class CaptureRestartPolicyTests: XCTestCase {

    /// An ordinary autonomous end (the run was not itself a restart) grants
    /// one automatic restart.
    func test_autonomousEnd_grantsOneRestart() {
        let policy = CaptureRestartPolicy()
        XCTAssertTrue(policy.mayStart)

        XCTAssertEqual(policy.captureEndedAutonomously(ranMs: 5_000), .restart)
        XCTAssertTrue(policy.mayStart, "the granted restart is still allowed")
        policy.captureStarted()
        XCTAssertTrue(policy.restartIsRunning, "the granted start is the restart run")
    }

    /// A restart that ends again within 60 s withholds: no further automatic
    /// restarts until a new trigger re-arms.
    func test_restartDyingWithin60s_withholdsFurtherRestarts() {
        let policy = CaptureRestartPolicy()
        _ = policy.captureEndedAutonomously(ranMs: 5_000)
        policy.captureStarted() // the restart run

        XCTAssertEqual(
            policy.captureEndedAutonomously(ranMs: 2_000),
            .withhold(ranMs: 2_000),
            "the restart itself died young — withhold"
        )
        XCTAssertFalse(policy.mayStart, "no further automatic restarts after the withhold")
    }

    /// The withhold boundary is exclusive: exactly 60 s is still healthy.
    func test_restartRunning60sOrMore_isHealthy() {
        let policy = CaptureRestartPolicy()
        _ = policy.captureEndedAutonomously(ranMs: 1_000)
        policy.captureStarted()

        XCTAssertEqual(policy.captureEndedAutonomously(ranMs: 60_000), .restart,
                       "a 60 s run is healthy — the next autonomous end gets a restart again")
        policy.captureStarted()
        XCTAssertEqual(policy.captureEndedAutonomously(ranMs: 61_000), .restart,
                       "healthy runs keep the restart budget armed")
        XCTAssertTrue(policy.mayStart)
    }

    /// A granted restart that fails to start withholds with `ran_ms` 0.
    func test_restartStartFailure_withholdsWithRanMsZero() {
        let policy = CaptureRestartPolicy()
        _ = policy.captureEndedAutonomously(ranMs: 4_000)

        XCTAssertEqual(policy.restartStartFailed(), .withhold(ranMs: 0),
                       "the restart never started — ran_ms is 0")
        XCTAssertFalse(policy.mayStart)
    }

    /// A start failure after a non-autonomous stop is not a withhold: there is
    /// no restart attempt to account.
    func test_startFailureWithoutAutonomousEnd_isNotAWithhold() {
        let policy = CaptureRestartPolicy()
        policy.stopWasUserOrInterruption()

        XCTAssertNil(policy.restartStartFailed())
        XCTAssertTrue(policy.mayStart)
    }

    /// A user stop or interruption clears restart accounting: the next run is
    /// not a restart run, so its own early death does not withhold.
    func test_userOrInterruptionStop_isNeverCountedAgainstTheBudget() {
        let policy = CaptureRestartPolicy()
        _ = policy.captureEndedAutonomously(ranMs: 3_000)
        policy.captureStarted() // restart run
        policy.stopWasUserOrInterruption() // e.g. interruption .began ended it

        // Next start is NOT a restart run; its early death grants another restart.
        policy.captureStarted()
        XCTAssertFalse(policy.restartIsRunning)
        XCTAssertEqual(policy.captureEndedAutonomously(ranMs: 1_000), .restart)
    }

    /// A new trigger re-arms after a withhold.
    func test_reArm_allowsRestartsAgain() {
        let policy = CaptureRestartPolicy()
        _ = policy.captureEndedAutonomously(ranMs: 1_000)
        policy.captureStarted()
        _ = policy.captureEndedAutonomously(ranMs: 500) // withhold
        XCTAssertFalse(policy.mayStart)

        policy.reArm()
        XCTAssertTrue(policy.mayStart, "the trigger re-arms automatic restarts")
        policy.captureStarted()
        XCTAssertFalse(policy.restartIsRunning,
                       "a run started after a re-arm is a fresh run, not the withheld restart")
    }
}

extension CaptureRestartPolicyTests {

    /// The trigger that lets a granted restart run (e.g. the reconnect that
    /// re-acquired the route) must not erase the restart identity: that run is
    /// still THE restart, and its own early death withholds.
    func test_reArmWhileARestartIsPending_keepsTheRestartIdentity() {
        let policy = CaptureRestartPolicy()
        _ = policy.captureEndedAutonomously(ranMs: 1_000) // grants the restart
        policy.reArm() // the reconnect trigger arrives before the restart starts

        policy.captureStarted()
        XCTAssertTrue(policy.restartIsRunning, "the trigger-adjacent start is still the granted restart")
        XCTAssertEqual(policy.captureEndedAutonomously(ranMs: 800), .withhold(ranMs: 800))
        XCTAssertFalse(policy.mayStart)
    }

    /// Coming out of a withhold is a fresh budget: the next run is not a
    /// restart run, so its early death grants a restart instead of withholding.
    func test_reArmAfterWithhold_startsAFreshBudget() {
        let policy = CaptureRestartPolicy()
        _ = policy.captureEndedAutonomously(ranMs: 1_000)
        policy.captureStarted()
        _ = policy.captureEndedAutonomously(ranMs: 500) // withhold
        policy.reArm()

        policy.captureStarted()
        XCTAssertFalse(policy.restartIsRunning)
        XCTAssertEqual(policy.captureEndedAutonomously(ranMs: 700), .restart)
    }
}
