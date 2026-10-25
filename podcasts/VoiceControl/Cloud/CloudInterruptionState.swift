import Foundation

/// Client-side interruption state (`docs/specs/cloud-assistant.md` → Interruption, pinned
/// `9e309cc1`).
///
/// The contract requires the client to hold, across a turn boundary, two things:
///
///   * **the retained follow-up** — the complete interrupting utterance, held until the PRIOR turn
///     reaches a terminal acknowledgement, then submitted ONCE on its own socket; and
///   * **the pending interruption report** — `{"request_id", "playback_position_ms"}`, attached to
///     the next turn's authentication frame so the server can correct already-settled history
///     before assembling model input.
///
/// Both orderings are reachable and they resolve differently:
///
///   * **acknowledgement first** (`done` for the interrupted turn, even with `completed`) — the
///     follow-up is released for submission exactly once, and the report is retained;
///   * **refusal first** (a pre-terminal `invalid_request` on that turn) — the follow-up is
///     DISCARDED, the report is retained, and nothing is submitted.
///
/// REQUEST BINDING IS THE CENTRAL INVARIANT. Every transition here names the interrupted turn, and
/// a terminal for any OTHER turn is ignored. An earlier version released the hold for whatever
/// terminal arrived while something was held, which let an unrelated turn's `done` authorise a
/// follow-up the user had addressed to the interrupted one (reviewer ff00457c item 2). The bound
/// id is `interruptedRequestId`, set by `hold` and never inferred from "something is pending".
///
/// SEQUENTIAL INTERRUPTIONS. Resolving one interruption must not lock out the next: the resolved
/// ids live in `resolved` and are consulted per turn, rather than a single "released" slot that
/// stayed set forever and made `claimInterruptEmission` refuse every later turn (reviewer item 3).
///
/// REPORT DURABILITY. `takePendingReport` does NOT clear. The report survives until it is either
/// ACKNOWLEDGED as attached to a turn that reached the server (`confirmReportAttached`) or the
/// conversation is abandoned. An earlier version cleared on take, so a connection or token failure
/// before the frame left destroyed the correction with no way to recover it (reviewer item 4).
///
/// Thread-safety: one lock for every transition. The type is a plain class rather than an actor
/// because the sink's turn loop is not async-isolated from it at every call site, and a suspended
/// await between "read the follow-up" and "submit it" is exactly where a second submit must lose.
final class CloudInterruptionState: @unchecked Sendable {
    /// The pending report attached to the next turn's auth frame.
    ///
    /// Carries no playback position until one is measured: the contract makes
    /// `playback_position_ms` optional and calls it untrusted reported progress, so an absent
    /// measurement is omitted rather than guessed.
    struct PendingReport: Equatable {
        let requestId: String
        let playbackPositionMs: Int64?
        /// The conversation whose settled history this report corrects. A report is valid only
        /// inside ITS conversation; abandoning that conversation discards it.
        var conversationId: String?
    }

    /// A follow-up released for submission.
    struct ReleasedFollowUp: Equatable {
        let request: String
        let utteranceId: String
        let origin: Int?
        /// The INTERRUPTED turn this follow-up was addressed to — the subject of the pending
        /// report and, with the release, the whole authority to submit.
        let interruptedRequestId: String
    }

    private struct HeldFollowUp {
        let request: String
        let utteranceId: String
        let origin: Int?
        /// The turn this utterance interrupts. Bound at hold time; a terminal for any other turn
        /// must not resolve it.
        let interruptedRequestId: String
    }

    private let lock = NSLock()

    /// The interrupting utterance, held while ITS interrupted turn is live.
    private var held: HeldFollowUp?
    /// The report awaiting the next turn.
    private var pendingReport: PendingReport?
    /// The turn whose interrupt has already been emitted. ONE shot per turn, and cleared as soon
    /// as that turn resolves, so a LATER turn may interrupt again.
    private var interruptSentForRequestId: String?
    /// Turns whose interruption is already resolved (released or discarded). Consulted per turn so
    /// one resolution cannot block the next interruption (reviewer item 3).
    private var resolved: Set<String> = []

