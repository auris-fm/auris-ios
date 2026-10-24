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
    /// The scheduler-completion registration this drain is waiting on, so cancellation can drop it.
    private var pendingCompletionID: UUID?
    /// Set when the current drain was refused, so its continuation re-offers rather than counting
    /// as a completed pass.
    private var drainWasRefused = false

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

    /// CANCELLATION, exercised while the trigger is still alive (reviewer 280f4c52): drop any
    /// pending completion registration, clear the slot, and refuse further work until cancelled
    /// tasks have drained. A cancelled trigger must neither send nor keep waking up.
    func cancelForTesting() {
        stateLock.lock()
        let completionID = pendingCompletionID
        pendingCompletionID = nil
        workPending = false
        drainInFlight = false
        activeToken = nil
        let task = drainTask
        stateLock.unlock()
        if let completionID { scheduler.cancelOwnerCompletion(completionID) }
        task?.cancel()
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

    /// One drain, then a COALESCED follow-up if work arrived while it ran or if the scheduler was
    /// owned by someone else.
    ///
    /// NO POLLING (reviewer 280f4c52): a refused pass COMPLETES straight away with `.busy`, so
    /// re-offering from its own completion recurses for as long as another owner holds the
    /// scheduler. Instead the refusal registers with the scheduler for the owner's completion and
    /// stops; that callback (fired exactly once, under the same lock that decides ownership) is
    /// what re-offers. `Task.isCancelled` is checked at every transition so a cancelled trigger
    /// neither sends nor keeps a registration.
    private func startDrain(token: UUID) {
        drainTask = Task { [weak self, scheduler] in
            guard let self, !Task.isCancelled else { return }
            let outcome = await scheduler.drainOnce()
            guard !Task.isCancelled else {
                self.finishDrain(token: token, refused: false)
                return
            }
            if case .busy = outcome {
                self.finishRefusedDrain(token: token)
                return
            }
            self.finishDrain(token: token, refused: false)
        }
    }

    /// A refused pass: wait for the OWNER to finish, then re-offer once. Never recurses by itself.
    private func finishRefusedDrain(token: UUID) {
        guard !Task.isCancelled else {
            finishDrain(token: token, refused: false)
            return
        }
        let registration = scheduler.registerOwnerCompletion { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard self.activeToken == token else {
                self.stateLock.unlock()
                return
            }
            self.pendingCompletionID = nil
            self.drainInFlight = false
            self.activeToken = nil
            self.workPending = false
            self.stateLock.unlock()
            // Re-offer through the SAME gates: authorization and cancellation are re-read.
            self.triggerDrainIfPermitted()
        }
        stateLock.lock()
        if registration.assumedOwnership {
            // The owner finished between the refusal and now: run immediately instead of waiting
            // for a callback that will never come.
            stateLock.unlock()
            finishDrain(token: token, refused: true)
            return
        }
        pendingCompletionID = registration.id
        stateLock.unlock()
    }

    /// Completes the slot for the drain holding `token`, and re-offers once if work is pending.
    private func finishDrain(token: UUID, refused: Bool) {
        stateLock.lock()
        guard activeToken == token else {
            stateLock.unlock()
            return
        }
        let pending = workPending
        drainInFlight = false
        activeToken = nil
        workPending = false
        stateLock.unlock()
        if pending || refused {
            triggerDrainIfPermitted()
        }
    }

    @objc private func appBecameActive() {
        triggerDrainIfPermitted()
    }
}