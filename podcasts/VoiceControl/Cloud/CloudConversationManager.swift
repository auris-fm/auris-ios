import Combine
import Foundation

/// What selected a turn. The conversation mode follows this, not the wire history.
enum CloudConversationSelection: Equatable {
    /// A wake word. A wake that registers a NEW live origin always starts a new conversation;
    /// a delayed wake callback from an origin that has ended does not, and the selection alone
    /// cannot tell those apart — the origin does.
    case wakeWord
    /// A wake-free follow-up within the window. This is the only case that continues the
    /// conversation already open.
    case followUp
}

/// The complete logical request a turn must carry, prepared before it is dialled.
///
/// Carried whole rather than rebuilt: a transport retry of the same turn must reuse the SAME
/// `request_id` as well as the same conversation, and regenerating any part of it on a retry
/// makes the server see a second logical turn instead of the same one.
struct CloudPreparedConversation: Equatable {
    /// The wire `request_id` of this logical turn, stable across its transport retries.
    let requestId: String
    let conversationId: String
    /// Lowercase `create` or `resume`, required on every turn including the first.
    let mode: String
}

/// Prepares the conversation identity for each cloud turn
/// (`docs/specs/cloud-assistant.md` → "Conversations").
///
/// Every turn carries a client-generated UUID `conversation_id` and a lowercase
/// `conversation_mode`. The mode follows what actually selected the turn rather than remembered
/// history, because a wake word must always start a new conversation — a rule any "is a
/// conversation open?" test would violate.
///
/// The origin (the generation the turn was dispatched under) is the bound. A turn whose origin
/// is no longer live — a stale generation, an unstamped dispatch, or a delayed callback from a
/// window that has ended — is REFUSED rather than given a replacement conversation. Creating one
/// would turn a turn the user never made into a legitimate `create`, and it would also discard
/// the successor window's handle, so the follow-up that genuinely belonged to the live window
/// would then find nothing to resume.
final class CloudConversationManager {
    /// The origin currently in force.
    private var liveOrigin: Int?

    /// Carries ADMITTED-WORK authority to the prepare fence, for the same reason the dispatch
    /// fence consults it: a turn admitted before the deadline remains eligible through recognition
    /// (voice-control-core.md:270) and may prepare after the window expired, so an origin that is
    /// no longer live can still be the origin of admittedly-live work. Turn-scoped, so retirement
    /// and unrelated-generation reuse are still refused. Set by the assembly; nil keeps the
    /// live-origin-only fence.
    var admittedWorkAuthority: (() -> GracePeriodSignal.AdmittedWorkAuthority?)?

    var liveOriginForTesting: Int? { liveOrigin }

    /// The conversation opened in the live origin.
    private var current: OpenConversation?
    /// Conversations opened by DELAYED admitted work, keyed by the origin that opened them.
    ///
    /// A turn admitted before the deadline remains eligible through recognition and may prepare
    /// after its window expired, under ITS OWN origin. That turn owns its window's conversation
    /// and must not publish into `current`, which belongs to whichever window is live now: doing
    /// so would let a late turn replace a successor's handle, and the successor's own follow-up
    /// would then create a second conversation instead of resuming the one it opened.
    ///
    /// Keyed by origin rather than per-utterance so a follow-up of the SAME admitted window
    /// resumes the conversation that window opened, which is what the window-scoped rule is for.
    /// Retired with its origin (see `registerLiveOrigin`), so this is not an immortal second map.
    private var byOrigin: [Int: OpenConversation] = [:]
    /// REQUEST OWNERSHIP: utterance id -> prepared logical request, for utterances prepared in
    /// the LIVE window. Retired wholesale with the window (registerLiveOrigin change) — one
    /// entry per real utterance, never evicted mid-window.
    private var preparedByUtteranceId: [String: CloudPreparedConversation] = [:]

    private struct OpenConversation {
        let id: String
        let origin: Int
        /// The logical request that created this conversation. A same-owner retry of that
        /// request reuses the conversation rather than opening a second one.
        let creationRequestId: String
        /// Whether the server has acknowledged a turn in this conversation.
        var acknowledged: Bool
    }

