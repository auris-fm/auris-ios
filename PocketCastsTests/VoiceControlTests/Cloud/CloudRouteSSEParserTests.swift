import XCTest
@testable import podcasts

final class CloudRouteSSEParserTests: XCTestCase {
    func testParsesMixedEvents() {
        var parser = CloudRouteSSEParser()
        var events: [CloudRouteEvent] = []
        let lines = """
            event: action
            data: {"tool":"playback","action":"pause","params":{}}

            event: token
            data: {"text":"Hi"}

            event: done
            data: {"input_tokens":1,"output_tokens":1}
            """.components(separatedBy: "\n")
        for line in lines {
            events.append(contentsOf: parser.consume(line: line))
        }
        events.append(contentsOf: parser.finish())
        XCTAssertEqual(
            events,
            [
                .action(tool: "playback", action: "pause", params: [:]),
                .token("Hi"),
                .done(inputTokens: 1, outputTokens: 1),
            ]
        )
    }

    func testJoinsMultiLineDataWithNewline() {
        var parser = CloudRouteSSEParser()
        var events: [CloudRouteEvent] = []
        for line in ["event: token", "data: {\"text\":", "data: \"ab\"}", ""] {
            events.append(contentsOf: parser.consume(line: line))
        }
        XCTAssertEqual(events, [.token("ab")])
    }
}
