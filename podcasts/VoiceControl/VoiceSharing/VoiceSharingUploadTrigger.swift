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
    /// The live drain task. ALL reads and writes go through `stateLock` (reviewer 4377e2bd): a
    /// fast completion/re-offer re-assigns this handle while a test await or deinit may read it.
    private var drainTaskStorage: Task<Void, Never>?
    private var drainTask: Task<Void, Never>? {
        get { stateLock.withLock { drainTaskStorage } }
        set { stateLock.withLock { drainTaskStorage = newValue } }
    }
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
    /// CANCELLATION GENERATION (reviewer b8991889): bumped by every stop/cancel. A follow-up
    /// re-offer is admitted only if the generation that produced it is still current, checked
    /// ATOMICALLY WITH SLOT ADMISSION — so a stop landing between a completion and its re-offer
    /// cannot let the already-decided follow-up open a new era.
    private var stopGeneration = 0

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
        // TEARDOWN UNDER ONE HOLD (reviewer 4377e2bd): the live registration is REMOVED from the
        // scheduler (so a completion can never fire into a dying object), the slot and pending
        // work are dropped, and the drain task is cancelled. The drain task body captures only
        // weak self plus the scheduler, so it cannot retain the trigger across an await.
        stateLock.lock()
        let completionID = pendingCompletionID
        pendingCompletionID = nil
        let task = drainTaskStorage
        drainTaskStorage = nil
        drainInFlight = false
        activeToken = nil
        workPending = false
        stateLock.unlock()
        if let completionID { scheduler.cancelOwnerCompletion(completionID) }
        task?.cancel()
    }

    /// Test seam: await the current drain (used by controls that must observe the FOLLOW-UP pass
    /// started automatically on completion).
    func awaitCurrentDrainForTesting() async {
        let task = drainTask
        await task?.value
    }

    /// DETERMINISTIC RACE SEAM (reviewer b8991889 #2): invoked by the completion callback after
    /// the slot cleared but BEFORE its re-offer admission — the exact window where a stop() must
    /// refuse the already-decided follow-up via the cancellation generation.
    var preReofferHookForTesting: (() -> Void)?

    /// Test seam: the publication-before-registration invariant, observable.
    var hasPublishedCompletionRegistrationForTesting: Bool {
        stateLock.withLock { pendingCompletionID != nil }
    }

    /// Test seam: whether a drain currently owns the slot.
    var isDrainingForTesting: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return drainInFlight
    }

    /// CANCELLATION, exercised while the trigger is still alive (reviewer 280f4c52): drop any
    /// pending completion registration, clear the slot, and refuse further work until cancelled
    /// tasks have drained. A cancelled trigger must neither send nor keep waking up.
    /// PRODUCTION CANCELLATION (reviewer 4377e2bd/9d33f359): the app calls this when the feature's
    /// preconditions vanish in a way that must stop all trigger activity — e.g. the surface is
    /// compiled off in a future build, or the owning coordinator tears down. Same semantics as the
    /// test seam: drop the registration, clear the slot, cancel the task.
    func stop() {
        cancelForTesting()
    }

    /// Test seam exposing the production cancellation semantics directly.
    func cancelForTesting() {
        stateLock.lock()
        stopGeneration += 1
        let completionID = pendingCompletionID
        pendingCompletionID = nil
        workPending = false
        drainInFlight = false
        activeToken = nil
        let task = drainTaskStorage
        drainTaskStorage = nil
        stateLock.unlock()
        if let completionID { scheduler.cancelOwnerCompletion(completionID) }
        task?.cancel()
    }

    /// The guarded entry a lifecycle event reaches. Also callable directly (background task
    /// expiration, push-to-sync) with the SAME gates — there is no unguarded path.
    func triggerDrainIfPermitted() {
        triggerDrainIfPermitted(matchingGeneration: nil)
    }

    /// The completion-path re-offer. `producingGeneration` is the cancellation generation read
    /// under the SAME lock hold that cleared the slot; if a stop has bumped the generation since,
    /// the already-decided follow-up is refused here, atomically with slot admission.
    private func triggerDrainIfPermitted(matchingGeneration: Int?) {
        // Gate 1: compiled-off surface ⇒ literal no-op. This is what keeps the feature
        // unreachable in shipped builds regardless of policy or network state.
        guard surfaceEnabled() else { return }
        // Gate 2: live collection policy.
        guard isAuthorized() else { return }
        stateLock.lock()
        if let produced = matchingGeneration, stopGeneration != produced {
            stateLock.unlock()
            return
        }
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
        // TOKEN-BOUND PUBLICATION (reviewer 2a570a0b #3): the handle is stored under the lock and
        // only while this token still owns the slot, so a stale task's delayed setter cannot
        // overwrite a successor's handle. The task body promotes self only AFTER the await, so
        // nothing strong is retained across `drainOnce` (reviewer 2a570a0b #2).
        stateLock.lock()
        guard activeToken == token else {
            stateLock.unlock()
            return
        }
        let scheduler = self.scheduler
        let task = Task { [weak self] in
            // PRE-ENTRY CANCELLATION (reviewer b8991889): a stop() before this task first
            // executes must prevent the drain from starting at all — the post-await check alone
            // was too late and could still send. stop() has already cleared the slot, so an
            // early return here leaves no bookkeeping behind.
            if Task.isCancelled { return }
            let outcome = await scheduler.drainOnce()
            guard let self else { return }
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
        drainTaskStorage = task
        stateLock.unlock()
    }

    /// A refused pass: wait for the OWNER to finish, then re-offer once. Never recurses by itself.
    ///
    /// PUBLICATION IS TOKEN-VALIDATED (reviewer 4377e2bd): the callback captures the drain's token
    /// and re-checks it under the lock before touching ANY state, so a stale callback (one whose
    /// drain was already superseded or cancelled) changes nothing. The registration ID is
    /// published under the same lock, and a cancellation that ran before publication still wins —
    /// the ID is checked against `activeToken`'s era, and a registration left over after the slot
    /// cleared is dropped here.
    private func finishRefusedDrain(token: UUID) {
        guard !Task.isCancelled else {
            finishDrain(token: token, refused: false)
            return
        }
        // NO LOST WAKEUP (reviewer 2a570a0b #1): the callback is made live BEFORE it can fire.
        // Publication happens first (ID stored under the lock, era re-validated), and only then is
        // the callback registered — so the scheduler can never invoke a callback whose identity is
        // not yet visible. The callback validates on the ERA TOKEN alone, so even an
        // already-consumed-or-cancelling window degrades to a correct no-op or a correct re-offer,
        // never to a stuck slot.
        let registrationID = UUID()
        stateLock.lock()
        guard activeToken == token else {
            stateLock.unlock()
            return
        }
        pendingCompletionID = registrationID
        stateLock.unlock()

        let registration = scheduler.registerOwnerCompletion(id: registrationID) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            // THE TOKEN IS THE ERA: only the callback of the drain that still owns the slot may
            // act. Superseded, completed, or cancelled drains are no-ops.
            guard self.activeToken == token else {
                self.stateLock.unlock()
                return
            }
            self.pendingCompletionID = nil
            let generation = self.stopGeneration
            self.drainInFlight = false
            self.activeToken = nil
            self.workPending = false
            self.stateLock.unlock()
            // Re-offer through the SAME gates, gated on the generation read atomically with the
            // slot clearing: a stop in this window refuses the follow-up.
            preReofferHookForTesting?()
            self.triggerDrainIfPermitted(matchingGeneration: generation)
        }
        stateLock.lock()
        let eraAlive = activeToken == token
        stateLock.unlock()
        if !eraAlive {
            // Cancellation (or a newer drain) ended this era while we registered: the registration
            // must not linger in the scheduler.
            scheduler.cancelOwnerCompletion(registrationID)
            stateLock.lock()
            if pendingCompletionID == registrationID { pendingCompletionID = nil }
            stateLock.unlock()
            return
        }
        if registration.assumedOwnership {
            // The owner finished between the refusal and now: run immediately instead of waiting
            // for a callback that will never come.
            scheduler.cancelOwnerCompletion(registrationID)
            stateLock.lock()
            if pendingCompletionID == registrationID { pendingCompletionID = nil }
            stateLock.unlock()
            finishDrain(token: token, refused: true)
        }
    }

    /// Completes the slot for the drain holding `token`, and re-offers once if work is pending.
    private func finishDrain(token: UUID, refused: Bool) {
        stateLock.lock()
        guard activeToken == token else {
            stateLock.unlock()
            return
        }
        let pending = workPending
        let generation = stopGeneration
        drainInFlight = false
        activeToken = nil
        workPending = false
        // Only the finishing era releases its own handle; a successor's stays.
        drainTaskStorage = nil
        stateLock.unlock()
        if pending || refused {
            triggerDrainIfPermitted(matchingGeneration: generation)
        }
    }

    @objc private func appBecameActive() {
        triggerDrainIfPermitted()
    }
}