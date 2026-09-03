import XCTest
@testable import podcasts

final class SlotRepairTests: XCTestCase {
    func test_collapseRepetition_collapsesRepeatedSuffix() {
        XCTAssertEqual(
            SlotRepair.collapseRepetition("the turning point the turning point"),
            "the turning point"
        )
    }

    func test_repair_seekRelativeFromMinuteUtterance_overridesWrongModelSlots() {
        let fromMinutes = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', minutes=1)]<|tool_call_end|>",
            utterance: "Could you just go back a minute, please?",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertEqual(fromMinutes?.name, "playback")
        XCTAssertEqual(fromMinutes?.arguments["delta_seconds"] as? Int, -60)

        let fromWrongDelta = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=-1)]<|tool_call_end|>",
            utterance: "go back a minute",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertEqual(fromWrongDelta?.arguments["delta_seconds"] as? Int, -60)
    }

    func test_repair_garbledTitle_restoredFromQuotedSpan() {
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[dialog_control(action='provide_slot', target_tool='bookmark', target_action='rename', slot='title', value='Key Insuel')]<|tool_call_end|>",
            utterance: "Call it 'Key Insight'.",
            tool: "dialog_control",
            action: "provide_slot"
        )
        XCTAssertEqual(repaired?.arguments["value"] as? String, "Key Insight")
    }

    func test_repair_noMatch_returnsEmptyParams() {
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[no_match(action='')]<|tool_call_end|>",
            utterance: "hello there",
            tool: "no_match",
            action: ""
        )
        XCTAssertEqual(repaired?.name, "no_match")
        XCTAssertTrue(repaired?.arguments.isEmpty == true)
    }

    func test_repair_neverChangesClassifierToolAndAction() {
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[volume(action='set_volume', volume=50)]<|tool_call_end|>",
            utterance: "go back a minute",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertEqual(repaired?.name, "playback")
        XCTAssertEqual(repaired?.arguments["action"] as? String, "seek_relative")
    }

    func test_repair_volumeKeepsVolumeSlot() {
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[volume(action='set_volume', volume=50)]<|tool_call_end|>",
            utterance: "set volume to 50",
            tool: "volume",
            action: "set_volume"
        )
        XCTAssertEqual(repaired?.name, "volume")
        XCTAssertEqual(repaired?.arguments["volume"] as? Int, 50)
        XCTAssertEqual(repaired?.arguments["action"] as? String, "set_volume")
    }

    func test_repair_seekRelativeWithoutDelta_fillsSignedDefaultFromWording() {
        let forward = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative')]<|tool_call_end|>",
            utterance: "skip ahead",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertEqual(forward?.arguments["delta_seconds"] as? Int, 30)

        let backward = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative')]<|tool_call_end|>",
            utterance: "skip back",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertEqual(backward?.arguments["delta_seconds"] as? Int, -30)

        // `\bback\b` does not match inside "backwards" — must still fill -30.
        let backwards = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative')]<|tool_call_end|>",
            utterance: "skip backwards",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertEqual(backwards?.arguments["delta_seconds"] as? Int, -30)
    }
}
