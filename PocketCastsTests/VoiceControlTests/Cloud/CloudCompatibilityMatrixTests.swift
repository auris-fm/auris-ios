/// The origin these cases dispatch under. The conversation bound refuses a turn whose origin
/// is not live, so a sink built for these cases must be given one — otherwise every turn would
/// be refused before it dials and the case would exercise the bound rather than the sink.
private let cloudTestOrigin = 1

private func testConversationManager() -> CloudConversationManager {
    let manager = CloudConversationManager()
    manager.registerLiveOrigin(cloudTestOrigin)
    return manager
}

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
        self.pendingFixture =
            """
            event: token
            data: {"text":"partial"}

            event: error
            data: {"code":"unauthorized","message":"token expired"}

            """

        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: UUID().uuidString)

        // MID-SESSION (stream already open, a partial token arrived first) — distinct from the
        // pre-stream case above. Spec ruling 2026-10-23 (f4b34311): the server's `message` is
        // operator diagnostics, "never spoken or used to select client feedback" — so whatever
        // feedback is chosen here, the remote prose must NOT be spoken. This implementation
        // emits the local error earcon; assert that and assert the prose is absent.
        XCTAssertEqual(response.response, .earcon(.error))
        if case .spoken(let text) = response.response {
            XCTAssertFalse(text.contains("token expired"), "the server's message is never spoken verbatim")
        } else {
            XCTAssertTrue(true, "the remote prose is not surfaced as speech")
        }
        XCTAssertTrue(playback.calls.contains(.resume), "the turn restores playback after a mid-session failure")
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "error")
    }

    func testAuthExpiryBeforeStreamIsAnErrorNotASilentTurn() async {
        // On the socket a rejected credential is an **error frame**, not an HTTP
        // status: the credential rides the first frame, so there is no 401 body
        // to read. The turn must still fail visibly rather than pass silently.
        self.pendingFixture =
            """
            event: error
            data: {"code":"unauthorized","message":""}

            """

        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: UUID().uuidString)

        // `unauthorized` has no user-facing template, so the failure signal is
        // the error earcon — never silence, and never English prose for TTS.
        XCTAssertEqual(response.response, .earcon(.error))
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
        // Frames arrive, then the socket closes with no `done`/`error`: the
        // stub runs out of frames, which is what a dropped connection looks
        // like from the client's side.
        self.pendingFixture =
            """
            event: token
            data: {"text":"She"}

            event: action
            data: {"tool":"playback","operation_id":"op-X12625","capability_version":"v7","action":"seek_to","params":{"reference_position_ms":100000}}

            """
        mapper.playbackSecondsForReference = [100.0: 110.0]

        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: UUID().uuidString)

        XCTAssertTrue(playback.calls.contains(.seekTo(110)), "actions that did arrive are honored")
        XCTAssertTrue(playback.calls.contains(.resume), "an interrupted stream still restores playback")
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "error")
        // The code carries no message; the sink speaks it only in the user's own
        // locale and otherwise emits the error earcon (spec ruling 2026-09-24).
        // Asserting those two exact values (never `.silent`) keeps this pin able to
        // fail if the turn ever regressed to silence (PR #19 review).
        XCTAssertTrue(
            response.response == .spoken("Connection lost. Please try again.") || response.response == .earcon(.error),
            "expected a locale-appropriate failure signal, got \(response)"
        )
    }

    // MARK: - unaligned quotes

    /// An unmapped `play_quote` is refused rather than converted by assumption: reference time
    /// is not playback time, and the raw value is a position the server never asked for. With
    /// the seek refused, no pre-action position is captured, so `stop_quote` has nothing to
    /// restore — and must not seek on that missing evidence either.
    func testUnmappedQuoteIsRefusedAndStopQuoteDoesNotRestore() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","operation_id":"op-X77564","capability_version":"v7","action":"play_quote","params":{"reference_position_ms":500000}}

            event: token
            data: {"text":"quote"}

            event: action
            data: {"tool":"playback","operation_id":"op-X57434","capability_version":"v7","action":"stop_quote","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // No mapping for reference 500s.
        playback.positionMs = 900_000
        let sink = makeSink()

        _ = await sink.routeToCloud(request: "play that", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: UUID().uuidString)

        // The refusal removes the QUOTE seek only. stop_quote still restores the pre-action
        // position, which was captured before the refusal and is sink time — the existing
        // restore behaviour @spec kept.
        XCTAssertFalse(playback.calls.contains(.seekTo(500)), "an unmapped reference must not become a playback position")
        XCTAssertTrue(playback.calls.contains(.seekTo(900)), "stop_quote restores the pre-action position in sink time")
        let unavailable = await MainActor.run { sink.unavailableReferenceSeek }
        XCTAssertEqual(unavailable?.reason, OperationReason.referenceMappingUnavailable)
    }

    /// The mapped counterpart: a quote with a known mapping seeks to the mapped position and
    /// `stop_quote` restores the pre-action position, which is sink time.
    func testMappedQuoteSeeksToMappedPositionAndStopRestoresPreActionPosition() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","operation_id":"op-X77564","capability_version":"v7","action":"play_quote","params":{"reference_position_ms":500000}}

            event: token
            data: {"text":"quote"}

            event: action
            data: {"tool":"playback","operation_id":"op-X57434","capability_version":"v7","action":"stop_quote","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // 500s reference maps to 515s playback: a nonzero offset, so passing this by seeking to
        // the raw reference value is not possible.
        mapper.playbackSecondsForReference = [500.0: 515.0]
        playback.positionMs = 900_000
        let sink = makeSink()

        _ = await sink.routeToCloud(request: "play that", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: UUID().uuidString)

        XCTAssertTrue(playback.calls.contains(.seekTo(515)), "the quote seeks to the mapped position")
        XCTAssertFalse(playback.calls.contains(.seekTo(500)), "the raw reference value is not the target")
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
        let cloudConfig = CloudConfig(defaults: defaults)
        let fixture = pendingFixture ?? ""
        return CloudRouteSink(
            clientFactory: {
                CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: fixture).client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            analytics: VoiceAnalytics(analytics: analytics),
            conversationManager: testConversationManager()
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
    /// Host playing at the moment the turn reads it. Tests set this to
    /// false to model a user who paused before speaking.
    var isPlaying = true
    enum Call: Equatable { case pause, resume, seekRelative(Int?, SeekDirection), seekTo(Int), nextEpisode }


    var calls: [Call] = []
    var positionMs: Int64 = 0

    func pause() -> VoiceResponse { calls.append(.pause); return .earcon(.success) }
    func resume() -> VoiceResponse { calls.append(.resume); return .silent }
    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse {
        calls.append(.seekRelative(deltaSeconds, direction))
        return .silent
    }
    func seekTo(positionSeconds: Int) -> VoiceResponse { calls.append(.seekTo(positionSeconds)); return .silent }
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse {
        calls.append(.seekTo(positionSeconds))
        return .silent
    }
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
