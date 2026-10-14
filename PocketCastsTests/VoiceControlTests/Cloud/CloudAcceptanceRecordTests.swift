import XCTest
@testable import podcasts

/// The acceptance recorder is REQUEST-SCOPED and ALLOWLISTED: it accumulates only the server's text and
/// the terminal outcome for the turn it was created for, so one turn's evidence can never satisfy
/// another and no credential-bearing field is ever recorded.
final class CloudAcceptanceRecordTests: XCTestCase {

    func testRecorderCapturesResponseTextAndTerminalOnly() {
        let recorder = CloudAcceptanceRecord.Recorder(requestId: "req-1", conversationId: "conv-A")
        recorder.observe(.connected(codec: CloudAudioCodec(name: "pcm_s16le@24k")!))
        recorder.observe(.token("the "))
        recorder.observe(.token("nonce is NONCE-42"))
        recorder.observe(.action(tool: "player", action: "pause", params: [:]))
        recorder.observe(.done(usage: CloudTurnUsage(inputTokens: 1, outputTokens: 2, speech: nil)))

        let record = recorder.record()
        XCTAssertEqual(record.requestId, "req-1")
        XCTAssertEqual(record.conversationId, "conv-A")
        XCTAssertEqual(record.responseText, "the nonce is NONCE-42")
        XCTAssertEqual(record.terminal, .done)
    }

    func testAnOpenTurnHasNoTerminal() {
        let recorder = CloudAcceptanceRecord.Recorder(requestId: "req-2", conversationId: "conv-B")
        recorder.observe(.token("partial"))
        let record = recorder.record()
        XCTAssertNil(record.terminal, "a turn with no terminal event must not read as finished")
        XCTAssertEqual(record.responseText, "partial")
    }

    func testErrorIsTerminalAndDistinctFromDone() {
        let recorder = CloudAcceptanceRecord.Recorder(requestId: "req-3", conversationId: nil)
        recorder.observe(.error(code: "invalid_response", message: "x"))
        XCTAssertEqual(recorder.record().terminal, .error(code: "invalid_response"))
    }

    /// The recall assertion is against the INCOMING response text. This proves the two directions are
    /// distinguishable: the OUTGOING envelope's recent-conversation context is not what the recorder
    /// reports, so a turn whose request merely MENTIONED a nonce cannot make recall pass.
    func testOutgoingRecentConversationIsNotPartOfTheRecord() {
        let outgoing = CloudTurnEnvelope.make(
            capabilities: [],
            routeHint: nil,
            recentConversation: [RecentConversationTurn(role: .user, text: "NONCE-42")]
        )
        XCTAssertFalse(outgoing.recentConversation.isEmpty, "the fixture must carry outgoing context")

        let recorder = CloudAcceptanceRecord.Recorder(requestId: "req-4", conversationId: "conv-C")
        recorder.observe(.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil)))
        XCTAssertEqual(
            recorder.record().responseText, "",
            "the recorder reported outgoing context as a response; recall would pass falsely"
        )
    }

    /// REQUEST IDENTITY: the record carries the request id of the turn that was SUBMITTED, so two
    /// steps' records are distinguishable and a recall assertion cannot be judged against another
    /// step's turn. Fresh recorders alone would not establish this.
    func testRecordCarriesTheSubmittedTurnsRequestId() {
        let a = CloudAcceptanceRecord.Recorder(requestId: "req-A", conversationId: "conv-A")
        a.observe(.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil)))
        let b = CloudAcceptanceRecord.Recorder(requestId: "req-B", conversationId: "conv-A")
        b.observe(.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil)))

        XCTAssertEqual(a.record().requestId, "req-A")
        XCTAssertEqual(b.record().requestId, "req-B")
        XCTAssertNotEqual(a.record().requestId, b.record().requestId, "two turns share a request id")
        XCTAssertEqual(a.record().conversationId, b.record().conversationId, "same conversation, same id")
    }
}
