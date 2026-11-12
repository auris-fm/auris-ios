import Foundation

/// Starts an upload pass when something suggests one may be useful.
///
/// Wakes on: a recording being published, sign-in restored, the app entering the foreground, and the
/// network returning. At most one pass runs at a time; a request that arrives during a pass is
/// remembered and served once that pass ends, so nothing is lost by arriving at a busy moment.
///
/// The feature is compiled off until an owner-approved activation build; while
/// `surfaceEnabled` is false this type does nothing at all.
final class VoiceSharingUploadTrigger {

    private let uploader: VoiceSharingUploader
    private let surfaceEnabled: () -> Bool
    private let isAuthorized: () -> Bool

    private let lock = NSLock()
    private var running = false
    private var pending = false
    private var stopped = false
    /// The one pending retry wake.
    private var retryWake: Task<Void, Never>?
    /// Cancels whatever the transport has in flight, so `stop()` reaches the transfer itself.
    private let cancelInFlight: () -> Void

    init(uploader: VoiceSharingUploader,
         surfaceEnabled: @escaping () -> Bool = { VoiceSharingSettingsModel.surfaceEnabled },
         isAuthorized: @escaping () -> Bool,
         cancelInFlight: @escaping () -> Void = {}) {
        self.uploader = uploader
        self.surfaceEnabled = surfaceEnabled
        self.isAuthorized = isAuthorized
        self.cancelInFlight = cancelInFlight
    }

    /// Asks for a pass. Returns immediately; the pass runs on its own task.
    ///
    /// There is no permanent latch: `stop()` halts the current work, and the next permission —
    /// sharing turned back on, a new recording, the app foregrounded — resumes it via this same call.
    func trigger() {
        guard surfaceEnabled() else { return }
        lock.lock()
        if stopped {
            // A pass is only refused while sharing is actually off. Re-reading the live
            // authorization here means turning sharing back on needs no separate re-enable call.
            guard !isAuthorized() else {
                stopped = false
                lock.unlock()
                trigger()
                return
            }
            lock.unlock()
            return
        }
        if running {
            // One remembered request is enough: the pass that is about to finish will serve it.
            pending = true
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        Task { [weak self] in await self?.run() }
    }

    /// Stops the trigger AND cancels the request in flight. Setting a flag alone would leave a
    /// recording already on the wire still travelling to the server after consent was withdrawn.
    func stop() {
        lock.lock()
        stopped = true
        pending = false
        retryWake?.cancel()
        retryWake = nil
        lock.unlock()
        // The transfer is cancelled, not merely left to finish: a recording must not keep
        // travelling to the server after the user said stop.
        cancelInFlight()
    }

    /// Test seam: whether a pass is currently running.
    var isRunningForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Test seam: whether a pass is running OR one has been requested and not yet served. A
    /// `trigger()` that finds a pass already in flight only REMEMBERS the request, so waiting on
    /// `isRunningForTesting` alone returns while that queued pass is still owed — and a control that
    /// asserted right there would be racing the work it asked for.
    var hasPendingOrRunningWorkForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return running || pending
    }

    private func run() async {
        defer { finish() }
        guard isAuthorized() else { return }
        await uploader.drain()
    }

    /// Arms the single wake that a retry needs. Called after a pass that left work behind: without
    /// it a quiet app would keep a recording indefinitely, waiting for an unrelated event to happen.
    /// Re-arming replaces the previous wake, so there is never more than one pending.
    func armRetryWake() async {
        guard surfaceEnabled() else { return }
        guard let delay = await uploader.secondsUntilNextRetry() else {
            lock.lock(); retryWake?.cancel(); retryWake = nil; lock.unlock()
            return
        }
        // The slot is read and written under the same lock `stop()` takes, so arming and stopping
        // cannot interleave into a timer that outlives the stop.
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        retryWake?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.trigger()
        }
        retryWake = task
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        running = false
        let again = pending && !stopped
        pending = false
        lock.unlock()
        if again { trigger() }
        // A pass that left an entry inside its backoff window owes the app a wake when it is due.
        Task { await armRetryWake() }
    }
}