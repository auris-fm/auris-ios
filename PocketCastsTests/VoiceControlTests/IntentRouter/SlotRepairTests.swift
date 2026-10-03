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

    func test_repair_seekRelativeWithoutDelta_fillsDirectionNotDelta() {
        // Per the recovery contract (PR 59, cloud-seek-relative):
        // The mapper no longer manufactures a delta for direction-only calls.
        // The sink owns the app's configurable seek interval and applies it
        // in the request's direction.
        let neither = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative')]<|tool_call_end|>",
            utterance: "skip",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertNil(neither?.arguments["delta_seconds"],
                     "repair must not manufacture a delta when the model omitted it")
        XCTAssertEqual(neither?.arguments["direction"] as? String, "forward",
                       "when neither delta nor direction stated, fill forward default")
    }

    func test_repair_seekRelative_preservesExistingDirection() {
        // If the model already produced a direction, repair must not overwrite it.
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', direction='backward')]<|tool_call_end|>",
            utterance: "skip ahead",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertEqual(repaired?.arguments["direction"] as? String, "backward",
                       "existing direction must not be overwritten by utterance wording")
    }

    func test_repair_seekRelative_zeroDroppedWhenNoSpokenAmount() {
        // Per the ruling at 1bf6e04: a produced `0` is not a stated amount.
        // When the utterance states no amount, zero must be dropped so the
        // sink receives null and applies its interval in the stated direction.
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=0, direction='backward')]<|tool_call_end|>",
            utterance: "go back",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertNil(repaired?.arguments["delta_seconds"],
                     "produced zero with no spoken amount must be dropped as unstated")
        XCTAssertEqual(repaired?.arguments["direction"] as? String, "backward",
                       "direction must survive when zero is dropped")
    }

    func test_repair_seekRelative_zeroReplacedBySpokenAmount() {
        // When the model produces `0` but the utterance states a signed amount,
        // the repair preserves the spoken signed amount.
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=0)]<|tool_call_end|>",
            utterance: "rewind fifteen seconds",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertEqual(repaired?.arguments["delta_seconds"] as? Int, -15,
                       "spoken amount replaces produced zero")
    }

    func test_repair_seekRelative_nonZeroSignPreserved() {
        // A nonzero produced sign must never be overwritten.
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=-30)]<|tool_call_end|>",
            utterance: "go back",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertEqual(repaired?.arguments["delta_seconds"] as? Int, -30,
                       "nonzero produced sign must be preserved")
    }

    func test_repair_seekRelative_zeroDroppedExtractsDirectionFromUtterance() {
        // Per the fixture revision at 1c527f6: bare-zero with no model
        // direction must extract direction from utterance text.
        // "go back" ⇒ BACKWARD.
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=0)]<|tool_call_end|>",
            utterance: "go back",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertNil(repaired?.arguments["delta_seconds"],
                     "produced zero with no spoken amount must be dropped")
        XCTAssertEqual(repaired?.arguments["direction"] as? String, "backward",
                       "direction extracted from utterance when model produced zero")
    }

    func test_repair_seekRelative_zeroDroppedExtractsForwardFromUtterance() {
        // "skip ahead" ⇒ FORWARD.
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=0)]<|tool_call_end|>",
            utterance: "skip ahead",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertNil(repaired?.arguments["delta_seconds"],
                     "produced zero with no spoken amount must be dropped")
        XCTAssertEqual(repaired?.arguments["direction"] as? String, "forward",
                       "direction extracted from utterance when model produced zero")
    }

    func test_repair_seekRelative_noDirectionExtractedFillsForwardDefault() {
        // When utterance states neither delta nor direction, fill forward.
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=0)]<|tool_call_end|>",
            utterance: "skip",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertNil(repaired?.arguments["delta_seconds"],
                     "produced zero with no spoken amount must be dropped")
        XCTAssertEqual(repaired?.arguments["direction"] as? String, "forward",
                       "forward default when no direction extracted from utterance")
    }

    func test_repair_seekRelative_outOfRangeAmountReturnsNull() {
        // Per the fixture: an unsupported spoken amount (exceeding ±1 hour)
        // must repair to null (no repaired call), not a clamped or defaulted
        // one. "jump back ninety minutes" = -5400s is outside the constraint.
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=0)]<|tool_call_end|>",
            utterance: "jump back ninety minutes",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertNil(repaired,
                     "unsupported spoken amount must produce no repaired call")
    }

    func test_repair_seekRelative_directionNotStrippedBySanitization() {
        // Direction must survive sanitization — it is now an allowed param.
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=0, direction='backward')]<|tool_call_end|>",
            utterance: "go back",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertNotNil(repaired, "repair must not return nil")
        XCTAssertEqual(repaired?.arguments["direction"] as? String, "backward",
                       "direction must not be stripped by sanitization")
    }

    func test_repair_seekRelative_numericPreservesProducedSign() {
        // Numeric repair corrects magnitude but preserves the model's sign.
        // Model produced 1 (positive), utterance says "rewind fifteen seconds" → 15 (not -15).
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=1)]<|tool_call_end|>",
            utterance: "rewind fifteen seconds",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertEqual(repaired?.arguments["delta_seconds"] as? Int, 15,
                       "magnitude corrected from utterance, sign preserved from model")
    }

    func test_repair_seekRelative_producedOutOfRangeReturnsNull() {
        // A hallucinated two-hour delta with no spoken support must be rejected.
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=7200)]<|tool_call_end|>",
            utterance: "go back",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertNil(repaired,
                     "produced out-of-range delta must be rejected even with no spoken amount")
    }

    func test_repair_seekRelative_producedNegativeOutOfRangeReturnsNull() {
        let repaired = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', delta_seconds=-7200)]<|tool_call_end|>",
            utterance: "skip ahead",
            tool: "playback",
            action: "seek_relative"
        )
        XCTAssertNil(repaired,
                     "produced negative out-of-range delta must be rejected")
    }
}
