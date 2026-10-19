import XCTest
@testable import podcasts

/// Item 5 (iOS half) — edge turn contract: `request_id`, `capabilities` gating,
/// typed-only `route_hint`, and a bounded `context.recent_conversation`.
/// Field names/semantics are pinned against `docs/specs/cloud-assistant.md`
/// ("Turn control fields").
final class CloudTurnContractTests: XCTestCase {
    // MARK: - source-first runtime request + optional source_language (core b6eafe25)

    /// The runtime `request` carries the complete wake-trimmed SOURCE utterance when one is
    /// available; the English routing translation never replaces the original on the wire.
    /// The optional `source_language` carries the ASR pipeline's actual LID — yue stays yue.
    func testSourceUtteranceAndLanguageRideTheAuthFrameWhenAvailable() async throws {
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        let json = try await authFrame(
            request: "play something upbeat",   // English routing translation
            turn: turn,
            sourceTranscript: "来点欢快的",       // wake-trimmed source utterance
            sourceLanguage: "yue"                // actual ASR LID — yue, not zh
        )
        XCTAssertEqual(json["request"] as? String, "来点欢快的",
                       "the original source utterance must be the runtime request, not the routing translation")
        XCTAssertEqual(json["source_language"] as? String, "yue",
                       "the actual detected language must ride the frame, preserving yue vs zh")
    }

    /// Translated-only (backend translate exposes English only): no original exists, so the
    /// available English text is used WITHOUT fabricating an original, and `source_language` is
    /// omitted — unknown is omitted, never invented (not the OS locale, not "en").
    func testTranslatedOnlyTurnSendsAvailableTextAndOmitsUnknownLanguage() async throws {
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        let json = try await authFrame(
            request: "play something upbeat",
            turn: turn,
            sourceTranscript: nil,
            sourceLanguage: nil
        )
        XCTAssertEqual(json["request"] as? String, "play something upbeat",
                       "without an original, the available text is the request — nothing fabricated")
        XCTAssertFalse(json.keys.contains("source_language"),
                       "an unknown language must be OMITTED from the frame, never defaulted")
    }

    /// An EMPTY source transcript is not an original: the routing request is used and the
    /// language rides only if actually present.
    func testEmptySourceTranscriptFallsBackToRoutingRequest() async throws {
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        let json = try await authFrame(
            request: "pause",
            turn: turn,
            sourceTranscript: "",
            sourceLanguage: "zh"
        )
        XCTAssertEqual(json["request"] as? String, "pause",
                       "an empty source transcript must not replace the routing request")
        XCTAssertEqual(json["source_language"] as? String, "zh")
    }

    // MARK: - request_id

