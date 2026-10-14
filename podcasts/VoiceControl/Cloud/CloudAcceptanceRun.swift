import Foundation

/// THE REAL OPT-IN CLIENT PATH: it submits the three controlled turns through the client, collects the
/// records each one returns, and hands them to `CloudAcceptanceConsumer` for the verdict.
///
/// It is opt-in per run and used only for the controlled benign acceptance turns; it is not a general
/// traffic path. It never reads or exports a credential: it submits text through the same route the app
/// uses and reads only the allowlisted acceptance fields.
struct CloudAcceptanceRun {

    struct Request {
        let request: String          // the text submitted for the turn
        let conversationId: String
        let mode: String             // "create" or "resume"
    }

    /// Drives one run: A1 (nonce) and A2 (recall ask) in ONE conversation, then B1 (isolation ask) in a
    /// NEW one. The submit closure is the client's own route entry, so this path submits exactly what a
    /// turn submits and collects the record the collector returns.
    static func run(
        nonce: String,
        conversationA: String,
        conversationB: String,
        client: CloudRouteClient,
        context: CloudRouteContext,
        submit: (String, CloudTurnEnvelope) -> CloudAcceptanceConsumer.StepOutcome
    ) -> CloudAcceptanceConsumer.Verdict {
        func envelope(_ conversationId: String, mode: String) -> CloudTurnEnvelope {
            CloudTurnEnvelope.make(
                capabilities: [],
                routeHint: nil,
                recentConversation: [],
                conversation: CloudPreparedConversation(requestId: UUID().uuidString, conversationId: conversationId, mode: mode)
            )
        }
        let a1 = submit("please remember this: \(nonce)", envelope(conversationA, mode: "create"))
        let a2 = submit("what was the token I asked you to remember?", envelope(conversationA, mode: "resume"))
        let b1 = submit("what was the token I asked you to remember?", envelope(conversationB, mode: "create"))

        return CloudAcceptanceConsumer(a1: a1, a2: a2, b1: b1, nonce: nonce).evaluate()
    }
}
