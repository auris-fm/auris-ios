import XCTest
@testable import podcasts

/// The conversation admission contract (`cloud-assistant.md` → "Conversations").
///
/// Every turn carries a client-generated UUID `conversation_id` and a lowercase
/// `conversation_mode`. The mode is not derived from the wire history: it follows what
/// actually selected the turn — a wake word always opens a NEW conversation, while a
/// wake-free follow-up continues the current one.
final class CloudConversationManagerTests: XCTestCase {
    private var manager: CloudConversationManager!

    override func setUp() {
        super.setUp()
        manager = CloudConversationManager()
    }

    func testFirstTurnCreates() {
        let prepared = manager.prepare(selection: .wakeWord, generation: 1)
        XCTAssertEqual(prepared.mode, "create")
        XCTAssertNotNil(UUID(uuidString: prepared.conversationId), "the id must be a UUID")
    }

    func testWakeWordAlwaysStartsANewConversationEvenDuringGrace() {
        // SAME generation on purpose. With different generations the origin check would
        // refuse the resume on its own and this case would pass without exercising the
        // wake-word rule at all — which is exactly how its first version was inert.
        let first = manager.prepare(selection: .wakeWord, generation: 1)
        let second = manager.prepare(selection: .wakeWord, generation: 1)

        XCTAssertEqual(second.mode, "create", "a wake word selects a new conversation")
        XCTAssertNotEqual(
            second.conversationId, first.conversationId,
            "a wake word during grace must not resume the previous conversation"
        )
    }

    func testWakeFreeFollowUpResumesTheCurrentConversation() {
        let first = manager.prepare(selection: .wakeWord, generation: 1)
        let followUp = manager.prepare(selection: .followUp, generation: 1)

        XCTAssertEqual(followUp.mode, "resume")
        XCTAssertEqual(followUp.conversationId, first.conversationId)
    }

    func testRetryOfTheSameTurnKeepsItsLogicalIdentity() {
        let first = manager.prepare(selection: .wakeWord, generation: 1)
        let retry = manager.prepare(
            selection: .wakeWord, generation: 1, retryingCreationRequestId: first.creationRequestId
        )

        XCTAssertEqual(retry.conversationId, first.conversationId,
                       "a same-owner retry keeps the original creation identity")
        XCTAssertEqual(retry.mode, "create")
    }

    func testStaleOriginDiscardsRatherThanResuming() {
        // A FOLLOW-UP first, so the only thing that can refuse the resume below is the
        // origin: using a wake word here would let the wake-word rule carry the case.
        let first = manager.prepare(selection: .followUp, generation: 1)
        // The origin no longer exists: this turn must not resume a conversation it never
        // belonged to.
        let later = manager.prepare(selection: .followUp, generation: 7)

        XCTAssertNotEqual(later.conversationId, first.conversationId,
                          "a stale origin must not resume an earlier conversation")
        XCTAssertEqual(later.mode, "create")
    }

    func testModeIsAlwaysLowercaseAndNonNull() {
        for selection in [CloudConversationSelection.wakeWord, .followUp] {
            let prepared = manager.prepare(selection: selection, generation: 1)
            XCTAssertTrue(["create", "resume"].contains(prepared.mode),
                          "unexpected mode \(prepared.mode)")
            XCTAssertFalse(prepared.conversationId.isEmpty)
        }
    }

    // MARK: - Conversation identity on the wire

    func testFrameCarriesConversationIdAndMode() {
        let prepared = CloudPreparedConversation(
            conversationId: "11111111-2222-3333-4444-555555555555",
            mode: "create",
            creationRequestId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        let frame = CloudRouteRequestBuilder.envelope(
            request: "what did they say",
            context: CloudRouteContext(
                episodeId: "ep-1", podcastId: nil, referencePositionMs: nil,
                clientPositionMs: 1000, recentReferencePositions: [], previousReferencePositionMs: nil
            ),
            turn: CloudTurnEnvelope.make(
                capabilities: [], routeHint: nil, recentConversation: [], conversation: prepared
            )
        )

        XCTAssertEqual(frame["conversation_id"] as? String, prepared.conversationId)
        XCTAssertEqual(frame["conversation_mode"] as? String, "create")
    }

    func testFrameDoesNotSendClientSuppliedConversationHistory() {
        // The owning paragraph retains history SERVER-side and forbids client-supplied
        // history; sending ours would offer the model text the server never authenticated.
        let frame = CloudRouteRequestBuilder.envelope(
            request: "x",
            context: CloudRouteContext(
                episodeId: "ep-1", podcastId: nil, referencePositionMs: nil,
                clientPositionMs: 0, recentReferencePositions: [], previousReferencePositionMs: nil
            ),
            turn: CloudTurnEnvelope.make(
                capabilities: [], routeHint: nil,
                recentConversation: [RecentConversationTurn(role: .user, text: "earlier")],
                conversation: nil
            )
        )

        let context = frame["context"] as? [String: Any]
        XCTAssertNil(context?["recent_conversation"], "client-supplied history was still sent")
    }

    func testConversationIdentityIsIndependentOfEpisodeContext() {
        // A conversation is not a property of what is playing: the fields must be present
        // even when the frame carries no episode.
        let prepared = CloudPreparedConversation(
            conversationId: "99999999-8888-7777-6666-555555555555",
            mode: "resume",
            creationRequestId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        let frame = CloudRouteRequestBuilder.envelope(
            request: "x",
            context: CloudRouteContext(
                episodeId: "", podcastId: nil, referencePositionMs: nil,
                clientPositionMs: 0, recentReferencePositions: [], previousReferencePositionMs: nil
            ),
            turn: CloudTurnEnvelope.make(
                capabilities: [], routeHint: nil, recentConversation: [], conversation: prepared
            )
        )

        XCTAssertEqual(frame["conversation_id"] as? String, prepared.conversationId)
        XCTAssertEqual(frame["conversation_mode"] as? String, "resume")
    }

}
