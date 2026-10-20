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
        self.pendingFixture = """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":1130000}}

            event: token
            data: {"text":"She"}

            event: token
            data: {"text":" is arguing."}

            event: done
            data: {"usage":{"input_tokens":500,"output_tokens":80}}

            """

        let events = await collect(client().route(request: "What did she mean?", context: sampleContext))

        XCTAssertEqual(
            events,
            [
                .action(
                    tool: "playback",
                    action: "seek_to",
                    params: ["reference_position_ms": .int(1_130_000)],
                    operationId: nil,
                    capabilityVersion: nil
                ),
                .token("She"),
                .token(" is arguing."),
                .done(usage: CloudTurnUsage(inputTokens: 500, outputTokens: 80)),
            ]
        )
        assertRouteBody(capturedTask?.sentTextFrames.first)
    }

    /// The `app_operation_result` frame rides the SAME socket as its turn (wire contract rev
    /// da327e624), observed on ONE client/turn across its whole life: held open → mid-turn send
    /// SUBMITTED (frame captured on that socket) → turn completes → send after close is
    /// UNDELIVERED (typed local-knowledge, not a server receipt). A duplicate live registration
    /// of the same request_id is retired only by its own turn.
    func testOperationResultRidesTheLiveTurnSocketAndReportsUndeliveredAfterClose() async throws {
        let liveFixture = [
            "event: action",
            "data: {\"operation_id\":\"op-live\",\"capability_version\":\"v1\",\"tool\":\"playback\",\"action\":\"pause\",\"params\":{}}",
            "",
            "event: done",
            "data: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}",
            "",
        ].joined(separator: "\n")
        let liveTask = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: liveFixture))
        let heldGate = Gate()
        liveTask.holdUntilReleased(heldGate)
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: userId,
            tokenProvider: StubTokenProvider(token: "t"),
            webSocketTaskFactory: { _ in liveTask }
        )
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [], conversation: testPreparedConversation())
        let routed = client.routeWithResultSocket(request: "x", context: sampleContext, turn: turn)
        let stream = routed.stream
        let resultSocket = routed.resultSocket
        let reader = Task {
            var events: [CloudRouteEvent] = []
            for await event in stream { events.append(event) }
            // The consumer owns the close on normal completion (as the sink does).
            resultSocket.finishTurn()
            return events
        }
        // Barrier 1: the turn has SUBMITTED (auth frame is the first send) before the result send.
        let submitted = Date().addingTimeInterval(5)
        while Date() < submitted && liveTask.sentTextFrames.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let frame = AppOperationResultFrame(
            operationId: "op-live", outcome: .refused,
            reason: OperationReason.referenceMappingUnavailable
        )
        let midTurnReport = await client.sendOperationResult(try XCTUnwrap(frame), via: resultSocket)
        XCTAssertEqual(midTurnReport, .submitted, "a result sent while the turn socket is live is submitted")
        let captured = try XCTUnwrap(
            liveTask.sentTextFrames.last.flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            },
            "the result left as a text frame on the turn's own socket"
        )
        XCTAssertEqual(captured["type"] as? String, "app_operation_result")
        XCTAssertEqual(captured["operation_id"] as? String, "op-live")
        XCTAssertEqual(captured["outcome"] as? String, "refused")
        XCTAssertEqual(captured["reason"] as? String, "reference_mapping_unavailable")

        // Barrier 2: the SAME turn completes; the socket closes; the registration retires.
        heldGate.release()
        _ = await reader.value
        let afterCloseReport = await client.sendOperationResult(try XCTUnwrap(frame), via: resultSocket)
        XCTAssertEqual(
            afterCloseReport, .undelivered,
            "after the SAME turn closed, the result is undelivered — typed local-knowledge, not a server receipt"
        )
    }

    /// A `request_id` reused while a predecessor turn is STILL OPEN, on ONE client (one registry,
    /// factory returning socket A then socket B): the predecessor's close retires only its own
    /// registration, AND a LATE result sent via the predecessor's handle is undelivered — never
    /// routed onto the successor's socket.
    func testADuplicateLiveRequestIDIsNotRetiredByThePredecessorsClose() async throws {
        let openFixture = [
            "event: action",
            "data: {\"operation_id\":\"op-a\",\"capability_version\":\"v1\",\"tool\":\"playback\",\"action\":\"pause\",\"params\":{}}",
            "",
        ].joined(separator: "\n")
        let gateA = Gate()
        let taskA = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: openFixture))
        taskA.holdUntilReleased(gateA)
        let gateB = Gate()
        let taskB = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: openFixture))
        taskB.holdUntilReleased(gateB)
        var sockets: [StubWebSocketTask] = []
        let lock = NSLock()
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: userId,
            tokenProvider: StubTokenProvider(token: "t"),
            webSocketTaskFactory: { _ in
                lock.lock(); defer { lock.unlock() }
                let next = sockets.isEmpty ? taskA : taskB
                sockets.append(next)
                return next
            }
        )
        // BOTH turns deliberately share one request_id (the reuse the rules guard).
        let sharedTurn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [], conversation: testPreparedConversation())
        // SERIALIZE the turn starts (the factory hands out sockets in call order, so concurrent
        // starts could swap A/B): start A, wait for its submission, then start B.
        let routedA = client.routeWithResultSocket(request: "a", context: sampleContext, turn: sharedTurn)
        let readerA = Task { for await _ in routedA.stream {} }
        let deadlineA = Date().addingTimeInterval(5)
        while Date() < deadlineA && taskA.sentTextFrames.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let routedB = client.routeWithResultSocket(request: "b", context: sampleContext, turn: sharedTurn)
        let readerB = Task { for await _ in routedB.stream {} }
        let deadlineB = Date().addingTimeInterval(5)
        while Date() < deadlineB && taskB.sentTextFrames.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // A closes: retires only its own registration — B's result path must stay live.
        gateA.release()
        _ = await readerA.value
        let frame = AppOperationResultFrame(
            operationId: "op-a", outcome: .refused,
            reason: OperationReason.malformedSeekTarget
        )
        let successorReport = await client.sendOperationResult(try XCTUnwrap(frame), via: routedB.resultSocket)
        XCTAssertEqual(successorReport, .submitted, "the successor's registration survived the predecessor's close")
        XCTAssertEqual(
            taskB.sentTextFrames.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["type"] as? String,
            "app_operation_result",
            "the frame rode the successor's socket"
        )
        // LATE PREDECESSOR result: A's handle is retired; the result must NOT route onto B.
        // Snapshot B's count BEFORE the late send and assert UNCHANGED after.
        let framesOnBBefore = taskB.sentTextFrames.count
        let lateReport = await client.sendOperationResult(try XCTUnwrap(frame), via: routedA.resultSocket)
        XCTAssertEqual(
            lateReport, .undelivered,
            "a late result from the retired predecessor is undelivered, never routed onto the successor's socket"
        )
        XCTAssertEqual(
            taskB.sentTextFrames.count, framesOnBBefore,
            "no extra frame landed on B from the late predecessor send"
        )
        gateB.release()
        _ = await readerB.value
    }

        func testActionOnlyStream() async {
        self.pendingFixture = """
            event: action
            data: {"tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":10,"output_tokens":0}}

            """

        let events = await collect(client().route(request: "pause", context: sampleContext))
        XCTAssertEqual(
            events,
            [
                .action(tool: "playback", action: "pause", params: [:], operationId: nil, capabilityVersion: nil),
                .done(usage: CloudTurnUsage(inputTokens: 10, outputTokens: 0)),
            ]
        )
    }

    func testTokenOnlyStream() async {
        self.pendingFixture = """
            event: token
            data: {"text":"Hello"}

            event: token
            data: {"text":" world"}

            event: done
            data: {"usage":{"input_tokens":20,"output_tokens":5}}

            """

        let events = await collect(client().route(request: "summarize", context: sampleContext))
        XCTAssertEqual(
            events,
            [
                .token("Hello"),
                .token(" world"),
                .done(usage: CloudTurnUsage(inputTokens: 20, outputTokens: 5)),
            ]
        )
    }

    /// The HTTP-era pre-stream cases (400/401 status bodies surfacing as error
    /// events) retired with the SSE transport: on the socket the credential
    /// rides the first frame, so a rejected credential is an `unauthorized`
    /// error *frame* — pinned by `testMissingCredentialYieldsUnauthorizedError`
    /// and the unauthorized-signal suites — and there is no status code to read.

    func testInlineErrorEventLimitExceeded() async {
        self.pendingFixture = """
            event: error
            data: {"code":"limit_exceeded","message":"You've used 10/10 free requests today."}

            """

        let events = await collect(client().route(request: "hello", context: sampleContext))
        XCTAssertEqual(
            events,
            [.error(source: .server, code: "limit_exceeded", message: "You've used 10/10 free requests today.")]
        )
    }

    /// A token carries embedded newlines through the socket unchanged.
    ///
    /// This replaces the SSE line-joining case: the socket sends one JSON object
    /// per text frame, so there is no `data:`-line joining to test — but text
    /// with newlines must still survive the frame and reach the sink intact, or
    /// a multi-paragraph answer is read as a run-on.
    func testTokenWithEmbeddedNewlinesSurvivesTheFrame() async {
        self.pendingFixture =
            """
            event: token
            data: {"text":"line1\\nline2"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """

        let events = await collect(client().route(request: "hello", context: sampleContext))
        XCTAssertEqual(
            events,
            [
                .token("line1\nline2"),
                .done(usage: CloudTurnUsage(inputTokens: 1, outputTokens: 1)),
            ]
        )
    }

    func testMidStreamConnectionDropEmitsConnectionError() async {
        // Frames arrive, then the socket ends with no terminal event — what a
        // dropped connection looks like from the client's side.
        self.pendingFixture =
            """
            event: token
            data: {"text":"partial"}

            """

        let events = await collect(client().route(request: "hello", context: sampleContext))
        XCTAssertEqual(events.first, .token("partial"))
        guard case let .error(_, code, _)? = events.dropFirst().first else {
            XCTFail("Expected connection_lost after partial token, got \(events)")
            return
        }
        XCTAssertEqual(code, "connection_lost")
    }

    func testClientCancellationStopsCollection() async {
        // Two tokens are queued; the collector stops after the first and must
        // never observe the second.
        self.pendingFixture =
            """
            event: token
            data: {"text":"first"}

            event: token
            data: {"text":"second"}

            """

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

    /// The client must never advertise a codec its player cannot decode: a codec
    /// we cannot play would be negotiated by the server and then played as noise,
    /// surfacing as "speech is broken" rather than "the client claimed a codec it
    /// cannot back". `CloudAudioPlayer` copies frames as raw Int16 PCM with no
    /// Opus decoder, so the list is PCM-only. Re-adding `opus@48k` fails this
    /// until an Opus decoder exists and is declared in `decodableCodecs`.
    func testAdvertisedCodecsAreDecodableByThePlayer() {
        XCTAssertFalse(
            CloudRouteClient.supportedCodecs.isEmpty,
            "The client must advertise at least one codec or the server refuses the turn"
        )
        for codec in CloudRouteClient.supportedCodecs {
            // Advertised form is `<base>@<rate>` (e.g. `pcm_s16le@24k`); the
            // decodable set names the base codec.
            let base = codec.split(separator: "@").first.map(String.init) ?? codec
            XCTAssertTrue(
                CloudAudioPlayer.decodableCodecs.contains(base),
                "Advertised codec '\(codec)' has no decoder in CloudAudioPlayer.decodableCodecs"
            )
        }
    }

    // MARK: - Helpers

    /// The socket the most recent client in this test was built on, so a case
    /// can assert on the frames the client *sent*.
    private var capturedTask: StubWebSocketTask?

    private func client() -> CloudRouteClient {
        let built = CloudRouteClient.stubbed(userId: userId, fixture: nextFixture())
        capturedTask = built.task
        return built.client
    }

    private func collect(_ stream: AsyncStream<CloudRouteEvent>) async -> [CloudRouteEvent] {
        var events: [CloudRouteEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    private func assertRouteBody(_ text: String?) {
        guard let text else {
            XCTFail("Expected a captured auth frame")
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
        CloudRouteClient.stubbed(fixture: nextFixture()).client
    }

    func testMidStreamDropWithoutDoneCarriesNoEnglishProse() async {
        // Frames arrive, then the socket closes with no terminal event.
        self.pendingFixture =
            """
            event: token
            data: {"text":"hi"}

            """
        let events = await makeClient().route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        guard case let .error(_, code, message)? = events.last else {
            return XCTFail("expected a terminal error, got \(events)")
        }
        XCTAssertEqual(code, "connection_lost")
        XCTAssertTrue(message.isEmpty, "a reachable diagnostic must not be English prose for TTS")
    }

    /// A rejected credential arrives as an error **frame** on the socket, not an
    /// HTTP status — the credential rides the first frame, so there is no 401
    /// body to read. This replaces an HTTP-era case that asserted the 401 body's
    /// text; the property it protected (a rejection is never silent) is kept.
    func testRejectedCredentialFrameStaysSilentWithoutAServerMessage() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"unauthorized","message":""}

            """
        let events = await makeClient().route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        guard case let .error(_, code, message)? = events.first else {
            return XCTFail("expected an error event, got \(events)")
        }
        XCTAssertEqual(code, "unauthorized")
        XCTAssertTrue(message.isEmpty, "the server supplied no message; the client must not synthesize English")
    }

    func testServerSuppliedMessageIsPassedThrough() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"limit_exceeded","message":"Daily limit reached"}

            """
        let events = await makeClient().route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        guard case let .error(_, code, message)? = events.first else {
            return XCTFail("expected an error event, got \(events)")
        }
        XCTAssertEqual(code, "limit_exceeded")
        XCTAssertEqual(message, "Daily limit reached", "the server's own message is passed through as-is")
    }
}

/// PR #20 review: the client must tell the credential source which credential was
/// rejected, so a burst of 401s refreshes once rather than once per response.
/// Retired with the SSE transport.
///
/// These three cases drove a **401 pre-stream status** through the route client
/// and asserted that the rejected credential was reported to the token provider.
/// The socket carries the credential in its first frame, so there is no status
/// to read and the route client no longer reports rejections — the contract now
/// belongs to the HTTP prefetch client, which calls
/// `handleUnauthorized(rejectedToken:)` on a 401 and is covered by
/// `CloudPrefetchClientTests`. The route client's own unauthorized handling is
/// pinned by `testMissingCredentialYieldsUnauthorizedError` above (an
/// `unauthorized` frame, never silence).
///
/// Nothing was lost here by deletion: the reporting path these cases exercised
/// is gone, and the assertions that remain true of the socket are covered by
/// that case and by the locale/contract suites.

final class CloudRouteWebSocketPathTests: XCTestCase {
    private func client(task: StubWebSocketTask, token: String?) -> CloudRouteClient {
        CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_test",
            requestTimeoutSeconds: 15,
            tokenProvider: StubTokenProvider(token: token),
            webSocketTaskFactory: { _ in task }
        )
    }

    private func collect(_ stream: AsyncStream<CloudRouteEvent>) async -> [CloudRouteEvent] {
        var events: [CloudRouteEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    /// The socket is closed as the transport call returns (it is a `defer`), so
    /// a consumer that has drained the stream can still observe the closure a
    /// moment later. Wait briefly for it rather than racing the assertion.
    /// Shared with the other suites (`StubWebSocketTask.awaitCancellation`), so
    /// the cross-task ordering hazard is handled in one place.
    private func waitForCancellation(_ task: StubWebSocketTask) async -> Bool {
        await task.awaitCancellation()
    }

    private func context() -> CloudRouteContext {
        CloudRouteContext(from: PlaybackContext(
            episodeId: "ep",
            podcastId: "pod",
            referencePositionMs: 1_000,
            clientPositionMs: 1_100,
            recentReferencePositions: [],
            previousReferencePositionMs: nil
        ))
    }

    /// A turn with no credential must end with a terminal `unauthorized` event.
    /// Finishing silently leaves the user with no error and no outcome.
    func testMissingCredentialYieldsUnauthorizedError() async {
        let task = StubWebSocketTask([])
        let events = await collect(client(task: task, token: nil).route(request: "hello", context: context()))

        XCTAssertEqual(events.last, .error(source: .server, code: "unauthorized", message: ""),
                       "a turn with no credential must report the failure, not end silently")
        XCTAssertEqual(task.sent.count, 0, "nothing is sent without a credential")
    }

    /// The production path parses `connected` for the negotiated codec, plays
    /// binary frames as audio, and closes the socket when the turn ends.
    func testConnectedThenAudioThenDoneOnProductionTransport() async {
        let connected = #"{"type":"connected","codec":"pcm_s16le@24k"}"#
        let done = #"{"type":"done","usage":{"input_tokens":3,"output_tokens":4}}"#
        let task = StubWebSocketTask([
            .string(connected),
            .data(Data([0x01, 0x00, 0x02, 0x00])),
            .string(done)
        ])

        let events = await collect(client(task: task, token: "tok").route(request: "hello", context: context()))
        XCTAssertEqual(events.count, 3, "connected, one audio frame, done — got \(events)")
        if case let .connected(codec) = events[0] {
            XCTAssertEqual(codec.base, "pcm_s16le")
            XCTAssertEqual(codec.sampleRateHz, 24_000, "the negotiated rate comes from the codec name")
        } else {
            XCTFail("expected a .connected event carrying the negotiated codec, got \(events[0])")
        }
        let frames = events.compactMap { if case let .audioFrame(f) = $0 { return f }; return nil }
        XCTAssertEqual(frames.map(\.data), [Data([0x01, 0x00, 0x02, 0x00])], "the binary frame arrives as audio")
        XCTAssertEqual(events.last, .done(usage: CloudTurnUsage(inputTokens: 3, outputTokens: 4)),
                       "the turn ends on done")
        XCTAssertEqual(task.sent.count, 1, "the auth frame went out")
        let closed = await waitForCancellation(task)
        XCTAssertTrue(closed, "the socket must be closed when the turn ends")
    }

    /// A stream that ends without a terminal event is reported, not silent.
    func testClosedWithoutTerminalYieldsConnectionLost() async {
        let task = StubWebSocketTask([.string(#"{"type":"connected","codec":"pcm_s16le@24k"}"#)])
        let events = await collect(client(task: task, token: "tok").route(request: "hello", context: context()))

        guard case let .error(_, code, _)? = events.last else {
            return XCTFail("expected a terminal error, got \(String(describing: events.last))")
        }
        XCTAssertEqual(code, "connection_lost", "a stream that ends without a terminal event is reported")
        let closed = await waitForCancellation(task)
        XCTAssertTrue(closed, "the socket is closed on the non-terminal path too")
    }

    /// A failed WebSocket upgrade is terminal: the retired SSE fallback used to
    /// be reachable here, so this pins the no-fallback property itself — the
    /// turn reports the failure and sends **no** second request.
    func testFailedUpgradeIsTerminalAndIssuesNoSecondRequest() async {
        let task = StubWebSocketTask([])
        task.receiveError = URLError(.cannotConnectToHost)
        let client = client(task: task, token: "tok")

        let events = await collect(client.route(request: "hello", context: context()))

        guard case let .error(_, code, message)? = events.last else {
            return XCTFail("a failed upgrade must report an error, got \(events)")
        }
        XCTAssertEqual(code, "connection_lost")
        XCTAssertTrue(message.isEmpty, "no English URLSession prose reaches the user")

        // The auth frame is the only thing the client ever sends. A fallback
        // transport would have posted a second request; there is none.
        let sent = task.sentTextFrames
        XCTAssertEqual(sent.count, 1, "exactly one frame — the auth frame — and no fallback request")
        XCTAssertTrue(sent[0].contains("authenticate"), "the one frame is the authenticate frame")
    }
}

// MARK: - Turn-socket lifetime ownership

extension CloudRouteClientTests {
    private func makeResultSocketClient(actionId: String) -> (CloudRouteClient, CloudTurnEnvelope, StubWebSocketTask) {
        let fixture = [
            "event: action",
            "data: {\"operation_id\":\"\(actionId)\",\"capability_version\":\"v1\",\"tool\":\"playback\",\"action\":\"pause\",\"params\":{}}",
            "",
            "event: done",
            "data: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}",
            "",
        ].joined(separator: "\n")
        let task = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: fixture))
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: userId,
            tokenProvider: StubTokenProvider(token: "t"),
            webSocketTaskFactory: { _ in task }
        )
        return (client, CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [], conversation: testPreparedConversation()), task)
    }

    private func resultFrame(operationId: String) -> AppOperationResultFrame {
        AppOperationResultFrame(
            operationId: operationId,
            outcome: .refused,
            reason: OperationReason.unsupportedOperation,
            detail: nil
        )!
    }

    /// A CLAIMED consumer held past the bounded grace deadline keeps its registration: the
    /// producer-finish grace cleanup applies only while no consumer has claimed ownership.
    func testGraceCleanupDoesNotSeverAClaimedConsumerHeldPastTheDeadline() async throws {
        let (client, turn, _) = makeResultSocketClient(actionId: "op-grace-claim")
        let routed = client.routeWithResultSocket(request: "x", context: sampleContext, turn: turn)
        let stream = routed.stream
        let socket = routed.resultSocket
        // Consume the first event, then hold the consumer past the 2s grace.
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        socket.claimConsumerOwnership()
        try await Task.sleep(nanoseconds: 2_400_000_000)
        let report = await client.sendOperationResult(
            resultFrame(operationId: "op-grace-claim"), via: socket
        )
        XCTAssertEqual(report, .submitted, "a claimed consumer must keep its registration past the grace deadline")
    }

    /// A turn whose stream is never consumed is cleaned up on a bound, not held forever.
    func testNeverConsumedTurnSocketIsCleanedUpByTheBoundedGrace() async throws {
        let (client, turn, _) = makeResultSocketClient(actionId: "op-grace-orphan")
        let routed = client.routeWithResultSocket(request: "x", context: sampleContext, turn: turn)
        // Deliberately never iterate. The producer finishes; the grace timer owns cleanup.
        var report: CloudRouteClient.AppOperationResultSendReport?
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            report = await client.sendOperationResult(
                resultFrame(operationId: "op-grace-orphan"), via: routed.resultSocket
            )
            if report == .undelivered { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(report, .undelivered, "an unclaimed turn's registration must be retired by the bounded cleanup")
    }

    /// A consumer that abandons the stream closes the registration immediately (.cancelled).
    func testCancelledConsumerClosesTheTurnSocketImmediately() async throws {
        // Cancellation cleanup is bound to the task that owns consumer execution via
        // withTaskCancellationHandler (the sink's production pattern), not to AsyncStream
        // termination, which does not fire on task cancellation.
        let (client, turn, liveTask) = makeResultSocketClient(actionId: "op-cancel-close")
        // Hold the producer open so the consumer is genuinely SUSPENDED in the handler when
        // cancellation strikes — the production shape (a live turn mid-stream), not a stream
        // that already finished and deregistered the handler.
        let heldGate = Gate()
        liveTask.holdUntilReleased(heldGate)
        let routed = client.routeWithResultSocket(request: "x", context: sampleContext, turn: turn)
        let stream = routed.stream
        // PRODUCTION SHAPE: the consumer claims, installs the same single idempotent close the
        // sink runs in a defer, and iterates. Cancelling the OWNING task makes AsyncStream's
        // next() return nil, the loop exits, and the defer retires the registration — no
        // test-only cancellation handler.
        let reader = Task {
            routed.resultSocket.claimConsumerOwnership()
            defer { routed.resultSocket.finishTurn() }
            for await _ in stream {}
        }
        // The consumer claims ownership (cancelling the creation-armed grace), then abandons
        // the turn: only the cancellation close can retire the registration.
        try await Task.sleep(nanoseconds: 300_000_000)
        routed.resultSocket.claimConsumerOwnership()
        reader.cancel()
        await reader.value
        var report: CloudRouteClient.AppOperationResultSendReport?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            report = await client.sendOperationResult(
                resultFrame(operationId: "op-cancel-close"), via: routed.resultSocket
            )
            if report == .undelivered { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(report, .undelivered, "cancellation while the consumer is suspended in the handler must close the socket")
    }

    /// finishTurn is idempotent: a second call neither traps nor resurrects the registration.
    func testFinishTurnIsIdempotent() async throws {
        let (client, turn, _) = makeResultSocketClient(actionId: "op-idem")
        let routed = client.routeWithResultSocket(request: "x", context: sampleContext, turn: turn)
        routed.resultSocket.claimConsumerOwnership()
        routed.resultSocket.finishTurn()
        routed.resultSocket.finishTurn()
        let report = await client.sendOperationResult(
            resultFrame(operationId: "op-idem"), via: routed.resultSocket
        )
        XCTAssertEqual(report, .undelivered)
    }
}
