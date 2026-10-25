import Foundation

/// Client-side interruption state (`docs/specs/cloud-assistant.md` → Interruption, spec ruling
/// c5fe3416).
///
/// The contract requires the client to hold, across a turn boundary, two things this client did
/// not previously keep:
///
///   * **the retained follow-up** — the complete interrupting utterance, held until the prior turn
///     reaches a terminal acknowledgement, then submitted ONCE on its own socket; and
///   * **the pending interruption report** — `{"request_id", "playback_position_ms"}`, attached to
///     the next turn's authentication frame so the server can correct already-settled history
///     before model input.
///
/// The two orderings are both handled here because both are reachable and they resolve
/// differently:
///
///   * **acknowledgement first** (the prior turn's terminal — `done` even with `completed`, or a
///     refusal) — the follow-up is released for submission, exactly once, and the report is
///     retained for the next turn;
///   * **refusal first** (a pre-terminal `invalid_request`) — the follow-up is DISCARDED and the
///     report is retained for a later explicit user request.
///
/// A late interrupt cannot be retried: post-terminal interrupts are ignored by the server, so this
/// type never re-sends one. `interruptSentFor` records that a turn's interrupt already went out so
/// the emitter has exactly one shot per turn, by construction rather than by caller discipline.
///
/// Thread-safety: all state transitions happen under one lock. The type is deliberately a plain
/// class rather than an actor — the sink's turn loop is not async-isolated from it at every call
/// site, and a suspended await between "read the follow-up" and "submit it" is exactly where a
/// second enabled submit must lose. Every enable is a compare-and-set so that race has one winner.
final class CloudInterruptionState: @unchecked Sendable {
    /// The pending report attached to the next turn's auth frame. Carries no playback position
    /// until one is measured: the contract makes `playback_position_ms` optional and calls it
    /// untrusted reported progress, so an absent measurement is omitted rather than guessed.
    struct PendingReport: Equatable {
        let requestId: String
        let playbackPositionMs: Int64?
        /// The conversation whose settled history this report corrects. A report is only valid
        /// inside ITS conversation; abandoning that conversation discards it.
        var conversationId: String?
    }

    /// A follow-up released for submission, with the identity the fence was won under.
    struct ReleasedFollowUp: Equatable {
        let request: String
        let utteranceId: String
        let origin: Int?
        /// The turn that was INTERRUPTED — the subject of the pending report. Carried so the
        /// report names the interrupted turn rather than whichever turn later completed.
        let interruptedRequestId: String?
    }

    private struct HeldFollowUp {
        let request: String
        let utteranceId: String
        let origin: Int?
    }

    private let lock = NSLock()

    /// The interrupting utterance, held while the prior turn is live.
    private var held: HeldFollowUp?
    /// The report awaiting the next turn.
    private var pendingReport: PendingReport?
    /// The turn whose interrupt has already been emitted — one shot, never retried.
    private var interruptSentForRequestId: String?
    /// The request id whose follow-up may be submitted. Set exactly once per held follow-up, by
    /// whichever terminal arrives first; a second terminal of a different kind must not re-enable.
    private var releasedForRequestId: String?
    /// Set when the refusal discarded the follow-up: nothing may be submitted for it afterwards.
    private var discardedForRequestId: String?

    // MARK: - Emitting the interrupt (one shot)

    /// Whether an `interrupt` frame should be sent for `requestId`.
    ///
    /// Returns true at most once per request id. The caller sends on the prior turn's OPEN socket
    /// immediately after this returns true: if the prior terminal has already arrived the frame is
    /// useless (the server ignores post-terminal interrupts), so `recordTerminal` clears the right
    /// to send and this returns false from then on.
    func claimInterruptEmission(forRequestId requestId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // A turn whose terminal already landed may NOT be interrupted: the server ignores a
        // post-terminal interrupt, so sending one would claim an effect that cannot happen. That is
        // enforced by the CLEARED marker and the released/discarded CAS below, not by a separate
        // settled-id set: a set was tried, and a mutant that removed it survived every control,
        // which is what an unreachable double-check looks like. Kept out rather than kept
        // unexercised.
        guard interruptSentForRequestId == nil else { return false }
        guard releasedForRequestId == nil, discardedForRequestId == nil else { return false }
        interruptSentForRequestId = requestId
        return true
    }

    /// True once an interrupt was emitted for this turn and no terminal has landed yet.
    func hasOpenInterrupt(forRequestId requestId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return interruptSentForRequestId == requestId
            && releasedForRequestId == nil
            && discardedForRequestId == nil
    }

    // MARK: - Holding the follow-up

    /// Hold the interrupting utterance for the prior turn's `requestId`.
    ///
    /// A second hold for the SAME request id replaces the first (the user may speak again while the
    /// interruption is un-acknowledged; only the latest utterance is submitted). A hold for a
    /// DIFFERENT request id is refused when one is already held — the contract has exactly one
    /// retained follow-up at a time, and silently swapping it would strand the earlier one.
    @discardableResult
    func hold(
        request: String,
        utteranceId: String,
        origin: Int?,
        forRequestId requestId: String
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let releasedForRequestId, releasedForRequestId != requestId { return false }
        if let discardedForRequestId, discardedForRequestId != requestId { return false }
        held = HeldFollowUp(request: request, utteranceId: utteranceId, origin: origin)
        // A new hold re-opens the possibility of a terminal resolving it.
        if releasedForRequestId == requestId { releasedForRequestId = nil }
        return true
    }

