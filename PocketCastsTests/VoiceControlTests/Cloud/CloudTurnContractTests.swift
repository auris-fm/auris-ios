import XCTest
@testable import podcasts

/// Item 5 (iOS half) — edge turn contract: `request_id`, `capabilities` gating,
/// typed-only `route_hint`, and a bounded `context.recent_conversation`.
/// Field names/semantics are pinned against `docs/specs/cloud-assistant.md`
/// ("Turn control fields").
final class CloudTurnContractTests: XCTestCase {
    // MARK: - request_id

    func testRequestIdIsPresentAndStableWhenReused() throws {
        let turn = CloudTurnEnvelope.make(
            capabilities: [],
            routeHint: nil,
            recentConversation: []
        )
        let body = try CloudRouteRequestBuilder.body(
            request: "what did they say about AI?",
            context: sampleContext(),
            turn: turn
        )
        let json = try decode(body)

        XCTAssertEqual(json["request_id"] as? String, turn.requestId, "request_id must come from the envelope")
        XCTAssertNotNil(UUID(uuidString: turn.requestId), "request_id must be a UUID")

        // A transport retry reuses the same logical-turn envelope.
        let retry = try CloudRouteRequestBuilder.body(request: "what did they say about AI?", context: sampleContext(), turn: turn)
        XCTAssertEqual(try decode(retry)["request_id"] as? String, turn.requestId, "retries keep the same request_id")
    }

    func testDistinctTurnsGetDistinctRequestIds() {
        let a = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        let b = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        XCTAssertNotEqual(a.requestId, b.requestId)
    }

    /// The pin @spec asked for: a duplicate transport attempt of the SAME
    /// logical turn must present the same `request_id`, so the server admits one
    /// turn rather than two. (A turn recorded under a server-assigned id must
    /// never be auto-retried at all — there is no client retry loop.)
    func testDuplicateTransportAttemptsReuseTheSameRequestId() async throws {
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        var capturedIds: [String] = []
        CloudRouteTestURLProtocol.onRequest = { _, body in
            guard let body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let requestId = object["request_id"] as? String
            else { return }
            capturedIds.append(requestId)
        }
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        )

        let client = makeClient()
        for _ in 0..<2 {
            for await _ in client.route(request: "same logical turn", context: sampleContext(), turn: turn) {}
        }

        XCTAssertEqual(capturedIds.count, 2, "both transport attempts reached the server")
        XCTAssertEqual(Set(capturedIds), [turn.requestId], "duplicate attempts carry one request_id (one admitted turn)")

