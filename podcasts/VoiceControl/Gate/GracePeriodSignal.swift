import Foundation
import Combine
import PocketCastsUtils

/// 30s conversation grace period after a wake-word detection or command recognition.
/// Keeps continuous listening alive so the user can issue follow-up commands
/// without re-triggering the wake word.
class GracePeriodSignal: ObservableObject {
    @Published private(set) var isActive = false
    private let timeout: TimeInterval
    private var timer: Timer?
    /// Escalation budget for the current window (shared client contract: at most
    /// one dispatch per grace window). Restored by anything that opens or resets
    /// the window — a wake or a recognised command — and never by the escalation
    /// attempt itself, so a run of routing failures inside one window dispatches
    /// once instead of once per failure.
    private var escalationClaimed = false
    /// The LIVE playback holds holding this window's expiry open. Ownership is a TOKEN, not the
    /// generation: repeated begins on one generation each get their own independently releasable
    /// hold, and an end clears only its own token — no overwrite, no clearing another owner.
    private var playbackHolds: [PlaybackHoldToken] = []
    /// Identifies the window a dispatch was issued under. State alone cannot do
    /// this: an old request completing after a privacy close and a new wake would
    /// otherwise extend — or re-arm — a window it never belonged to.
    private var generation = 0
    /// The generation whose refusal tone has already been played. A repeat refusal
    /// inside one window is the same request against the same spent allowance, so
    /// a second tone carries no new information; a new window gets one again.
    private var refusalToneGeneration: Int?

    init(timeout: TimeInterval = 30.0) {
        self.timeout = timeout
    }

    func onCommandRecognized() {
        startOrReset(trigger: "command recognized")
    }

    func onWakeWordDetected() {
        // A wake is a new user-initiated act, so it opens a new window and a new
        // generation — a dispatch from an earlier one cannot extend this one. A
        // recognised command keeps the generation: it continues the conversation
        // rather than starting it.
        startOrReset(trigger: "wake word detected", opensGeneration: true)
    }

    /// Audio route change (e.g. unplugging headphones) breaks the grace period
    /// to avoid exposing the user's voice when they may not expect it.
    func onAudioRouteChanged() {
        deactivate(trigger: "route changed")
    }

    /// App backgrounding's effect on grace is CONDITIONAL (owner delta 8fe04cd/0aa4480).
    ///
    /// Privacy fails closed by default: with no active cloud/answer hold, backgrounding ends the
    /// window immediately. But while a hold is live — an admitted turn whose answer/audio is still
    /// running — foreground loss must PRESERVE the window so the background answer can finish;
    /// this is why the reset uses LOCAL audio completion rather than server `done`.
    ///
    /// Capture is a separate gate concern: the gate still decides whether the microphone may be
    /// used. This only governs the window's lifetime.
    func onAppBackgrounded() {
        // A live hold on the CURRENT generation is active work: do not retire it here.
        // (`playbackHolds` is only ever populated for the live generation at acquisition, and
        // stale-generation holds are retired in `endPlaybackHoldOnMain`.)
        if playbackHolds.contains(where: { $0.generation == generation }) {
            FileLog.shared.addMessage("[VoicePipeline] GracePeriod: preserved (backgrounded with active hold)")
            return
        }
        deactivate(trigger: "backgrounded")
    }

