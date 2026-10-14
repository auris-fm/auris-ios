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
    /// The conversation this turn belongs to.
    let conversationId: String?
    /// Text the SERVER sent for this turn (the `token` events), accumulated for this turn only.
    let responseText: String
    /// The terminal outcome of this turn, or nil while it is still open.
    let terminal: Terminal?

    enum Terminal: Equatable {
        case done
        case error(code: String)
    }

    /// A recorder for one turn. It is request-scoped: the caller creates one per turn and reads it
    /// after the terminal event, so evidence from one turn can never satisfy another.
    final class Recorder {
        private let lock = NSLock()
        private var text = ""
        private var terminal: Terminal?
        private let conversationId: String?

        init(conversationId: String?) { self.conversationId = conversationId }

        /// Called at the transport boundary for every event of THIS turn.
        func observe(_ event: CloudRouteEvent) {
            lock.lock(); defer { lock.unlock() }
            switch event {
            case .token(let t):
                text += t
            case .done:
                terminal = .done
            case .error(let code, _):
                terminal = .error(code: code)
            default:
                break   // audio, actions and discovery results carry no acceptance field
            }
        }

        /// The record for this turn. `terminal == nil` means the turn never finished, which is a real
        /// outcome rather than a success.
        func record() -> CloudAcceptanceRecord {
            lock.lock(); defer { lock.unlock() }
            return CloudAcceptanceRecord(conversationId: conversationId, responseText: text, terminal: terminal)
        }
    }
}
