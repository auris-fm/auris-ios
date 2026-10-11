import Foundation

/// The outcome of an app operation the server asked this client to perform.
///
/// `unknown` is the honest answer whenever the effect is not knowable from the client's
/// evidence. That is wider than a missing sink: the sink may have answered nothing at all,
/// the result may have been lost before it reached the server, or the process may have been
/// interrupted while the mutation was in flight. `unknown` means *do not reason as if it did
/// or did not happen* — so a caller must not re-execute and must not report success.
enum OperationOutcome: String, Equatable, CaseIterable {
    case succeeded
    case refused
    case failed
    case cancelled
    case unknown

    /// Whether recording this outcome must stop the operation from ever being executed again.
    ///
    /// True for every case, `unknown` included — and `unknown` is the case that matters, since
    /// it is the one that says the mutation *may have happened* and must therefore not be
    /// repeated. This deliberately does not mean "the effect is known": `unknown` is recorded
    /// and final for the journal while telling the server nothing about what occurred.
    var preventsReExecution: Bool { true }
}

/// A recorded result: the outcome and, for every non-success, the machine-readable reason
/// the owning contract requires.
///
/// `reason` is required on every non-success outcome. An earlier shape of this type left it
/// optional, which would freeze a client type that omits a field the server reads — the
/// envelope cannot demand a reason and the client decline to supply one.
struct OperationResult: Equatable {
    let outcome: OperationOutcome
    let reason: String?

    private init(outcome: OperationOutcome, reason: String?) {
        self.outcome = outcome
        self.reason = reason
    }

    /// A non-success result carries a reason; success carries none.
    static func nonSuccess(_ outcome: OperationOutcome, reason: String) -> OperationResult {
        precondition(outcome != .succeeded, "success is not a non-success outcome")
        return OperationResult(outcome: outcome, reason: reason)
    }

    static let succeeded = OperationResult(outcome: .succeeded, reason: nil)
}

/// The reasons an app operation does not succeed, as named by the owning contract.
///
/// The cancellation codes are the ones the client can actually observe — see the executor's
/// supersede path and the dialog's cancellation path. A code the client cannot distinguish is
/// not a code it can honestly send, so the list stays at what the evidence supports.
enum OperationReason {
    /// The client's own policy declined the action before mutating anything.
    static let clientPolicy = "client_policy"
    /// A precondition read from current client state failed before the mutation. A refusal,
    /// not a failure: the contract's table places it under `refused` precisely because no
    /// mutation was attempted.
    static let stalePrecondition = "stale_precondition"
    /// The sink does not support this operation at all, as opposed to supporting it and
    /// refusing for a policy reason.
    static let unsupportedOperation = "unsupported_operation"
    /// The account or device is not entitled to the operation.
    static let missingEntitlement = "missing_entitlement"
    /// A required audio session was **refused**. **Unsupported on this client, deliberately.**
    ///
    /// No operation here has been shown to observe a denied session acquisition. The volume
    /// operation's failure path is a slider lookup that cannot be resolved, and that is not a
    /// refusal of a session — nothing asked for a session and was denied. Recording it under
    /// this name would rename a real failure to fit an enum, which makes the wire say something
    /// the client never observed.
    ///
    /// The reason stays defined so the contract can name it once a producer exists; it has no
    /// producer today, and a producer is not to be manufactured for it.
    static let audioSessionDenied = "audio_session_denied"

    /// The sink cannot act because the mechanism it needs is unavailable — here, the system
    /// volume slider could not be resolved, so no volume was changed.
    ///
    /// This is the honest name for the volume operation's failure: the operation could not be
    /// carried out, and no session was denied.
    static let volumeControlUnavailable = "volume_control_unavailable"
    /// The sink had no implementation for this operation — an explicit unavailability.
    static let sinkUnimplemented = "sink_unimplemented"
    /// An independent confident fast control preempted a pending flow; the preempted flow
    /// cannot later execute from a stale reply.
    static let supersededByPreemption = "superseded_by_preemption"
    /// The user withdrew the request that was being carried out.
    static let cancelledByUser = "cancelled_by_user"
    /// An **observed** turn budget expired before the operation could be carried out.
    ///
    /// A turn merely ending with the operation undispatched does not establish this: that is a
    /// generic terminal event, and it is equally consistent with the turn being abandoned for
    /// another reason. This code requires a budget this client actually observes expiring —
    /// and this client has no per-turn execution budget today (the retained-turn count sent in
    /// the envelope is a conversation-history window, not an execution deadline). Until such a
    /// budget exists, only `.unknown` is honest for a turn that ended mid-flight.
    static let turnBudgetExhausted = "turn_budget_exhausted"
    /// The mutation was interrupted in flight: it may or may not have happened.
    static let interruptedInFlight = "interrupted_in_flight"
}

/// The result of claiming an operation for execution.
enum OperationClaim: Equatable {
    /// This caller is the first to claim it: run the operation, then `complete`.
    case claimed
    /// Another caller holds the claim and is still executing: do not run the operation.
    case inProgress
    /// The operation already ran, and this is what happened.
    case alreadyRun(OperationResult)
    /// A previous process claimed the operation and did not record an outcome — the app was
    /// interrupted while the mutation was in flight. The effect is not knowable: the operation
    /// must NOT be executed again, and its result is `unknown`.
    case interrupted(OperationResult)
}

