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

/// Convention (PR #19 review): client-generated diagnostics carry a `code` with an
/// empty `message`, so the sink emits its localized earcon instead of TTS reading
/// English prose to a non-English user. These pin the sweep across the client.
final class CloudRouteClientLocaleTests: XCTestCase {
    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
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

    func testMidStreamDropWithoutDoneCarriesNoEnglishProse() async {
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .complete(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data("event: token\ndata: {\"text\":\"hi\"}\n\n".utf8))
        }
        let events = await makeClient().route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        guard case let .error(code, message)? = events.last else {
            return XCTFail("expected a terminal error, got \(events)")
        }
        XCTAssertEqual(code, "connection_lost")
        XCTAssertTrue(message.isEmpty, "a reachable diagnostic must not be English prose for TTS")
    }

    func testPreStreamErrorWithoutAServerMessageStaysSilent() async {
        CloudRouteTestURLProtocol.stubJSON(status: 401, body: #"{"code":"unauthorized"}"#)
        let events = await makeClient().route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        guard case let .error(code, message)? = events.first else {
            return XCTFail("expected an error event, got \(events)")
        }
        XCTAssertEqual(code, "unauthorized")
        XCTAssertTrue(message.isEmpty, "the server supplied no message; the client must not synthesize English")
    }

    func testServerSuppliedMessageIsPassedThrough() async {
        CloudRouteTestURLProtocol.stubJSON(status: 429, body: #"{"code":"limit_exceeded","message":"Daily limit reached"}"#)
        let events = await makeClient().route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        guard case let .error(code, message)? = events.first else {
            return XCTFail("expected an error event, got \(events)")
        }
        XCTAssertEqual(code, "limit_exceeded")
        XCTAssertEqual(message, "Daily limit reached", "the server's own message is passed through as-is")
    }
}

/// PR #20 review: the client must tell the credential source which credential was
/// rejected, so a burst of 401s refreshes once rather than once per response.
final class CloudRouteClientUnauthorizedSignalTests: XCTestCase {
    private final class RecordingProvider: CloudTokenProviding {
        var token: String? = "token-1"
        var rejections: [String?] = []
        func token() async -> String? { token }
        func handleUnauthorized(rejectedToken: String?) async { rejections.append(rejectedToken) }
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    func testPreStreamUnauthorizedReportsTheRejectedCredential() async {
        CloudRouteTestURLProtocol.stubJSON(status: 401, body: #"{"code":"unauthorized"}"#)
        let provider = RecordingProvider()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_legacy",
            session: URLSession(configuration: config),
            tokenProvider: provider
        )

        let events = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        XCTAssertEqual(provider.rejections, ["token-1"], "the credential that was rejected must be named")
        guard case .error = events.first else { return XCTFail("expected an error event, got \(events)") }
    }

    /// PR #20 review: the handler can await a refresh *and* an exchange (15 s
    /// each), and the sink has already paused playback by then, so recovery must
    /// not be able to hold the caller's error up. The gate makes that structural
    /// rather than racy: recovery blocks until the caller has been handed its
    /// error, so if the client awaited recovery *before* finishing the stream, the
    /// caller would never be served and this test would time out instead of
    /// passing.
    func testRecoveryCannotHoldUpTheCallersError() async {
        CloudRouteTestURLProtocol.stubJSON(status: 401, body: #"{"code":"unauthorized"}"#)
        let gate = RecoveryGate()
        let log = OrderLog()
        let provider = GatedProvider(gate: gate, log: log)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_legacy",
            session: URLSession(configuration: config),
            tokenProvider: provider
        )

        let stream = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0))
        let consumer = Task { () -> [CloudRouteEvent] in
            var events: [CloudRouteEvent] = []
            for await event in stream {
                events.append(event)
                await log.append("delivered")
                await gate.release()   // the caller owns its failure from here
            }
            return events
        }

        let delivered = await waitFor(log: log, entry: "delivered", timeout: 5)
        XCTAssertTrue(delivered, "the error must reach the caller without recovery unblocking it")
        // Recovery runs detached, so its writes are unordered against delivery.
        // `recovery-started` is appended by the handler *after* recording
        // `rejections` and `ranCancelled`, so waiting for it is what orders the two
        // assertions below (PR #20 review).
        let started = await waitFor(log: log, entry: "recovery-started", timeout: 5)
        XCTAssertTrue(started, "recovery must start on its own, not be cancelled with the producer")
        XCTAssertEqual(provider.rejections, ["token-1"], "recovery still names the rejected credential")
        XCTAssertEqual(provider.ranCancelled, false,
                       "recovery must not run inside the producer task that finish() cancels")
        let finished = await waitFor(log: log, entry: "recovery-finished", timeout: 5)
        XCTAssertTrue(finished, "recovery must run to completion, not out of a cancelled task")
        XCTAssertTrue(provider.completed, "a cancelled task throws out of its first cancellable await")
        let events = await consumer.value
        guard case .error = events.first else { return XCTFail("expected an error event, got \(events)") }
    }

    func testSuccessfulStreamDoesNotReportARejection() async {
        CloudRouteTestURLProtocol.stubSSE("event: done\ndata: {\"input_tokens\":1,\"output_tokens\":1}\n\n")
        let provider = RecordingProvider()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_legacy",
            session: URLSession(configuration: config),
            tokenProvider: provider
        )

        _ = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        XCTAssertTrue(provider.rejections.isEmpty, "a successful turn must not invalidate the credential")
    }
}


/// Records the order of two things the review requires to be ordered: the caller
/// receiving its error, and the credential recovery starting.
actor OrderLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

/// Hypothesis for the ordering property: recovery starts, then blocks until the
/// caller has been served. A client that awaited recovery before finishing the
/// stream can never satisfy it, so the condition is a real gate rather than a
/// timing assumption.
actor RecoveryGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

final class GatedProvider: CloudTokenProviding {
    let gate: RecoveryGate
    let log: OrderLog
    var rejections: [String?] = []
    private(set) var ranCancelled: Bool?
    private(set) var completed = false
    init(gate: RecoveryGate, log: OrderLog) { self.gate = gate; self.log = log }
    func token() async -> String? { "token-1" }
    func handleUnauthorized(rejectedToken: String?) async {
        rejections.append(rejectedToken)
        // `finish()` runs the stream's onTermination, which cancels the producer
        // task. Recovery must not run inside it: a cancelled task throws out of
        // its first cancellable await, so this records whether it did.
        ranCancelled = Task.isCancelled
        await log.append("recovery-started")
        await gate.wait()
        do {
            try await Task.sleep(nanoseconds: 20_000_000)   // cancellable
            completed = true
        } catch {
            completed = false
        }
        await log.append("recovery-finished")
    }
}

/// Polls rather than sleeping a fixed interval, so a passing case costs
/// milliseconds and a broken one fails at the timeout with the message attached.
func waitFor(log: OrderLog, entry: String, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await log.entries.contains(entry) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await log.entries.contains(entry)
}
