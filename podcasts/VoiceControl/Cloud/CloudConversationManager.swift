import Foundation

/// What selected a turn. The conversation mode follows this, not the wire history.
enum CloudConversationSelection: Equatable {
    /// A wake word. The spec: "A wake word always selects a new conversation, even during
    /// grace." Nothing resumes.
    case wakeWord
    /// A wake-free follow-up within the window. This is the only case that continues the
    /// conversation that is already open.
    case followUp
}

/// The conversation identity a turn must carry, prepared before the turn is dialled.
struct CloudPreparedConversation: Equatable {
    let conversationId: String
    /// Lowercase `create` or `resume`, required on every turn including the first.
    let mode: String
    /// The request id of the turn that created this conversation. A same-owner retry of that
    /// creation reuses the conversation rather than opening a second one.
    let creationRequestId: String
}

/// Prepares the conversation identity for each cloud turn
/// (`docs/specs/cloud-assistant.md` → "Conversations").
///
/// Every turn carries a client-generated UUID `conversation_id` and a lowercase
/// `conversation_mode`. The mode is derived from what actually selected the turn rather than
/// from remembered history, because a wake word must always start a new conversation — a rule
/// that would be violated by any "is there an open conversation?" test.
///
/// The origin is the generation the turn runs under. A turn from an origin that no longer
/// exists cannot resume a conversation that belonged to a different one, so a stale origin
/// discards and creates instead; otherwise a turn the user never made could continue a
/// conversation they had left.
final class CloudConversationManager {
    private struct OpenConversation {
        let id: String
        let origin: Int
        let creationRequestId: String
    }

    private var open: OpenConversation?

    /// - Parameters:
    ///   - selection: what selected this turn.
    ///   - generation: the origin the turn runs under.
    ///   - retryingCreationRequestId: set when this is a transport retry of a turn that
    ///     already created a conversation; the retry keeps that conversation's identity
    ///     instead of opening a second one.
    func prepare(
        selection: CloudConversationSelection,
        generation: Int,
        retryingCreationRequestId: String? = nil
    ) -> CloudPreparedConversation {
        // A retry of a creation keeps the identity it created, whatever selected it: the
        // logical turn is the same turn, and a second conversation would strand the first.
        if let creationRequestId = retryingCreationRequestId,
           let existing = open,
           existing.creationRequestId == creationRequestId {
            return CloudPreparedConversation(
                conversationId: existing.id,
                mode: Self.create,
                creationRequestId: creationRequestId
            )
        }

        // Resume only a follow-up that belongs to the origin still in force. Everything
        // else creates: a wake word by rule, and a stale origin because it cannot be
        // attributed to the conversation it would continue.
        if case .followUp = selection,
           let existing = open,
           existing.origin == generation {
            return CloudPreparedConversation(
                conversationId: existing.id,
                mode: Self.resume,
                creationRequestId: existing.creationRequestId
            )
        }

        let id = UUID().uuidString
        let requestId = UUID().uuidString
        open = OpenConversation(id: id, origin: generation, creationRequestId: requestId)
        return CloudPreparedConversation(
            conversationId: id,
            mode: Self.create,
            creationRequestId: requestId
        )
    }

    /// The client stops naming a conversation to leave it; the retained history expires by
    /// TTL. Nothing is sent on the wire to end one.
    func forget() {
        open = nil
    }

    private static let create = "create"
    private static let resume = "resume"
}