/// Storage for the journal's records. Separated so the journal's rules are testable without a
/// real file, and so the durable backing can change without changing those rules.
protocol OperationRecordStore {
    func load() -> [String: StoredRecord]
    func save(_ records: [String: StoredRecord])
}

/// One operation's persisted state.
enum StoredRecord: Equatable {
    case inProgress
    case finished(OperationResult)
}

/// Maps `operation_id` to the state of the operation it names, so a redelivered operation is
/// answered from the record instead of being executed a second time — including across a
/// process restart, which is the case the durable store exists for.
///
/// Two properties this type has to provide, and they are different:
///
/// * **Exactly-once ownership** — the claim performs the check and the transition in one
///   critical section, so two callers cannot both see the operation absent and both execute.
///   A lock around separate "has it run?" and "mark it running" calls would not provide this.
/// * **Execution deduplication across an interruption** — a process that dies mid-mutation
///   leaves an in-progress record behind. On the next launch that record is read back as
///   `.interrupted`, whose effect is not knowable, so the operation is answered `unknown`
///   rather than run again. Without the durable store the record would be gone and the
///   operation would execute a second time.
///
/// The record is written *before* the mutation runs, which is what makes the interruption
/// answerable: a record that is only written afterwards cannot distinguish "never started"
/// from "started and died", and both would have to be re-executed.
final class OperationJournal {
    private let store: OperationRecordStore
    private var records: [String: StoredRecord]
    private let lock = NSLock()

    init(store: OperationRecordStore) {
        self.store = store
        self.records = store.load()
    }

    /// Atomically claims the operation for execution.
    ///
    /// The claim is persisted before it is returned, so an interruption after this point is
    /// reconstructible as `.interrupted` rather than silently forgotten.
    func claim(_ operationID: String) -> OperationClaim {
        lock.lock()
        defer { lock.unlock() }
        switch records[operationID] {
        case .finished(let result)?:
            return .alreadyRun(result)
        case .inProgress?:
            // A second caller while the first is still executing must not run the mutation:
            // returning `.claimed` here is exactly the both-execute failure the atomic
            // boundary exists to prevent.
            return .inProgress
        case nil:
            records[operationID] = .inProgress
            store.save(records)
            return .claimed
        }
    }

    /// Claims an operation that a previous process left in progress.
    ///
    /// Called at launch for records found in progress: the mutation may have happened, so the
    /// answer is `unknown` and the operation is recorded as settled. It is never re-executed.
    func reconstructInterrupted(_ operationID: String) -> OperationResult? {
        lock.lock()
        defer { lock.unlock() }
        guard case .inProgress? = records[operationID] else { return nil }
        let result = OperationResult.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight)
        records[operationID] = .finished(result)
        store.save(records)
        return result
    }

    /// Records the outcome of a claimed operation.
    func complete(_ operationID: String, result: OperationResult) {
        lock.lock()
        defer { lock.unlock() }
        records[operationID] = .finished(result)
        store.save(records)
    }

    /// The recorded result, or nil when the operation never ran or is still in progress.
    func result(for operationID: String) -> OperationResult? {
        lock.lock()
        defer { lock.unlock() }
        if case .finished(let result)? = records[operationID] { return result }
        return nil
    }

    /// The ids a previous process left in progress, in a stable order.
    func interruptedOperationIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { $0.value == .inProgress }.keys.sorted()
    }
}

/// An in-memory store for tests and for callers that do not need durability.
final class InMemoryOperationRecordStore: OperationRecordStore {
    private var records: [String: StoredRecord]
    init(records: [String: StoredRecord] = [:]) { self.records = records }
    func load() -> [String: StoredRecord] { records }
    func save(_ records: [String: StoredRecord]) { self.records = records }
}

/// A file-backed store, so the claim survives a process restart.
///
/// The encoding is deliberately small and total: an operation is either in progress or
/// finished, and a finished result is an outcome plus a reason. A record whose outcome this
/// build does not recognise is dropped rather than guessed at, and dropping it means the
/// operation is treated as genuinely new rather than reported with an outcome we invented.
final class FileOperationRecordStore: OperationRecordStore {
    private let url: URL

    init(url: URL) { self.url = url }

    func load() -> [String: StoredRecord] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return [:] }

        var records: [String: StoredRecord] = [:]
        for (operationID, fields) in raw {
            switch fields["state"] {
            case "inProgress":
                records[operationID] = .inProgress
            case "finished":
                guard let outcome = fields["outcome"].flatMap(OperationOutcome.init(rawValue:)) else { continue }
                records[operationID] = .finished(
                    outcome == .succeeded
                        ? .succeeded
                        : .nonSuccess(outcome, reason: fields["reason"] ?? OperationReason.interruptedInFlight)
                )
            default:
                // An unreadable record is treated as absent: the operation is not claimed, so
                // it will execute rather than be reported with an outcome we made up.
                continue
            }
        }
        return records
    }

    func save(_ records: [String: StoredRecord]) {
        var raw: [String: [String: String]] = [:]
        for (operationID, record) in records {
            switch record {
            case .inProgress:
                raw[operationID] = ["state": "inProgress"]
            case .finished(let result):
                var fields: [String: String] = [
                    "state": "finished",
                    "outcome": result.outcome.rawValue,
                ]
                if let reason = result.reason { fields["reason"] = reason }
                raw[operationID] = fields
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
