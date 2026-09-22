import XCTest
@testable import podcasts

/// Item 5 (iOS half), slice 2 — the negotiated `search_results_v1` renderer.
///
/// Contract (`docs/specs/cloud-assistant.md` → "Structured discovery result",
/// `cloud-search.md` → "Normalized evidence"):
/// - only clients advertising `search_results_v1` receive `event: result`;
/// - the client renders results without auto-playing them;
/// - an item without an Auris `episode_id` is discovery-only and resolves
///   through the catalog flow;
/// - `seekable == false` disables timed jumps;
/// - provider IDs are never player keys;
/// - empty `items` is a successful no-match result (distinct from unavailable).
final class CloudDiscoveryResultsTests: XCTestCase {
    private func item(
        id: String = "ev_1",
        episodeId: String? = "ep-uuid",
        seekable: Bool = true,
        playable: Bool = true
    ) -> DiscoveryEvidenceItem {
        DiscoveryEvidenceItem(
            evidenceId: id,
            source: "particle",
            podcastId: "pod-uuid",
            episodeId: episodeId,
            providerPodcastId: "provider-pod",
            providerEpisodeId: "provider-ep",
            title: "Episode title",
            text: "Some bounded passage text.",
            speaker: "Speaker A",
            sourceUrl: nil,
            playable: playable,
            seekable: seekable
        )
    }

    // MARK: - parsing

