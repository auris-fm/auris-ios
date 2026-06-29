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

    func test_map_playbackSeekRelative_returnsSeekRelativeIntent() {
        let call = ToolCall(name: "playback", arguments: ["action": "seek_relative", "delta_seconds": 30])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        XCTAssertEqual(playbackIntent, .seekRelative(deltaSeconds: 30))
    }

    func test_map_playbackSeekRelative_defaultDelta() {
        let call = ToolCall(name: "playback", arguments: ["action": "seek_relative"])
        let intent = ToolCallMapper().map(call)
        guard let playbackIntent = intent as? PlaybackIntent else { XCTFail(); return }
        XCTAssertEqual(playbackIntent, .seekRelative(deltaSeconds: 30))
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
        let call = ToolCall(name: "effects", arguments: ["action": "set_trim_mode", "trim_mode": "medium"])
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

    func test_parser_validFunctionCall_returnsToolCall() {
        let output = "<start_function_call>call:playback{action:pause}<end_function_call>"
        let toolCall = FunctionGemmaParser.parse(output)
        XCTAssertNotNil(toolCall)
        XCTAssertEqual(toolCall?.name, "playback")
        XCTAssertEqual(toolCall?.arguments["action"] as? String, "pause")
    }

    func test_parser_noFunctionCall_returnsNil() {
        let output = "just some random text"
        let toolCall = FunctionGemmaParser.parse(output)
        XCTAssertNil(toolCall)
    }

    func test_parser_integerArgument_parsedAsInt() {
        let output = "<start_function_call>call:sleep{action:set,minutes:30}<end_function_call>"
        let toolCall = FunctionGemmaParser.parse(output)
        XCTAssertEqual(toolCall?.arguments["minutes"] as? Int, 30)
    }

    func test_parser_floatArgument_parsedAsDouble() {
        let output = "<start_function_call>call:effects{action:set_speed,speed:1.5}<end_function_call>"
        let toolCall = FunctionGemmaParser.parse(output)
        XCTAssertEqual(toolCall?.arguments["speed"] as? Double, 1.5)
    }
}
