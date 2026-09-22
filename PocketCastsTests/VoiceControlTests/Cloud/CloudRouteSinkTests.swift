import XCTest
@testable import podcasts

final class CloudRouteSinkTests: XCTestCase {
    private var playback: RecordingPlaybackSink!
    private var mapper: RecordingFingerprintMapper!
    private var contextState: CloudPlaybackContextState!
    private var analytics: RecordingAnalytics!
    private var voiceAnalytics: VoiceAnalytics!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        mapper = RecordingFingerprintMapper()
        contextState = CloudPlaybackContextState()
        analytics = RecordingAnalytics()
        voiceAnalytics = VoiceAnalytics(analytics: analytics)
        suiteName = "cloud_route_sink_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMixedStreamDispatchesSeekSpeaksTokensOnDone() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":1130000}}

            event: token
            data: {"text":"She"}

            event: token
            data: {"text":" is arguing."}

            event: done
            data: {"input_tokens":10,"output_tokens":4}

            """
        )
        mapper.playbackSecondsForReference = [1130.0: 1200.0]
        playback.positionMs = 500_000

        let response = await makeSink().routeToCloud(
            request: "What did she mean?",
            tier: .free,
            context: sampleContext()
        )

        XCTAssertEqual(response, .spoken("She is arguing."))
        XCTAssertTrue(playback.calls.contains(.pause))
        XCTAssertTrue(playback.calls.contains(.resume), "done must restore turn-owned auto-pause")
        XCTAssertEqual(playback.calls.filter { $0 == .seekTo(1200) }.count, 1)
        XCTAssertEqual(analytics.events.last?.0, "cloud_assistant_turn")
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "done")
        let snap = contextState.snapshot()
        XCTAssertEqual(snap.recentReferencePositions.last, 1_130_000)
        XCTAssertEqual(snap.previousReferencePositionMs, 500_000)
    }

    func testDoneResumesTurnOwnedAutoPause() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: token
            data: {"text":"Answer."}

            event: done
            data: {"input_tokens":1,"output_tokens":1}

            """
        )

        let response = await makeSink().routeToCloud(
            request: "summarize",
            tier: .free,
            context: sampleContext()
        )

        XCTAssertEqual(response, .spoken("Answer."))
        XCTAssertEqual(playback.calls.first, .pause)
        XCTAssertEqual(playback.calls.last, .resume)
        XCTAssertEqual(playback.calls.filter { $0 == .pause }.count, 1)
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1)
    }

    func testPlayQuoteAndStopQuoteRestorePosition() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":500000}}

            event: action
            data: {"tool":"playback","action":"stop_quote","params":{}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        )
        mapper.playbackSecondsForReference = [500.0: 510.0]
        playback.positionMs = 900_000

        let response = await makeSink().routeToCloud(
            request: "play that",
            tier: .free,
            context: sampleContext()
        )

        XCTAssertEqual(response, .silent)
        XCTAssertTrue(playback.calls.contains(.seekTo(510)))
        XCTAssertTrue(playback.calls.contains(.seekTo(900)))
        XCTAssertTrue(playback.calls.contains(.resume))
    }

    func testUnknownActionIgnored() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: action
            data: {"tool":"playback","action":"do_a_barrel_roll","params":{}}

            event: action
            data: {"tool":"bookmarks","action":"add","params":{}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        )

        _ = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0)
    }

    func testErrorClearsBufferRestoresPauseDoesNotRollbackSeek() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":100000}}

            event: token
            data: {"text":"partial"}

            event: error
            data: {"code":"limit_exceeded","message":"rate limited"}

            """
        )
        mapper.playbackSecondsForReference = [100.0: 110.0]
        playback.positionMs = 50_000

        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())

        XCTAssertEqual(response, .spoken("rate limited"))
        XCTAssertTrue(playback.calls.contains(.seekTo(110)))
        XCTAssertTrue(playback.calls.contains(.resume))
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "error")
    }

    func testUnmappedReferenceSeeksAsIsBestEffort() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":200000}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        )
        _ = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())
        XCTAssertTrue(playback.calls.contains(.seekTo(200)))
    }

    /// Per-turn state: a `stop_quote` in a turn that issued no `play_quote`
    /// must NOT seek to a previous turn's captured pre-quote position.
    func testStopQuoteWithoutPlayQuoteInLaterTurnDoesNotUseStalePosition() async {
        // RecordingFingerprintMapper is a struct — configure it before the sink copies it.
        mapper.playbackSecondsForReference = [500.0: 510.0]
        playback.positionMs = 900_000
        let sink = makeSink()

        // Turn 1 captures a pre-quote position via play_quote.
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":500000}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        )
        _ = await sink.routeToCloud(request: "play that", tier: .free, context: sampleContext())
        XCTAssertTrue(playback.calls.contains(.seekTo(510)))

        // Turn 2 (same sink): stop_quote without play_quote must be a no-op seek-wise.
        playback.calls.removeAll()
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: action
            data: {"tool":"playback","action":"stop_quote","params":{}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        )
        _ = await sink.routeToCloud(request: "stop", tier: .free, context: sampleContext())
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0)
    }

    /// Slice 1: the sink sends one turn envelope — request_id on the wire and
    /// capabilities only once a structured-results renderer exists.
    func testSinkSendsTurnEnvelopeWithRequestIdAndGatedCapabilities() async throws {
        var bodies: [[String: Any]] = []
        CloudRouteTestURLProtocol.onRequest = { _, body in
            if let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                bodies.append(object)
            }
        }
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: token
            data: {"text":"ok"}

            event: done
            data: {"input_tokens":1,"output_tokens":1}

            """
        )

        _ = await makeSink().routeToCloud(request: "what did they say?", tier: .free, context: sampleContext())

        let body = try XCTUnwrap(bodies.first)
        let requestId = try XCTUnwrap(body["request_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: requestId), "request_id must be a client-assigned UUID")
        XCTAssertNil(body["capabilities"], "no renderer yet: capabilities must be omitted so the server uses token+done")
        XCTAssertNil(body["route_hint"], "free-text turns carry no hint")
    }

    func testSinkAdvertisesSearchResultsV1OnlyWhenRendererAvailable() async throws {
        var bodies: [[String: Any]] = []
        CloudRouteTestURLProtocol.onRequest = { _, body in
            if let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                bodies.append(object)
            }
        }
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        )

        _ = await makeSink(rendersStructuredResults: true, routeHint: CloudRouteHint(
            operation: "search_spoken_content",
            arguments: ["query": .string("climate")]
        )).routeToCloud(request: "find the climate bit", tier: .free, context: sampleContext())

        let body = try XCTUnwrap(bodies.first)
        XCTAssertEqual(body["capabilities"] as? [String], ["search_results_v1"])
        let hint = try XCTUnwrap(body["route_hint"] as? [String: Any])
        XCTAssertEqual(hint["operation"] as? String, "search_spoken_content")
    }

    // MARK: - Helpers

    private func makeSink(
        rendersStructuredResults: Bool = false,
        routeHint: CloudRouteHint? = nil
    ) -> CloudRouteSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let session = URLSession(configuration: config)
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                CloudRouteClient(
                    baseURL: cloudConfig.baseUrl,
                    userId: "user_test",
                    session: session
                )
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            rendersStructuredResults: rendersStructuredResults,
            routeHintProvider: { routeHint }
        )
    }

    private func sampleContext() -> PlaybackContext {
        PlaybackContext(
            episodeId: "ep",
            podcastId: "pod",
            referencePositionMs: 1_000,
            clientPositionMs: 1_100,
            recentReferencePositions: [],
            previousReferencePositionMs: nil
        )
    }
}

