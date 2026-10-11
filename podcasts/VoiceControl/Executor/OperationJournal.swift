import Foundation

/// The outcome of an app operation the server asked this client to perform.
///
/// The case set is the wire contract's; `refused` and `failed` are separated because they
/// prompt different follow-ups — a refusal is a policy answer the model can relay, a failure
/// is something to retry or report.
enum OperationOutcome: String, Equatable {
    case succeeded
    case refused
    case failed
    case cancelled
    case unknown

    /// A machine-readable code for the non-success cases, drawn from the reasons an action
    /// actually fails on this client.
    ///
    /// `stalePrecondition` covers an episode/queue/bookmark that changed between the
    /// server's proposal and execution; `clientPolicy` is the capture gate's own refusals,
    /// which are a different rule from action eligibility and prompt a different reply.
    var reasonCode: String? {
        switch self {
        case .succeeded: return nil
        case .refused: return "client_policy"
        case .failed: return "stale_precondition"
        case .cancelled: return nil
        case .unknown: return "sink_unimplemented"
        }
    }
}

/// Maps `operation_id -> prior outcome`, so a redelivered operation is answered from the
/// journal instead of being executed a second time.
///
/// The dedup rule is about the MUTATION, not the answer: the result may be re-sent any
/// number of times — a reconnecting client needs the redelivery answered — but the mutation
/// itself must run once. That is why lookup and record are separate calls rather than one
/// "execute once" wrapper: the caller decides where execution happens, and the journal only
/// remembers.
///
/// Unbounded by design for now: entries are small and the population is one per server
/// operation. If that ever needs a bound, the eviction rule has to keep entries whose
/// redelivery is still plausible, which is a property of the server's retry window rather
/// than of this type.
final class OperationJournal {
    private var outcomes: [String: OperationOutcome] = [:]
    private let lock = NSLock()

    /// The prior outcome for this operation, or nil when it has not run.
    func outcome(for operationID: String) -> OperationOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcomes[operationID]
    }

    /// Records the outcome of an operation that has just run.
    func record(_ operationID: String, outcome: OperationOutcome) {
        lock.lock()
        defer { lock.unlock() }
        outcomes[operationID] = outcome
    }
}