    /// The terminal ARRIVED FIRST: the follow-up is now submit-ready, exactly once.
    ///
    /// Returns the released follow-up on the first call and nil on every one after, so two callers
    /// racing to submit cannot both win. `acknowledgingRequestId` distinguishes the cases: an
    /// acknowledgement for the held turn releases it.
    @discardableResult
    func recordTerminalAcknowledgement(forRequestId requestId: String) -> ReleasedFollowUp? {
        lock.lock(); defer { lock.unlock() }
        // A terminal for a different turn is none of this type's business.
        guard interruptSentForRequestId == requestId || held != nil else { return nil }
        interruptSentForRequestId = nil
        // A second terminal for the SAME turn must not release the follow-up again — nor anything
        // else. Set BEFORE the "nothing held" test, so a repeat for the same turn is refused on the
        // CAS below. (An earlier version tested `releasedForRequestId == nil` first and then set it,
        // which a mutant that set it unconditionally survived untouched.)
        guard releasedForRequestId != requestId,
              releasedForRequestId == nil,
              discardedForRequestId == nil else { return nil }
        guard let followUp = held else {
            releasedForRequestId = requestId
            return nil
        }
        releasedForRequestId = requestId
        held = nil
        return ReleasedFollowUp(
            request: followUp.request,
            utteranceId: followUp.utteranceId,
            origin: followUp.origin,
            interruptedRequestId: requestId
        )
    }

    /// The REFUSAL arrived first: discard the follow-up, retain the report for a later explicit
    /// user request.
    ///
    /// Returns true when this call is the one that discarded it. After this, nothing may submit
    /// the follow-up for this request id, and a later acknowledgement cannot resurrect it.
    @discardableResult
    func recordRefusal(forRequestId requestId: String, retainingReport: PendingReport?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard releasedForRequestId == nil, discardedForRequestId == nil else { return false }
        // Only an ACTUAL interruption refusal retains a report. The earlier version wrote the
        // report before this guard, so a refusal of an unrelated turn replaced a genuinely pending
        // report describing the turn that was interrupted (caught by the ordering controls).
        guard interruptSentForRequestId == requestId || held != nil else { return false }
        interruptedReportLocked(retainingReport)
        interruptSentForRequestId = nil
        discardedForRequestId = requestId
        held = nil
        return true
    }

    // MARK: - The pending report

    /// ABANDONING THE CONVERSATION DISCARDS THE REPORT (`cloud-assistant.md` → Interruption:
    /// "Abandoning that conversation discards the report; retained history still cannot claim the
    /// generated answer was heard"). The report annotates one conversation's prior history, so
    /// carrying it into a DIFFERENT conversation would tell the server to correct turns it never
    /// settled. A conversation change is exactly that abandonment.
    func discardPendingReport() {
        lock.lock(); defer { lock.unlock() }
        pendingReport = nil
    }

    /// The conversation the pending report belongs to, if any. Read WITHOUT consuming, so a turn
    /// can decide whether this is the same conversation before it takes the report.
    var pendingReportConversationId: String? {
        lock.lock(); defer { lock.unlock() }
        return pendingReport?.conversationId
    }

    /// Take the report for the next turn's authentication frame.
    ///
    /// A report is consumed once and attached once: after this returns non-nil the caller owns it
    /// and a retry of the SAME turn must reuse it rather than dropping the correction.
    func takePendingReport() -> PendingReport? {
        lock.lock(); defer { lock.unlock() }
        let report = pendingReport
        pendingReport = nil
        return report
    }

    var hasPendingReport: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingReport != nil
    }

    /// Record a report for a later turn without an interrupt having been refused — the case where
    /// buffered answer audio kept playing after the prior turn's `done`.
    func recordPendingReport(_ report: PendingReport?) {
        lock.lock(); defer { lock.unlock() }
        interruptedReportLocked(report)
    }

    private func interruptedReportLocked(_ report: PendingReport?) {
        guard let report else { return }
        // Only the latest correction matters: a second report for the same prior turn supersedes
        // the first (both name a settled turn; the later position is the better evidence). A report
        // for a DIFFERENT turn is kept rather than overwritten only when it names the newer turn.
        pendingReport = report
    }

    /// Release a hold whose interrupt never left the client.
    ///
    /// Called when there was no transport to send on: no acknowledgement can ever arrive for an
    /// interruption the server never saw, so keeping the follow-up held would strand the user's own
    /// utterance forever. Not a retry path — the hold is dropped, not re-armed.
    func releaseUnsentHold(request: String) {
        lock.lock(); defer { lock.unlock() }
        guard let held, held.request == request else { return }
        self.held = nil
        interruptSentForRequestId = nil
    }

    // MARK: - Test seams (no production caller)

    var heldFollowUpForTesting: (request: String, utteranceId: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let held else { return nil }
        return (held.request, held.utteranceId)
    }

    var pendingReportForTesting: PendingReport? {
        lock.lock(); defer { lock.unlock() }
        return pendingReport
    }
}