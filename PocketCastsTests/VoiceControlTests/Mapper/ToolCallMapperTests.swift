import XCTest
@testable import podcasts

final class ToolCallMapperTests: XCTestCase {

    func test_map_playbackPause_returnsPauseIntent() {
        let call = ToolCall(name: "playback", arguments: ["action": "pause"])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        XCTAssertEqual(playbackIntent, .pause)
    }

    func test_map_playbackResume_returnsResumeIntent() {
        let call = ToolCall(name: "playback", arguments: ["action": "resume"])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        XCTAssertEqual(playbackIntent, .resume)
    }

    func test_map_playbackSeekRelative_withPositiveDelta() {
        let call = ToolCall(name: "playback", arguments: ["action": "seek_relative", "delta_seconds": 30])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        XCTAssertEqual(playbackIntent, .seekRelative(deltaSeconds: 30, direction: .forward))
    }

    func test_map_playbackSeekRelative_withNegativeDelta() {
        let call = ToolCall(name: "playback", arguments: ["action": "seek_relative", "delta_seconds": -15])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        XCTAssertEqual(playbackIntent, .seekRelative(deltaSeconds: -15, direction: .backward))
    }

    func test_map_playbackSeekRelative_directionOnly() {
        let call = ToolCall(name: "playback", arguments: ["action": "seek_relative", "direction": "backward"])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        // No delta manufactured — the sink owns the interval.
        XCTAssertEqual(playbackIntent, .seekRelative(deltaSeconds: nil, direction: .backward))
    }

    func test_map_playbackSeekRelative_neitherDeltaNorDirection() {
        let call = ToolCall(name: "playback", arguments: ["action": "seek_relative"])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        // Neither stated → (nil, FORWARD) so the sink applies its default.
        XCTAssertEqual(playbackIntent, .seekRelative(deltaSeconds: nil, direction: .forward))
    }

    func test_map_playbackSeekRelative_zeroDeltaNormalizedToNil() {
        // Zero delta is treated as "no stated amount" — normalizes to nil
        // so the sink applies its interval in the request's direction.
        let call = ToolCall(name: "playback", arguments: ["action": "seek_relative", "delta_seconds": 0])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        XCTAssertEqual(playbackIntent, .seekRelative(deltaSeconds: nil, direction: .forward),
                       "zero delta normalizes to nil")
    }

    func test_map_playbackSeekRelative_zeroDeltaWithDirectionPreservesDirection() {
        let call = ToolCall(name: "playback", arguments: ["action": "seek_relative", "delta_seconds": 0, "direction": "backward"])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        XCTAssertEqual(playbackIntent, .seekRelative(deltaSeconds: nil, direction: .backward),
                       "zero delta normalizes to nil, direction preserved")
    }

    func test_map_playbackSeekTo_returnsSeekToIntent() {
        let call = ToolCall(name: "playback", arguments: ["action": "seek_to", "position_seconds": 120])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        XCTAssertEqual(playbackIntent, .seekTo(positionSeconds: 120))
    }

    func test_map_noMatch_returnsNil() {
        let call = ToolCall(name: "no_match", arguments: [:])
        let intent = ToolCallMapper().map(call)
        XCTAssertNil(intent)
    }

    func test_map_sleepSet_returnsSetIntent() {
        let call = ToolCall(name: "sleep", arguments: ["action": "set", "minutes": 30])
        let intent = ToolCallMapper().map(call)
        guard let sleepIntent = intent as? SleepIntent else { XCTFail(); return }
        XCTAssertEqual(sleepIntent, .set(minutes: 30))
    }

    func test_map_sleepCancel_returnsCancelIntent() {
        let call = ToolCall(name: "sleep", arguments: ["action": "cancel"])
        let intent = ToolCallMapper().map(call)
        guard let sleepIntent = intent as? SleepIntent else { XCTFail(); return }
        XCTAssertEqual(sleepIntent, .cancel)
    }

    func test_map_unknownTool_returnsNil() {
        let call = ToolCall(name: "unknown", arguments: [:])
        let intent = ToolCallMapper().map(call)
        XCTAssertNil(intent)
    }

    func test_map_effectsSetSpeed_returnsSetSpeedIntent() {
        let call = ToolCall(name: "effects", arguments: ["action": "set_speed", "speed": 1.5])
        let intent = ToolCallMapper().map(call)
        guard let effectsIntent = intent as? EffectsIntent else { XCTFail(); return }
        XCTAssertEqual(effectsIntent, .setSpeed(1.5))
    }

    func test_map_effectsSetTrimMode_returnsSetTrimModeIntent() {
        let call = ToolCall(name: "effects", arguments: ["action": "set_trim_mode", "mode": "medium"])
        let intent = ToolCallMapper().map(call)
        guard let effectsIntent = intent as? EffectsIntent else { XCTFail(); return }
        XCTAssertEqual(effectsIntent, .setTrimMode(.medium))
    }

    func test_map_chapterByIndex_returnsByIndexIntent() {
        let call = ToolCall(name: "chapter", arguments: ["action": "by_index", "index": 3])
        let intent = ToolCallMapper().map(call)
        guard let chapterIntent = intent as? ChapterIntent else { XCTFail(); return }
        XCTAssertEqual(chapterIntent, .byIndex(3))
    }

