import Foundation

/// The outcome of an app operation the server asked this client to perform.
///
/// `unknown` is reserved for a sink that answered nothing at all — a crash, a timeout, a
/// missing implementation of the operation's family. A sink that *refuses* is not unknown:
/// it answered, with a policy or a precondition failure, and the case for that is `refused`.
/// Collapsing the two would tell the server a thing crashed when in fact the client declined.
enum OperationOutcome: String, Equatable {
    case succeeded
    case refused
    case failed
    case cancelled
    case unknown

    /// The agreed reason for `cancelled` is pending with @cloud's frame proposal; until it
    /// lands, a cancellation records the outcome without a code rather than borrowing one
    /// from a different failure.
    var reasonCode: String? {
        switch self {
        case .succeeded, .cancelled: return nil
        case .refused: return "client_policy"
        case .failed: return "stale_precondition"
        case .unknown: return "sink_unimplemented"
        }
    }
}

/// The result of claiming an operation for execution.
enum OperationClaim: Equatable {
    /// This caller is the first to claim it: run the operation, then `complete`.
    case claimed
    /// Another caller holds the claim and is still executing: do not run the operation.
    case inProgress
    /// The operation already ran, and this is what happened.
    case alreadyRun(OperationOutcome)
}

/// Maps `operation_id` to the state of the operation it names, so a redelivered operation is
/// answered from the record instead of being executed a second time.
///
/// The claim is atomic. A lock around separate "has it run?" and "mark it running" calls
/// would not be: two callers can both see the operation absent and both proceed to execute.
/// `claim` performs the check and the transition in one critical section, so exactly one
/// caller receives `.claimed` and every later one receives the outcome.
///
/// The disposition on a crash is deliberately absent from this type: an in-memory journal
/// forgets everything when the process dies, so a redelivery after a crash is answered by
/// executing again. A durable record is a separate change, and noting the gap here is what
/// keeps it visible rather than assumed away.
final class OperationJournal {
    private enum State {
        case inProgress
        case finished(OperationOutcome)
    }

    private var states: [String: State] = [:]
    private let lock = NSLock()

    /// Atomically claims the operation for execution.
    ///
    /// - Returns: `.claimed` for the first caller, or `.alreadyRun(outcome)` when the
    ///   operation has already completed and the outcome is the answer to redelivery.
    func claim(_ operationID: String) -> OperationClaim {
        lock.lock()
        defer { lock.unlock() }
        switch states[operationID] {
        case .finished(let outcome)?:
            return .alreadyRun(outcome)
        case .inProgress?:
            // A second caller while the first is still executing must not run the mutation:
            // returning `.claimed` here is the both-execute failure the atomic boundary
            // exists to prevent.
            return .inProgress
        case nil:
            states[operationID] = .inProgress
            return .claimed
        }
    }

    /// Records the outcome of a claimed operation, releasing it for no further execution.
    ///
    /// A crash before this call leaves the operation recorded as in-progress with no
    /// outcome — see the disposition note on the type.
    func complete(_ operationID: String, outcome: OperationOutcome) {
        lock.lock()
        defer { lock.unlock() }
        states[operationID] = .finished(outcome)
    }

    /// The recorded outcome, or nil when the operation never ran or is still in progress.
    func outcome(for operationID: String) -> OperationOutcome? {
        lock.lock()
        defer { lock.unlock() }
        if case .finished(let outcome)? = states[operationID] { return outcome }
        return nil
    }
}