    private func startOrReset(trigger: String, opensGeneration: Bool = false) {
        // Wake/ASR callbacks arrive off the main thread. `Timer.scheduledTimer`
        // binds to the *current* run loop — on a cooperative QoS queue that loop
        // never spins, so the grace period never expires and listening stays
        // continuous. Mirror Android (`Dispatchers.Main` + delay).
        if Thread.isMainThread {
            startOrResetOnMain(trigger: trigger, opensGeneration: opensGeneration)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.startOrResetOnMain(trigger: trigger, opensGeneration: opensGeneration)
            }
        }
    }

    /// Consumes the window's escalation budget, returning the generation it was
    /// claimed under — the dispatch hands that back on completion. `nil` when the
    /// window is closed or the allowance is already spent, in which case the
    /// caller keeps the turn local.
    /// Test-only observation: whether the current window's escalation allowance is spent.
    func escalationClaimedForTesting() -> Bool { escalationClaimed }

    func claimEscalationBudget() -> Int? {
        if Thread.isMainThread { return claimEscalationBudgetOnMain() }
        return DispatchQueue.main.sync { claimEscalationBudgetOnMain() }
    }

    /// Claims this window's escalation allowance **on behalf of a turn that captured `origin`**,
    /// and refuses without consuming anything when that origin is not the live window.
    ///
    /// The comparison and the claim are ONE main-actor operation by construction: a separate
    /// "is this origin current?" check followed by an unconditional claim leaves a gap in which a
    /// wake or a privacy close could land, so a turn could still spend an allowance that was not
    /// its own — or be refused against a window it never belonged to. `nil` means refused; the
    /// caller must not consume, build a client, or act.
    ///
    /// `origin == nil` is a turn that captured nothing (no window identity of its own). That keeps
    /// the pre-existing policy: such a turn is judged by the live window exactly as before.
    func claimEscalationBudget(capturedOrigin origin: Int?) -> Int? {
        if Thread.isMainThread { return claimEscalationBudgetOnMain(capturedOrigin: origin) }
        return DispatchQueue.main.sync { claimEscalationBudgetOnMain(capturedOrigin: origin) }
    }

    private func claimEscalationBudgetOnMain(capturedOrigin origin: Int?) -> Int? {
        // A turn with no captured identity keeps the live-window policy.
        if let origin, origin != generation { return nil }
        return claimEscalationBudgetOnMain()
    }

    /// The generation a turn is running under, for stamping an intent that was
    /// not created by a fallback. Read when the turn starts, so a completion is
    /// judged against the window it actually belonged to.
    func currentGeneration() -> Int {
        // Same main-queue synchronization as the claim: the generation is mutated
        // by wake and privacy-close, and reading it off the service thread would
        // race those rather than snapshot a window.
        if Thread.isMainThread { return generation }
        return DispatchQueue.main.sync { generation }
    }

    /// Restores the allowance for a completion that still belongs to its window,
    /// as a single operation on the main queue.
    ///
    /// Checking "is this still current?" and then calling the reset separately
    /// would leave a gap: the reset hops to the main queue, and a privacy close
    /// landing in between would be undone by a turn that no longer belongs. Returns
    /// whether the completion was applied.
    func recognizeCommandIfCurrentWindow(_ generation: Int) -> Bool {
        if Thread.isMainThread { return recognizeCommandIfCurrentOnMain(generation) }
        return DispatchQueue.main.sync { recognizeCommandIfCurrentOnMain(generation) }
    }

    private func recognizeCommandIfCurrentOnMain(_ generation: Int) -> Bool {
        guard isActive, self.generation == generation else { return false }
        // A RECOGNIZED command is a SELECTED renewal (the success model): the answer arrived, so
        // the window's allowance is new information again — even while a playback hold keeps the
        // clock from arming. Clock arming and explicit recognized renewal are separate concerns
        // (review 24f236de): the hold suppresses ARMING only.
        startOrResetOnMain(trigger: "cloud route", renewingAllowance: true)
        return true
    }

    /// Whether an active cloud/answer playback hold is keeping THIS window open — the condition
    /// that lets foreground loss preserve the window (owner delta 8fe04cd/0aa4480).
    var hasActiveHold: Bool {
        if Thread.isMainThread { return hasActiveHoldOnMain() }
        return DispatchQueue.main.sync { hasActiveHoldOnMain() }
    }

    private func hasActiveHoldOnMain() -> Bool {
        isActive && playbackHolds.contains { $0.generation == generation }
    }

    /// Whether this refusal should be audible. The first refusal in a generation
    /// speaks — that is the only signal the user gets that their deliberate
    /// question went unanswered — and repeats within the same generation do not,
    /// because they are the same allowance rather than a new event.
    func claimRefusalTone() -> Bool {
        if Thread.isMainThread { return claimRefusalToneOnMain() }
        return DispatchQueue.main.sync { claimRefusalToneOnMain() }
    }

    private func claimRefusalToneOnMain() -> Bool {
        guard refusalToneGeneration != generation else { return false }
        refusalToneGeneration = generation
        return true
    }

    /// Continues the window a dispatch was issued under, without restoring the
    /// allowance that permitted it.
    ///
    /// Used when the turn was itself a fallback: the conversation should carry on,
    /// but re-arming the allowance here would let one window dispatch repeatedly —
    /// the fallback would be paying for its own permission.
    ///
    /// The completion only counts for the window it belongs to. If that window has
    /// ended — a privacy close, then possibly a new wake — it is dropped rather
    /// than applied to whatever window is current.
    func extendWindowKeepingEscalationSpent(underGeneration: Int) {
        if Thread.isMainThread {
            guard isActive, generation == underGeneration else { return }
            startOrResetOnMainKeepingBudget(trigger: "fallback dispatch")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.generation == underGeneration else { return }
            self.startOrResetOnMainKeepingBudget(trigger: "fallback dispatch")
        }
    }

    private func startOrResetOnMainKeepingBudget(trigger: String) {
        // The allowance stays spent across this reset, so the refusal that spent
        // it is still the latest news in this window: restore the tone claim with
        // it, or the next refusal beeps again for the *same* spent allowance —
        // two tones for one fact, which is what the claim exists to prevent.
        let claimed = escalationClaimed
        let toneClaimed = refusalToneGeneration
        startOrResetOnMain(trigger: trigger, renewingAllowance: false)
        escalationClaimed = claimed
        refusalToneGeneration = toneClaimed
    }

    private func claimEscalationBudgetOnMain() -> Int? {
        guard isActive, !escalationClaimed else { return nil }
        escalationClaimed = true
        return generation
    }

    private func startOrResetOnMain(trigger: String, opensGeneration: Bool = false, renewingAllowance: Bool = true) {
        // Publish first, then log. Logging while `isActive` still held the old
        // value let Combine condition refreshes resolve the wrong listening mode.
        let becameActive = !isActive
        if becameActive || opensGeneration {
            generation += 1   // a window belongs to a generation
        }
        isActive = true
        // Renewal is each caller's EXPLICIT decision (review 24f236de): a recognized command
        // renews (success model); the fallback extension and the hold's plain release do not.
        if renewingAllowance {
            // The allowance is restored for this window, so a refusal in it is new
            // information again and must speak (PR #23 review).
            refusalToneGeneration = nil
            escalationClaimed = false
        }
        if becameActive {
            FileLog.shared.addMessage("[VoicePipeline] GracePeriod: true (\(trigger))")
        }
        timer?.invalidate()
        // GRACE CONTRACT (shared timer path): while THIS window's work/playback holds expiry, NO
        // caller re-arms the clock under the hold — command recognition, fallback extension, and
        // wake resets all preserve their allowance/state here, and the expiry resumes exactly
        // once when the last hold releases. Holds of OTHER (older) generations do not bind this
        // window: a successor wake must time out normally.
        let suppressedByHold = playbackHolds.contains(where: { $0.generation == generation })
        if !suppressedByHold {
            let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                self?.deactivate(trigger: "timeout")
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// An independently releasable ownership hold on a window's expiry. The generation is
    /// recorded at ACQUISITION (refused unless live); the token — not the generation — is the
    /// release identity, so repeated begins on one generation never overwrite each other and an
    /// end never clears another owner's hold.
    final class PlaybackHoldToken: Equatable {
        let generation: Int
        fileprivate let id = UUID()
        init(generation: Int) { self.generation = generation }
        static func == (lhs: PlaybackHoldToken, rhs: PlaybackHoldToken) -> Bool { lhs.id == rhs.id }
    }

    /// SUSPENDS this window's expiry while its cloud work / local playback runs — from the
    /// ADMITTED DISPATCH through done and the actual drain/stop, regardless of duration (grace
    /// contract). Identity-bound at acquisition: refused unless `generation` is the LIVE window —
    /// a stale turn's work can never hold a window it does not belong to. The interval is not
    /// restarted here; releasing the LAST hold does that exactly once, at the real stop.
    func beginPlaybackHold(forGeneration generation: Int) -> PlaybackHoldToken? {
        if Thread.isMainThread { return beginPlaybackHoldOnMain(generation) }
        return DispatchQueue.main.sync { beginPlaybackHoldOnMain(generation) }
    }

    private func beginPlaybackHoldOnMain(_ generation: Int) -> PlaybackHoldToken? {
        guard isActive, self.generation == generation else { return nil }
        let token = PlaybackHoldToken(generation: generation)
        playbackHolds.append(token)
        timer?.invalidate()
        timer = nil
        return token
    }

    /// ENDS exactly this token's hold at its real terminal/stop/cancel. When the LAST hold goes,
    /// the permitted interval starts (resumes) EXACTLY ONCE — and only if the released hold's
    /// generation is still the live window: a stale stop, a privacy close that already ended the
    /// window, or a successor's event drops its own hold and NEVER starts or extends the current
    /// window.
    func endPlaybackHold(_ token: PlaybackHoldToken?) {
        guard let token else { return }
        if Thread.isMainThread { endPlaybackHoldOnMain(token); return }
        DispatchQueue.main.async { [weak self] in self?.endPlaybackHoldOnMain(token) }
    }

    private func endPlaybackHoldOnMain(_ token: PlaybackHoldToken) {
        guard let index = playbackHolds.firstIndex(of: token) else { return }
        playbackHolds.remove(at: index)
        // CURRENT-GENERATION counting: only holds belonging to the LIVE window keep its expiry
        // suspended. A stale hold from an older generation neither delays this release nor can
        // its later end repair (or disturb) this window — it is retired here so it can never
        // suppress a successor's clock. (Reviewer 7fc40b74 defect 2: an old outstanding hold
        // used to leave a released successor hold-free AND timer-free.)
        playbackHolds.removeAll { $0.generation != self.generation }
        guard !playbackHolds.contains(where: { $0.generation == self.generation }) else { return }
        // Only the LIVE window resumes: a hold whose window was closed (privacy close, expiry of
        // a later interval) is dropped without re-arming anything.
        guard isActive, self.generation == token.generation else { return }
        // DEFECT 1 (reviewer 7fc40b74): the resume arms the clock WITHOUT renewal. This window
        // already spent its escalation allowance and tone decision before the hold; a drained
        // playback resumes the SAME interval, it does not open a fresh one.
        startOrResetOnMain(trigger: "playback drained", renewingAllowance: false)
    }

    private func deactivate(trigger: String) {
        let apply = { [weak self] in
            guard let self else { return }
            let wasActive = self.isActive
            self.generation += 1   // a privacy close ends the generation
            self.playbackHolds.removeAll()   // a closed window cannot be held
            self.timer?.invalidate()
            self.timer = nil
            self.isActive = false
            if wasActive {
                FileLog.shared.addMessage("[VoicePipeline] GracePeriod: false (\(trigger))")
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}
