import Foundation
import PocketCastsUtils

/// The GUARDED production trigger for contribution uploads (task73 wiring): observes app
/// lifecycle events and runs one bounded scheduler drain — ONLY when every gate permits.
///
/// Gates, checked at EACH trigger:
/// 1. `VoiceSharingSettingsModel.surfaceEnabled` — the compiled-off constant. While it is false
///    this trigger does nothing at all; flipping it requires an owner-approved activation build.
/// 2. The live collection policy (`permitsCollection`) — re-read at trigger time, so a withdrawal
///    between events stops uploads immediately.
///
/// This type performs NO activation: with today's compiled constant the drain is unreachable, and
/// turning it on is an owner decision in a future build. It adds no locks around capture paths —
/// the drain runs on its own task and the scheduler serializes itself.
final class VoiceSharingUploadTrigger {
    private let scheduler: VoiceSharingUploadScheduler
    private let surfaceEnabled: () -> Bool
    private let isAuthorized: () -> Bool
    private var drainTask: Task<Void, Never>?

    init(
        scheduler: VoiceSharingUploadScheduler,
        surfaceEnabled: @escaping () -> Bool = { VoiceSharingSettingsModel.surfaceEnabled },
        isAuthorized: @escaping () -> Bool
    ) {
        self.scheduler = scheduler
        self.surfaceEnabled = surfaceEnabled
        self.isAuthorized = isAuthorized
        // The trigger rides the SAME lifecycle signal the rest of the app uses; a foreground
        // transition is when connectivity and credentials are most likely healthy.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        drainTask?.cancel()
    }

    /// The guarded entry a lifecycle event reaches. Also callable directly (background task
    /// expiration, push-to-sync) with the SAME gates — there is no unguarded path.
    func triggerDrainIfPermitted() {
        // Gate 1: compiled-off surface ⇒ literal no-op. This is what keeps the feature
        // unreachable in shipped builds regardless of policy or network state.
        guard surfaceEnabled() else { return }
        // Gate 2: live collection policy.
        guard isAuthorized() else { return }
        // Serialized by the scheduler itself; a second trigger while one drain runs is a no-op.
        guard drainTask == nil || drainTask?.isCancelled == true else { return }
        drainTask = Task { [scheduler] in
            _ = await scheduler.drainOnce()
        }
    }

    @objc private func appBecameActive() {
        triggerDrainIfPermitted()
    }
}