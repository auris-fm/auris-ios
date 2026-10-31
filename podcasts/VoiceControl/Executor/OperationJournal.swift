import CryptoKit
import Foundation

/// Production surface for an operation outcome the server must be able to reason about.
///
/// The wire contract (`app_operation_result`, core-app-tools rev da327e624) makes the refusal a
/// frame the server reads. A stored field only tests read is not a surface (PR #49 review
/// 4305981598): sinks report every non-success outcome here, and the assembly owns the transport
/// wiring. `context` names what was refused in machine terms (action/reason origin), kept free of
/// user-visible prose.
protocol CloudOperationResultConsuming: AnyObject {
    func consume(_ result: OperationResult, context: String)
}

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

    /// Whether a turn with this outcome may be RE-DRIVEN.
    ///
    /// The admission predicate is `(unknown ∨ failed) ∧ idempotent` — **not**
    /// `wasFailure(outcome)`. Stated by the cloud side from the turn contract:
    ///
    ///   * `succeeded` is a settled FACT. An empty state is a real answer ("the app looked and
    ///     there is nothing"), not an absence, so replaying it contradicts an answer already given.
    ///   * `refused` is a settled DECISION — the app declined BEFORE acting. Replaying contradicts
    ///     its answer.
    ///   * `failed` means the app TRIED and did not complete. A non-idempotent failed operation may
    ///     already have had its effect, so `failed` alone is NOT a retry signal.
    ///   * `unknown` is the one that says nothing was established — "do not reason as if it did or
    ///     did not happen".
    ///
    /// The `idempotent` conjunct is what stops this being permissive in exactly the case where
    /// permissiveness has consequences: a NON-IDEMPOTENT operation that failed.
    /// The switch below is EXHAUSTIVE with no `default`, and that is deliberate: a new case added
    /// to this enum fails the BUILD here rather than silently taking a default branch. The cloud
    /// lane lost a refusal code to the opposite arrangement — a hand-written allow-list that drifted
    /// from the source union, so a code reached the client as an unrecognised server fault and
    /// nothing failed, because the list had no coverage. A compiler-enforced switch cannot drift.
    func admitsReplay(isIdempotent: Bool) -> Bool {
        guard isIdempotent else { return false }
        switch self {
        case .unknown, .failed:
            return true
        case .succeeded, .refused, .cancelled:
            return false
        }
    }

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
    /// The ACTUAL resulting state AT SETTLEMENT, typed per the owning family. Replay contract:
    /// the stored state — not a fresh reading of current playback — is what a redelivery answers
    /// with, so an unrelated later operation cannot rewrite a settled answer.
    let state: [String: CloudRouteJSONValue]?

    private init(outcome: OperationOutcome, reason: String?, state: [String: CloudRouteJSONValue]?) {
        self.outcome = outcome
        self.reason = reason
        self.state = state
    }

    /// A non-success result carries a reason and NO state; success carries its settled state.
    static func nonSuccess(_ outcome: OperationOutcome, reason: String) -> OperationResult {
        precondition(outcome != .succeeded, "success is not a non-success outcome")
        return OperationResult(outcome: outcome, reason: reason, state: nil)
    }

    static func succeeded(state: [String: CloudRouteJSONValue]) -> OperationResult {
        OperationResult(outcome: .succeeded, reason: nil, state: state)
    }
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
    /// Wire-pinned (cloud-assistant.md @ bf5fb219): a required identity precondition is
    /// missing — the operation is malformed, refused before any execution.
    static let invalidRequest = "invalid_request"
    /// The exactly-once record could not be durably persisted (or existing history is
    /// unreadable): the mutation is refused before any effect rather than risking an
    /// unrecorded execution.
    static let persistenceUnavailable = "persistence_unavailable"
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

    /// The seek request carried both target forms, neither, or a value that could not be
    /// parsed. Nothing was sought: the request does not say where to go.
    static let malformedSeekTarget = "malformed_seek_target"

    /// The target is expressed in reference (transcript) time, and this client cannot map it to
    /// playback time. No position was changed, and the seek must not be performed at the raw
    /// reference value: on a mapped episode that is a different position.
    static let referenceMappingUnavailable = "reference_mapping_unavailable"

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

    /// Every reason this client can put on the wire. Kept as one list so the wire grammar can be
    /// checked against the whole vocabulary rather than only the tokens a test happens to name.
    static let allWireReasons: [String] = [
        clientPolicy, stalePrecondition, unsupportedOperation, invalidRequest,
        persistenceUnavailable, missingEntitlement, audioSessionDenied, malformedSeekTarget,
        referenceMappingUnavailable, volumeControlUnavailable, sinkUnimplemented,
        supersededByPreemption, cancelledByUser, turnBudgetExhausted, interruptedInFlight,
    ]
}

