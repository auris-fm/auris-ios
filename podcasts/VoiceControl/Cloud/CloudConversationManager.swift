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
        let existingForOrigin = originIsLive ? current : byOrigin[origin]
        if case .followUp = selection, let existing = existingForOrigin, existing.origin == origin {
            prepared = CloudPreparedConversation(
                requestId: utteranceId,
                conversationId: existing.id,
                mode: Self.resume
            )
        } else {

            let requestId = utteranceId
            let conversationId = UUID().uuidString
            let opened = OpenConversation(
                id: conversationId,
                origin: origin,
                creationRequestId: requestId
            )
            // A turn of the LIVE window publishes to `current`; a delayed admitted turn keeps
            // its conversation under its own origin, where its follow-ups will find it.
            if originIsLive {
                current = opened
            } else {
                byOrigin[origin] = opened
            }
            prepared = CloudPreparedConversation(
                requestId: requestId,
                conversationId: conversationId,
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
