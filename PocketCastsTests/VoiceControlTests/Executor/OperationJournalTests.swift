import XCTest
@testable import podcasts

/// The claim is atomic: exactly one caller executes; every other caller gets the answer.
///
/// The distinction this pins is the contract's — a reconnecting client needs the prior
/// outcome re-sent, so the ANSWER may repeat, but the MUTATION may not. A lock around
/// separate "has it run?" and "mark it running" calls would not provide that: two callers can
/// both see the operation absent and both execute. These cases drive the claim through the
/// same race the lock-shaped version would lose.
final class OperationJournalTests: XCTestCase {

    func test_firstClaim_isClaimed() {
        let journal = OperationJournal()
        XCTAssertEqual(journal.claim("op-1"), .claimed)
    }

    func test_secondClaimForTheSameOperation_isAlreadyRun() {
        let journal = OperationJournal()
        XCTAssertEqual(journal.claim("op-1"), .claimed)
        journal.complete("op-1", outcome: .succeeded)
        XCTAssertEqual(journal.claim("op-1"), .alreadyRun(.succeeded))
    }

    func test_differentOperations_claimIndependently() {
        let journal = OperationJournal()
        XCTAssertEqual(journal.claim("op-1"), .claimed)
        XCTAssertEqual(journal.claim("op-2"), .claimed)
        journal.complete("op-1", outcome: .refused)
        journal.complete("op-2", outcome: .succeeded)
        XCTAssertEqual(journal.claim("op-1"), .alreadyRun(.refused))
        XCTAssertEqual(journal.claim("op-2"), .alreadyRun(.succeeded))
    }

    func test_complete_replacesTheRecordedOutcome() {
        let journal = OperationJournal()
        XCTAssertEqual(journal.claim("op-1"), .claimed)
        journal.complete("op-1", outcome: .failed)
        XCTAssertEqual(journal.outcome(for: "op-1"), .failed)
        journal.complete("op-1", outcome: .succeeded)
        XCTAssertEqual(journal.outcome(for: "op-1"), .succeeded)
    }

    func test_outcome_forAnUnclaimedOperation_isNil() {
        XCTAssertNil(OperationJournal().outcome(for: "op-1"))
    }

    func test_aSecondClaimWhileInProgress_doesNotClaimAgain() {
        // The in-progress state is the boundary's payload: a second caller must neither
        // execute nor receive an outcome, because nothing has happened yet. Returning
        // `.claimed` again would admit a second execution — the both-execute failure.
        let journal = OperationJournal()
        XCTAssertEqual(journal.claim("op-1"), .claimed)
        XCTAssertEqual(journal.claim("op-1"), .inProgress)
        XCTAssertNil(journal.outcome(for: "op-1"))

        // Completion releases the answer for redelivery.
        journal.complete("op-1", outcome: .succeeded)
        XCTAssertEqual(journal.claim("op-1"), .alreadyRun(.succeeded))
    }

    func test_reasonCode_isAbsentForSuccessAndCancelled() {
        XCTAssertNil(OperationOutcome.succeeded.reasonCode)
        XCTAssertNil(OperationOutcome.cancelled.reasonCode)
    }

    func test_reasonCode_presentForNonSuccess() {
        XCTAssertEqual(OperationOutcome.failed.reasonCode, "stale_precondition")
        XCTAssertEqual(OperationOutcome.refused.reasonCode, "client_policy")
        XCTAssertEqual(OperationOutcome.unknown.reasonCode, "sink_unimplemented")
    }

    /// Concurrent claims must yield exactly one `.claimed` per operation.
    ///
    /// The journal sits between the server's frames and execution, which arrive on their own
    /// queue while execution runs elsewhere, so claims from more than one thread are the
    /// case the atomic boundary exists for.
    func test_concurrentClaims_admitExactlyOneCallerPerOperation() {
        let journal = OperationJournal()
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let callers = 8
        var claimed = 0
        let lock = NSLock()

        for _ in 0..<callers {
            DispatchQueue.global().async(group: group) {
                start.wait()
                if case .claimed = journal.claim("op-shared") {
                    lock.lock(); claimed += 1; lock.unlock()
                }
            }
        }

        start.signal()
        for _ in 0..<(callers - 1) { start.signal() }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "callers did not finish")

        XCTAssertEqual(
            claimed, 1,
            "\(claimed) callers claimed the same operation: the boundary is not atomic"
        )
    }
}