/// The result of claiming an operation for execution.
enum OperationClaim: Equatable {
    /// This caller is the first to claim it: run the operation, then `complete`.
    case claimed
    /// Another caller holds the claim and is still executing: do not run the operation.
    case inProgress
    /// The exactly-once record could not be durably persisted (or history is unreadable):
    /// the mutation is refused fail-closed, never executed unrecorded.
    case persistenceUnavailable
    /// The operation already ran, and this is what happened.
    case alreadyRun(OperationResult)
    /// The id is already recorded against DIFFERENT contents, or a different owner,
    /// conversation or turn. The amendment is explicit: the same id with different contents is a
    /// different operation, refused rather than executed under the old identity — which would
    /// apply an effect no record accounts for.
    case identityConflict
    /// A previous process claimed the operation and did not record an outcome — the app was
    /// interrupted while the mutation was in flight. The effect is not knowable: the operation
    /// must NOT be executed again, and its result is `unknown`.
    case interrupted(OperationResult)
}

/// Storage for the journal's records. Separated so the journal's rules are testable without a
/// real file, and so the durable backing can change without changing those rules.
protocol OperationRecordStore {
    func load() -> [String: StoredRecord]
    /// Persists the whole record map. Returns false when persistence FAILED — the journal
    /// treats a failed claim write as fail-closed (refuse the effect), never silent.
    @discardableResult
    func save(_ records: [String: StoredRecord]) -> Bool

    /// Distinguishes "no history yet" from "history present but unreadable": corrupt history
    /// must fail closed, never silently become empty.
    func loadResult() -> OperationRecordLoadResult
}

enum OperationRecordLoadResult {
    case loaded([String: StoredRecord])
    case unreadable
}

/// WHO an app operation belongs to, and WHICH bytes it was.
///
/// The amendment (cloud-assistant.md @ bf5fb219) does not let an operation id stand alone: the id
/// is server-issued and turn-bound, a redelivery within a turn must carry byte-identical
/// serialized action, and the same id with different contents is a DIFFERENT operation the
/// client refuses rather than executes.
struct OperationIdentity {
    /// The authenticated account the turn was opened for.
    let owner: String
    /// The conversation the turn belongs to.
    let conversation: String
    /// The turn the operation was issued in. An id never spans turns.
    let turn: String
    /// The exact serialized UTF-8 action the server sent. Replay identity is BYTE equality.
    let actionBytes: Data

    /// The identity as persisted and re-read: the digest this identity carries.
    ///
    /// A persisted record stores the digest, not the frame — the frame's bytes are not needed
    /// again (a replay answers with the settled result). Re-reading must therefore yield a value
    /// whose `actionDigest` IS that stored digest, which is why an identity can be built from a
    /// validated digest instead of being re-hashed on the way in.
    var actionDigest: String {
        if let digest = knownDigest { return digest }
        return Self.digest(of: actionBytes)
    }

    /// Set only for an identity reconstructed from a persisted digest; nil for a live one.
    private let knownDigest: String?