    /// The conversation a live turn must carry, or nil when the turn's origin is not live.
    ///
    /// - Parameters:
    ///   - selection: what selected this turn.
    ///   - origin: the generation the turn was DISPATCHED under. `nil` for an unstamped
    ///     dispatch: it belongs to no window, so it cannot create or continue one.
    ///   - utteranceId: the admitted utterance's identity. A transport retry of the SAME
    ///     utterance passes the SAME id and is served from retention — it can never adopt
    ///     a different identity, and a turn without an id is refused.
    func prepare(
        selection: CloudConversationSelection,
        origin: Int?,
        utteranceId: String? = nil
    ) -> CloudPreparedConversation? {
        // Origin validated BEFORE every reuse path (reviewer 0c546ce5 item 3): a stale
        // callback — including one carrying a retained utterance identity or a retry id — can
        // never bypass the live-window check.
        // An origin that is no longer live can still be the origin of admittedly-live work
        // (a turn admitted before the deadline and still in recognition). Both are checked
        // against THIS turn's identity, so neither admits retired or unrelated work.
        guard let origin else { return nil }
        let originIsLive = origin == liveOrigin
        let turnHoldsAdmittedWork: Bool = {
            guard let authority = admittedWorkAuthority?() else { return false }
            return authority.isAdmittedWork(utteranceId ?? "", origin)
        }()
        guard originIsLive || turnHoldsAdmittedWork else { return nil }

        // ONE IDENTITY ON THE WIRE (contract delta f47e972, reviewer 9ab31c6d): the turn's
        // `request_id` IS the admitted utterance's identity. A dispatch without one has no
        // identity to present and is refused here — the manager never mints a stand-in UUID,
        // so no turn can reach the wire under a fabricated identity.
        guard let utteranceId else { return nil }

        // REQUEST OWNERSHIP (owner delta 3484cbc/5eca874): a repeated callback for the SAME
        // utterance reuses its retained logical request. RETENTION RULE: every utterance
        // prepared inside the live window is retained for exactly the WINDOW's lifetime — no
        // cap, no eviction — so a duplicate can never become a fresh dispatch; the window's
        // close (registerLiveOrigin to nil or a new generation) retires the whole map.
        if let prepared = preparedByUtteranceId[utteranceId] {
            return prepared
        }

        var prepared: CloudPreparedConversation
        // The conversation this turn carries: the one opened FOR ITS OWN ORIGIN, so a delayed
        // admitted turn continues its own window's conversation and never the successor's.
        //
        // The window's conversation, whatever its acknowledgement state: preparation names it and
        // the mode is decided at the SEND (`dialed`), because `connected` may arrive while this turn
        // waits for a predecessor to quiesce. A create replaces it — the window has moved on — so
        // only its latest conversation can be continued.
        let existingForOrigin = originIsLive ? current : byOrigin[origin]
        if case .followUp = selection, let existing = existingForOrigin, existing.origin == origin {
            prepared = CloudPreparedConversation(
                requestId: utteranceId,
                conversationId: existing.id,
                mode: Self.resume
            )
        } else {
            // Held as the window's conversation but UNACKNOWLEDGED: only `connected` makes it
            // resumable, and that is decided at the send (`dialed`), not here.
            let opened = OpenConversation(
                id: UUID().uuidString,
                origin: origin,
                creationRequestId: utteranceId,
                acknowledged: false
            )
            // The window's own conversation, unacknowledged. A later create of the same window
            // replaces it — the window has moved on — and `connected` for a replaced one lands on
            // nothing, which is right: that conversation was never continued.
            if originIsLive { current = opened } else { byOrigin[origin] = opened }
            prepared = CloudPreparedConversation(
                requestId: utteranceId,
                conversationId: opened.id,
                mode: Self.create
            )
        }
        // Both create AND resume preparations are retained under the utterance identity.
        preparedByUtteranceId[utteranceId] = prepared
        return prepared
    }