private final class RecordingPlaybackSink: VoicePlaybackSink {
    enum Call: Equatable {
        case pause, resume, seekRelative(Int), seekTo(Int), nextEpisode
    }

    var calls: [Call] = []
    var positionMs: Int64 = 0

    func pause() -> VoiceResponse {
        calls.append(.pause)
        return .earcon(.success)
    }

    func resume() -> VoiceResponse {
        calls.append(.resume)
        return .silent
    }

    func seekRelative(deltaSeconds: Int) -> VoiceResponse {
        calls.append(.seekRelative(deltaSeconds))
        return .silent
    }

    func seekTo(positionSeconds: Int) -> VoiceResponse {
        calls.append(.seekTo(positionSeconds))
        return .silent
    }

    func nextEpisode() -> VoiceResponse {
        calls.append(.nextEpisode)
        return .silent
    }
}

private struct RecordingFingerprintMapper: FingerprintMappingProviding {
    var playbackSecondsForReference: [TimeInterval: TimeInterval] = [:]

    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { nil }

    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? {
        playbackSecondsForReference[referenceTime]
    }
}

private final class RecordingAnalytics: AnalyticsService {
    var events: [(String, [String: Any])] = []
    func track(_ event: String, properties: [String: Any]) {
        events.append((event, properties))
    }
}

