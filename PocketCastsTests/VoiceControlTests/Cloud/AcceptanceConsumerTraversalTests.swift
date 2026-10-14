import XCTest
@testable import podcasts

/// TRAVERSAL through the REAL wrapper and consumer. These do not construct records by hand: they drive
/// `CloudRouteClient.collectAcceptance` over a stubbed transport and feed the records it returns into
/// `CloudAcceptanceConsumer.evaluate()`, which is what the runner does.
final class AcceptanceConsumerTraversalTests: XCTestCase {

    /// A client whose only job is to hand `collectAcceptance` its injected stream. `CloudRouteClient`
    /// is final, so the seam is the injected stream rather than a subclass: the collector's own code
    /// path is the one under test.
    private struct StaticToken: CloudTokenProviding {
        func token() async -> String? { "t" }
        func prepare() async {}
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    private func client() -> CloudRouteClient {
        CloudRouteClient(baseURL: "https://api-staging.auris.fm", userId: "u", tokenProvider: StaticToken())
    }

    private func events(_ texts: [String], terminal: CloudRouteEvent) -> [CloudRouteEvent] {
        texts.map { .token($0) } + [terminal]
    }

    private func envelope(_ conversationId: String) -> CloudTurnEnvelope {
        CloudTurnEnvelope.make(
            capabilities: [],
            routeHint: nil,
            recentConversation: [],
            conversation: CloudPreparedConversation(requestId: "", conversationId: conversationId, mode: "create")
        )
    }

    private func runStep(_ client: CloudRouteClient, _ events: [CloudRouteEvent], conversationId: String) async -> CloudAcceptanceConsumer.StepOutcome {
        let upstream = AsyncStream<CloudRouteEvent> { c in
            for e in events { c.yield(e) }
            c.finish()
        }
        let (stream, record) = client.collectAcceptance(turn: envelope(conversationId), upstream: upstream)
        for await _ in stream {}
        let r = record()
        return .init(requestId: r.requestId, conversationId: r.conversationId, responseText: r.responseText, terminal: r.terminal)
    }

    /// The whole protocol, driven THROUGH the wrapper and decided BY the consumer: recall in A, no
    /// recall in a new B.
    func testConsumerPassesWhenRecallAndIsolationHold() async {
        let nonce = "NONCE-777"
        let done = CloudRouteEvent.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil))
        let client = client()
        let a1 = await runStep(client, events([nonce], terminal: done), conversationId: "conv-A")
        let a2 = await runStep(client, events(["the nonce was ", nonce], terminal: done), conversationId: "conv-A")
        let b1 = await runStep(client, events(["I don't know"], terminal: done), conversationId: "conv-B")
        XCTAssertEqual(CloudAcceptanceConsumer(a1: a1, a2: a2, b1: b1, nonce: nonce).evaluate(), .pass)
    }

    /// REJECTION: a new conversation that recalls the nonce must FAIL isolation.
    func testConsumerRejectsCrossConversationRecall() async {
        let nonce = "NONCE-777"
        let done = CloudRouteEvent.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil))
        let client = client()
        let a1 = await runStep(client, events([nonce], terminal: done), conversationId: "conv-A")
        let a2 = await runStep(client, events([nonce], terminal: done), conversationId: "conv-A")
        let b1 = await runStep(client, events(["you told me ", nonce], terminal: done), conversationId: "conv-B")
        XCTAssertEqual(
            CloudAcceptanceConsumer(a1: a1, a2: a2, b1: b1, nonce: nonce).evaluate(),
            .fail("a NEW conversation recalled the nonce, so conversations are not isolated")
        )
    }

    /// REJECTION: if A1 and A2 are different conversations there is no recall to prove.
    func testConsumerRejectsMismatchedConversationIds() async {
        let nonce = "NONCE-777"
        let done = CloudRouteEvent.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil))
        let client = client()
        let a1 = await runStep(client, events([nonce], terminal: done), conversationId: "conv-A")
        let a2 = await runStep(client, events([nonce], terminal: done), conversationId: "conv-DIFFERENT")
        let b1 = await runStep(client, events([], terminal: done), conversationId: "conv-B")
        if case .fail = CloudAcceptanceConsumer(a1: a1, a2: a2, b1: b1, nonce: nonce).evaluate() {} else {
            XCTFail("mismatched A1/A2 conversation ids were accepted")
        }
    }

    /// REJECTION: a step with no terminal cannot complete the protocol, and an outgoing-only nonce
    /// (server sent nothing) is not recall.
    func testConsumerRejectsMissingTerminalAndOutgoingOnlyEvidence() async {
        let nonce = "NONCE-777"
        let done = CloudRouteEvent.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil))
        let client = client()
        let a1 = await runStep(client, events([nonce], terminal: done), conversationId: "conv-A")
        let a2 = await runStep(client, [.token("")], conversationId: "conv-A")   // NO terminal
        let b1 = await runStep(client, events([], terminal: done), conversationId: "conv-B")
        if case .fail = CloudAcceptanceConsumer(a1: a1, a2: a2, b1: b1, nonce: nonce).evaluate() {} else {
            XCTFail("a step with no terminal was accepted")
        }
        // The COLLECTOR classifies a terminal-less end as a transport failure: the turn must not read
        // as open, and it must not read as success either.
        XCTAssertEqual(
            a2.terminal, .transportFailure(code: "stream_ended_without_terminal"),
            "a terminal-less turn was not classified as a transport failure"
        )
        XCTAssertFalse(a2.responseText.contains(nonce), "outgoing-only evidence was read as recall")
    }
}
