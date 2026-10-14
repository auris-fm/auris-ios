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

    enum Terminal: Equatable {
        case done
        /// A parsed server error, a transport failure, OR a socket that closed with no terminal —
        /// the transport paths all surface as an error event carrying a code.
        case error(code: String)
        /// The turn was CANCELLED. The transport finishes the stream with NO terminal event on
        /// cancellation, so a cancelled turn is recorded as such rather than left looking open (or,
        /// worse, looking successful). This is the case a parsed-done/error-only recorder misses.
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

        /// Marks the turn cancelled. The transport `finish()`es without a terminal event when the
        /// task is cancelled, so without this the turn would be indistinguishable from one still
        /// running; a cancelled turn must never read as a completed one.
        func markCancelled() {
            lock.lock(); defer { lock.unlock() }
            if terminal == nil { terminal = .cancelled }
        }

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
            return CloudAcceptanceRecord(
                requestId: requestId,
                conversationId: conversationId,
                responseText: text,
                terminal: terminal
            )
        }
    }
}