// MARK: - Slice 4: superseded turns

/// A second turn (double wake / barge-in) supersedes the first: the older turn
/// must stop consuming its stream and must not touch playback state, analytics,
/// or late actions after the new turn takes over.
final class CloudRouteSupersedeTests: XCTestCase {
    private var playback: RecordingPlaybackSink!
    private var mapper: RecordingFingerprintMapper!
    private var analytics: RecordingAnalytics!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        mapper = RecordingFingerprintMapper()
        analytics = RecordingAnalytics()
        suiteName = "cloud_route_supersede_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSupersededTurnDoesNotRestoreOrRecordAnalytics() async {
        // Turn A: a slow stream that will still be open when B starts.
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .slowChunks(
                body: Data("event: token\ndata: {\"text\":\"slow\"}\n\n".utf8),
                chunkDelayNanoseconds: 400_000_000
            )
        }
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext()) }

        // Let A start and pause playback.
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(playback.calls.contains(.pause), "the first turn paused playback")

        // Turn B supersedes A and completes cleanly.
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: done
            data: {"input_tokens":1,"output_tokens":1}

            """
        )
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext())
        _ = await slow.value

        // Exactly one resume: the superseding turn's. A must not restore after B.
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1, "only the winning turn restores playback")
        // Analytics records only the winning turn's outcome.
        XCTAssertEqual(analytics.events.count, 1)
    }

    func testSupersededTurnDoesNotExecuteLateActions() async {
        // Turn A: an action arrives only after a delay — B supersedes first.
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .slowChunks(
                body: Data("""
                event: action
                data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":100000}}

                event: done
                data: {"input_tokens":1,"output_tokens":0}

                """.utf8),
                chunkDelayNanoseconds: 500_000_000
            )
        }
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext()) }
        try? await Task.sleep(nanoseconds: 150_000_000)

        CloudRouteTestURLProtocol.stubSSE(
            """
            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        )
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext())
        _ = await slow.value

        let seeks = playback.calls.filter { if case .seekTo = $0 { return true }; return false }
        XCTAssertTrue(seeks.isEmpty, "a superseded turn must not execute actions that arrive after it lost the turn")
    }

    private func makeSink() -> CloudRouteSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let session = URLSession(configuration: config)
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                CloudRouteClient(baseURL: cloudConfig.baseUrl, userId: "user_test", session: session)
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            analytics: VoiceAnalytics(analytics: analytics)
        )
    }

    private func sampleContext() -> PlaybackContext {
        PlaybackContext(
            episodeId: "ep",
            podcastId: "pod",
            referencePositionMs: 1_000,
            clientPositionMs: 1_100,
            recentReferencePositions: [],
            previousReferencePositionMs: nil
        )
    }
}
