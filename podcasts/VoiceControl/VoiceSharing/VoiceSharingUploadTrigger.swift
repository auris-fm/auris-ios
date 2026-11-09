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
    private let onStop: (() -> Void)?

    init(uploader: VoiceSharingUploader,
         surfaceEnabled: @escaping () -> Bool = { VoiceSharingSettingsModel.surfaceEnabled },
         isAuthorized: @escaping () -> Bool,
         onStop: (() -> Void)? = nil) {
        self.uploader = uploader
        self.surfaceEnabled = surfaceEnabled
        self.isAuthorized = isAuthorized
        self.onStop = onStop
    }

    /// Asks for a pass. Returns immediately; the pass runs on its own task.
    func trigger() {
        guard surfaceEnabled() else { return }
        lock.lock()
        if stopped { lock.unlock(); return }
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
        let cancel = onStop
        lock.unlock()
        cancel?()
    }

    /// Test seam: whether a pass is currently running.
    var isRunningForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
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
        retryWake?.cancel()
        guard let delay = await uploader.secondsUntilNextRetry() else {
            retryWake = nil
            return
        }
        lock.lock()
        let allowed = !stopped
        lock.unlock()
        guard allowed else { return }
        retryWake = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.trigger()
        }
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