    // MARK: - Emitting the interrupt (one shot per turn)

    /// Whether an `interrupt` frame should be sent for `requestId`.
    ///
    /// Returns true at most once per request id, and never for a turn already resolved. The caller
    /// sends on that turn's OPEN socket immediately: if its terminal has arrived the frame is
    /// useless (the server ignores post-terminal interrupts), which is why a resolved turn refuses.
    func claimInterruptEmission(forRequestId requestId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resolved.contains(requestId) else { return false }
        guard interruptSentForRequestId == nil else { return false }
        guard held == nil else { return false }
        interruptSentForRequestId = requestId
        return true
    }

    /// True once an interrupt was emitted for this turn and its terminal has not landed yet.
    func hasOpenInterrupt(forRequestId requestId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return interruptSentForRequestId == requestId && !resolved.contains(requestId)
    }

    /// The turn currently interrupted and unresolved, if any. The sink uses this to know whether a
    /// successor must wait before going on the wire.
    var interruptedRequestId: String? {
        lock.lock(); defer { lock.unlock() }
        return interruptSentForRequestId
    }

    // MARK: - Holding the follow-up

    /// Hold `request` as the follow-up for the interrupted turn `interruptedRequestId`.
    ///
    /// A second hold for the SAME interrupted turn replaces the first (the user may speak again
    /// while the interruption is un-acknowledged; only the latest utterance is submitted). A hold
    /// for a DIFFERENT turn is refused while one is outstanding — the contract has exactly one
    /// retained follow-up at a time, and silently swapping it would strand the earlier one.
    @discardableResult
    func hold(
        request: String,
        utteranceId: String,
        origin: Int?,
        forRequestId interruptedRequestId: String
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resolved.contains(interruptedRequestId) else { return false }
        if let held, held.interruptedRequestId != interruptedRequestId { return false }
        held = HeldFollowUp(
            request: request,
            utteranceId: utteranceId,
            origin: origin,
            interruptedRequestId: interruptedRequestId
        )
        return true
    }

    /// The INTERRUPTED turn reached its terminal: release the follow-up exactly once.
    ///
    /// Returns the follow-up on the first call for that turn and nil on every call after, so two
    /// callers racing to submit cannot both win. A terminal for any OTHER turn returns nil and
    /// changes nothing — that is the binding reviewer ff00457c item 2 required.
    @discardableResult
    func recordTerminalAcknowledgement(forRequestId requestId: String) -> ReleasedFollowUp? {
        lock.lock(); defer { lock.unlock() }
        guard let held else { return nil }
        // THE BINDING: only the interrupted turn's own terminal may release its follow-up.
        guard held.interruptedRequestId == requestId else { return nil }
        guard !resolved.contains(requestId) else { return nil }
        resolved.insert(requestId)
        self.held = nil
        if interruptSentForRequestId == requestId { interruptSentForRequestId = nil }
        return ReleasedFollowUp(
            request: held.request,
            utteranceId: held.utteranceId,
            origin: held.origin,
            interruptedRequestId: requestId
        )
    }

