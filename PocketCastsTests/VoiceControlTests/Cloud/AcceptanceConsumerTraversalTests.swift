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
            a2.terminal, .transportFailure(stage: .transport, code: "stream_ended_without_terminal", message: nil),
            "a terminal-less turn was not classified as a transport failure"
        )
        XCTAssertFalse(a2.responseText.contains(nonce), "outgoing-only evidence was read as recall")
    }
}

/// The OPT-IN CLIENT PATH end to end: `CloudAcceptanceRun.run` submits A1/A2/B1, and the verdict comes
/// from the records those submissions produced. This exercises the integration rather than the consumer
/// in isolation.
final class AcceptanceRunPathTests: XCTestCase {

    private struct StaticToken: CloudTokenProviding {
        func token() async -> String? { "t" }
        func prepare() async {}
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    private final class ScriptedSubmit {
        var conversationIds: [String] = []
        var modes: [String] = []
        var steps: [CloudAcceptanceConsumer.StepOutcome] = []
        func submit(_ request: String, _ turn: CloudTurnEnvelope) -> CloudAcceptanceConsumer.StepOutcome {
            conversationIds.append(turn.conversation?.conversationId ?? "nil")
            modes.append(turn.conversation?.mode ?? "nil")
            return steps.isEmpty ? .init(requestId: nil, conversationId: nil, responseText: "", terminal: nil) : steps.removeFirst()
        }
    }

    private func step(_ id: String, _ conv: String, _ text: String, _ terminal: CloudAcceptanceRecord.Terminal?) -> CloudAcceptanceConsumer.StepOutcome {
        .init(requestId: id, conversationId: conv, responseText: text, terminal: terminal)
    }

    func testRunPathSubmitsThreeTurnsAndPasses() {
        let scripted = ScriptedSubmit()
        let nonce = "NONCE-314"
        scripted.steps = [
            step("r1", "conv-A", "ok", .done),
            step("r2", "conv-A", "you asked me to remember \(nonce)", .done),
            step("r3", "conv-B", "I have no idea", .done),
        ]
        let client = CloudRouteClient(baseURL: "https://api-staging.auris.fm", userId: "u", tokenProvider: StaticToken())
        let verdict = CloudAcceptanceRun.run(
            nonce: nonce, conversationA: "conv-A", conversationB: "conv-B",
            client: client, context: CloudRouteContext(episodeId: nil, clientPositionMs: nil),
            submit: scripted.submit
        )
        XCTAssertEqual(verdict, .pass)
        XCTAssertEqual(scripted.modes, ["create", "resume", "create"], "the run must continue the same conversation for A2")
        XCTAssertEqual(scripted.conversationIds, ["conv-A", "conv-A", "conv-B"], "A1/A2 share A; B1 uses B")
    }

    /// A non-done terminal on any step is a FAILED acceptance, never a pass: an error, a transport
    /// failure or a cancellation is not a completed turn.
    func testRunPathFailsWhenAStepDidNotComplete() {
        for terminal in [CloudAcceptanceRecord.Terminal.transportFailure(stage: .transport, code: "connection_lost", message: nil), .cancelled, nil] as [CloudAcceptanceRecord.Terminal?] {
            let scripted = ScriptedSubmit()
            let nonce = "NONCE-314"
            scripted.steps = [
                step("r1", "conv-A", "ok", .done),
                step("r2", "conv-A", "you asked me to remember \(nonce)", terminal),
                step("r3", "conv-B", "I have no idea", .done),
            ]
            let client = CloudRouteClient(baseURL: "https://api-staging.auris.fm", userId: "u", tokenProvider: StaticToken())
            let verdict = CloudAcceptanceRun.run(
                nonce: nonce, conversationA: "conv-A", conversationB: "conv-B",
                client: client, context: CloudRouteContext(episodeId: nil, clientPositionMs: nil),
                submit: scripted.submit
            )
            if case .pass = verdict {
                XCTFail("a step with terminal \(String(describing: terminal)) was accepted as a pass")
            }
        }
    }
}

/// Gates the reviewer asked to keep: an empty nonce, an empty B1 response and empty/absent ids must all
/// be REJECTED, because each of them would make a check pass for the wrong reason.
final class AcceptanceGateTests: XCTestCase {

