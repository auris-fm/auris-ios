import Foundation
import PocketCastsUtils

/// THE OPERATOR ENTRY for authenticated acceptance. It is the ONE place that reaches the acceptance
/// path through the PRODUCTION client — the same factory the app's sink uses, hence the same base URL,
/// identity and token provider — rather than an injected closure.
///
/// It runs the three controlled turns, exports ONLY the allowlisted acceptance fields, and prints a
/// single machine-readable verdict. It never prints or writes a credential: the token provider supplies
/// it inside the client and nothing here reads it.
enum CloudAcceptanceHarness {

    /// The exported, allowlisted form of a step: request id, conversation id, response text, terminal.
    /// Nothing else leaves this type.
    struct ExportedStep: Codable, Equatable {
        let requestId: String?
        let conversationId: String?
        let responseText: String
        let terminal: String
        /// WHERE the terminal originated, bounded to the protocol's observable stages. The export
        /// previously carried only the code, so a client construction failure and a served error were
        /// indistinguishable after the fact — which is what an "empty message" reading rested on.
        let stage: String
        /// A BOUNDED reason for a served rejection, and its length. Free-form server text is NOT
        /// exported: an arbitrary server string is outside this protocol's allowlist. Only the
        /// request-validation reason this controlled run needs is preserved, and it is matched against a
        /// known set rather than passed through, so the export carries a bounded token.
        let serverReason: String?
        let serverReasonLength: Int?
    }

    struct Export: Codable, Equatable {
        let nonce: String
        let a1: ExportedStep
        let a2: ExportedStep
        let b1: ExportedStep
        let verdict: String
    }

    /// A BOUNDED serialization of a terminal: stage and code only, never a server message. The
    /// verdict line is built from the same parts, so raw server text cannot reach either.
    static func boundedTerminal(_ terminal: CloudAcceptanceRecord.Terminal?) -> String {
        guard let terminal else { return "none" }
        switch terminal {
        case .done: return "done"
        case .cancelled: return "cancelled"
        case .transportFailure(let stage, let code, _): return "\(stage.rawValue):\(code)"
        }
    }

    /// Runs the protocol against the production client and returns the export.
    ///
    /// It records the CLIENT'S OWN resolved base URL and whether a credential is present BEFORE the
    /// turns run, because `invalid_request` and `unauthorized` have different sources and the difference
    /// decides what the run is evidence of. Neither value is a credential: the URL is configuration and
    /// the credential is reported as a boolean.
    static func run(
        nonce: String,
        conversationA: String = UUID().uuidString,
        conversationB: String = UUID().uuidString,
        client: CloudRouteClient,
        context: CloudRouteContext
    ) async -> Export {
        func step(_ text: String, _ conversationId: String, _ mode: String) async -> CloudAcceptanceConsumer.StepOutcome {
            // The request_id on the WIRE is `turn.conversation?.requestId ?? turn.requestId`, and the
            // conversation's value wins when present. An EMPTY string is present, so it was sent as
            // `request_id = ""` — which is not a UUID, and the server refused it with exactly that
            // message. The conversation must carry a real UUID, and it must be the SAME one the envelope
            // minted so the retry identity stays stable.
            let envelope = CloudTurnEnvelope.make(
                capabilities: [],
                routeHint: nil,
                recentConversation: [],
                conversation: nil
            )
            let turn = CloudTurnEnvelope(
                requestId: envelope.requestId,
                capabilities: [],
                routeHint: nil,
                recentConversation: [],
                conversation: CloudPreparedConversation(
                    requestId: envelope.requestId,
                    conversationId: conversationId,
                    mode: mode
                )
            )
            let (stream, record) = client.collectAcceptance(request: text, context: context, turn: turn)
            for await _ in stream {}
            let r = record()
            return .init(requestId: r.requestId, conversationId: r.conversationId, responseText: r.responseText, terminal: r.terminal)
        }

        FileLog.shared.addMessage("[ScratchAcceptance] client baseURL=\(client.resolvedBaseURLForDiagnostics) credentialPresent=\(await client.hasCredentialForDiagnostics)")
        let a1 = await step("please remember this token: \(nonce)", conversationA, "create")
        let a2 = await step("what was the token I asked you to remember?", conversationA, "resume")
        let b1 = await step("what was the token I asked you to remember?", conversationB, "create")

        let verdict = CloudAcceptanceConsumer(a1: a1, a2: a2, b1: b1, nonce: nonce).verdictLine()
        func export(_ s: CloudAcceptanceConsumer.StepOutcome) -> ExportedStep {
            var stage = "none"
            var serverReason: String? = nil
            if case .transportFailure(let st, _, let message) = s.terminal {
                stage = st.rawValue
                // BOUNDED: the raw text is matched against the request-validation reasons this control
                // needs, and anything else becomes "other". The export never carries arbitrary server
                // prose, which is outside the allowlist.
                switch message {
                case "request_id must be a UUID": serverReason = "request_id_must_be_uuid"
                case "a valid access token is required": serverReason = "token_invalid"
                case "access_token is required": serverReason = "token_missing"
                case "codecs is required and must be an array": serverReason = "codecs_missing"
                case nil: serverReason = nil
                default: serverReason = "other"
                }
            }
            return ExportedStep(
                requestId: s.requestId,
                conversationId: s.conversationId,
                responseText: s.responseText,
                // BOUNDED: the terminal is serialized from the bounded parts only. `String(describing:)`
                // on the case would embed the raw server message, which is the free-form text this
                // export must not carry.
                terminal: Self.boundedTerminal(s.terminal),
                stage: stage,
                serverReason: serverReason,
                serverReasonLength: serverReason?.count
            )
        }
        return Export(nonce: nonce, a1: export(a1), a2: export(a2), b1: export(b1), verdict: verdict)
    }
}
