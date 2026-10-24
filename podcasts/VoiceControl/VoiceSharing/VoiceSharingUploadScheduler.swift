import Foundation
import PocketCastsUtils

/// The composition point that actually DRAINS the queue: picks ready entries in age order and
/// drives each through the uploader, honoring the queue's own enforced boundaries.
///
/// Deliberately minimal and SERIALIZED (spec: "One entry has at most one in-flight request"; the
/// queue's `admitAttempt` refuses concurrent ownership anyway). One drain task at a time; callers
/// re-invoke `drainOnce` when state changes (app foreground, new entry finalized, retry boundary
/// passing). This type does not spin, sleep on timers, or own a wake schedule — it executes one
/// bounded pass and reports what happened.
final class VoiceSharingUploadScheduler {
    /// What one bounded pass did.
    enum PassOutcome {
        /// Nothing was eligible (empty, held, or every entry behind its not-before boundary).
        case idle
        /// ANOTHER PASS OWNS THIS SCHEDULER, so this call attempted NOTHING. Distinct from `.idle`
        /// (reviewer/spec a857340b): a refused pass reports "try again shortly", while `.idle` says
        /// "there was nothing to do". Conflating them let a foreground trigger be silently dropped
        /// whenever a drain was already running.
        case busy
        /// Every entry result, in the order attempted.
        case drained([(entry: VoiceSharingUploadQueue.Entry, outcome: VoiceSharingUploader.Outcome)])
    }

    /// DIAGNOSTIC (spec a857340b): the identity of the scheduler that most recently REFUSED a pass,
    /// so a competing pass can be attributed to a specific instance instead of assumed. Guarded by
    /// `passLock` — these are written from pass paths and read from tests.
    private var lastRefusedPassByDiagnosticStorage: (scheduler: ObjectIdentifier, at: Date)?
    private var lastIdleDecisionByDiagnosticStorage: (discovery: String, at: Date)?

    var lastRefusedPassByDiagnostic: (scheduler: ObjectIdentifier, at: Date)? {
        passLock.withLock { lastRefusedPassByDiagnosticStorage }
    }

    var lastIdleDecisionByDiagnostic: (discovery: String, at: Date)? {
        passLock.withLock { lastIdleDecisionByDiagnosticStorage }
    }

    /// OWNER-COMPLETION SIGNAL (reviewer 280f4c52). A refused caller used to have no way to learn
    /// when the owner finished, so recovering from `.busy` meant polling. This is the atomic
    /// handshake: `registerOwnerCompletion` answers whether this caller already OWNS the scheduler,
    /// and if it does not, installs the callback under the SAME lock — so a completion that lands
    /// between the busy result and the registration cannot be missed, and the callback is fired
    /// exactly once when the owning pass ends.
    struct OwnerCompletion {
        let assumedOwnership: Bool
        let id: UUID
    }

    private var ownerCompletionWaiters: [UUID: () -> Void] = [:]

    func registerOwnerCompletion(_ body: @escaping () -> Void) -> OwnerCompletion {
        passLock.lock()
        if !passInFlight {
            // Free right now: the caller may simply run rather than wait for someone else.
            passLock.unlock()
            return OwnerCompletion(assumedOwnership: true, id: UUID())
        }
        let id = UUID()
        ownerCompletionWaiters[id] = body
        passLock.unlock()
        return OwnerCompletion(assumedOwnership: false, id: id)
    }

    /// The scheduler's ownership state, read under the same lock the pass uses.
    var isPassInFlightForTesting: Bool {
        passLock.withLock { passInFlight }
    }

    /// Cancels a completion registration (a cancelled caller must not be woken).
    func cancelOwnerCompletion(_ id: UUID) {
        passLock.withLock { ownerCompletionWaiters.removeValue(forKey: id) }
    }

    private let queue: VoiceSharingUploadQueue
    private let uploader: VoiceSharingUploader
    private let isAuthorized: () -> Bool
    /// Max entries attempted per pass: a bounded pass cannot pin the caller forever.
    private let maxEntriesPerPass: Int
    /// Serializes passes: a second concurrent drain is refused, not interleaved.
    private let passLock = NSLock()
    private var passInFlight = false

    init(
        queue: VoiceSharingUploadQueue,
        uploader: VoiceSharingUploader,
        isAuthorized: @escaping () -> Bool,
        maxEntriesPerPass: Int = 8
    ) {
        self.queue = queue
        self.uploader = uploader
        self.isAuthorized = isAuthorized
        self.maxEntriesPerPass = maxEntriesPerPass
    }

    /// One bounded drain pass. Never throws into the caller.
    ///
    /// Authorization gates the WHOLE pass (no bytes leave without live permission), but the
    /// entries themselves are attempted through the uploader, which re-checks and enforces the
    /// queue's coverage hold, attempt leases and not-before boundaries.
    func drainOnce() async -> PassOutcome {
        // Refuse a concurrent second pass: serialized by construction. The refusal is REPORTED as
        // `.busy`, not `.idle`, so a caller can tell "another pass owns this" from "nothing to do".
        guard passLock.withLockElse({ !passInFlight }, set: { passInFlight = true }) else {
            passLock.withLock {
                lastRefusedPassByDiagnosticStorage = (ObjectIdentifier(self), Date())
            }
            return .busy
        }
        defer {
            // THE OWNER IS DONE: fire every waiter so a refused caller can re-offer exactly once.
            // Taken and cleared under the lock, then invoked outside it.
            let waiters: [() -> Void] = passLock.withLock {
                passInFlight = false
                let pending = Array(ownerCompletionWaiters.values)
                ownerCompletionWaiters.removeAll()
                return pending
            }
            for waiter in waiters { waiter() }
        }
        guard isAuthorized() else { return .idle }
        // Neither unknown coverage nor a revocation hold may feed the scheduler: both yield
        // nothing here (the same fail-closed rule serving uses).
        let discovery = queue.readyEntriesReportingUnknownCoverage()
        guard case .known(let ready) = discovery, !ready.isEmpty else {
            // DIAGNOSTIC (reviewer 08e42a5a): `.idle` has two very different causes — an empty
            // served set versus a held one — and inferring between them from the outside was
            // wrong. Record what the decision actually saw.
            passLock.withLock {
                lastIdleDecisionByDiagnosticStorage = (discovery: String(describing: discovery), at: Date())
            }
            return .idle
        }

        var results: [(entry: VoiceSharingUploadQueue.Entry, outcome: VoiceSharingUploader.Outcome)] = []
        for entry in ready.prefix(maxEntriesPerPass) {
            // Live authorization is re-checked per entry: a withdrawal mid-pass stops it.
            guard isAuthorized() else { break }
            let outcome = await uploader.upload(entry)
            results.append((entry, outcome))
            // A revocation mid-pass ends the pass entirely: the queue is being purged.
            if case .revoked = outcome { break }
        }
        return results.isEmpty ? .idle : .drained(results)
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }

    fileprivate func withLockElse(_ condition: () -> Bool, set: () -> Void) -> Bool {
        lock()
        defer { unlock() }
        if condition() {
            set()
            return true
        }
        return false
    }
}