    private func step(_ id: String?, _ conv: String?, _ text: String, _ t: CloudAcceptanceRecord.Terminal? = .done) -> CloudAcceptanceConsumer.StepOutcome {
        .init(requestId: id, conversationId: conv, responseText: text, terminal: t)
    }

    private func verdict(nonce: String, a1: CloudAcceptanceConsumer.StepOutcome, a2: CloudAcceptanceConsumer.StepOutcome, b1: CloudAcceptanceConsumer.StepOutcome) -> CloudAcceptanceConsumer.Verdict {
        CloudAcceptanceConsumer(a1: a1, a2: a2, b1: b1, nonce: nonce).evaluate()
    }

    func testEmptyNonceIsRejected() {
        let v = verdict(nonce: "",
                        a1: step("r1", "A", "ok"), a2: step("r2", "A", "ok"), b1: step("r3", "B", "no"))
        if case .pass = v { XCTFail("an empty nonce was accepted") }
    }

    func testEmptyB1ResponseIsNotIsolation() {
        let v = verdict(nonce: "N",
                        a1: step("r1", "A", "ok"), a2: step("r2", "A", "you said N"), b1: step("r3", "B", ""))
        if case .pass = v { XCTFail("an empty B1 response was accepted as isolation") }
    }

    func testEmptyA2ResponseIsNotRecall() {
        let v = verdict(nonce: "N",
                        a1: step("r1", "A", "ok"), a2: step("r2", "A", ""), b1: step("r3", "B", "no"))
        if case .pass = v { XCTFail("an empty A2 response was accepted as recall") }
    }

    func testAbsentOrReusedIdsAreRejected() {
        let absent = verdict(nonce: "N",
                             a1: step(nil, "A", "ok"), a2: step("r2", "A", "you said N"), b1: step("r3", "B", "no"))
        if case .pass = absent { XCTFail("an absent request id was accepted") }

        let reused = verdict(nonce: "N",
                             a1: step("r1", "A", "ok"), a2: step("r1", "A", "you said N"), b1: step("r3", "B", "no"))
        if case .pass = reused { XCTFail("a reused request id was accepted") }
    }
}

/// THE WIRING: the assembly's acceptance entry uses the SAME client factory the sink is built with, so
/// the harness submits through the app's client path rather than constructing its own.
final class AcceptanceAssemblyWiringTests: XCTestCase {

    private struct StaticToken: CloudTokenProviding {
        func token() async -> String? { "t" }
        func prepare() async {}
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    private final class CountingFactory {
        var built = 0
        func make() -> CloudRouteClient {
            built += 1
            return CloudRouteClient(baseURL: "https://api-staging.auris.fm", userId: "u", tokenProvider: StaticToken())
        }
    }

    /// The wiring point is the SAME call that builds the sink's client: the factory is retained there,
    /// so the acceptance entry cannot diverge from the sink's client.
    ///
    /// LIMITATION, stated rather than forced: `buildVoiceControlService` returns nil in this environment
    /// (no wake-word models), so the full service build cannot be driven here. This exercises the wiring
    /// point directly instead, and the entry itself is exercised in
    /// `AcceptanceAssemblyWiringTests.testAcceptanceEntryBuildsThroughTheRetainedFactory`.
    func testTheBuildPathRetainsTheFactoryForAcceptance() {
        let counting = CountingFactory()
        let assembly = VoiceControlAssembly()
        let factory = assembly.acceptanceClientFactoryForBuild(counting.make)
        _ = factory()
        XCTAssertEqual(counting.built, 1, "the retained factory is not the one the build was given")
    }

    func testAcceptanceEntryBuildsThroughTheRetainedFactory() async {
        let counting = CountingFactory()
        let assembly = VoiceControlAssembly()
        assembly.acceptanceClientFactoryForBuild(counting.make)

        let before = counting.built
        _ = await assembly.runAcceptance(nonce: "NONCE-1")
        XCTAssertEqual(counting.built, before + 1, "the acceptance entry did not use the assembly's factory")
    }
}

/// The STAGE discriminator: the export must say WHERE a terminal came from, because the code alone does
/// not. A client construction failure and a served error can carry the SAME code string.
final class AcceptanceStageDiscriminationTests: XCTestCase {

