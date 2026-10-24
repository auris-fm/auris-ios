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
    /// WORK THAT ARRIVED WHILE A DRAIN WAS RUNNING (reviewer 44d39ef8). Previously an event during
    /// a drain was dropped outright by the guard below, and a `.busy` refusal was "retried" with
    /// `Task.yield` — which does not await the owner, so both attempts could finish refused and the
    /// event was lost anyway. The flag is the handoff: whoever COMPLETES a drain re-offers once.
    private var workPending = false

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
        // CANCELLATION IS HONOURED (reviewer 44d39ef8): a cancelled drain must not start a
        // follow-up, so the slot is cleared and any pending work is discarded with the object.
        drainTask?.cancel()
        stateLock.lock()
        drainInFlight = false
        activeToken = nil
        workPending = false
        stateLock.unlock()
    }

    /// Test seam: await the current drain (used by controls that must observe the FOLLOW-UP pass
    /// started automatically on completion).
    func awaitCurrentDrainForTesting() async {
        let task = drainTask
        await task?.value
    }

    /// Test seam: whether a drain currently owns the slot.
    var isDrainingForTesting: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return drainInFlight
    }

    /// The guarded entry a lifecycle event reaches. Also callable directly (background task
    /// expiration, push-to-sync) with the SAME gates — there is no unguarded path.
    func triggerDrainIfPermitted() {
        // Gate 1: compiled-off surface ⇒ literal no-op. This is what keeps the feature
        // unreachable in shipped builds regardless of policy or network state.
        guard surfaceEnabled() else { return }
        // Gate 2: live collection policy.
        guard isAuthorized() else { return }
        stateLock.lock()
        guard !drainInFlight else {
            // A DRAIN IS ALREADY RUNNING: record that work arrived, and let its COMPLETION re-offer.
            // Dropping the event here (the previous behaviour) meant new work waited for the next
            // lifecycle event, and a busy refusal was never retried at all.
            workPending = true
            stateLock.unlock()
            return
        }
        drainInFlight = true
        workPending = false
        let token = UUID()
        activeToken = token
        stateLock.unlock()
        startDrain(token: token)
    }

    /// One drain, then a COALESCED follow-up if work arrived while it ran. Completion is the
    /// handoff point — not a yield-based poll (reviewer 44d39ef8): the re-offer happens when the
    /// owning pass has actually finished, and any number of arrivals collapse into ONE extra pass.
    private func startDrain(token: UUID) {
        drainTask = Task { [weak self, scheduler] in
            let outcome = await scheduler.drainOnce()
            guard let self else { return }
            // A REFUSED PASS IS NOT A COMPLETED PASS (reviewer 44d39ef8): another pass owns the
            // scheduler, so this drain attempted nothing. Treat it as work still owed, exactly as
            // if the event had arrived mid-drain — the completion handoff below re-offers once the
            // owner releases, instead of dropping the event.
            if case .busy = outcome {
                self.stateLock.lock()
                self.workPending = true
                self.stateLock.unlock()
            }
            self.stateLock.lock()
            // Only the drain that still owns the slot may complete it.
            guard self.activeToken == token else {
                self.stateLock.unlock()
                return
            }
            let pending = self.workPending
            if pending {
                // HAND THE SLOT ON: the follow-up is this trigger's drain, so the flag stays set
                // and a new token owns it. Authorization is re-read inside triggerDrainIfPermitted.
                self.drainInFlight = false
                self.activeToken = nil
                self.workPending = false
                self.stateLock.unlock()
                self.triggerDrainIfPermitted()
                return
            }
            self.drainInFlight = false
            self.activeToken = nil
            self.stateLock.unlock()
        }
    }

    @objc private func appBecameActive() {
        triggerDrainIfPermitted()
    }
}