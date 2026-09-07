import XCTest
@testable import podcasts

final class CloudRouteClientTests: XCTestCase {
    private let userId = "user_79424ba0-f09b-013b-249c-566ad7a4dc9d"
    private let sampleContext = CloudRouteContext(
        episodeId: "79424ba0-f09b-013b-249c-566ad7a4dc9d",
        podcastId: "da7aba5e-f11e-f11e-f11e-da7aba5ef11e",
        referencePositionMs: 1_230_000,
        clientPositionMs: 1_234_567,
        recentReferencePositions: [1_130_000],
        previousReferencePositionMs: 1_230_000
    )

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    func testMixedStreamEmitsActionTokensAndDone() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":1130000}}

            event: token
            data: {"text":"She"}

            event: token
            data: {"text":" is arguing."}

            event: done
            data: {"input_tokens":500,"output_tokens":80}

            """
        )

        var capturedBody: Data?
        CloudRouteTestURLProtocol.onRequest = { _, body in capturedBody = body }

        let events = await collect(client().route(request: "What did she mean?", context: sampleContext))

        XCTAssertEqual(
            events,
            [
                .action(
                    tool: "playback",
                    action: "seek_to",
                    params: ["reference_position_ms": .int(1_130_000)]
                ),
                .token("She"),
                .token(" is arguing."),
                .done(inputTokens: 500, outputTokens: 80),
            ]
        )
        assertRouteBody(capturedBody)
    }

    func testActionOnlyStream() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: action
            data: {"tool":"playback","action":"pause","params":{}}

            event: done
            data: {"input_tokens":10,"output_tokens":0}

            """
        )

        let events = await collect(client().route(request: "pause", context: sampleContext))
        XCTAssertEqual(
            events,
            [
                .action(tool: "playback", action: "pause", params: [:]),
                .done(inputTokens: 10, outputTokens: 0),
            ]
        )
    }

    func testTokenOnlyStream() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: token
            data: {"text":"Hello"}

            event: token
            data: {"text":" world"}

            event: done
            data: {"input_tokens":20,"output_tokens":5}

            """
        )

        let events = await collect(client().route(request: "summarize", context: sampleContext))
        XCTAssertEqual(
            events,
            [
                .token("Hello"),
                .token(" world"),
                .done(inputTokens: 20, outputTokens: 5),
            ]
        )
    }

    func test400InvalidRequestEmitsErrorBeforeStream() async {
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .complete(
                status: 400,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"code":"invalid_request","message":"missing request"}"#.utf8)
            )
        }

        let events = await collect(client().route(request: "", context: sampleContext))
        XCTAssertEqual(events, [.error(code: "invalid_request", message: "missing request")])
    }

    func test401EmitsErrorBeforeStream() async {
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .complete(
                status: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"message":"unauthorized"}"#.utf8)
            )
        }

        let events = await collect(client().route(request: "hello", context: sampleContext))
        guard case let .error(code, _)? = events.first, events.count == 1 else {
            XCTFail("Expected single error, got \(events)")
            return
        }
        XCTAssertEqual(code, "unauthorized")
    }

    func testInlineErrorEventLimitExceeded() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: error
            data: {"code":"limit_exceeded","message":"You've used 10/10 free requests today."}

            """
        )

        let events = await collect(client().route(request: "hello", context: sampleContext))
        XCTAssertEqual(
            events,
            [.error(code: "limit_exceeded", message: "You've used 10/10 free requests today.")]
        )
    }

    func testMultiLineDataFieldIsJoinedBeforeParsing() async {
        // Multi-line `data:` frames are joined with `\n` (SSE). Split where a
        // newline is legal JSON whitespace so Foundation's parser accepts it.
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: token
            data: {"text":
            data: "line1\\nline2"}

            event: done
            data: {"input_tokens":1,"output_tokens":1}

            """
        )

        let events = await collect(client().route(request: "hello", context: sampleContext))
        XCTAssertEqual(
            events,
            [
                .token("line1\nline2"),
                .done(inputTokens: 1, outputTokens: 1),
            ]
        )
    }

    func testMidStreamConnectionDropEmitsConnectionError() async {
        // Deliver a partial SSE body then cleanly close (no `done`/`error`).
        // URLSession.bytes does not reliably surface didLoad-before-didFail;
        // truncated EOF without a terminal event is the portable drop signal.
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .complete(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(
                    """
                    event: token
                    data: {"text":"partial"}

                    """.utf8
                )
            )
        }

        let events = await collect(client().route(request: "hello", context: sampleContext))
        XCTAssertEqual(events.first, .token("partial"))
        guard case let .error(code, _)? = events.dropFirst().first else {
            XCTFail("Expected connection_lost after partial token, got \(events)")
            return
        }
        XCTAssertEqual(code, "connection_lost")
    }

    func testClientCancellationStopsCollection() async {
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .slowChunks(
                body: Data(
                    """
                    event: token
                    data: {"text":"first"}

                    event: token
                    data: {"text":"second"}

                    """.utf8
                ),
                chunkDelayNanoseconds: 200_000_000
            )
        }

        let stream = client().route(request: "hello", context: sampleContext)
        var received: [CloudRouteEvent] = []
        let collectTask = Task {
            for await event in stream {
                received.append(event)
                if case .token("first") = event {
                    break
                }
            }
        }
        await collectTask.value
        collectTask.cancel()

        XCTAssertEqual(received, [.token("first")])
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(received, [.token("first")])
    }

    func testRequestTimeoutExceedsServerBudget() {
        let client = CloudRouteClient(baseURL: "https://example.com", userId: userId)
        XCTAssertGreaterThanOrEqual(client.requestTimeoutSeconds, 15)
    }

    // MARK: - Helpers

    private func client() -> CloudRouteClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config)
        return CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: userId,
            session: session,
            requestTimeoutSeconds: 15
        )
    }

    private func collect(_ stream: AsyncStream<CloudRouteEvent>) async -> [CloudRouteEvent] {
        var events: [CloudRouteEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    private func assertRouteBody(_ body: Data?) {
        guard let body, let text = String(data: body, encoding: .utf8) else {
            XCTFail("Expected captured request body")
            return
        }
        XCTAssertTrue(text.contains("\"request\":\"What did she mean?\""))
        XCTAssertTrue(text.contains("\"episode_id\":\"79424ba0-f09b-013b-249c-566ad7a4dc9d\""))
        XCTAssertTrue(text.contains("\"podcast_id\":\"da7aba5e-f11e-f11e-f11e-da7aba5ef11e\""))
        XCTAssertTrue(text.contains("\"reference_position_ms\":1230000"))
        XCTAssertTrue(text.contains("\"client_position_ms\":1234567"))
    }
}