    init(owner: String, conversation: String, turn: String, actionBytes: Data) {
        self.owner = owner
        self.conversation = conversation
        self.turn = turn
        self.actionBytes = actionBytes
        self.knownDigest = nil
    }

    /// Rebuilds an identity from what a record persisted. The digest is used AS PERSISTED — it is
    /// never hashed again, which is what makes a restart compare digest-to-digest. `actionBytes`
    /// carries the digest text so two identities cannot look equal while differing in identity.
    init?(persistedOwner owner: String, conversation: String, turn: String, digest: String) {
        guard !owner.isEmpty, !conversation.isEmpty, !turn.isEmpty, !digest.isEmpty else {
            return nil
        }
        self.owner = owner
        self.conversation = conversation
        self.turn = turn
        self.actionBytes = Data(digest.utf8)
        self.knownDigest = digest
    }

    /// Hex SHA-256 of the original bytes. An identity token, not a security primitive.
    static func digest(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

extension OperationIdentity: Equatable {
    /// Equality is on the identity's MEANING, not its storage form: a live identity holds the
    /// frame's bytes and a reopened one holds the digest that was persisted, so comparing
    /// `actionBytes` would report a redelivery as a different operation purely because the
    /// process restarted. The digest is the same value in both forms (`actionDigest`), which is
    /// exactly why it is persisted.
    static func == (lhs: OperationIdentity, rhs: OperationIdentity) -> Bool {
        lhs.owner == rhs.owner
            && lhs.conversation == rhs.conversation
            && lhs.turn == rhs.turn
            && lhs.actionDigest == rhs.actionDigest
    }
}

/// One operation's persisted state.
enum StoredRecord: Equatable {
    /// The claim WITH the identity it was claimed under: a redelivery is answered only when the
    /// identity matches byte-for-byte, so the record has to keep it.
    case inProgress(OperationIdentity)
    case finished(OperationIdentity, OperationResult)
}

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
/// Maps `operation_id` to the state of the operation it names, so a redelivered operation is
/// answered from the record instead of being executed a second time — including across a
/// process restart, which is the case the durable store exists for.
///
/// PHASE STATUS (PR #49 review 4305981658): this type has NO production constructor, and that
/// is deliberate, not a gap. Its records are keyed on `operation_id`, which the normative
/// cloud-multiturn wire contract (core-app-tools `app-operation-wire-contract.md`, rev
/// da327e624) does not put on today's actions — no cloud-multiturn action carries an
/// operation identity, so any wiring here would have to fabricate keys, and a fabricated key
/// defeats exactly-once: the same logical action redelivered would claim a fresh id and run
/// again. The journal becomes wireable when actions carry server-assigned identities (the
/// `app_operation_result` frame's contract already names the shape); until then it stays a
/// fully tested building block and no reading of existing guarantees should cite it.
///
final class OperationJournal {
    private let store: OperationRecordStore
    private var records: [String: StoredRecord]
    private let lock = NSLock()

    init(store: OperationRecordStore) {
        self.store = store
        switch store.loadResult() {
        case .loaded(let loaded): self.records = loaded
        case .unreadable:
            // Corrupt/unreadable durable history fails CLOSED: every claim is refused rather
            // than running mutations that could not be exactly-once recorded.
            self.records = [:]
            self.persistenceUnavailable = true
        }
    }

    /// True when durable history was unreadable at load or a claim/settlement write failed.
    private var persistenceUnavailable = false

    /// Atomically claims the operation for execution.
    ///
    /// The claim is persisted before it is returned, so an interruption after this point is
    /// reconstructible as `.interrupted` rather than silently forgotten.
    func claim(_ operationID: String, identity: OperationIdentity) -> OperationClaim {
        lock.lock()
        defer { lock.unlock() }
        switch records[operationID] {
        case .finished(let recorded, let result)?:
            // Replay identity is BYTE equality on the original serialized action plus the
            // owner/conversation/turn triple: same id + same identity = a redelivery answered
            // from the record; same id + anything else = a different operation, refused.
            guard recorded == identity else { return .identityConflict }
            return .alreadyRun(result)
        case .inProgress(let recorded)?:
            guard recorded == identity else { return .identityConflict }
            // A second caller while the first is still executing must not run the mutation:
            // returning `.claimed` here is exactly the both-execute failure the atomic
            // boundary exists to prevent.
            return .inProgress
        case nil:
            if persistenceUnavailable { return .persistenceUnavailable }
            records[operationID] = .inProgress(identity)
            guard store.save(records) else {
                // Fail closed: an unrecorded claim must never reach the effect. Revert and
                // refuse every further claim until persistence is healthy again.
                records.removeValue(forKey: operationID)
                persistenceUnavailable = true
                return .persistenceUnavailable
            }
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
        guard case .inProgress(let identity)? = records[operationID] else { return nil }
        let result = OperationResult.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight)
        // Persist FIRST, publish second: a failed settlement write must leave the durable
        // record in progress (still interrupted, never executable) and NOT report settled
        // unknown that disk never saw.
        var updated = records
        updated[operationID] = .finished(identity, result)
        guard store.save(updated) else {
            persistenceUnavailable = true
            return nil
        }
        records = updated
        return result
    }

    /// Records the outcome of a claimed operation.
    /// Settles a claimed operation. Returns false when the settlement could NOT be persisted:
    /// the in-memory record then stays in progress and the caller must not report success.
    /// Settles a claimed operation UNDER THE IDENTITY IT WAS CLAIMED WITH.
    ///
    /// The identity is required, not decorative: a settlement that could name any identity would
    /// let a second, different operation rewrite a durable result. Callers pass back the identity
    /// they claimed with, and a settlement that does not match the recorded claim is refused —
    /// as is settling an operation that was never claimed or is already settled.
    @discardableResult
    func complete(_ operationID: String, identity: OperationIdentity, result: OperationResult) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .inProgress(let claimed)? = records[operationID] else { return false }
        guard claimed == identity else { return false }
        var updated = records
        updated[operationID] = .finished(identity, result)
        guard store.save(updated) else {
            persistenceUnavailable = true
            return false
        }
        records = updated
        return true
    }

    /// The recorded result, or nil when the operation never ran or is still in progress.
    func result(for operationID: String) -> OperationResult? {
        lock.lock()
        defer { lock.unlock() }
        if case .finished(_, let result)? = records[operationID] { return result }
        return nil
    }

    /// The ids a previous process left in progress, in a stable order.
    func interruptedOperationIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { record in
            if case .inProgress = record.value { return true }
            return false
        }.keys.sorted()
    }
}

