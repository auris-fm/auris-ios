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
        /// Every entry result, in the order attempted.
        case drained([(entry: VoiceSharingUploadQueue.Entry, outcome: VoiceSharingUploader.Outcome)])
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
        // Refuse a concurrent second pass: serialized by construction.
        guard passLock.withLockElse({ !passInFlight }, set: { passInFlight = true }) else {
            return .idle
        }
        defer { passLock.withLock { passInFlight = false } }
        guard isAuthorized() else { return .idle }
        // Unknown coverage must never feed the scheduler: `.unknownCoverage` yields nothing here
        // (the same fail-closed rule serving uses).
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(), !ready.isEmpty
        else { return .idle }

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