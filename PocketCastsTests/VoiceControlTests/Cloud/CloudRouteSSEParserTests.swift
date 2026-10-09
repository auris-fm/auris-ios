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
        // A unit-less amount cannot be interpreted, so the record is absent
        // rather than carried unreadable.
        let speech = CloudSpeechUsage(amount: 1000, unit: "")
        XCTAssertNil(speech)
    }

    /// The other side of the same boundary, and the one the server actually
    /// sends on a provider failure: `amount: null` with `unit: "unavailable"`
    /// (cloud-assistant.md) is a *usable* record — "the provider failed" is
    /// information — so it must be kept. Without this case, the guard above
    /// could be "simplified" into dropping exactly the record the spec sends,
    /// and no test would object.
    func testSpeechUnavailableUnitWithNullAmountIsKept() {
        let speech = CloudSpeechUsage(amount: nil, unit: "unavailable")
        XCTAssertNotNil(speech, "a provider-failure record is information, not an absent record")
        XCTAssertNil(speech?.amount)
        XCTAssertEqual(speech?.unit, "unavailable")
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

// MARK: - WebSocket text frame parser tests

final class CloudRouteClientTextParserTests: XCTestCase {
    /// The socket carries `token` frames, so the socket parser must read them.
    ///
    /// This looks like an SSE leftover and is not one: the Worker's
    /// `lifecycle.ts` `sendVisible("token", { text })` writes them on the live
    /// WebSocket path. A parser without this case falls to `default: return []`
    /// and drops a frame the wire defines. That is a fidelity defect rather than
    /// a user-visible one — `CloudRouteSink` plays answers instead of speaking
    /// them — and the frame still has to be read for what it is.
    func testParsesTokenOnTheSocket() {
        XCTAssertEqual(
            CloudRouteClient.parseTextFrame(#"{"type":"token","text":"forty-two"}"#),
            [.token("forty-two")],
            "token rides the socket; dropping it loses the answer text"
        )
    }

    /// The `usage` counts have exactly **one** shape on the wire, and a frame
    /// that omits it parses to no recorded cost rather than to a top-level
    /// fallback.
    ///
    /// This is the test that pins the *absence* of that fallback: it fails if one
    /// is ever restored, which a fixture-level check cannot do (a fixture using
    /// the nested shape passes either way). The Worker nests the counts
    /// (`protocol/frames.ts`), and with a single transport an accepted second
    /// shape could only absorb a format change silently instead of failing —
    /// which is the detection the removed comment claimed to provide.
    func testDoneWithoutNestedUsage_recordsNoCost_ratherThanFallingBack() {
        let nested = CloudRouteClient.parseTextFrame(
            #"{"type":"done","usage":{"input_tokens":7,"output_tokens":3}}"#
        )
        XCTAssertEqual(
            nested,
            [.done(usage: CloudTurnUsage(inputTokens: 7, outputTokens: 3))],
            "the Worker's nested shape is read"
        )

        // Flat top-level counts are not a shape the wire defines: they must not
        // be picked up, so a frame carrying only those records nothing.
        let flat = CloudRouteClient.parseTextFrame(
            #"{"type":"done","input_tokens":7,"output_tokens":3}"#
        )
        XCTAssertEqual(
            flat,
            [.done(usage: CloudTurnUsage(inputTokens: nil, outputTokens: nil))],
            "top-level counts are not a fallback shape"
        )
    }

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