/// An in-memory store for tests and for callers that do not need durability.
final class InMemoryOperationRecordStore: OperationRecordStore {
    private var records: [String: StoredRecord]
    init(records: [String: StoredRecord] = [:]) { self.records = records }
    func load() -> [String: StoredRecord] { records }
    @discardableResult
    func save(_ records: [String: StoredRecord]) -> Bool { self.records = records; return true }
    func loadResult() -> OperationRecordLoadResult { .loaded(records) }
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
        switch loadResult() {
        case .loaded(let records): return records
        case .unreadable: return [:]
        }
    }

    func loadResult() -> OperationRecordLoadResult {
        // Classify the ACTUAL read error: only genuine not-found is fresh history. Presence
        // heuristics (fileExists) cannot establish absence — permissions/I/O failures refuse.
        do {
            let data = try Data(contentsOf: url)
            return try Self.decodeFile(data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .loaded([:])
        } catch {
            return .unreadable
        }
    }

    private static func decodeFile(_ data: Data) throws -> OperationRecordLoadResult {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else {
            return .unreadable // present but undecodable: fail closed, never silently empty
        }
        var records: [String: StoredRecord] = [:]
        for (operationID, fields) in raw {
            // Every record must carry its identity: without one it cannot tell a redelivery from
            // a different operation, and history we cannot settle that question for is corrupt,
            // not absent. A record predating identity is therefore unreadable → fail closed.
            guard let identity = Self.decodeIdentity(fields) else { return .unreadable }
            switch fields["state"] {
            case "inProgress":
                records[operationID] = .inProgress(identity)
            case "finished":
                guard let outcome = fields["outcome"].flatMap(OperationOutcome.init(rawValue:)) else {
                    return .unreadable // a bogus outcome is corruption, not absence
                }
                if outcome != .succeeded && fields["reason"]?.isEmpty != false {
                    // A stored nonsuccess without its reason is corrupt: never fabricate
                    // interrupted_in_flight for a reason the file did not carry.
                    return .unreadable
                }
                if outcome == .succeeded {
                    // Replay contract: the settled state is PART of the record. A success
                    // without its state is corrupt history, not a stateless success.
                    guard let raw = fields["result_state"],
                          let data = raw.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data),
                          let state = json as? [String: Any],
                          !state.isEmpty
                    else { return .unreadable }
                    var typed: [String: CloudRouteJSONValue] = [:]
                    for (key, value) in state {
                        guard let item = CloudRouteJSONValue(json: value) else { return .unreadable }
                        typed[key] = item
                    }
                    records[operationID] = .finished(identity, .succeeded(state: typed))
                } else {
                    records[operationID] = .finished(
                        identity, .nonSuccess(outcome, reason: fields["reason"]!)
                    )
                }
            default:
                // An unknown state is semantically corrupt: the whole history is unreadable,
                // so no id in it can silently re-claim and execute.
                return .unreadable
            }
        }
        return .loaded(records)
    }

    /// The persisted identity, or nil when a field is missing/empty. The digest is taken AS
    /// PERSISTED (see `OperationIdentity.init(persistedOwner:…)`): hashing the stored text again
    /// would make a restarted process compare `SHA256(digest)` against `SHA256(frame)` and refuse
    /// a legitimate replay.
    private static func decodeIdentity(_ fields: [String: String]) -> OperationIdentity? {
        guard let owner = fields["owner"],
              let conversation = fields["conversation"],
              let turn = fields["turn"],
              let digest = fields["action_sha256"]
        else { return nil }
        return OperationIdentity(
            persistedOwner: owner, conversation: conversation, turn: turn, digest: digest
        )
    }

    private static func encodeIdentity(_ identity: OperationIdentity) -> [String: String] {
        [
            "owner": identity.owner,
            "conversation": identity.conversation,
            "turn": identity.turn,
            "action_sha256": identity.actionDigest,
        ]
    }

    @discardableResult
    func save(_ records: [String: StoredRecord]) -> Bool {
        var raw: [String: [String: String]] = [:]
        for (operationID, record) in records {
            switch record {
            case .inProgress(let identity):
                var fields = Self.encodeIdentity(identity)
                fields["state"] = "inProgress"
                raw[operationID] = fields
            case .finished(let identity, let result):
                var fields: [String: String] = [
                    "state": "finished",
                    "outcome": result.outcome.rawValue,
                ]
                for (key, value) in Self.encodeIdentity(identity) { fields[key] = value }
                if let reason = result.reason { fields["reason"] = reason }
                if let state = result.state,
                   let data = try? JSONSerialization.data(
                        withJSONObject: state.mapValues { $0.toJSONSerializable() }
                   ),
                   let encoded = String(data: data, encoding: .utf8) {
                    fields["result_state"] = encoded
                }
                raw[operationID] = fields
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              (try? data.write(to: url, options: .atomic)) != nil
        else { return false }
        return true
    }
}


/// Durable backing: one JSON file in Application Support. Whole-file rewrite per save — record
/// counts are bounded by resolved operations, and the write happens inside the journal's critical
/// section, so last-writer consistency is sufficient for the exactly-once contract.
