import Foundation

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
    }

    struct Export: Codable, Equatable {
        let nonce: String
        let a1: ExportedStep
        let a2: ExportedStep
        let b1: ExportedStep
        let verdict: String
    }

    /// Runs the protocol against the production client and returns the export.
    static func run(
        nonce: String,
        conversationA: String = UUID().uuidString,
        conversationB: String = UUID().uuidString,
        client: CloudRouteClient,
        context: CloudRouteContext
    ) async -> Export {
        func step(_ text: String, _ conversationId: String, _ mode: String) async -> CloudAcceptanceConsumer.StepOutcome {
            let turn = CloudTurnEnvelope.make(
                capabilities: [],
                routeHint: nil,
                recentConversation: [],
                conversation: CloudPreparedConversation(requestId: "", conversationId: conversationId, mode: mode)
            )
            let (stream, record) = client.collectAcceptance(request: text, context: context, turn: turn)
            for await _ in stream {}
            let r = record()
            return .init(requestId: r.requestId, conversationId: r.conversationId, responseText: r.responseText, terminal: r.terminal)
        }

        let a1 = await step("please remember this token: \(nonce)", conversationA, "create")
        let a2 = await step("what was the token I asked you to remember?", conversationA, "resume")
        let b1 = await step("what was the token I asked you to remember?", conversationB, "create")

        let verdict = CloudAcceptanceConsumer(a1: a1, a2: a2, b1: b1, nonce: nonce).verdictLine()
        func export(_ s: CloudAcceptanceConsumer.StepOutcome) -> ExportedStep {
            ExportedStep(
                requestId: s.requestId,
                conversationId: s.conversationId,
                responseText: s.responseText,
                terminal: s.terminal.map { String(describing: $0) } ?? "none"
            )
        }
        return Export(nonce: nonce, a1: export(a1), a2: export(a2), b1: export(b1), verdict: verdict)
    }
}