    func test_map_chapterByTitle_readsQueryKey() {
        let call = ToolCall(name: "chapter", arguments: ["action": "by_title", "query": "interview"])
        let intent = ToolCallMapper().map(call)
        guard let chapterIntent = intent as? ChapterIntent else { XCTFail(); return }
        XCTAssertEqual(chapterIntent, .byTitle("interview"))
    }

    func test_map_bookmarkAdd_returnsAddIntent() {
        let call = ToolCall(name: "bookmark", arguments: ["action": "add", "title": "Great quote"])
        let intent = ToolCallMapper().map(call)
        guard let bookmarkIntent = intent as? BookmarkIntent else { XCTFail(); return }
        XCTAssertEqual(bookmarkIntent, .add(title: "Great quote"))
    }

    func test_map_queueAddTop_returnsAddTopIntent() {
        let call = ToolCall(name: "queue", arguments: ["action": "add_top", "episode": "ep123"])
        let intent = ToolCallMapper().map(call)
        guard let queueIntent = intent as? QueueIntent else { XCTFail(); return }
        XCTAssertEqual(queueIntent, .addTop(episode: "ep123"))
    }

    func test_map_playbackQueryWhatsPlaying_returnsWhatsPlayingIntent() {
        let call = ToolCall(name: "playback_query", arguments: ["action": "whats_playing"])
        let intent = ToolCallMapper().map(call)
        guard let queryIntent = intent as? PlaybackQueryIntent else { XCTFail(); return }
        XCTAssertEqual(queryIntent, .whatsPlaying)
    }

    func test_map_statsQueryListeningTime_returnsListeningTimeIntent() {
        let call = ToolCall(name: "stats_query", arguments: ["action": "listening_time", "period": "week"])
        let intent = ToolCallMapper().map(call)
        guard let statsIntent = intent as? StatsQueryIntent else { XCTFail(); return }
        XCTAssertEqual(statsIntent, .listeningTime(period: "week"))
    }

    func test_map_cloudRoute_returnsRequestOnlyIntent() {
        let call = ToolCall(name: "cloud_route", arguments: ["request": "find that quote", "tier": "premium"])
        let intent = ToolCallMapper().map(call)
        guard let cloudIntent = intent as? CloudRouteIntent else { XCTFail(); return }
        XCTAssertEqual(cloudIntent.request, "find that quote")
        XCTAssertEqual(cloudIntent.tier, .premium)
    }

    func test_parser_validToolCall_returnsToolCall() {
        let output = "<|tool_call_start|>[playback(action='pause')]<|tool_call_end|>"
        let toolCall = LfmToolCallParser.parse(output)
        XCTAssertNotNil(toolCall)
        XCTAssertEqual(toolCall?.name, "playback")
        XCTAssertEqual(toolCall?.arguments["action"] as? String, "pause")
    }

    func test_parser_noToolCall_returnsNil() {
        let output = "just some random text"
        let toolCall = LfmToolCallParser.parse(output)
        XCTAssertNil(toolCall)
    }

    func test_parser_integerArgument_parsedAsInt() {
        let output = "<|tool_call_start|>[sleep(action='set', minutes=30)]<|tool_call_end|>"
        let toolCall = LfmToolCallParser.parse(output)
        XCTAssertEqual(toolCall?.arguments["minutes"] as? Int, 30)
    }

    func test_parser_floatArgument_parsedAsDouble() {
        let output = "<|tool_call_start|>[effects(action='set_speed', speed=1.5)]<|tool_call_end|>"
        let toolCall = LfmToolCallParser.parse(output)
        XCTAssertEqual(toolCall?.arguments["speed"] as? Double, 1.5)
    }

    // MARK: - The runtime's reduced label set

    /// An action the mapper does not know is rejected, including one inside a family it does
    /// know.
    ///
    /// The landed contract reduces the local vocabulary to `lfm + cloud`-marked actions, so
    /// the runtime must not execute a cloud-owned action locally. Knowing the local tools is
    /// not by itself proof of that: a cloud-marked action name could sit inside a family the
    /// mapper handles, and a family switch that fell through to a default *value* rather than
    /// nil would execute it.
    ///
    /// So the claim is checked per family rather than once: for each family, an action it does
    /// not define must map to nil, which the caller treats as `no_match` and escalates.
    func test_map_unknownActionInsideAKnownFamily_isRejected() {
        let mapper = ToolCallMapper()
        let families = [
            "playback", "effects", "volume", "sleep",
            "chapter", "bookmark", "queue", "playback_query", "stats_query"
        ]

        for family in families {
            // A plausible cloud-owned operation name inside a family the mapper knows.
            let call = ToolCall(name: family, arguments: ["action": "cloud_owned_operation"])
            XCTAssertNil(
                mapper.map(call),
                """
                the mapper produced an intent for \(family).cloud_owned_operation, which is \
                not in the local vocabulary: a cloud-marked action would have been executed \
                locally instead of being escalated.
                """
            )
        }
    }

    /// And an unknown family is rejected, so a wholly cloud-owned tool cannot execute.
    func test_map_unknownTool_isRejected() {
        let call = ToolCall(name: "app_operation", arguments: ["action": "anything"])
        XCTAssertNil(
            ToolCallMapper().map(call),
            "an unlisted tool produced a local intent instead of escalating"
        )
    }
}
