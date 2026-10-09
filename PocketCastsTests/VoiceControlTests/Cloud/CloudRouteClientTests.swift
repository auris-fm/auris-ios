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
            data: {"input_tokens":500,"output_tokens":80}

            """

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
                .done(usage: CloudTurnUsage(inputTokens: 500, outputTokens: 80)),
            ]
        )
        assertRouteBody(lastStubSocket?.sentTextFrames.first)
    }

    func testActionOnlyStream() async {
        self.pendingFixture = """
            event: action
            data: {"tool":"playback","action":"pause","params":{}}

            event: done
            data: {"input_tokens":10,"output_tokens":0}

            """

        let events = await collect(client().route(request: "pause", context: sampleContext))
        XCTAssertEqual(
            events,
            [
                .action(tool: "playback", action: "pause", params: [:]),
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
            data: {"input_tokens":20,"output_tokens":5}

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
            [.error(code: "limit_exceeded", message: "You've used 10/10 free requests today.")]
        )
    }

    func testMultiLineDataFieldIsJoinedBeforeParsing() async {
        // Multi-line `data:` frames are joined with `\n` (SSE). Split where a
        // newline is legal JSON whitespace so Foundation's parser accepts it.
        self.pendingFixture = """
            event: token
            data: {"text":
            data: "line1\\nline2"}

            event: done
            data: {"input_tokens":1,"output_tokens":1}

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
        guard case let .error(code, _)? = events.dropFirst().first else {
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
            requestTimeoutSeconds: 15,
        )
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

        guard case let .error(code, message)? = events.last else {
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

        guard case let .error(code, message)? = events.first else {
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

        // `handleUnauthorized` runs off the caller's path, so its record is read
        // from the test task while another task writes it: the box makes that
        // exchange sound rather than lucky.
        private let box = RejectionBox()
        var rejections: [String?] { box.values }
        func token() async -> String? { token }
        func handleUnauthorized(rejectedToken: String?) async { box.append(rejectedToken) }
    }

    /// Appends from one task, reads from another. A lock is the smallest thing
    /// that is correct here; the poll below runs while the report lands.
    private final class RejectionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String?] = []
        var values: [String?] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        func append(_ value: String?) {
            lock.lock(); defer { lock.unlock() }
            stored.append(value)
        }
    }

    /// Waits for an async side effect so the assertion measures the behaviour
    /// rather than the scheduling. Returns whether it arrived, so a timeout is
    /// the failure rather than a silent five-second pause before an unrelated
    /// assertion fails. (Not named `waitFor`: this file has a global by that
    /// name, and it would be shadowed here.)
    @discardableResult
    private func awaitCondition(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
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
            tokenProvider: provider,
        )

        let events = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        // The rejection is reported off the caller's path by design (recovery
        // must never delay the user's error), so it is awaited rather than
        // raced: asserting immediately is a race the slower CI machine loses,
        // which is how this failed there while passing locally.
        let reported = await awaitCondition { !provider.rejections.isEmpty }
        XCTAssertTrue(reported, "the rejected credential must be reported within the timeout")
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
            tokenProvider: provider,
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
        self.pendingFixture = "event: done\ndata: {\"input_tokens\":1,\"output_tokens\":1}\n\n"
        let provider = RecordingProvider()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_legacy",
            session: URLSession(configuration: config),
            tokenProvider: provider,
        )

        _ = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        // A successful turn must never report a rejection. There is nothing to
        // wait *for* here, so give any erroneous report the same window a real
        // one gets rather than asserting the instant the stream drains — the
        // shape that cost two rounds on the sibling test.
        _ = await awaitCondition(timeout: 1) { !provider.rejections.isEmpty }
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
    /// The same *pattern* as the sibling provider above — its own box, not a
    /// shared one. `handleUnauthorized` runs off the caller's path, so the
    /// record is written by one task and read by the test task. The read
    /// happens to be ordered today by the preceding `waitFor(log:entry:)`,
    /// which is why it has not bitten; this makes it sound rather than lucky.
    private let box = GatedProviderBox()
    var rejections: [String?] { box.rejections }
    var ranCancelled: Bool? { box.ranCancelled }
    var completed: Bool { box.completed }
    init(gate: RecoveryGate, log: OrderLog) { self.gate = gate; self.log = log }
    func token() async -> String? { "token-1" }
    func handleUnauthorized(rejectedToken: String?) async {
        box.appendRejection(rejectedToken)
        // `finish()` runs the stream's onTermination, which cancels the producer
        // task. Recovery must not run inside it: a cancelled task throws out of
        // its first cancellable await, so this records whether it did.
        box.setRanCancelled(Task.isCancelled)
        await log.append("recovery-started")
        await gate.wait()
        do {
            try await Task.sleep(nanoseconds: 20_000_000)   // cancellable
            box.setCompleted(true)
        } catch {
            box.setCompleted(false)
        }
        await log.append("recovery-finished")
    }
}

/// Holds `GatedProvider`'s cross-task state behind one lock. A single box for
/// the three fields keeps the provider's reads and writes in one place.
final class GatedProviderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRejections: [String?] = []
    private var storedRanCancelled: Bool?
    private var storedCompleted = false

    var rejections: [String?] { lock.lock(); defer { lock.unlock() }; return storedRejections }
    var ranCancelled: Bool? { lock.lock(); defer { lock.unlock() }; return storedRanCancelled }
    var completed: Bool { lock.lock(); defer { lock.unlock() }; return storedCompleted }

    func appendRejection(_ value: String?) { lock.lock(); defer { lock.unlock() }; storedRejections.append(value) }
    func setRanCancelled(_ value: Bool) { lock.lock(); defer { lock.unlock() }; storedRanCancelled = value }
    func setCompleted(_ value: Bool) { lock.lock(); defer { lock.unlock() }; storedCompleted = value }
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

// MARK: - Production transport (WebSocket) through the task seam

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
    private func waitForCancellation(_ task: StubWebSocketTask) async -> Bool {
        for _ in 0..<50 {
            if task.cancelled != nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return task.cancelled != nil
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

        XCTAssertEqual(events.last, .error(code: "unauthorized", message: ""),
                       "a turn with no credential must report the failure, not end silently")
        XCTAssertEqual(task.sent.count, 0, "nothing is sent without a credential")
    }

    /// The production path parses `connected` for the negotiated codec, plays
    /// binary frames as audio, and closes the socket when the turn ends.
    func testConnectedThenAudioThenDoneOnProductionTransport() async {
        let connected = #"{"type":"connected","codec":"pcm_s16le@24k"}"#
        let done = #"{"type":"done","input_tokens":3,"output_tokens":4}"#
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

        guard case let .error(code, _)? = events.last else {
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

        guard case let .error(code, message)? = events.last else {
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
