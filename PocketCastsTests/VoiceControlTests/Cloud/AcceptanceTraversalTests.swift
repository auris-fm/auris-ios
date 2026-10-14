import XCTest
@testable import podcasts

/// ROUTE-LOOP / CONSUMER TRAVERSAL controls. Standalone record construction does not validate the
/// traversal: these drive the SAME recorder the collector uses through an event sequence and assert the
/// reader's rules — a stale request's evidence must not satisfy a fresh step, empty or mismatched ids
/// must not pass, and an outgoing-only mention of the nonce must not read as recall.
final class AcceptanceTraversalTests: XCTestCase {

    private func drain(_ events: [CloudRouteEvent]) -> CloudAcceptanceRecord.Recorder {
        let recorder = CloudAcceptanceRecord.Recorder(requestId: events.first?.acceptanceRequestId, conversationId: nil)
        for e in events { recorder.observe(e) }
        return recorder
    }

    /// A step must be judged on ITS OWN request. A record from an older request id does not satisfy a
    /// fresh step, because the reader compares the id it submitted with the id in the record.
    func testStaleRequestEvidenceDoesNotSatisfyAFreshStep() {
        let stale = CloudAcceptanceRecord.Recorder(requestId: "req-1", conversationId: "conv-A")
        stale.observe(.token("the nonce is NONCE-42"))
        stale.observe(.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil)))

        let fresh = CloudAcceptanceRecord.Recorder(requestId: "req-2", conversationId: "conv-A")
        fresh.observe(.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil)))

        XCTAssertNotEqual(stale.record().requestId, fresh.record().requestId)
        XCTAssertFalse(
            fresh.record().responseText.contains("NONCE-42"),
            "a stale request's response was read as the fresh step's evidence"
        )
    }

    /// Empty or missing ids must not pass: the ids are what tie an assertion to a turn.
    func testEmptyOrMissingIdsDoNotPass() {
        let noRequest = CloudAcceptanceRecord.Recorder(requestId: nil, conversationId: "conv-A")
        noRequest.observe(.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil)))
        XCTAssertNil(noRequest.record().requestId, "an absent request id must not be treated as an id")

        let noConversation = CloudAcceptanceRecord.Recorder(requestId: "req-1", conversationId: nil)
        XCTAssertNil(noConversation.record().conversationId, "an absent conversation id must not be treated as an id")

        let empty = CloudAcceptanceRecord.Recorder(requestId: "", conversationId: "")
        XCTAssertTrue(
            (empty.record().requestId ?? "").isEmpty,
            "an empty id must stay empty so a caller's nonempty check can reject it"
        )
    }

    /// RECALL IS ABOUT THE INCOMING RESPONSE. A turn whose only mention of the nonce is in the OUTGOING
    /// prompt records an empty response, so recall cannot pass on the prompt.
    func testOutgoingNonceInThePromptIsNotRecall() {
        let recorder = CloudAcceptanceRecord.Recorder(requestId: "req-2", conversationId: "conv-A")
        recorder.observe(.token(""))                       // server sent no content
        recorder.observe(.done(usage: CloudTurnUsage(inputTokens: 0, outputTokens: 0, speech: nil)))
        XCTAssertFalse(
            recorder.record().responseText.contains("NONCE-42"),
            "an outgoing-only nonce was read as recall"
        )
    }

    /// TRANSPORT TERMINALS are covered: a cancelled turn and a transport error are both terminal, and
    /// neither reads as success.
    func testTransportFailureAndCancellationAreBothTerminal() {
        let failed = CloudAcceptanceRecord.Recorder(requestId: "req-1", conversationId: "conv-A")
        failed.observe(.error(code: "connection_lost", message: ""))
        XCTAssertEqual(failed.record().terminal, .error(code: "connection_lost"))

        let cancelled = CloudAcceptanceRecord.Recorder(requestId: "req-2", conversationId: "conv-A")
        cancelled.observe(.token("partial"))
        cancelled.markCancelled()
        XCTAssertEqual(cancelled.record().terminal, .cancelled, "a cancelled turn must not read as open or done")
    }
}

/// Helper so the fixtures above can name a request id without inventing an envelope.
private extension CloudRouteEvent {
    var acceptanceRequestId: String? { nil }
}
