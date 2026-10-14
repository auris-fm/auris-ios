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
        /// The SERVER's message for a served error, and its LENGTH. Both are carried so "the server sent
        /// an empty message" is a measurement rather than an inference: a present-but-empty message and
        /// an absent one are different facts, and the length distinguishes them from a truncated view.
        let serverMessage: String?
        let serverMessageLength: Int?
    }

    struct Export: Codable, Equatable {
        let nonce: String
        let a1: ExportedStep
        let a2: ExportedStep
        let b1: ExportedStep
        let verdict: String
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
            var serverMessage: String? = nil
            if case .transportFailure(let st, _, let message) = s.terminal {
                stage = st.rawValue
                serverMessage = message
            }
            return ExportedStep(
                requestId: s.requestId,
                conversationId: s.conversationId,
                responseText: s.responseText,
                terminal: s.terminal.map { String(describing: $0) } ?? "none",
                stage: stage,
                serverMessage: serverMessage,
                serverMessageLength: serverMessage?.count
            )
        }
        return Export(nonce: nonce, a1: export(a1), a2: export(a2), b1: export(b1), verdict: verdict)
    }
}
