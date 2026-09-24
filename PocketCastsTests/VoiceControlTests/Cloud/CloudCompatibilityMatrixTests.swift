import XCTest
@testable import podcasts

/// Item 5 (iOS half), slice 5 — the compatibility matrix the plan names:
/// auth expiry mid-session, interrupted mixed streams, unaligned quotes, and a
/// missing-evidence "who is speaking now?" turn. These pin client behavior at
/// the boundaries where the edge contract changes what the client sees.
final class CloudCompatibilityMatrixTests: XCTestCase {
    private var playback: MatrixPlaybackSink!
    private var mapper: MatrixFingerprintMapper!
    private var analytics: MatrixAnalytics!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        playback = MatrixPlaybackSink()
        mapper = MatrixFingerprintMapper()
        analytics = MatrixAnalytics()
        suiteName = "cloud_matrix_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - auth expiry mid-session

    func testAuthExpiryMidSessionSurfacesUnauthorizedAndRestores() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: token
            data: {"text":"partial"}

            event: error
            data: {"code":"unauthorized","message":"token expired"}

            """
        )

        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())

        XCTAssertEqual(response, .spoken("token expired"))
        XCTAssertTrue(playback.calls.contains(.resume), "the turn restores playback after a mid-session failure")
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "error")
    }

    func testAuthExpiryBeforeStreamIsAnErrorNotASilentTurn() async {
        CloudRouteTestURLProtocol.stubJSON(status: 401, body: #"{"code":"unauthorized","message":"expired"}"#)

        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())

        XCTAssertEqual(response, .spoken("expired"))
        XCTAssertTrue(playback.calls.contains(.resume))
    }

    // MARK: - interrupted mixed streams

    /// An interrupted mixed stream: the action and token arrive, then the stream
    /// ends without `done`. The client honors what arrived, restores playback,
    /// and reports the loss — it never leaves the turn half-applied.
    ///
    /// (Delivered via chunked writes rather than the URLProtocol failure path:
    /// `didFailWithError` discards bytes already loaded, so a prefix is not
    /// observable there — a harness limitation, documented rather than papered
    /// over.)
    func testInterruptedMixedStreamKeepsEarlierEventsAndReportsConnectionLoss() async {
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .slowChunks(
                body: Data("""
                event: token
                data: {"text":"She"}

                event: action
                data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":100000}}

                """.utf8),
                chunkDelayNanoseconds: 5_000_000
            )
        }
        mapper.playbackSecondsForReference = [100.0: 110.0]

        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext())

        XCTAssertTrue(playback.calls.contains(.seekTo(110)), "actions that did arrive are honored")
        XCTAssertTrue(playback.calls.contains(.resume), "an interrupted stream still restores playback")
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "error")
        // The code carries no message; the sink speaks it only in the user's own
        // locale and otherwise emits the error earcon (spec ruling 2026-09-24).
        // Asserting those two exact values (never `.silent`) keeps this pin able to
        // fail if the turn ever regressed to silence (PR #19 review).
        XCTAssertTrue(
            response == .spoken("Connection lost. Please try again.") || response == .earcon(.error),
            "expected a locale-appropriate failure signal, got \(response)"
        )
    }

    // MARK: - unaligned quotes

    func testUnalignedQuoteSeeksBestEffortAndStopRestoresPreActionPosition() async {
        CloudRouteTestURLProtocol.stubSSE(
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":500000}}

            event: token
            data: {"text":"quote"}

            event: action
            data: {"tool":"playback","action":"stop_quote","params":{}}

            event: done
            data: {"input_tokens":1,"output_tokens":0}

            """
        )
        // No mapping for reference 500s: the client seeks as-is (best effort).
        playback.positionMs = 900_000

        _ = await makeSink().routeToCloud(request: "play that", tier: .free, context: sampleContext())

        XCTAssertTrue(playback.calls.contains(.seekTo(500)), "unmapped reference seeks as-is")
        XCTAssertTrue(playback.calls.contains(.seekTo(900)), "stop_quote restores the pre-action playback position")
    }

    // MARK: - missing evidence ("who is speaking now?")

    func testMissingEvidenceTurnMakesNoSeekClaimAndRendersAsDiscoveryOnly() {
        // The server answers a missing-evidence turn with episode-level,
        // non-seekable evidence (cloud-search.md). The client must not convert
        // that into a timed claim.
        let item = DiscoveryEvidenceItem(
            evidenceId: "ev-1",
            source: "particle",
            podcastId: "pod",
            episodeId: nil,
            providerPodcastId: "provider-pod",
            providerEpisodeId: nil,
            title: "Episode overview",
            text: "Episode-level context only.",
            speaker: nil,
            sourceUrl: nil,
            playable: false,
            seekable: false
        )
        let model = DiscoveryResultsViewModel(result: DiscoveryResult(
            kind: "episode_results",
            scope: .currentEpisode,
            items: [item],
            nextCursor: nil
        ))

        XCTAssertEqual(model.rows.first?.isDiscoveryOnly, true)
        XCTAssertEqual(model.rows.first?.canSeek, false, "no alignment means no timed jump")

        let action = DiscoverySelectionHandler().action(for: model.rows[0])
        guard case .resolveThroughCatalog = action else {
            return XCTFail("discovery-only evidence resolves through the catalog, got \(action)")
        }
    }

    // MARK: - helpers

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


// MARK: - local test doubles (the shared ones are file-private)

private final class MatrixPlaybackSink: VoicePlaybackSink {
    enum Call: Equatable { case pause, resume, seekRelative(Int), seekTo(Int), nextEpisode }

    var calls: [Call] = []
    var positionMs: Int64 = 0

    func pause() -> VoiceResponse { calls.append(.pause); return .earcon(.success) }
    func resume() -> VoiceResponse { calls.append(.resume); return .silent }
    func seekRelative(deltaSeconds: Int) -> VoiceResponse { calls.append(.seekRelative(deltaSeconds)); return .silent }
    func seekTo(positionSeconds: Int) -> VoiceResponse { calls.append(.seekTo(positionSeconds)); return .silent }
    func nextEpisode() -> VoiceResponse { calls.append(.nextEpisode); return .silent }
}

private struct MatrixFingerprintMapper: FingerprintMappingProviding {
    var playbackSecondsForReference: [TimeInterval: TimeInterval] = [:]

    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? {
        playbackSecondsForReference[referenceTime]
    }

    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { nil }
}

private final class MatrixAnalytics: AnalyticsService {
    var events: [(String, [String: Any])] = []

    func track(_ event: String, properties: [String: Any]) {
        events.append((event, properties))
    }
}
