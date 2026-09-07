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
        XCTAssertEqual(playback.calls.filter { $0 == .seekTo(1200) }.count, 1)
        XCTAssertEqual(analytics.events.last?.0, "cloud_assistant_turn")
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "done")
        let snap = contextState.snapshot()
        XCTAssertEqual(snap.recentReferencePositions.last, 1_130_000)
        XCTAssertEqual(snap.previousReferencePositionMs, 500_000)
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

    // MARK: - Helpers

    private func makeSink() -> CloudRouteSink {
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
            analytics: voiceAnalytics
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