    func testRequestIdIsPresentAndStableWhenReused() async throws {
        let turn = CloudTurnEnvelope.make(
            capabilities: [],
            routeHint: nil,
            recentConversation: []
        )
        let json = try await authFrame(request: "what did they say about AI?", turn: turn)

        XCTAssertEqual(json["request_id"] as? String, turn.requestId, "request_id must come from the envelope")
        XCTAssertNotNil(UUID(uuidString: turn.requestId), "request_id must be a UUID")

        // A transport retry reuses the same logical-turn envelope.
        let retry = try await authFrame(request: "what did they say about AI?", turn: turn)
        XCTAssertEqual(retry["request_id"] as? String, turn.requestId, "retries keep the same request_id")
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
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """

        // One client per attempt: each carries the envelope it was given, so the
        // id on the wire is readable per attempt.
        let firstAttempt = makeClient()
        for await _ in firstAttempt.route(request: "same logical turn", context: sampleContext(), turn: turn) {}
        let sameTask = capturedTasks.removeLast()

        // The same *envelope* re-driven and a fresh envelope: the id belongs to
        // the logical turn, not to the attempt.
        capturedTasks.removeAll()
        let retry = makeClient()
        for await _ in retry.route(request: "same logical turn", context: sampleContext(), turn: turn) {}
        let secondTurn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        let fresh = makeClient()
        for await _ in fresh.route(request: "next turn", context: sampleContext(), turn: secondTurn) {}

        // The first attempt, the retry of the same envelope, then a fresh turn.
        XCTAssertEqual(
            sameTask.sentAuthFrame?["request_id"] as? String,
            turn.requestId,
            "the attempt carries the envelope's own id"
        )
        let retriedId = capturedTasks[0].sentAuthFrame?["request_id"] as? String
        XCTAssertEqual(retriedId, turn.requestId, "a re-driven envelope reuses its id (one admitted turn)")
        let freshId = capturedTasks[1].sentAuthFrame?["request_id"] as? String
        XCTAssertEqual(freshId, secondTurn.requestId, "a genuinely new turn gets its own id")
        XCTAssertNotEqual(secondTurn.requestId, turn.requestId)
    }

    // MARK: - capabilities

    func testCapabilitiesOmittedWhenRendererNotAvailable() async throws {
        // Default iOS posture: no `search_results_v1` renderer yet, so nothing
        // is advertised and the server falls back to short token text + done.
        let turn = CloudTurnEnvelope.make(
            capabilities: CloudClientCapabilities.advertised(rendersStructuredResults: false),
            routeHint: nil,
            recentConversation: []
        )
        XCTAssertTrue(turn.capabilities.isEmpty)

        let json = try await authFrame(request: "x", turn: turn)
        XCTAssertNil(json["capabilities"], "capabilities must be omitted, not sent empty")
    }

    func testCapabilitiesAdvertiseSearchResultsV1Only() async throws {
        let capabilities = CloudClientCapabilities.advertised(rendersStructuredResults: true)
        XCTAssertEqual(capabilities, ["search_results_v1"])

        let turn = CloudTurnEnvelope.make(capabilities: capabilities, routeHint: nil, recentConversation: [])
        let json = try await authFrame(request: "x", turn: turn)
        XCTAssertEqual(json["capabilities"] as? [String], ["search_results_v1"])
    }

    /// PR #19 review: the 8 KiB bound is a byte bound, so a single CJK/emoji turn
    /// must not trim to 8 Ki *characters* (~32 KiB of bytes).
    func testSingleOversizedMultibyteTurnIsTrimmedByUtf8Bytes() {
        // 4 000 CJK characters = 12 000 UTF-8 bytes, well over the 8 KiB bound.
        let cjk = String(repeating: "暂", count: 4_000)
        let bounded = RecentConversation.bounded([RecentConversationTurn(role: .user, text: cjk)])

        XCTAssertEqual(bounded.count, 1)
        let bytes = bounded[0].text.utf8.count
        XCTAssertLessThanOrEqual(bytes, RecentConversation.maxBytes, "bound is bytes, not characters")
        XCTAssertGreaterThan(bytes, 7_000, "the newest speech is still kept, not emptied")
        XCTAssertFalse(bounded[0].text.isEmpty)
    }

    func testMultibyteTrimNeverSplitsAScalar() {
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 2_000)
        let bounded = RecentConversation.bounded([RecentConversationTurn(role: .user, text: emoji)])
        XCTAssertLessThanOrEqual(bounded[0].text.utf8.count, RecentConversation.maxBytes)
        // A split scalar would have produced replacement characters.
        XCTAssertFalse(bounded[0].text.contains("\u{FFFD}"))
    }

    func testAsciiTurnsStillBoundByBytes() {
        let ascii = String(repeating: "a", count: 20_000)
        let bounded = RecentConversation.bounded([RecentConversationTurn(role: .assistant, text: ascii)])
        XCTAssertEqual(bounded[0].text.utf8.count, RecentConversation.maxBytes)
    }

    // MARK: - route_hint

    func testRouteHintOmittedForFreeTextTurns() async throws {
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        let json = try await authFrame(request: "play the bit about AI", turn: turn)
        XCTAssertNil(json["route_hint"], "free-text cloud_route keeps working without a hint")
    }

    func testRouteHintSerializesOperationAndArguments() async throws {
        let hint = CloudRouteHint(
            operation: "search_spoken_content",
            arguments: ["query": .string("climate"), "scope": .string("current_episode")]
        )
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: hint, recentConversation: [])
        let json = try await authFrame(request: "x", turn: turn)

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

    func testRecentConversationOmittedWhenEmpty() async throws {
        let turn = CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        let json = try await authFrame(request: "x", turn: turn)
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertNil(context["recent_conversation"])
    }

    /// Superseded by the owning paragraph, which retains history server-side and forbids
    /// client-supplied history in the frame. This case asserted the OLD contract — that the
    /// client serialized `context.recent_conversation` — and it held the frame to a shape the
    /// spec now refuses, so it is inverted rather than deleted: the field must be absent even
    /// when the client still holds local context, or the model would receive text the server
    /// never authenticated.
    func testRecentConversationIsNeverSerializedIntoTheFrame() async throws {
        let turn = CloudTurnEnvelope.make(
            capabilities: [],
            routeHint: nil,
            recentConversation: [RecentConversationTurn(role: .user, text: "who is speaking?")]
        )
        let json = try await authFrame(request: "x", turn: turn)
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertNil(
            context["recent_conversation"],
            "client-supplied conversation history was sent; the server retains history itself"
        )
    }

    // MARK: - existing contract preserved

    func testExistingContextFieldsUnchanged() async throws {
        let json = try await authFrame(request: "hello", turn: CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: []))
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

    /// The authenticate frame the client **actually sends** for a turn.
    ///
    /// Driven through the real transport rather than a parallel builder: these
    /// cases pin the turn envelope, and the only way to pin what ships is to read
    /// the frame the socket carries. (They previously read a POST body built by a
    /// second implementation that no production path called, so the assertions
    /// could pass while the wired frame drifted.)
    private func authFrame(
        request: String,
        turn: CloudTurnEnvelope,
        token: String? = "test_token",
        sourceTranscript: String? = nil,
        sourceLanguage: String? = nil
    ) async throws -> [String: Any] {
        let task = StubWebSocketTask(textFrames: [#"{"type":"done","usage":{"input_tokens":1,"output_tokens":0}}"#])
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_test",
            requestTimeoutSeconds: 15,
            tokenProvider: StubTokenProvider(token: token),
            webSocketTaskFactory: { _ in task }
        )
        for await _ in client.route(
            request: request,
            context: sampleContext(),
            turn: turn,
            sourceTranscript: sourceTranscript,
            sourceLanguage: sourceLanguage
        ) {}
        return try XCTUnwrap(task.sentAuthFrame)
    }

    /// One entry per client built, so a case can assert the id the client *sent*
    /// on each attempt (the auth frame carries `request_id`).
    private var capturedTasks: [StubWebSocketTask] = []

    private func makeClient() -> CloudRouteClient {
        let built = CloudRouteClient.stubbed(fixture: nextFixture())
        capturedTasks.append(built.task)
        return built.client
    }
    /// A send that TRANSMITS and then fails is reported as an ordinary transport failure.
    ///
    /// The distinction that matters is preserved even though the never-submitted case is gone: a
    /// frame that left the client is NOT treated as one that never did, so nothing may re-drive it.
    /// The assertion is that the failure is surfaced at all and the frame is recorded as sent —
    /// there is no separate "never submitted" outcome for a transmitted frame to be misclassified
    /// into, which is the stronger position.
    func testASendThatTransmitsThenThrowsIsReportedAsATransportFailure() async {
        let built = CloudRouteClient.stubbed(baseURL: "https://cloud.test", fixture: "")
        let task = built.task
        let client = built.client
        task.transmitsThenThrows = true

        var sawError = false
        for await event in client.route(
            request: "x",
            context: CloudRouteContext(
                episodeId: nil, podcastId: nil, referencePositionMs: nil,
                clientPositionMs: nil, recentReferencePositions: [], previousReferencePositionMs: nil
            ),
            turn: CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        ) {
            if case .error = event { sawError = true }
        }

        XCTAssertEqual(task.sent.count, 1, "the frame was not transmitted, so the case is vacuous")
        XCTAssertTrue(sawError, "the failure was not surfaced at all")
    }

    /// The PRODUCTION task must not be left suspended. A `URLSessionWebSocketTask` starts suspended
    /// and must be resumed to begin connecting; without the resume the task never reached startup,
    /// so a turn could not begin. (Startup is the observed requirement; "every suspended send
    /// fails" was not measured and is not claimed.)
    ///
    /// This case deliberately does NOT inject `webSocketTaskFactory`: injecting it bypasses the
    /// default path, which is exactly how the missing resume survived the entire suite. It drives
    /// the real factory and reads the state of the task that factory produced.
    func testTheProductionWebSocketTaskIsNotLeftSuspended() async {
        let client = CloudRouteClient(baseURL: "wss://cloud.test", userId: "user_test")
        // Drive the production path far enough to create its task. The connection itself cannot
        // succeed here, which is fine: the assertion is about the task's STATE, not its outcome.
        let stream = client.route(
            request: "x",
            context: CloudRouteContext(
                episodeId: nil, podcastId: nil, referencePositionMs: nil,
                clientPositionMs: nil, recentReferencePositions: [], previousReferencePositionMs: nil
            ),
            turn: CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        )
        let consumer = Task { for await _ in stream {} }
        // Give the production path a moment to create and resume its task.
        try? await Task.sleep(nanoseconds: 500_000_000)
        consumer.cancel()

        let state = client.lastProductionTaskStateForTesting
        XCTAssertNotNil(state, "the production path never created a task, so this case is vacuous")
        XCTAssertNotEqual(
            state, .suspended,
            "the production WebSocket task was left SUSPENDED, so it never began connecting and "
                + "a turn could not start"
        )
    }

}