    func testResultEventParsesItemsAndScope() throws {
        let json = """
        {"kind":"episode_results","scope":"global","items":[
          {"evidence_id":"ev_1","source":"particle","podcast_id":"pod","episode_id":"ep","provider_podcast_id":"pp","provider_episode_id":"pe","title":"T","text":"X","speaker":null,"source_url":null,"playable":true,"seekable":true}
        ],"next_cursor":"cursor-1"}
        """
        let result = try XCTUnwrap(DiscoveryResult.parse(json: json))
        XCTAssertEqual(result.kind, "episode_results")
        XCTAssertEqual(result.scope, .global)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].episodeId, "ep")
        XCTAssertEqual(result.nextCursor, "cursor-1")
    }

    func testUnknownKindIsIgnored() {
        let json = #"{"kind":"something_else_v9","items":[]}"#
        XCTAssertNil(DiscoveryResult.parse(json: json), "unknown kinds must not break the stream")
    }

    func testMalformedResultPayloadIsIgnoredByTheModelParser() {
        XCTAssertNil(DiscoveryResult.parse(json: "not json"))
        XCTAssertNil(DiscoveryResult.parse(json: #"{"kind":"episode_results"}"#), "items are required")
    }

    /// Parity with Android's reviewed payload-failure behavior: a malformed
    /// payload on the *known* `result` event surfaces as `invalid_response`;
    /// an unknown `kind` stays forward-compatible and is ignored.
    func testParserSurfacesMalformedResultPayloadAsInvalidResponse() {
        var parser = CloudRouteSSEParser()
        _ = parser.consume(line: "event: result")
        _ = parser.consume(line: #"data: {"kind":"episode_results"}"#)
        let events = parser.consume(line: "")
        XCTAssertEqual(events.count, 1)
        guard case let .error(code, _) = events.first else {
            return XCTFail("expected invalid_response error, got \(events)")
        }
        XCTAssertEqual(code, "invalid_response")
    }

    func testParserIgnoresUnknownResultKind() {
        var parser = CloudRouteSSEParser()
        _ = parser.consume(line: "event: result")
        _ = parser.consume(line: #"data: {"kind":"something_else_v9","items":[]}"#)
        XCTAssertTrue(parser.consume(line: "").isEmpty, "unknown kinds must not break the stream")
    }

    func testParserEmitsResultEvent() {
        var parser = CloudRouteSSEParser()
        XCTAssertTrue(parser.consume(line: "event: result").isEmpty)
        XCTAssertTrue(parser.consume(line: #"data: {"kind":"episode_results","scope":"library","items":[],"next_cursor":null}"#).isEmpty)
        let events = parser.consume(line: "") // blank line dispatches the frame
        XCTAssertEqual(events.count, 1)
        guard case let .result(result) = events.first else {
            return XCTFail("expected a result event, got \(events)")
        }
        XCTAssertEqual(result.scope, .library)
        XCTAssertTrue(result.items.isEmpty)
    }

    // MARK: - states

    func testEmptyItemsRenderAsNoMatchNotUnavailable() {
        let model = DiscoveryResultsViewModel(result: DiscoveryResult(kind: "episode_results", scope: .library, items: [], nextCursor: nil))
        XCTAssertEqual(model.state, .noMatch)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testUnavailableStateIsDistinct() {
        let model = DiscoveryResultsViewModel.unavailable(scope: .global)
        XCTAssertEqual(model.state, .unavailable)
    }

    func testRowsCarryEligibilityFlags() {
        let model = DiscoveryResultsViewModel(result: DiscoveryResult(
            kind: "episode_results",
            scope: .currentEpisode,
            items: [
                item(id: "a", episodeId: "ep", seekable: true),
                item(id: "b", episodeId: nil, seekable: true),
                item(id: "c", episodeId: "ep", seekable: false),
            ],
            nextCursor: nil
        ))
        XCTAssertEqual(model.state, .items)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.rows[0].isDiscoveryOnly, false)
        XCTAssertEqual(model.rows[0].canSeek, true)
        XCTAssertEqual(model.rows[1].isDiscoveryOnly, true, "no Auris episode id means discovery-only")
        XCTAssertEqual(model.rows[1].canSeek, false, "discovery-only items cannot be seeked")
        XCTAssertEqual(model.rows[2].canSeek, false, "seekable=false disables timed jumps")
    }

    func testScopeIsLabeledForGlobalResults() {
        let model = DiscoveryResultsViewModel(result: DiscoveryResult(
            kind: "episode_results", scope: .global, items: [item()], nextCursor: nil
        ))
        XCTAssertEqual(model.scopeLabel, "Global")
    }

    // MARK: - selection

    func testSelectingPlayableItemProducesPlaybackIntentWithAurisIdsOnly() {
        let handler = DiscoverySelectionHandler()
        let model = DiscoveryResultsViewModel(result: DiscoveryResult(
            kind: "episode_results", scope: .library, items: [item(episodeId: "ep-uuid")], nextCursor: nil
        ))
        let action = handler.action(for: model.rows[0])
        guard case let .play(episodeId, seekable) = action else {
            return XCTFail("expected .play, got \(action)")
        }
        XCTAssertEqual(episodeId, "ep-uuid", "player commands use Auris ids only")
        XCTAssertTrue(seekable)
    }

    func testSelectingDiscoveryOnlyItemRequiresCatalogResolution() {
        let handler = DiscoverySelectionHandler()
        let model = DiscoveryResultsViewModel(result: DiscoveryResult(
            kind: "episode_results",
            scope: .global,
            items: [item(episodeId: nil)],
            nextCursor: nil
        ))
        let action = handler.action(for: model.rows[0])
        guard case let .resolveThroughCatalog(providerPodcastId, providerEpisodeId) = action else {
            return XCTFail("expected catalog resolution, got \(action)")
        }
        XCTAssertEqual(providerPodcastId, "provider-pod")
        XCTAssertEqual(providerEpisodeId, "provider-ep")
    }

    func testUnalignedItemIsNeverSeekedEvenWhenPlayable() {
        let handler = DiscoverySelectionHandler()
        let model = DiscoveryResultsViewModel(result: DiscoveryResult(
            kind: "episode_results", scope: .library, items: [item(episodeId: "ep-uuid", seekable: false)], nextCursor: nil
        ))
        let action = handler.action(for: model.rows[0])
        guard case let .play(_, seekable) = action else {
            return XCTFail("expected .play, got \(action)")
        }
        XCTAssertFalse(seekable, "an unaligned identified episode can be described but not timed")
    }

    // MARK: - presentation

    func testPresenterReceivesRenderedResultsAndNeverAutoPlays() async {
        let presenter = RecordingDiscoveryPresenter()
        let sink = CloudRouteSink(
            clientFactory: { fatalError("not used") },
            isConfigured: { true },
            playbackSink: RecordingPlaybackSinkForResults(),
            fingerprintMapper: RecordingMapperForResults(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            analytics: nil,
            rendersStructuredResults: true,
            resultsPresenter: presenter
        )
        let model = DiscoveryResultsViewModel(result: DiscoveryResult(
            kind: "episode_results", scope: .library, items: [item()], nextCursor: nil
        ))
        sink.presentDiscoveryResults(model)
        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertFalse(presenter.didAutoPlay, "rendering results must not initiate playback")
    }
}

// MARK: - test doubles

private final class RecordingDiscoveryPresenter: DiscoveryResultsPresenting {
    private(set) var presented: [DiscoveryResultsViewModel] = []
    var didAutoPlay = false

    func present(_ model: DiscoveryResultsViewModel) {
        presented.append(model)
    }
}

private final class RecordingPlaybackSinkForResults: VoicePlaybackSink {
    func pause() -> VoiceResponse { .silent }
    func resume() -> VoiceResponse { .silent }
    func seekRelative(deltaSeconds: Int) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int) -> VoiceResponse { .silent }
    func nextEpisode() -> VoiceResponse { .silent }
}

private struct RecordingMapperForResults: FingerprintMappingProviding {
    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? { referenceTime }
    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { playbackTime }
}