        // A genuinely new logical turn gets its own id.
        capturedIds.removeAll()
        let secondTurn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        for await _ in client.route(request: "next turn", context: sampleContext(), turn: secondTurn) {}
        XCTAssertEqual(capturedIds, [secondTurn.requestId])
        XCTAssertNotEqual(secondTurn.requestId, turn.requestId)
    }

    // MARK: - capabilities

    func testCapabilitiesOmittedWhenRendererNotAvailable() throws {
        // Default iOS posture: no `search_results_v1` renderer yet, so nothing
        // is advertised and the server falls back to short token text + done.
        let turn = CloudTurnEnvelope.make(
            capabilities: CloudClientCapabilities.advertised(rendersStructuredResults: false),
            routeHint: nil,
            recentConversation: []
        )
        XCTAssertTrue(turn.capabilities.isEmpty)

        let json = try decode(try CloudRouteRequestBuilder.body(request: "x", context: sampleContext(), turn: turn))
        XCTAssertNil(json["capabilities"], "capabilities must be omitted, not sent empty")
    }

    func testCapabilitiesAdvertiseSearchResultsV1Only() throws {
        let capabilities = CloudClientCapabilities.advertised(rendersStructuredResults: true)
        XCTAssertEqual(capabilities, ["search_results_v1"])

        let turn = CloudTurnEnvelope.make(capabilities: capabilities, routeHint: nil, recentConversation: [])
        let json = try decode(try CloudRouteRequestBuilder.body(request: "x", context: sampleContext(), turn: turn))
        XCTAssertEqual(json["capabilities"] as? [String], ["search_results_v1"])
    }

    // MARK: - route_hint

    func testRouteHintOmittedForFreeTextTurns() throws {
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        let json = try decode(try CloudRouteRequestBuilder.body(request: "play the bit about AI", context: sampleContext(), turn: turn))
        XCTAssertNil(json["route_hint"], "free-text cloud_route keeps working without a hint")
    }

    func testRouteHintSerializesOperationAndArguments() throws {
        let hint = CloudRouteHint(
            operation: "search_spoken_content",
            arguments: ["query": .string("climate"), "scope": .string("current_episode")]
        )
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: hint, recentConversation: [])
        let json = try decode(try CloudRouteRequestBuilder.body(request: "x", context: sampleContext(), turn: turn))

        let hintJSON = try XCTUnwrap(json["route_hint"] as? [String: Any])
        XCTAssertEqual(hintJSON["operation"] as? String, "search_spoken_content")
        let args = try XCTUnwrap(hintJSON["arguments"] as? [String: Any])
        XCTAssertEqual(args["query"] as? String, "climate")
        XCTAssertEqual(args["scope"] as? String, "current_episode")
    }

    // MARK: - bounded recent conversation

    func testRecentConversationIsBoundedToFourTurnsKeepingNewest() {
        let turns = (1...6).map { RecentConversationTurn(role: .user, text: "turn \($0)") }
        let bounded = RecentConversation.bounded(turns)
        XCTAssertEqual(bounded.count, 4)
        XCTAssertEqual(bounded.map(\.text), ["turn 3", "turn 4", "turn 5", "turn 6"], "oldest entries drop first")
    }

    func testRecentConversationIsBoundedToEightKilobytes() {
        let big = String(repeating: "a", count: 5_000)
        let turns = [
            RecentConversationTurn(role: .user, text: "old"),
            RecentConversationTurn(role: .assistant, text: big),
            RecentConversationTurn(role: .user, text: big),
        ]
        let bounded = RecentConversation.bounded(turns)
        let totalBytes = bounded.reduce(0) { $0 + $1.text.utf8.count }
        XCTAssertLessThanOrEqual(totalBytes, RecentConversation.maxBytes)
        XCTAssertEqual(bounded.last?.text, big, "the newest turn is kept")
    }

    func testRecentConversationOmittedWhenEmpty() throws {
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        let json = try decode(try CloudRouteRequestBuilder.body(request: "x", context: sampleContext(), turn: turn))
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertNil(context["recent_conversation"])
    }

    func testRecentConversationSerializesRoleAndText() throws {
        let turn = CloudTurnEnvelope.make(
            capabilities: [],
            routeHint: nil,
            recentConversation: [RecentConversationTurn(role: .user, text: "who is speaking?")]
        )
        let json = try decode(try CloudRouteRequestBuilder.body(request: "x", context: sampleContext(), turn: turn))
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        let conversation = try XCTUnwrap(context["recent_conversation"] as? [[String: Any]])
        XCTAssertEqual(conversation.count, 1)
        XCTAssertEqual(conversation[0]["role"] as? String, "user")
        XCTAssertEqual(conversation[0]["text"] as? String, "who is speaking?")
    }

    // MARK: - existing contract preserved

    func testExistingContextFieldsUnchanged() throws {
        let json = try decode(try CloudRouteRequestBuilder.body(request: "hello", context: sampleContext(), turn: CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])))
        XCTAssertEqual(json["request"] as? String, "hello")
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual(context["episode_id"] as? String, "ep")
        XCTAssertEqual(context["client_position_ms"] as? Int, 1_100)
    }

    // MARK: - helpers

    private func sampleContext() -> CloudRouteContext {
        CloudRouteContext(
            episodeId: "ep",
            podcastId: "pod",
            referencePositionMs: 1_000,
            clientPositionMs: 1_100,
            recentReferencePositions: [],
            previousReferencePositionMs: nil
        )
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeClient() -> CloudRouteClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        return CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_test",
            session: URLSession(configuration: config)
        )
    }
}
