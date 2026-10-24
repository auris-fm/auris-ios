import Foundation

/// The ALLOWLISTED acceptance record: the only fields acceptance evidence may carry.
///
/// It exists because the alternative — capturing the client log and redacting secrets with a regex — is
/// not safe: a redactor that misses one form (for example `Authorization: Bearer <token>`) leaks a
/// credential. Nothing outside these four fields is ever recorded, so there is no secret to redact.
///
/// Direction matters: `CloudTurnEnvelope.recentConversation` is OUTGOING request context built by
/// `CloudTurnEnvelope.make`, not a server response. Acceptance recall must be judged on the INCOMING
/// response, so this record is produced at the transport boundary where `CloudRouteEvent`s are parsed.
struct CloudAcceptanceRecord: Equatable {
    /// The REQUEST identity of the submitted turn, carried from the turn the route loop actually
    /// submitted. A fresh recorder alone does not establish request identity: without this field two
    /// steps' records are indistinguishable, so recall could be judged against the wrong turn.
    let requestId: String?
    /// The conversation this turn belongs to.
    let conversationId: String?
    /// Text the SERVER sent for this turn (the `token` events), accumulated for this turn only.
    let responseText: String
    /// The terminal outcome of this turn, or nil while it is still open.
    let terminal: Terminal?

    /// WHERE a terminal outcome originated. Bounded to the observable stages of this protocol.
    enum Stage: String, Equatable {
        /// The client could not construct the request (bad URL, unencodable frame).
        case clientRequest
        /// An ERROR EVENT parsed from the server's frames.
        case serverEvent
        /// The transport failed or the stream ended without a terminal event.
        case transport
        /// The caller cancelled the turn.
        case cancelled
    }

    enum Terminal: Equatable {
        case done
        /// A parsed server error, a transport failure, or a socket/stream that ended WITHOUT a
        /// terminal event. A missing done/error is an INCOMPLETE outcome and is classified as a
        /// transport failure, not as cancellation: upstream EOF is not, by itself, cancellation.
        ///
        /// The STAGE says WHERE the outcome originated, because the code alone does not: the same
        /// code string can come from client request construction or from a served error, and the
        /// export previously carried only the code, so neither could be distinguished after the fact.
        /// The server's message, carried ONLY when the stage is a served event. It answers the question
        /// the code alone cannot: whether an empty message was actually sent, or merely not surfaced.
        /// The client's own construction failures carry no server message.
        case transportFailure(stage: Stage, code: String, message: String?)
        /// The turn was EXPLICITLY cancelled. Only a caller saying "this turn was cancelled" produces
        /// this: it is never inferred from an upstream EOF or a downstream termination, because those
        /// also happen on ordinary completion and on failure.
        case cancelled
    }

    /// A recorder for one turn. It is request-scoped: the caller creates one per turn and reads it
    /// after the terminal event, so evidence from one turn can never satisfy another.
    final class Recorder {
        private let lock = NSLock()
        private var text = ""
        private var terminal: Terminal?
        private var cancelled = false
        private let conversationId: String?
        private let requestId: String?

        init(requestId: String? = nil, conversationId: String?) {
            self.requestId = requestId
            self.conversationId = conversationId
        }

        /// Marks the turn EXPLICITLY cancelled. The caller must know the turn was cancelled: this is
        /// never inferred, because an upstream EOF or a downstream termination also occurs on ordinary
        /// completion and on failure, and mislabelling those as cancellation would hide a real
        /// transport failure.
        func markCancelled() {
            lock.lock(); defer { lock.unlock() }
            if terminal == nil { terminal = .cancelled }
        }

        /// Marks the stream ENDED WITHOUT a terminal event: an incomplete turn, classified as a
        /// transport failure rather than as cancellation or success.
        func markStreamEndedWithoutTerminal() {
            lock.lock(); defer { lock.unlock() }
            if terminal == nil {
                terminal = .transportFailure(stage: .transport, code: "stream_ended_without_terminal", message: nil)
            }
        }

        /// Called at the transport boundary for every event of THIS turn.
        ///
        /// THE TERMINAL IS FINAL: once a turn has a terminal, later events are ignored, so a trailing
        /// token cannot extend a finished turn's response and a second terminal cannot overwrite the
        /// first. Overwriting would let a late frame rewrite the outcome a consumer had already read.
        func observe(_ event: CloudRouteEvent) {
            lock.lock(); defer { lock.unlock() }
            guard terminal == nil else { return }
            switch event {
            case .token(let t):
                text += t
            case .done:
                terminal = .done
            case .error(let source, let code, let message):
                // THE SOURCE IS STRUCTURAL, taken from the event itself rather than inferred from the
                // message text. The previous version sniffed a `stage=clientRequest` prefix, which
                // misclassifies whenever a server message happens to look like a tag or a tag is
                // reworded. The SERVER MESSAGE is retained for a served error so the export can answer
                // whether it was present and empty.
                let stage: Stage
                switch source {
                case .requestConstruction: stage = .clientRequest
                case .transport: stage = .transport
                case .server: stage = .serverEvent
                }
                terminal = .transportFailure(
                    stage: stage,
                    code: code,
                    message: stage == .serverEvent ? message : nil
                )
            default:
                break   // audio, actions and discovery results carry no acceptance field
            }
        }

        /// The record for this turn. `terminal == nil` means the turn never finished, which is a real
        /// outcome rather than a success.
        func record() -> CloudAcceptanceRecord {
            lock.lock(); defer { lock.unlock() }
            return CloudAcceptanceRecord(
                requestId: requestId,
                conversationId: conversationId,
                responseText: text,
                terminal: terminal
            )
        }
    }
}
