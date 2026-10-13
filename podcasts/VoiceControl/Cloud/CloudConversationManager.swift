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

    /// The conversation opened in the live origin.
    private var current: OpenConversation?

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
    ///   - retryingRequestId: set when this is a transport retry of a turn that already
    ///     created a conversation; the retry reuses that conversation AND its `request_id`.
    func prepare(
        selection: CloudConversationSelection,
        origin: Int?,
        retryingRequestId: String? = nil
    ) -> CloudPreparedConversation? {
        // A retry reuses the prepared logical request rather than rebuilding it, so the wire
        // `request_id` is the one the original attempt used.
        if let retryingRequestId,
           let existing = current,
           existing.creationRequestId == retryingRequestId {
            return CloudPreparedConversation(
                requestId: retryingRequestId,
                conversationId: existing.id,
                mode: Self.create
            )
        }

        // No live origin means no claim on any conversation. Refuse rather than create: a
        // replacement would be a conversation the user never opened, and it would also take
        // the place of the live window's own conversation.
        guard let origin, origin == liveOrigin else { return nil }

        if case .followUp = selection, let existing = current, existing.origin == origin {
            return CloudPreparedConversation(
                requestId: UUID().uuidString,
                conversationId: existing.id,
                mode: Self.resume
            )
        }

        let requestId = UUID().uuidString
        let conversationId = UUID().uuidString
        current = OpenConversation(
            id: conversationId,
            origin: origin,
            creationRequestId: requestId
        )
        return CloudPreparedConversation(
            requestId: requestId,
            conversationId: conversationId,
            mode: Self.create
        )
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
            if active { manager.registerLiveOrigin(signal.currentGeneration()) }
        }
    }

    /// Records the origin currently in force. A turn may only create or continue a
    /// conversation inside the window that is live *now*; an origin that was live when a
    /// request was dispatched but has since been replaced cannot.
    func registerLiveOrigin(_ origin: Int) {
        liveOrigin = origin
    }

    /// The client stops naming a conversation to leave it; the retained history expires by
    /// TTL.
    func forget() {
        current = nil
    }

    

    private static let create = "create"
    private static let resume = "resume"
}