    /// The INTERRUPTED turn was refused before any terminal: discard the follow-up, retain a report
    /// naming that turn.
    ///
    /// Returns true when this call is the one that resolved it. After this nothing may submit the
    /// follow-up for that turn and a later acknowledgement cannot resurrect it.
    @discardableResult
    func recordRefusal(forRequestId requestId: String, retainingReport: PendingReport?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resolved.contains(requestId) else { return false }
        // A refusal for a turn that neither holds a follow-up nor has an emitted interrupt is not
        // an interruption refusal at all — retain nothing, resolve nothing. (An earlier version
        // wrote the report before this test, so a refusal of an unrelated turn replaced a genuinely
        // pending report describing the turn that WAS interrupted.)
        let isInterruption = held?.interruptedRequestId == requestId
            || interruptSentForRequestId == requestId
        guard isInterruption else { return false }
        resolved.insert(requestId)
        // REFUSAL DISCARDS THE UTTERANCE: mark it suppressed so its already-enqueued turn cannot
        // reach the wire. The contract forbids submitting it after a refusal.
        if let held, held.interruptedRequestId == requestId {
            suppressedUtterances.insert(held.utteranceId)
        }
        held = nil
        if interruptSentForRequestId == requestId { interruptSentForRequestId = nil }
        if let report = retainingReport {
            pendingReport = PendingReport(
                requestId: report.requestId,
                playbackPositionMs: report.playbackPositionMs,
                conversationId: report.conversationId
            )
        }
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
    /// can decide whether this is still the same conversation before it attaches the report.
    var pendingReportConversationId: String? {
        lock.lock(); defer { lock.unlock() }
        return pendingReport?.conversationId
    }

    /// The report to attach to a turn's authentication frame. Does NOT consume it.
    ///
    /// The caller must call `confirmReportAttached(requestId:)` once that turn's frame has actually
    /// reached the transport. Retaining until then is what makes a failed connection, a token
    /// failure or an unbuildable frame harmless: the correction survives for the next attempt
    /// instead of being destroyed by the attempt that failed (reviewer ff00457c item 4).
    func takePendingReport() -> PendingReport? {
        lock.lock(); defer { lock.unlock() }
        return pendingReport
    }

    /// The turn carrying this report reached the transport: the correction is spent.
    ///
    /// Only the report that was actually carried is cleared, so a newer report recorded in the
    /// meantime is not lost by a late confirmation for an older turn.
    func confirmReportAttached(requestId: String) {
        lock.lock(); defer { lock.unlock() }
        guard pendingReport?.requestId == requestId else { return }
        pendingReport = nil
    }

    var hasPendingReport: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingReport != nil
    }

    /// Record a report for a later turn without an interrupt having been refused — the case where
    /// buffered answer audio kept playing after the interrupted turn's `done`.
    func recordPendingReport(_ report: PendingReport?) {
        lock.lock(); defer { lock.unlock() }
        guard let report else { return }
        pendingReport = report
    }

    /// Release a hold whose interrupt never left the client.
    ///
    /// Called when there was no transport to send on, or the send reported `.undelivered`: no
    /// acknowledgement can ever arrive for an interruption the server never saw, so keeping the
    /// follow-up held would strand the user's own utterance forever. The turn is NOT marked
    /// resolved — nothing happened to it — so it may be interrupted by a later turn. Not a retry
    /// path: the hold is dropped, not re-armed.
    func releaseUnsentHold(forRequestId requestId: String) {
        lock.lock(); defer { lock.unlock() }
        guard held?.interruptedRequestId == requestId else { return }
        held = nil
        if interruptSentForRequestId == requestId { interruptSentForRequestId = nil }
    }

    /// The interruption was REFUSED: the retained utterance must be DISCARDED, never submitted.
    ///
    /// Distinct from `releaseUnsentHold` (which means "the interrupt never reached the server"):
    /// here the server did answer, and its answer was refuse. The contract is explicit — "never
    /// treat refusal as settlement or automatically submit the held utterance" — so the utterance
    /// is marked as suppressed. Its already-enqueued turn must not reach the wire.
    func suppressHeldFollowUp(forRequestId requestId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let held, held.interruptedRequestId == requestId else { return }
        // Remember the UTTERANCE, not just the turn: its queued dispatch asks this before sending.
        suppressedUtterances.insert(held.utteranceId)
        self.held = nil
        if interruptSentForRequestId == requestId { interruptSentForRequestId = nil }
    }

    /// Whether this utterance's interruption was refused, so it must not be submitted.
    func isSuppressed(_ utteranceId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return suppressedUtterances.contains(utteranceId)
    }

    private var suppressedUtterances: Set<String> = []

    // MARK: - Retained-follow-up binding (PRODUCTION: the eager barge-in path)

    /// The turn this utterance is the retained follow-up FOR, or nil.
    ///
    /// Used by the eager interruption path to recognise its own earlier emission without awaiting:
    /// an utterance that already holds a follow-up must adopt that binding rather than claim a
    /// second interruption.
    func interruptedRequestId(forHeldUtterance utteranceId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let held, held.utteranceId == utteranceId else { return nil }
        return held.interruptedRequestId
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

    var resolvedForTesting: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return resolved
    }
}