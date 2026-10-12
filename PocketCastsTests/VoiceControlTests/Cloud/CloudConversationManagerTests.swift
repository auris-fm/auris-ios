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
}