    /// Binds a grace-window signal to this manager's live origin, and returns the cancellable
    /// that owns the subscription.
    ///
    /// This is the PRODUCTION registration path: the assembly uses it, and the test drives the
    /// same function rather than re-implementing the closure. A test that copies the closure
    /// instead tests its own copy, so breaking this wiring would leave the test green.
    @discardableResult
    static func bindLiveOrigin(to signal: GracePeriodSignal, on manager: CloudConversationManager) -> AnyCancellable {
        signal.$isActive.sink { active in
            // Registration follows the WINDOW, not merely its opening. When the signal closes,
            // no generation is live at all, so the origin must be cleared rather than left
            // naming the ended generation (PR #49 review comment 4305981418): otherwise a turn
            // dispatched while the window was open still matches `origin == liveOrigin` after
            // the window ends and creates or resumes a conversation the contract above refuses.
            // Closing always bumps the generation first, so a successor wake re-registers here
            // with the new value; a close with no successor registers nil.
            manager.registerLiveOrigin(active ? signal.currentGeneration() : nil)
        }
    }

    /// Records the origin currently in force, or clears it when `origin` is nil. A turn may only
    /// create or continue a conversation inside the window that is live *now*; an origin that was
    /// live when a request was dispatched but has since been replaced — or whose window has
    /// closed — cannot.
    func registerLiveOrigin(_ origin: Int?) {
        if origin != liveOrigin {
            // The owning window ended (or a new one opened): retained preparations belong to
            // the request/conversation lifecycle of THAT window and retire with it. Delayed
            // admitted conversations are held per origin and retire the same way, once no
            // admitted turn can still reach them.
            preparedByUtteranceId.removeAll()
            let authority = admittedWorkAuthority?()
            // The OUTGOING live conversation belongs to the origin that is being replaced. If
            // admitted work still holds that origin, its handle must be preserved so a delayed
            // follow-up RESUMES the conversation that window opened. Dropping it here is what
            // made a delayed follow-up open a second conversation for the same window.
            if let outgoing = current, authority?.hasAdmittedWork(outgoing.origin) == true {
                byOrigin[outgoing.origin] = outgoing
            }
            // Keep only conversations of origins that are STILL admitted work (a delayed turn
            // may yet prepare against its own origin) plus the origin now in force. This keeps
            // the map bounded by live admitted work rather than growing forever.
            byOrigin = byOrigin.filter { key, _ in
                key == origin || authority?.hasAdmittedWork(key) == true
            }
        }
        liveOrigin = origin
    }

    /// The conversation a prepared turn DIALS with, decided at the SEND rather than at preparation.
    ///
    /// The rule is one line — a follow-up may only resume a conversation the server has
    /// acknowledged — but it cannot be answered when the turn is prepared. Preparation happens
    /// before the sink waits for a predecessor to quiesce, and `connected` for the conversation
    /// being continued may arrive during that wait: deciding early meant sending `resume` for a
    /// conversation that was still a draft at the moment it went out.
    ///
    /// The prepared REQUEST identity is kept exactly as it is: a transport retry of the same
    /// logical request must present the same `request_id`.
    ///
    /// When the decision does change the conversation, the replacement is PUBLISHED as that
    /// window's conversation and retained under the utterance identity, exactly as a create made
    /// at preparation is. Otherwise the id would exist only on the wire: its `connected` would
    /// acknowledge nothing this client holds, the next follow-up would take the same branch
    /// again, and the user's thread would restart on every utterance for as long as the first
    /// create stayed unacknowledged. Publishing is also what makes a retry of THIS request reuse
    /// the conversation it actually dialled rather than minting a third one.
    func dialed(
        prepared: CloudPreparedConversation,
        selection: CloudConversationSelection,
        origin: Int?
    ) -> CloudPreparedConversation {
        guard selection == .followUp, prepared.mode == Self.resume,
              !isAcknowledgedForTesting(conversationId: prepared.conversationId)
        else { return prepared }
        // Still unacknowledged at the moment of sending: this turn opens its own conversation.
        let opened = OpenConversation(
            id: UUID().uuidString,
            origin: origin ?? liveOrigin ?? 0,
            creationRequestId: prepared.requestId,
            acknowledged: false
        )
        if opened.origin == liveOrigin { current = opened } else { byOrigin[opened.origin] = opened }
        let replacement = CloudPreparedConversation(
            requestId: prepared.requestId,
            conversationId: opened.id,
            mode: Self.create
        )
        preparedByUtteranceId[prepared.requestId] = replacement
        return replacement
    }

