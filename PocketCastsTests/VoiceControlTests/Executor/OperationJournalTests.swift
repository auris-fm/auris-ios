import XCTest
@testable import podcasts

/// Redelivery is answered from the journal; the mutation is what must not run twice.
///
/// The distinction is the contract's: a reconnecting client needs the prior outcome re-sent,
/// so "one result per operation" would forbid exactly the answer a reconnect needs. These
/// cases model the journal as the executor's gate — a second lookup for the same
/// `operation_id` must return the recorded outcome, and an unrecorded one must return nil so
/// the caller proceeds with execution.
final class OperationJournalTests: XCTestCase {

    func test_outcomeForUnrecordedOperation_isNil() {
        let journal = OperationJournal()
        XCTAssertNil(journal.outcome(for: "op-1"))
    }

    func test_record_thenLookup_returnsTheOutcome() {
        let journal = OperationJournal()
        journal.record("op-1", outcome: .succeeded)
        XCTAssertEqual(journal.outcome(for: "op-1"), .succeeded)
    }

    func test_record_secondOperation_doesNotDisturbTheFirst() {
        let journal = OperationJournal()
        journal.record("op-1", outcome: .succeeded)
        journal.record("op-2", outcome: .refused)
        XCTAssertEqual(journal.outcome(for: "op-1"), .succeeded)
        XCTAssertEqual(journal.outcome(for: "op-2"), .refused)
    }

    func test_record_replacesAnExistingOutcome() {
        // A retry that produces a different outcome replaces the prior entry, so the
        // journal answers with what the operation last did rather than what it first did.
        let journal = OperationJournal()
        journal.record("op-1", outcome: .failed)
        journal.record("op-1", outcome: .succeeded)
        XCTAssertEqual(journal.outcome(for: "op-1"), .succeeded)
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

    /// Concurrent record/lookup must not corrupt the map.
    ///
    /// The journal sits on the path between the server's frames and execution, which arrive
    /// on their own queue while the executor runs on another, so the map is read and written
    /// from more than one thread by construction.
    func test_concurrentOperations_conserveEveryEntry() {
        let journal = OperationJournal()
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let writers = 8
        let perWriter = 200

        for writer in 0..<writers {
            DispatchQueue.global().async(group: group) {
                start.wait()
                for index in 0..<perWriter {
                    let id = "op-\(writer)-\(index)"
                    journal.record(id, outcome: .succeeded)
                    _ = journal.outcome(for: id)
                }
            }
        }

        start.signal()
        for _ in 0..<(writers - 1) { start.signal() }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "writers did not finish")

        for writer in 0..<writers {
            for index in 0..<perWriter {
                XCTAssertNotNil(
                    journal.outcome(for: "op-\(writer)-\(index)"),
                    "an entry was lost under concurrency"
                )
            }
        }
    }
}
