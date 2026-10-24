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
    /// Guards the in-flight bookkeeping only; never held across upload or credential work.
    private let stateLock = NSLock()
    private var drainInFlight = false
    private var activeToken: UUID?

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
        // SINGLE-FLIGHT, but LIFETIME-CORRECT (reviewer aa84564a / spec 0414c13d): a COMPLETED
        // drain is not "in flight", so the flag must be cleared when the drain ends — otherwise
        // every later foreground trigger is refused forever. Each drain carries its own token and
        // may only clear the slot it owns, so a later drain's slot is never clobbered by an
        // earlier one finishing. State lives on `stateLock`, never on the capture path.
        stateLock.lock()
        guard !drainInFlight else {
            stateLock.unlock()
            return
        }
        drainInFlight = true
        let token = UUID()
        activeToken = token
        stateLock.unlock()
        drainTask = Task { [scheduler] in
            // A REFUSED pass is not a completed one (spec a857340b): the scheduler reports `.busy`
            // when another pass owns it, and returning here would drop this trigger's work forever
            // (the new entry would wait for the NEXT foreground event). Re-offer once the current
            // pass ends, bounded, with no spin: the scheduler itself serializes, so the retry is
            // queued behind the owner rather than racing it.
            let outcome = await scheduler.drainOnce()
            guard case .busy = outcome else { return }
            // Yield to the owning pass, then offer this work exactly once more. Bounded by
            // construction: a second refusal ends the attempt instead of looping.
            await Task.yield()
            guard case .busy = await scheduler.drainOnce() else { return }
        }
        Task { [weak self] in
            await self?.drainTask?.value
            guard let self else { return }
            self.stateLock.lock()
            if self.activeToken == token {
                self.drainInFlight = false
                self.activeToken = nil
            }
            self.stateLock.unlock()
        }
    }

    @objc private func appBecameActive() {
        triggerDrainIfPermitted()
    }
}