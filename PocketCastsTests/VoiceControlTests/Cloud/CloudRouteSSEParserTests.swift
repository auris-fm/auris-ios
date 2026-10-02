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
            data: {"usage":{"input_tokens":1,"output_tokens":1}}
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
                .done(usage: CloudTurnUsage(inputTokens: 1, outputTokens: 1)),
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

    func testParseError() {
        var parser = CloudRouteSSEParser()
        var events: [CloudRouteEvent] = []
        for line in ["event: error", "data: {\"code\":\"limit_exceeded\",\"message\":\"\"}", ""] {
            events.append(contentsOf: parser.consume(line: line))
        }
        XCTAssertEqual(events, [.error(code: "limit_exceeded", message: "")])
    }

    func testParseResult() {
        var parser = CloudRouteSSEParser()
        var events: [CloudRouteEvent] = []
        let json = """
        {"kind":"episode_results","scope":"current_episode","items":[],"next_cursor":null}
        """
        for line in ["event: result", "data: \(json)", ""] {
            events.append(contentsOf: parser.consume(line: line))
        }
        XCTAssertEqual(events.count, 1)
        if case .result(let result) = events.first {
            XCTAssertEqual(result.kind, "episode_results")
            XCTAssertEqual(result.scope, "current_episode")
        } else {
            XCTFail("expected .result")
        }
    }
}

// MARK: - WebSocket text frame parser tests

final class CloudRouteClientTextParserTests: XCTestCase {
    func testParsesConnected() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"connected","codec":"opus@48k","reservation_id":"abc"}"#
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testParsesAudioFrameBinaryNotFromText() {
        // Audio frames come as binary, not text — text parser ignores them.
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"audio"}"#
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testParsesAction() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"action","tool":"playback","action":"seek_to","params":{"reference_position_ms":1234567}}"#
        )
        XCTAssertEqual(events.count, 1)
        if case .action(let tool, let action, let params) = events.first {
            XCTAssertEqual(tool, "playback")
            XCTAssertEqual(action, "seek_to")
            XCTAssertEqual(params["reference_position_ms"]?.int64Value, 1_234_567)
        } else {
            XCTFail("expected .action")
        }
    }

    // No .token event on the WebSocket contract (cloud-assistant.md).
    // Token events only exist on the SSE path for backward compatibility.

    func testParsesDoneWithUsage() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"done","usage":{"input_tokens":100,"output_tokens":200,"speech":{"amount":5000,"unit":"ms"}}}"#
        )
        XCTAssertEqual(events.count, 1)
        if case .done(let usage) = events.first {
            XCTAssertEqual(usage.inputTokens, 100)
            XCTAssertEqual(usage.outputTokens, 200)
            XCTAssertEqual(usage.speech?.amount, 5000)
            XCTAssertEqual(usage.speech?.unit, "ms")
        } else {
            XCTFail("expected .done")
        }
    }

    func testParsesDoneWithNullTokens() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"done","usage":{"input_tokens":null,"output_tokens":null,"speech":null}}"#
        )
        XCTAssertEqual(events.count, 1)
        if case .done(let usage) = events.first {
            XCTAssertNil(usage.inputTokens)
            XCTAssertNil(usage.outputTokens)
            XCTAssertNil(usage.speech)
        } else {
            XCTFail("expected .done")
        }
    }

    func testParsesError() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"error","code":"limit_exceeded","message":"Daily limit reached"}"#
        )
        XCTAssertEqual(events.count, 1)
        if case .error(let code, let message) = events.first {
            XCTAssertEqual(code, "limit_exceeded")
            XCTAssertEqual(message, "Daily limit reached")
        } else {
            XCTFail("expected .error")
        }
    }

    func testParsesDoneWithoutUsageKey() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"done"}"#
        )
        XCTAssertEqual(events.count, 1)
        if case .done(let usage) = events.first {
            XCTAssertNil(usage.inputTokens)
            XCTAssertNil(usage.outputTokens)
        } else {
            XCTFail("expected .done")
        }
    }

    func testInvalidJsonReturnsEmpty() {
        let events = CloudRouteClient.parseTextFrame("not json")
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingTypeReturnsEmpty() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"foo":"bar"}"#
        )
        XCTAssertTrue(events.isEmpty)
    }
}
