import XCTest
@testable import podcasts

final class LfmToolCallParserTests: XCTestCase {
    func test_parse_sleepSet() {
        let call = LfmToolCallParser.parse(
            "<|tool_call_start|>[sleep(action='set', minutes=30)]<|tool_call_end|>"
        )
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.name, "sleep")
        XCTAssertEqual(call?.arguments["action"] as? String, "set")
        XCTAssertEqual(call?.arguments["minutes"] as? Int, 30)
    }

    func test_parse_usesLastToolCallSpan() {
        let call = LfmToolCallParser.parse(
            "noise <|tool_call_start|>[playback(action='pause')]<|tool_call_end|> " +
                "<|tool_call_start|>[volume(action='set_volume', volume=50)]<|tool_call_end|>"
        )
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.name, "volume")
        XCTAssertEqual(call?.arguments["action"] as? String, "set_volume")
        XCTAssertEqual(call?.arguments["volume"] as? Int, 50)
    }

    func test_parse_noMatch() {
        let call = LfmToolCallParser.parse(
            "<|tool_call_start|>[no_match(action='')]<|tool_call_end|>"
        )
        XCTAssertNotNil(call)
        XCTAssertEqual(call?.name, "no_match")
        XCTAssertTrue(call?.arguments.isEmpty == true)
    }

    func test_parse_invalidReturnsNil() {
        XCTAssertNil(LfmToolCallParser.parse("not a tool call"))
        XCTAssertNil(
            LfmToolCallParser.parse(
                "<|tool_call_start|>[broken(action=)]<|tool_call_end|>"
            )
        )
    }
}
