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

    /// A stable identity for tests that do not care which one: the journal's rules about replay,
    /// conflict and interruption are all expressed RELATIVE TO an identity, so every claim and
    /// settlement carries one.
    private func identity(
        owner: String = "owner-1",
        conversation: String = "conv-1",
        turn: String = "turn-1",
        bytes: String = #"{"tool":"playback","action":"pause"}"#
    ) -> OperationIdentity {
        OperationIdentity(owner: owner, conversation: conversation, turn: turn,
                          actionBytes: Data(bytes.utf8))
    }

    // MARK: - claim

    func test_firstClaim_isClaimed() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .claimed)
    }

    func test_secondClaimForTheSameOperation_isAlreadyRun() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .claimed)
        journal.complete("op-1", identity: identity(), result: .succeeded(state: ["position_seconds": .int(0)]))
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .alreadyRun(.succeeded(state: ["position_seconds": .int(0)])))
    }

    func test_differentOperations_claimIndependently() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .claimed)
        XCTAssertEqual(journal.claim("op-2", identity: identity()), .claimed)
        journal.complete("op-1", identity: identity(), result: .nonSuccess(.refused, reason: OperationReason.clientPolicy))
        journal.complete("op-2", identity: identity(), result: .succeeded(state: ["position_seconds": .int(0)]))
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .alreadyRun(.nonSuccess(.refused, reason: OperationReason.clientPolicy)))
        XCTAssertEqual(journal.claim("op-2", identity: identity()), .alreadyRun(.succeeded(state: ["position_seconds": .int(0)])))
    }

    func test_aSecondClaimWhileInProgress_doesNotClaimAgain() {
        // The in-progress state is the boundary's payload: a second caller must neither
        // execute nor receive an outcome, because nothing has happened yet. Returning
        // `.claimed` again would admit a second execution — the both-execute failure.
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .claimed)
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .inProgress)
        XCTAssertNil(journal.result(for: "op-1"))

        journal.complete("op-1", identity: identity(), result: .succeeded(state: ["position_seconds": .int(0)]))
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .alreadyRun(.succeeded(state: ["position_seconds": .int(0)])))
    }

    /// A settlement is FINAL. The former rule here — "a second complete() replaces the recorded
    /// result" — is exactly the rewrite the review forbade: a durable result must not be
    /// mutable by a later, differently-shaped settlement of the same id.
    func test_complete_doesNotReplaceAnAlreadyRecordedResult() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .claimed)
        journal.complete("op-1", identity: identity(), result: .nonSuccess(.refused, reason: OperationReason.stalePrecondition))
        XCTAssertEqual(journal.result(for: "op-1")?.outcome, .refused)
        XCTAssertFalse(
            journal.complete("op-1", identity: identity(), result: .succeeded(state: ["position_seconds": .int(0)])),
            "a settled operation is final"
        )
        XCTAssertEqual(journal.result(for: "op-1")?.outcome, .refused, "the recorded refusal stands")
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
        XCTAssertEqual(first.claim("op-1", identity: identity()), .claimed)

        // A new process reads the same store.
        let second = OperationJournal(store: store)
        XCTAssertEqual(second.interruptedOperationIDs(), ["op-1"])

        let reconstructed = second.reconstructInterrupted("op-1")
        XCTAssertEqual(reconstructed?.outcome, .unknown)
        XCTAssertEqual(reconstructed?.reason, OperationReason.interruptedInFlight)

        // Now settled: a redelivery is answered, never executed.
        XCTAssertEqual(second.claim("op-1", identity: identity()), .alreadyRun(.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight)))
    }

    func test_reconstructingAnInterruptedOperation_settlesIt() {
        let store = InMemoryOperationRecordStore()
        let first = OperationJournal(store: store)
        _ = first.claim("op-1", identity: identity())
        let second = OperationJournal(store: store)
        _ = second.reconstructInterrupted("op-1")
        XCTAssertTrue(second.interruptedOperationIDs().isEmpty, "the record should be settled")
        XCTAssertEqual(second.result(for: "op-1")?.outcome, .unknown)
    }

    func test_aCompletedOperation_isNotReconstructedAsInterrupted() {
        let store = InMemoryOperationRecordStore()
        let first = OperationJournal(store: store)
        _ = first.claim("op-1", identity: identity())
        first.complete("op-1", identity: identity(), result: .succeeded(state: ["position_seconds": .int(0)]))

        let second = OperationJournal(store: store)
        XCTAssertTrue(second.interruptedOperationIDs().isEmpty)
        XCTAssertEqual(second.claim("op-1", identity: identity()), .alreadyRun(.succeeded(state: ["position_seconds": .int(0)])))
    }

    func test_anUnclaimedOperationSurvivesRestartWithoutBecomingInterrupted() {
        // "Never started" must stay distinguishable from "started and died": only the latter
        // is unknown, and only a record written at claim time can tell them apart.
        let store = InMemoryOperationRecordStore()
        _ = OperationJournal(store: store)
        let restarted = OperationJournal(store: store)
        XCTAssertTrue(restarted.interruptedOperationIDs().isEmpty)
        XCTAssertEqual(restarted.claim("op-1", identity: identity()), .claimed)
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
        XCTAssertNotEqual(OperationOutcome.unknown, OperationOutcome.succeeded)
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

    /// `audio_session_denied` is defined and has no producer on this client. The volume
    /// operation's failure is a slider that cannot be resolved, which is not a refused session
    /// acquisition, so it is reported under its own reason rather than renamed to fit this one.
    func test_theVolumeFailureIsNotReportedAsASessionDenial() {
        XCTAssertNotEqual(OperationReason.volumeControlUnavailable, OperationReason.audioSessionDenied)
    }

    func test_audioSessionDenialIsDistinctFromTheOtherRefusals() {
        XCTAssertNotEqual(OperationReason.audioSessionDenied, OperationReason.clientPolicy)
        XCTAssertNotEqual(OperationReason.audioSessionDenied, OperationReason.sinkUnimplemented)
    }

    func test_successCarriesNoReason() {
        XCTAssertNil(OperationResult.succeeded(state: ["position_seconds": .int(0)]).reason)
        XCTAssertEqual(OperationResult.succeeded(state: ["position_seconds": .int(0)]).outcome, OperationOutcome.succeeded)
    }

    // MARK: - the file-backed store

    private func makeFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opjournal-\(UUID().uuidString).json")
    }

    /// The durability claim, driven through a real file rather than a test double: a claim
    /// written by one journal is read back by another built on the same URL.
    func test_theFileBackedStore_survivesAJournalRebuiltOnTheSameFile() {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(first.claim("op-1", identity: identity()), .claimed)

        let second = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(second.interruptedOperationIDs(), ["op-1"])
        XCTAssertEqual(second.reconstructInterrupted("op-1")?.outcome, .unknown)

        let third = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(
            third.result(for: "op-1")?.reason,
            OperationReason.interruptedInFlight,
            "the reconstructed result must survive another rebuild"
        )
    }

    func test_theFileBackedStore_roundTripsAFinishedResult() {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(first.claim("op-1", identity: identity()), .claimed)
        first.complete("op-1", identity: identity(), result: .nonSuccess(.refused, reason: OperationReason.stalePrecondition))

        let second = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(
            second.result(for: "op-1"),
            .nonSuccess(.refused, reason: OperationReason.stalePrecondition)
        )
    }

    func test_theFileBackedStore_doesNotTreatAnAbsentFileAsInterrupted() {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertTrue(journal.interruptedOperationIDs().isEmpty)
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .claimed, "a new operation must still execute")
    }

    func test_theFileBackedStore_recoversFromUnreadableContent() {
        // Unreadable durable history now FAILS CLOSED (PR #49 review): every claim is refused
        // with .persistenceUnavailable instead of silently starting from empty history — an
        // operation that could not be exactly-once recorded must never reach its effect.
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("not json".utf8).write(to: url)
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertTrue(journal.interruptedOperationIDs().isEmpty)
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .persistenceUnavailable)
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
        let shared = identity()

        for _ in 0..<callers {
            DispatchQueue.global().async(group: group) {
                start.wait()
                if case .claimed = journal.claim("op-shared", identity: shared) {
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


extension OperationJournalTests {
    /// A real file at an unreadable location must refuse through the ACTUAL Data read error
    /// path, not a presence heuristic: a directory URL makes Data(contentsOf:) fail with
    /// is-a-directory — that is unreadable, never fresh history.
    func test_realFilesystemReadFailure_refusesRatherThanFreshHistory() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-dir-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = OperationJournal(store: FileOperationRecordStore(url: dir))
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .persistenceUnavailable, "a real read error must fail closed")
    }

    /// A stored nonsuccess WITHOUT its reason is corrupt: never fabricate interrupted_in_flight.
    func test_storedNonsuccessMissingReason_isUnreadableNotReconstructed() {
        let url = makeFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("{\"op-r\":{\"state\":\"finished\",\"outcome\":\"refused\"}}".utf8).write(to: url)
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(journal.claim("op-r", identity: identity()), .persistenceUnavailable)
    }
}

extension OperationJournalTests {
    /// REAL filesystem failed-WRITE control (distinct from replacement-store stubs): the journal
    /// URL sits under a path whose parent is a plain FILE, so the actual atomic Data.write fails.
    /// The claim must refuse fail-closed through that real error path.
    func test_realFilesystemWriteFailure_refusesTheClaimThroughTheActualWritePath() {
        let parentFile = FileManager.default.temporaryDirectory.appendingPathComponent("journal-parent-\(UUID().uuidString)")
        try? Data("not a directory".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }
        let journal = OperationJournal(store: FileOperationRecordStore(url: parentFile.appendingPathComponent("child.json")))
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .persistenceUnavailable, "a real write failure must fail closed")
    }

    // MARK: - identity: replay is byte equality, conflict is refusal

    func test_identicalIdentityIsAReplayNotAReRun() {
        let (journal, _) = makeJournal()
        let original = identity()
        XCTAssertEqual(journal.claim("op-1", identity: original), .claimed)
        journal.complete("op-1", identity: original, result: .succeeded(state: ["position_seconds": .int(30)]))
        XCTAssertEqual(
            journal.claim("op-1", identity: original),
            .alreadyRun(.succeeded(state: ["position_seconds": .int(30)]))
        )
    }

    /// The same operation id carrying different action bytes is a DIFFERENT operation.
    func test_sameIdWithDifferentActionBytesIsRefused() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1", identity: identity(bytes: #"{"action":"pause"}"#)), .claimed)
        XCTAssertEqual(
            journal.claim("op-1", identity: identity(bytes: #"{"action":"resume"}"#)),
            .identityConflict
        )
    }

    /// "Same action as far as we can tell" is not replay identity: two encodings that a human
    /// would read the same are different bytes, so they are different requests.
    func test_byteDifferencesThatOnlyDifferInWhitespaceAreAConflict() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1", identity: identity(bytes: #"{"a": 1}"#)), .claimed)
        XCTAssertEqual(
            journal.claim("op-1", identity: identity(bytes: #"{"a":1}"#)),
            .identityConflict,
            "replay identity is byte equality, not parsed equality"
        )
    }

    /// An id is turn-bound: the same id under a different turn, conversation or owner is a
    /// conflict even when the bytes match exactly.
    func test_sameIdInADifferentTurnConversationOrOwnerIsAConflict() {
        let cases: [(String, OperationIdentity)] = [
            ("turn", identity(turn: "turn-2")),
            ("conversation", identity(conversation: "conv-2")),
            ("owner", identity(owner: "owner-2")),
        ]
        for (label, other) in cases {
            let (journal, _) = makeJournal()
            XCTAssertEqual(journal.claim("op-1", identity: identity()), .claimed)
            XCTAssertEqual(
                journal.claim("op-1", identity: other), .identityConflict,
                "a different \(label) is a different operation"
            )
        }
    }

    func test_conflictingIdentityIsRefusedWhileTheOriginalIsStillInProgress() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .claimed)
        XCTAssertEqual(journal.claim("op-1", identity: identity(bytes: "{}")), .identityConflict)
    }

    // MARK: - settlement is bound to the claimed identity

    /// A settlement must name the identity it settles. A different identity cannot rewrite a
    /// durable result, and settling an unclaimed id invents nothing.
    func test_settlementWithAForeignIdentityIsRefused() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .claimed)
        XCTAssertFalse(
            journal.complete("op-1", identity: identity(bytes: "{}"),
                             result: .succeeded(state: ["position_seconds": .int(99)])),
            "a settlement carrying different contents must not rewrite the claim"
        )
        XCTAssertNil(journal.result(for: "op-1"), "the operation stays in progress")
        XCTAssertFalse(journal.complete("op-never-claimed", identity: identity(),
                                        result: .succeeded(state: ["a": .int(1)])))
    }

    /// Once settled, a second settlement cannot rewrite the result — the record is final.
    func test_secondSettlementCannotRewriteADurableResult() {
        let (journal, _) = makeJournal()
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .claimed)
        XCTAssertTrue(journal.complete("op-1", identity: identity(),
                                       result: .succeeded(state: ["position_seconds": .int(10)])))
        XCTAssertFalse(journal.complete("op-1", identity: identity(),
                                        result: .succeeded(state: ["position_seconds": .int(20)])))
        XCTAssertEqual(journal.result(for: "op-1"), .succeeded(state: ["position_seconds": .int(10)]))
    }

    // MARK: - identity across a real file reopen

    /// The digest must be READ AS PERSISTED, never hashed again: a restarted process re-reads the
    /// record and must still recognise a byte-identical redelivery as a replay.
    func test_fileReopenReplaysIdenticalBytesAndRefusesConflictingBytes() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opjournal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = #"{"tool":"playback","action":"seek_to","params":{"position_seconds":42}}"#

        let first = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(first.claim("op-1", identity: identity(bytes: bytes)), .claimed)
        first.complete("op-1", identity: identity(bytes: bytes),
                       result: .succeeded(state: ["position_seconds": .int(42)]))

        let reopened = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(
            reopened.claim("op-1", identity: identity(bytes: bytes)),
            .alreadyRun(.succeeded(state: ["position_seconds": .int(42)])),
            "a reopened file must replay the same bytes, not refuse them"
        )
        XCTAssertEqual(
            reopened.claim("op-1", identity: identity(bytes: #"{"tool":"playback","action":"pause"}"#)),
            .identityConflict
        )
    }

    /// An in-progress record survives the reopen as still-in-progress for the SAME bytes, and as
    /// a conflict for different ones.
    func test_fileReopenKeepsAnInProgressIdentity() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opjournal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(first.claim("op-1", identity: identity(bytes: #"{"a":1}"#)), .claimed)

        let reopened = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(reopened.interruptedOperationIDs(), ["op-1"])
        XCTAssertEqual(reopened.claim("op-1", identity: identity(bytes: #"{"a":1}"#)), .inProgress)
        XCTAssertEqual(reopened.claim("op-1", identity: identity(bytes: #"{"a":2}"#)), .identityConflict)
        XCTAssertEqual(reopened.reconstructInterrupted("op-1")?.outcome, .unknown)
    }

    /// Full result/state replay across restarts: the settled state comes back exactly, and only
    /// for the matching identity.
    func test_finishedResultAndStateReplayAcrossRestarts() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opjournal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(first.claim("op-1", identity: identity()), .claimed)
        first.complete("op-1", identity: identity(),
                       result: .succeeded(state: ["position_seconds": .int(7), "playing": .bool(true)]))

        let reopened = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(
            reopened.result(for: "op-1"),
            .succeeded(state: ["position_seconds": .int(7), "playing": .bool(true)])
        )
        XCTAssertEqual(
            reopened.claim("op-1", identity: identity()),
            .alreadyRun(.succeeded(state: ["position_seconds": .int(7), "playing": .bool(true)]))
        )
        XCTAssertEqual(reopened.claim("op-1", identity: identity(owner: "someone-else")), .identityConflict)
    }

    /// Persisted history WITHOUT identity cannot answer the replay/conflict question, so it is
    /// unreadable history: claims fail closed rather than re-executing into an old id.
    func test_historyWithoutIdentityFieldsFailsClosed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opjournal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["op-1": ["state": "inProgress"]]).write(to: url)

        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(journal.claim("op-1", identity: identity()), .persistenceUnavailable)
        XCTAssertEqual(journal.claim("op-2", identity: identity()), .persistenceUnavailable)
    }

    /// The digest is the SHA-256 a reader can reproduce from the same bytes — the property that
    /// makes a persisted digest comparable to a live frame at all.
    func test_identityDigestIsTheFramesSha256() {
        let bytes = Data(#"{"a":1}"#.utf8)
        XCTAssertEqual(
            OperationIdentity.digest(of: bytes),
            "015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862"
        )
        // A digest-built identity and a bytes-built identity of the same frame are EQUAL, which
        // is what makes a reopened record recognise its own redelivery.
        let live = OperationIdentity(owner: "o", conversation: "c", turn: "t", actionBytes: bytes)
        let persisted = OperationIdentity(
            persistedOwner: "o", conversation: "c", turn: "t", digest: live.actionDigest
        )
        XCTAssertEqual(persisted, live)
    }
}