    func testClientConstructionFailureIsStagedClientRequest() {
        let r = CloudAcceptanceRecord.Recorder(requestId: "r1", conversationId: "c1")
        r.observe(.error(source: .client, code: "invalid_request", message: "request could not be built"))   // the client's own tag
        XCTAssertEqual(r.record().terminal, .transportFailure(stage: .clientRequest, code: "invalid_request", message: nil))
    }

    func testServedErrorIsStagedServerEvent() {
        let r = CloudAcceptanceRecord.Recorder(requestId: "r1", conversationId: "c1")
        r.observe(.error(source: .server, code: "invalid_request", message: ""))                      // a served frame
        XCTAssertEqual(r.record().terminal, .transportFailure(stage: .serverEvent, code: "invalid_request", message: ""))
    }

    /// THE POINT: the same code, two different stages, distinguishable after the fact.
    func testSameCodeWithDifferentSourcesIsDistinguishable() {
        let client = CloudAcceptanceRecord.Recorder(requestId: "r1", conversationId: "c1")
        client.observe(.error(source: .client, code: "invalid_request", message: "request could not be built"))
        let server = CloudAcceptanceRecord.Recorder(requestId: "r1", conversationId: "c1")
        server.observe(.error(source: .server, code: "invalid_request", message: ""))
        XCTAssertNotEqual(client.record().terminal, server.record().terminal, "the stage did not discriminate")
    }
}

/// The export must carry NO free-form server text — not in the reason field (bounded token), and not
/// smuggled inside the serialized terminal, where `String(describing:)` would have embedded it.
final class AcceptanceExportBoundingTests: XCTestCase {

    func testSerializedTerminalCarriesNoServerText() {
        let sentinel = "secret-server-prose-that-must-not-be-exported"
        let terminal = CloudAcceptanceRecord.Terminal.transportFailure(
            stage: .serverEvent, code: "invalid_request", message: sentinel
        )
        let serialized = CloudAcceptanceHarness.boundedTerminal(terminal)
        XCTAssertFalse(
            serialized.contains(sentinel),
            "the serialized terminal embedded raw server text: \(serialized)"
        )
        XCTAssertEqual(serialized, "serverEvent:invalid_request", "the terminal must be stage:code only")
    }

    func testBoundedTerminalHandlesEveryCase() {
        XCTAssertEqual(CloudAcceptanceHarness.boundedTerminal(nil), "none")
        XCTAssertEqual(CloudAcceptanceHarness.boundedTerminal(.done), "done")
        XCTAssertEqual(CloudAcceptanceHarness.boundedTerminal(.cancelled), "cancelled")
        XCTAssertEqual(
            CloudAcceptanceHarness.boundedTerminal(.transportFailure(stage: .clientRequest, code: "invalid_request", message: nil)),
            "clientRequest:invalid_request"
        )
    }
}

/// The VERDICT text must be bounded too: it is exported, and interpolating the terminal would carry the
/// raw server message out with it.
final class AcceptanceVerdictBoundingTests: XCTestCase {

    func testVerdictTextCarriesNoServerMessage() {
        let sentinel = "secret-server-prose-in-verdict"
        let step = CloudAcceptanceConsumer.StepOutcome(
            requestId: "r1", conversationId: "c1", responseText: "",
            terminal: .transportFailure(stage: .serverEvent, code: "invalid_request", message: sentinel)
        )
        let v = CloudAcceptanceConsumer(a1: step, a2: step, b1: step, nonce: "N")
        guard case .fail(let why) = v.evaluate() else { return XCTFail("expected a failure verdict") }
        XCTAssertFalse(why.contains(sentinel), "the verdict embedded raw server text: \(why)")
        XCTAssertTrue(why.contains("serverEvent:invalid_request"), "the verdict must name stage and code")
    }
}
