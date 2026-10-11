import XCTest
@testable import podcasts

/// The journal's two properties, kept distinct because they fail differently: a claim must
/// admit exactly one caller (ownership), and an interrupted operation must not execute again
/// (deduplication across a restart). The second is the one an in-memory journal cannot give —
/// its records are gone when the process is.
final class OperationJournalTests: XCTestCase {

    private func makeJournal() -> (OperationJournal, InMemoryOperationRecordStore) {
        let store = InMemoryOperationRecordStore()
        return (OperationJournal(store: store), store)
    }

    // MARK: - claim

    func test_firstClaim_isClaimed() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1"), .claimed)
    }

    func test_secondClaimForTheSameOperation_isAlreadyRun() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1"), .claimed)
        journal.complete("op-1", result: .succeeded)
        XCTAssertEqual(journal.claim("op-1"), .alreadyRun(.succeeded))
    }

    func test_differentOperations_claimIndependently() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1"), .claimed)
        XCTAssertEqual(journal.claim("op-2"), .claimed)
        journal.complete("op-1", result: .nonSuccess(.refused, reason: OperationReason.clientPolicy))
        journal.complete("op-2", result: .succeeded)
        XCTAssertEqual(journal.claim("op-1"), .alreadyRun(.nonSuccess(.refused, reason: OperationReason.clientPolicy)))
        XCTAssertEqual(journal.claim("op-2"), .alreadyRun(.succeeded))
    }

    func test_aSecondClaimWhileInProgress_doesNotClaimAgain() {
        // The in-progress state is the boundary's payload: a second caller must neither
        // execute nor receive an outcome, because nothing has happened yet. Returning
        // `.claimed` again would admit a second execution — the both-execute failure.
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1"), .claimed)
        XCTAssertEqual(journal.claim("op-1"), .inProgress)
        XCTAssertNil(journal.result(for: "op-1"))

        journal.complete("op-1", result: .succeeded)
        XCTAssertEqual(journal.claim("op-1"), .alreadyRun(.succeeded))
    }

    func test_complete_replacesTheRecordedResult() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1"), .claimed)
        journal.complete("op-1", result: .nonSuccess(.refused, reason: OperationReason.stalePrecondition))
        XCTAssertEqual(journal.result(for: "op-1")?.outcome, .refused)
        journal.complete("op-1", result: .succeeded)
        XCTAssertEqual(journal.result(for: "op-1"), .succeeded)
    }

    func test_result_forAnUnclaimedOperation_isNil() {
        let (journal, _) = makeJournal()
        XCTAssertNil(journal.result(for: "op-1"))
    }

    // MARK: - interruption reconstruction

    /// The case the durable store exists for: a claim written before the mutation, seen again
    /// by a later process. The effect is not knowable, so the answer is `unknown` and the
    /// operation is NOT executed again.
    func test_anOperationLeftInProgress_isReconstructedAsUnknownAndNotReExecuted() {
        let store = InMemoryOperationRecordStore()
        let first = OperationJournal(store: store)
        // The mutation is in flight when the process dies: claimed, never completed.
        XCTAssertEqual(first.claim("op-1"), .claimed)

        // A new process reads the same store.
        let second = OperationJournal(store: store)
        XCTAssertEqual(second.interruptedOperationIDs(), ["op-1"])

        let reconstructed = second.reconstructInterrupted("op-1")
        XCTAssertEqual(reconstructed?.outcome, .unknown)
        XCTAssertEqual(reconstructed?.reason, OperationReason.interruptedInFlight)

        // Now settled: a redelivery is answered, never executed.
        XCTAssertEqual(second.claim("op-1"), .alreadyRun(.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight)))
    }

    func test_reconstructingAnInterruptedOperation_settlesIt() {
        let store = InMemoryOperationRecordStore()
        let first = OperationJournal(store: store)
        _ = first.claim("op-1")
        let second = OperationJournal(store: store)
        _ = second.reconstructInterrupted("op-1")
        XCTAssertTrue(second.interruptedOperationIDs().isEmpty, "the record should be settled")
        XCTAssertEqual(second.result(for: "op-1")?.outcome, .unknown)
    }

    func test_aCompletedOperation_isNotReconstructedAsInterrupted() {
        let store = InMemoryOperationRecordStore()
        let first = OperationJournal(store: store)
        _ = first.claim("op-1")
        first.complete("op-1", result: .succeeded)

        let second = OperationJournal(store: store)
        XCTAssertTrue(second.interruptedOperationIDs().isEmpty)
        XCTAssertEqual(second.claim("op-1"), .alreadyRun(.succeeded))
    }

    func test_anUnclaimedOperationSurvivesRestartWithoutBecomingInterrupted() {
        // "Never started" must stay distinguishable from "started and died": only the latter
        // is unknown, and only a record written at claim time can tell them apart.
        let store = InMemoryOperationRecordStore()
        _ = OperationJournal(store: store)
        let restarted = OperationJournal(store: store)
        XCTAssertTrue(restarted.interruptedOperationIDs().isEmpty)
        XCTAssertEqual(restarted.claim("op-1"), .claimed)
    }

    // MARK: - the result contract

    /// `preventsReExecution` answers one question: may this operation be executed again?
    /// Every outcome stops it — including `unknown`, whose whole point is that it must NOT be
    /// re-run. It says nothing about whether the effect is known, which is why `unknown` stops
    /// re-execution while still not being a success.
    func test_everyOutcomePreventsReExecution() {
        for outcome in OperationOutcome.allCases {
            XCTAssertTrue(outcome.preventsReExecution, "\(outcome) must prevent re-execution")
        }
    }

    /// The distinction the outcome table turns on: `unknown` is a recorded, final answer that
    /// is not a success.
    func test_unknownPreventsReExecutionButIsNotSuccess() {
        XCTAssertNotEqual(OperationOutcome.unknown, .succeeded)
        XCTAssertEqual(
            OperationResult.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight).outcome,
            .unknown
        )
    }

    /// The refusal vocabulary the contract's table names, each producible by this client.
    func test_theRefusalReasonsAreTheOnesThisClientCanProduce() {
        XCTAssertEqual(OperationReason.stalePrecondition, "stale_precondition")
        XCTAssertEqual(OperationReason.unsupportedOperation, "unsupported_operation")
        XCTAssertEqual(OperationReason.missingEntitlement, "missing_entitlement")
        XCTAssertEqual(OperationReason.clientPolicy, "client_policy")
        XCTAssertEqual(OperationReason.sinkUnimplemented, "sink_unimplemented")
    }

    /// The audio-session denial is its own reason, not folded into a general policy refusal:
    /// the two produce different clarifications.
    ///
    /// It is also not a reason every operation can produce. It is reserved for operations that
    /// need a session, so reporting it elsewhere would name a failure that did not occur.
    func test_audioSessionDenialIsDistinctFromClientPolicy() {
        XCTAssertNotEqual(OperationReason.audioSessionDenied, OperationReason.clientPolicy)
        XCTAssertNotEqual(OperationReason.audioSessionDenied, OperationReason.sinkUnimplemented)
    }

    func test_successCarriesNoReason() {
        XCTAssertNil(OperationResult.succeeded.reason)
        XCTAssertEqual(OperationResult.succeeded.outcome, .succeeded)
    }

    // MARK: - concurrency

    /// Concurrent claims must yield exactly one `.claimed` per operation: claims arrive on the
    /// route client's queue while execution runs elsewhere.
    func test_concurrentClaims_admitExactlyOneCallerPerOperation() {
        let (journal, _) = makeJournal()
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
