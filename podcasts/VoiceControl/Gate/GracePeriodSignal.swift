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

    /// TEST SEAM (reviewer 1f2c96ce): the live window's scheduled expiry, so controls can
    /// distinguish a NEW window (generation bump) from a RENEWAL inside the same generation
    /// (same generation, later fire date). A discarded capture must do NEITHER.
    var timerFireDateForTesting: Date? { timer?.fireDate }

    /// TEST SEAM: run the window's real expiry transition now, instead of waiting out the
    /// timeout. It takes the SAME path the timer takes (`deactivate(trigger: "timeout")`), so a
    /// control can hold recognition open across an expiry without the test depending on wall
    /// clock alignment between the timeout and the suspended backend.
    /// TEST SEAM: run a named deactivation trigger now.
    func deactivateForTesting(trigger: String) {
        if Thread.isMainThread {
            deactivate(trigger: trigger)
        } else {
            DispatchQueue.main.sync { deactivate(trigger: trigger) }
        }
    }

    func expireForTesting() {
        if Thread.isMainThread {
            deactivate(trigger: "timeout")
        } else {
            DispatchQueue.main.sync { deactivate(trigger: "timeout") }
        }
    }
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

    /// Turns ADMITTED before their window's deadline and still in recognition, keyed by the
    /// admitted turn's OWN identity. Spec `voice-control-core.md:270`: "Speech observed before the
    /// deadline remains eligible through recognition" — an inactivity expiry ends the window for
    /// NEW follow-ups but must not retire work already admitted and observed.
    ///
    /// Keyed by turn id, not by generation: a generation-wide grant would let an unrelated turn
    /// reusing the same expired origin claim, and would let a completed turn's claim be replayed.
    /// Each entry is released on that turn's OWN completion/drop/cancellation, so a claim is never
    /// honoured twice, and privacy/route invalidation clears them all (see `retireInFlightTurns`).
    private var inFlightTurns: [String: Int] = [:]

    /// The admitted-work authority a downstream dispatch fence consults. It answers ONE
    /// question about ONE turn: does this exact turn still hold admitted work under this origin?
    ///
    /// It is deliberately turn-scoped rather than origin-scoped. A fence that admitted a bare
    /// origin would also admit an unrelated turn that happened to reuse an expired generation,
    /// which is exactly the confusion `inFlightTurns` is keyed by identity to prevent. Retirement
    /// answers false: a retired turn is not admitted work, so privacy and route invalidation still
    /// refuse it here as everywhere else.
    struct AdmittedWorkAuthority {
        let isAdmittedWork: (String, Int) -> Bool
        /// Whether ANY admitted turn currently holds work under this origin. Used to retire
        /// per-origin conversation state only once nothing can still reach it.
        let hasAdmittedWork: (Int) -> Bool
    }

    /// A live view over this signal's admission state, for the dispatch fence. `isAdmittedWork`
    /// is evaluated against the CURRENT reservation, so a turn that has since been released or
    /// retired no longer qualifies.
    var admittedWorkAuthority: AdmittedWorkAuthority {
        AdmittedWorkAuthority(
            isAdmittedWork: { [weak self] utteranceId, origin in
                guard let self else { return false }
                return self.admittedOriginForTurn(utteranceId: utteranceId) == origin
            },
            hasAdmittedWork: { [weak self] origin in
                guard let self else { return false }
                return self.inFlightTurns.values.contains(origin)
            }
        )
    }

    /// Injected source of the REAL playback context (an eligible episode exists — playing or
    /// paused). Nil in unit contexts without playback wiring; the gate's own context decision is
    /// the authority for capture either way.
    var playbackContextAvailable: (() -> Bool)?

    /// Whether the app is currently foreground. Driven by the production foreground source
    /// (`ForegroundConditionSource`); context loss is only a RETIREMENT event when the
    /// foreground is already gone — in the foreground, foreground alone is still context.
    private(set) var isForegroundAllowed = true

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
        isForegroundAllowed = false
        // Preservation requires BOTH (reviewer 0c546ce5; spec 3893cd55): a live hold (work worth
        // preserving) AND an INDEPENDENT playback context (an eligible episode loaded, playing
        // or paused — a real source that keeps capture allowed). Neither alone suffices: a hold
        // alone manufactures nothing (grace must not self-sustain), and context alone means
        // there is no held work to preserve.
        if hasActiveHold, playbackContextAvailable?() == true {
            FileLog.shared.addMessage("[VoicePipeline] GracePeriod: preserved (backgrounded: live hold + playback context)")
            return
        }
        deactivate(trigger: "backgrounded")
    }

    func onAppForegrounded() {
        isForegroundAllowed = true
    }

    /// The playback context changed (real production path: the playback publisher re-samples
    /// the provider on each playback event). LOSING the last context while the foreground is
    /// ALREADY gone retires the window — no further lifecycle notification is needed, and
    /// `deactivate` bumps the generation, releases holds, and (via the origin binding) clears
    /// the live origin. A hold does NOT save the window: preservation is hold AND context, so
    /// with the context gone nothing independently sustains it.
    func onPlaybackContextChanged(_ available: Bool) {
        guard !available, !isForegroundAllowed else { return }  // foreground alone is still context
        deactivate(trigger: "playback context lost")
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

    /// Queue a cloud dispatch for a turn, returning the generation it belongs to — the dispatch
    /// hands that back on completion. `nil` only when there is no live window to own the turn.
    ///
    /// There is deliberately NO grace-window dispatch budget (owner delta 3484cbc/5eca874):
    /// each independent utterance may dispatch its own request, including within one window.
    /// Duplicate-dispatch protection lives with the per-utterance REQUEST OWNERSHIP
    /// (`CloudConversationManager.prepare`), not here — so this must not refuse a second,
    /// independent dispatch.
    func claimDispatchOwnership() -> Int? {
        if Thread.isMainThread { return claimDispatchOwnershipOnMain() }
        return DispatchQueue.main.sync { claimDispatchOwnershipOnMain() }
    }

    /// Claims dispatch ownership **on behalf of a turn that captured `origin`**, and refuses
    /// without consuming anything when that origin is not the live window.
    ///
    /// The comparison is a single main-actor operation: a separate "is this origin current?"
    /// check would leave a gap in which a wake or a privacy close could land, so a turn could be
    /// dispatched against a window it never belonged to. The refusal here is WINDOW IDENTITY,
    /// not a count — a live window may own many independent utterances. `nil` means refused; the
    /// caller must not consume, build a client, or act.
    ///
    /// `origin == nil` is a turn that captured nothing (no window identity of its own). That keeps
    /// the pre-existing policy: such a turn is judged by the live window exactly as before.
    func claimDispatchOwnership(capturedOrigin origin: Int?, utteranceId: String? = nil) -> Int? {
        let granted: Int?
        if Thread.isMainThread {
            granted = claimDispatchOwnershipOnMain(capturedOrigin: origin, utteranceId: utteranceId)
        } else {
            granted = DispatchQueue.main.sync {
                claimDispatchOwnershipOnMain(capturedOrigin: origin, utteranceId: utteranceId)
            }
        }
        lastClaimObservationForTesting = (captured: origin, granted: granted)
        return granted
    }

    /// Claims dispatch ownership for a turn, and for a turn carrying a captured origin the claim
    /// is authorised by THAT TURN'S OWN admission — never by the mere existence of some other
    /// reservation with the same origin. A different turn must not borrow another's eligibility.
    private func claimDispatchOwnershipOnMain(capturedOrigin origin: Int?, utteranceId: String?) -> Int? {
        // A turn with no captured identity keeps the live-window policy.
        guard let origin else { return claimDispatchOwnershipOnMain() }
        if origin == generation { return claimDispatchOwnershipOnMain() }
        // Not the live window: honoured only if THIS turn was admitted while a window with this
        // origin was live and has not yet completed. Requiring the id — not just the origin — is
        // what stops an unrelated turn from borrowing a reservation it never made.
        guard let utteranceId, inFlightTurns[utteranceId] == origin else { return nil }
        return origin
    }

    /// Records that a turn was ADMITTED under the live window, so an inactivity expiry later
    /// preserves its eligibility through recognition (`voice-control-core.md:270`). Only a live
    /// window admits: a turn arriving after the deadline records nothing, so expiry can never make
    /// an origin reusable.
    func admitInFlightTurn(utteranceId: String, origin: Int?) {
        if Thread.isMainThread { return admitInFlightTurnOnMain(utteranceId, origin) }
        DispatchQueue.main.sync { admitInFlightTurnOnMain(utteranceId, origin) }
    }

    private func admitInFlightTurnOnMain(_ utteranceId: String, _ origin: Int?) {
        let admittedOrigin = origin ?? generation
        guard isActive, generation == admittedOrigin else { return }
        inFlightTurns[utteranceId] = admittedOrigin
    }

    /// The origin a turn was ADMITTED under, if it is still in flight. The routing path reads this
    /// by the turn's OWN id instead of re-reading the live generation, which by then may have moved
    /// past an expiry — the turn's window is the one it was admitted into, not whatever is current.
    func admittedOriginForTurn(utteranceId: String) -> Int? {
        if Thread.isMainThread { return inFlightTurns[utteranceId] }
        var result: Int?
        DispatchQueue.main.sync { result = inFlightTurns[utteranceId] }
        return result
    }

    /// Turns whose admission was RETIRED without completion — privacy or route invalidation. A late
    /// completion of such a turn must stay refused: its speech may no longer be safe to act on, and
    /// it must never adopt a window that opened afterwards.
    private var retiredTurns: Set<String> = []

    /// TEST SEAM: admit a turn that was admitted into an EARLIER window, which is what the
    /// production admission recorded before the deadline passed. `admitInFlightTurn` refuses this
    /// by design (it only admits into the LIVE window), so a control that needs a still-in-flight
    /// turn of a superseded origin records it here.
    func admitInFlightTurnForTesting(utteranceId: String, origin: Int) {
        let apply = { self.inFlightTurns[utteranceId] = origin }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.sync(execute: apply) }
    }

    /// TEST SEAM: the most recent dispatch claim's outcome, as (capturedOrigin, grantedOrigin).
    /// Nil until a claim is attempted. Lets a control observe the claim its own path made without
    /// reaching into the executor's sink.
    private(set) var lastClaimObservationForTesting: (captured: Int?, granted: Int?)?

    /// TEST SEAM.
    var inFlightCountForTesting: Int { inFlightTurns.count }

    /// A captured origin that can never be claimed, for a turn whose admission was retired. It is
    /// distinct from `nil` (which means "captured nothing" and keeps the legacy live-window policy)
    /// so a retired turn is REFUSED rather than silently re-judged against the current window.
    var policyRefusedOrigin: Int { -1 }

    /// Whether this turn was admitted and has since been retired. The caller treats this as a final
    /// refusal rather than falling back to live state.
    func isRetiredTurn(_ utteranceId: String) -> Bool {
        if Thread.isMainThread { return retiredTurns.contains(utteranceId) }
        var result = false
        DispatchQueue.main.sync { result = retiredTurns.contains(utteranceId) }
        return result
    }

    /// Releases one admitted turn's reservation. Called on EVERY terminal outcome for that turn —
    /// completion, drop, cancellation — so eligibility is owned for exactly as long as the work is
    /// in flight and a claim can never be honoured twice.
    func releaseInFlightTurn(utteranceId: String) {
        if Thread.isMainThread { return releaseInFlightTurnOnMain(utteranceId) }
        DispatchQueue.main.sync { releaseInFlightTurnOnMain(utteranceId) }
    }

    /// TEST/PRODUCTION SEAM: called after a turn's reservation is released, with the turn's id and
    /// the origin it held. Downstream state that exists only because of that admitted work (the
    /// per-origin conversation a delayed turn opened) is released here, so it dies with its OWNER
    /// rather than waiting for some future window transition — which may never come.
    var onInFlightTurnReleased: ((String, Int) -> Void)?

    private func releaseInFlightTurnOnMain(_ utteranceId: String) {
        let releasedOrigin = inFlightTurns.removeValue(forKey: utteranceId)
        retiredTurns.remove(utteranceId)
        if let releasedOrigin {
            onInFlightTurnReleased?(utteranceId, releasedOrigin)
        }
    }

    /// Retires every in-flight reservation. Used for privacy/route invalidation — which, unlike an
    /// ordinary expiry, must end an admitted turn's claim because the user's speech may no longer
    /// be safe to act on.
    private func retireInFlightTurns() {
        // Remember WHO was retired, so a late completion is refused outright instead of falling
        // back to whatever window is live by then (a new wake must not adopt a retired turn).
        retiredTurns.formUnion(inFlightTurns.keys)
        inFlightTurns.removeAll()
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

    /// Restores dispatch availability for a completion that still belongs to its window,
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

    /// Whether the CURRENT window has been RENEWED since its last refused act — the observable
    /// distinction between a completion that renews the window (a deliberate act) and one that
    /// merely extends it without renewal (a fallback). `claimRefusalTone` returning true means the
    /// window is in a renewed state (no announce is held for this generation).
    func windowIsRenewedForTesting() -> Bool {
        if Thread.isMainThread { return refusalToneGeneration != generation }
        return DispatchQueue.main.sync { refusalToneGeneration != generation }
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
        // No dispatch budget exists to preserve (owner delta 3484cbc/5eca874); the tone claim
        // is preserved across this NON-renewing reset so a refusal already announced for this
        // generation is not repeated as if it were a new fact.
        let toneClaimed = refusalToneGeneration
        startOrResetOnMain(trigger: trigger, renewingAllowance: false)
        refusalToneGeneration = toneClaimed
    }

    private func claimDispatchOwnershipOnMain() -> Int? {
        // NO window budget: only a CLOSED window refuses. An open window owns every independent
        // utterance that lands in it; request ownership (not a count) prevents duplicates.
        guard isActive else { return nil }
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
        // An ordinary inactivity expiry ends the window for NEW follow-ups but must NOT retire an
        // already-admitted turn still in recognition (voice-control-core.md:270). Every other
        // trigger is an invalidation — privacy, route, context loss, app background — and DOES
        // retire in-flight work, because the user's speech may no longer be safe to act on.
        let isExpiry = (trigger == "timeout")
        let apply = { [weak self] in
            guard let self else { return }
            let wasActive = self.isActive
            self.generation += 1   // a privacy close ends the generation
            if !isExpiry { self.retireInFlightTurns() }
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