    /// Records that the server acknowledged a turn in this conversation by sending `connected`,
    /// making the handle resumable. Called from the turn that RECEIVED the frame, so the binding
    /// is the wire's rather than an inference from a send that was merely attempted.
    ///
    /// An id this client is not holding is ignored: a late acknowledgement for a conversation a
    /// successor window already replaced must not convert the live conversation into something a
    /// follow-up resumes, and it must not resurrect a handle `forget` released.
    func acknowledge(conversationId: String) {
        // Marked IN PLACE, wherever the window holds it, so a retry's creation request id and an
        // earlier window's handle both survive. An id this client is not holding matches nothing.
        if let live = current, live.id == conversationId {
            current = OpenConversation(
                id: live.id, origin: live.origin, creationRequestId: live.creationRequestId,
                acknowledged: true
            )
        } else if let key = byOrigin.first(where: { $0.value.id == conversationId })?.key {
            let held = byOrigin[key]!
            byOrigin[key] = OpenConversation(
                id: held.id, origin: held.origin, creationRequestId: held.creationRequestId,
                acknowledged: true
            )
        }
    }

    /// TEST SEAM: the wire identity prepared for an utterance, so a control can name the
    /// conversation a turn actually carried rather than one it wrote itself.
    func preparedConversationForTesting(utteranceId: String) -> CloudPreparedConversation? {
        preparedByUtteranceId[utteranceId]
    }

    /// TEST SEAM: whether the manager currently holds this conversation as resumable.
    func isAcknowledgedForTesting(conversationId: String) -> Bool {
        if let live = current, live.id == conversationId { return live.acknowledged }
        return byOrigin.values.first { $0.id == conversationId }?.acknowledged ?? false
    }

    /// Leaves ONE conversation: the client stops naming it and the server's history expires by
    /// TTL. Scoped by id because the turn asking to leave may belong to an EARLIER window while a
    /// newer window is already in its own conversation — releasing everything there would drop
    /// the conversation the user is actually in, and their next follow-up would silently start
    /// over. An id this client never opened releases nothing.
    func forget(conversationId: String) {
        if current?.id == conversationId { current = nil }
        byOrigin = byOrigin.filter { $0.value.id != conversationId }
        // A retained preparation naming the released conversation would hand the same dead id
        // back to a repeated callback for that utterance.
        preparedByUtteranceId = preparedByUtteranceId.filter { $0.value.conversationId != conversationId }
    }

    /// The client stops naming a conversation to leave it; the retained history expires by
    /// TTL.
    func forget() {
        current = nil
        byOrigin.removeAll()
        preparedByUtteranceId.removeAll()
    }

    /// Releases the delayed-work state that existed ONLY for this turn's admitted work: once the
    /// turn's reservation is gone, the conversation its window opened can no longer be reached by
    /// a delayed follow-up, so keeping it would be exactly the unbounded retention the window
    /// sweep exists to avoid. Released by the turn's OWN completion, not by a future wake.
    /// TEST SEAM: whether a delayed conversation is currently retained for this origin.
    func hasDelayedStateForTesting(forOrigin origin: Int) -> Bool { byOrigin[origin] != nil }

    func releaseDelayedState(forOrigin origin: Int) {
        guard origin != liveOrigin else { return }
        // Only when the LAST admitted owner of that origin has gone. Two admitted turns of the
        // same window can be in flight at once; the first completion must NOT delete the shared
        // conversation the second still needs, or that one opens a duplicate instead of resuming.
        // The admitted-work count is the authority, so this is a refcount, not an inference.
        guard admittedWorkAuthority?()?.hasAdmittedWork(origin) != true else { return }
        byOrigin.removeValue(forKey: origin)
    }

    

    private static let create = "create"
    private static let resume = "resume"
}
