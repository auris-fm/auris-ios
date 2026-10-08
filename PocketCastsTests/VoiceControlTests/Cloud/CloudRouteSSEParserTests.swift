import XCTest
@testable import podcasts

// MARK: - CloudAudioFrame tests

final class CloudAudioFrameTests: XCTestCase {
    func testCreatesFrameWithData() {
        let payload = Data([0x00, 0x01, 0x02])
        let frame = CloudAudioFrame(data: payload)
        XCTAssertEqual(frame.data, payload)
    }

    func testEmptyDataCreatesFrame() {
        let frame = CloudAudioFrame(data: Data())
        XCTAssertTrue(frame.data.isEmpty)
    }

    func testFrameIsEquatable() {
        let data = Data([0x01, 0x02])
        let frame1 = CloudAudioFrame(data: data)
        let frame2 = CloudAudioFrame(data: data)
        let frame3 = CloudAudioFrame(data: Data([0x03]))
        XCTAssertEqual(frame1, frame2)
        XCTAssertNotEqual(frame1, frame3)
    }
}

// MARK: - CloudTurnUsage tests

final class CloudTurnUsageTests: XCTestCase {
    func testDefaultUsageHasNullTokens() {
        let usage = CloudTurnUsage()
        XCTAssertNil(usage.inputTokens)
        XCTAssertNil(usage.outputTokens)
        XCTAssertNil(usage.speech)
    }

    func testUsageWithTokens() {
        let usage = CloudTurnUsage(inputTokens: 100, outputTokens: 200)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 200)
        XCTAssertNil(usage.speech)
    }

    func testUsageWithSpeech() {
        let speech = CloudSpeechUsage(amount: 5000, unit: "ms")
        let usage = CloudTurnUsage(inputTokens: 10, outputTokens: 20, speech: speech)
        XCTAssertEqual(usage.speech?.amount, 5000)
        XCTAssertEqual(usage.speech?.unit, "ms")
    }

    func testSpeechWithEmptyUnitIsNil() {
        let speech = CloudSpeechUsage(amount: 1000, unit: "")
        XCTAssertNil(speech)
    }

    func testUsageWithNullTokens() {
        let usage = CloudTurnUsage(inputTokens: nil, outputTokens: nil)
        XCTAssertNil(usage.inputTokens)
        XCTAssertNil(usage.outputTokens)
    }

    func testUsageIsEquatable() {
        let usage1 = CloudTurnUsage(inputTokens: 10, outputTokens: 20)
        let usage2 = CloudTurnUsage(inputTokens: 10, outputTokens: 20)
        let usage3 = CloudTurnUsage(inputTokens: 10, outputTokens: 30)
        XCTAssertEqual(usage1, usage2)
        XCTAssertNotEqual(usage1, usage3)
    }
}

// MARK: - CloudSpeechUsage tests

final class CloudSpeechUsageTests: XCTestCase {
    func testSpeechUsageWithAmountAndUnit() throws {
        let speech = try XCTUnwrap(CloudSpeechUsage(amount: 5000, unit: "ms"))
        XCTAssertEqual(speech.amount, 5000)
        XCTAssertEqual(speech.unit, "ms")
    }

    func testSpeechUsageIsEquatable() throws {
        let s1 = try XCTUnwrap(CloudSpeechUsage(amount: 1000, unit: "ms"))
        let s2 = try XCTUnwrap(CloudSpeechUsage(amount: 1000, unit: "ms"))
        let s3 = try XCTUnwrap(CloudSpeechUsage(amount: 2000, unit: "ms"))
        XCTAssertEqual(s1, s2)
        XCTAssertNotEqual(s1, s3)
    }
}

// MARK: - CloudRouteEvent tests

final class CloudRouteEventTests: XCTestCase {
    func testAudioFrameEventIsEquatable() {
        let data = Data([0x01, 0x02])
        let event1 = CloudRouteEvent.audioFrame(CloudAudioFrame(data: data))
        let event2 = CloudRouteEvent.audioFrame(CloudAudioFrame(data: data))
        let event3 = CloudRouteEvent.audioFrame(CloudAudioFrame(data: Data([0x03])))
        XCTAssertEqual(event1, event2)
        XCTAssertNotEqual(event1, event3)
    }

    func testDoneEventWithUsage() {
        let usage = CloudTurnUsage(inputTokens: 100, outputTokens: 200)
        let event = CloudRouteEvent.done(usage: usage)
        if case .done(let u) = event {
            XCTAssertEqual(u.inputTokens, 100)
            XCTAssertEqual(u.outputTokens, 200)
        } else {
            XCTFail("expected .done")
        }
    }
}

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
            XCTAssertEqual(result.scope, .currentEpisode)
        } else {
            XCTFail("expected .result")
        }
    }
}

// MARK: - WebSocket text frame parser tests

final class CloudRouteClientTextParserTests: XCTestCase {
    func testParsesConnected() {
        // `connected` carries the codec the server negotiated; the player needs
        // it (rate included) to decode the binary frames that follow.
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"connected","codec":"pcm_s16le@24k","reservation_id":"abc"}"#
        )
        XCTAssertEqual(events, [.connected(codec: CloudAudioCodec(name: "pcm_s16le@24k")!)])
    }

    func testConnectedWithoutCodecIsIgnored() {
        XCTAssertTrue(
            CloudRouteClient.parseTextFrame(#"{"type":"connected","reservation_id":"abc"}"#).isEmpty,
            "a connected frame with no codec tells the client nothing"
        )
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

    func testParsesDoneWithPartialTokens() {
        // One token present, one missing.
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"done","usage":{"input_tokens":42,"speech":{"amount":1000,"unit":"ms"}}}"#
        )
        XCTAssertEqual(events.count, 1)
        if case .done(let usage) = events.first {
            XCTAssertEqual(usage.inputTokens, 42)
            XCTAssertNil(usage.outputTokens)
            XCTAssertEqual(usage.speech?.amount, 1000)
        } else {
            XCTFail("expected .done")
        }
    }

    func testParsesDoneWithEmptyUsage() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"done","usage":{}}"#
        )
        XCTAssertEqual(events.count, 1)
        if case .done(let usage) = events.first {
            XCTAssertNil(usage.inputTokens)
            XCTAssertNil(usage.outputTokens)
        } else {
            XCTFail("expected .done")
        }
    }

    func testUnknownTypeReturnsEmpty() {
        let events = CloudRouteClient.parseTextFrame(
            #"{"type":"unknown_event"}"#
        )
        XCTAssertTrue(events.isEmpty)
    }
}
