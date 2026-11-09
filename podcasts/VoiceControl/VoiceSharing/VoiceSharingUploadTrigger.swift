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

    init(uploader: VoiceSharingUploader,
         surfaceEnabled: @escaping () -> Bool = { VoiceSharingSettingsModel.surfaceEnabled },
         isAuthorized: @escaping () -> Bool) {
        self.uploader = uploader
        self.surfaceEnabled = surfaceEnabled
        self.isAuthorized = isAuthorized
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

    /// Stops accepting work. An in-flight pass is not cancelled: a recording is never left in an
    /// unknown state mid-request, and the pass ends on its own.
    func stop() {
        lock.lock()
        stopped = true
        pending = false
        lock.unlock()
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

    private func finish() {
        lock.lock()
        running = false
        let again = pending && !stopped
        pending = false
        lock.unlock()
        if again { trigger() }
    }
}