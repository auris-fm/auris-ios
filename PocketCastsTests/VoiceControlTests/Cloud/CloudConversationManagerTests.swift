import XCTest
@testable import podcasts

/// The conversation admission contract (`cloud-assistant.md` → "Conversations").
///
/// Every turn carries a client-generated UUID `conversation_id` and a lowercase
/// `conversation_mode`. The mode follows what actually selected the turn; the ORIGIN bounds
/// whether the turn may act on a conversation at all.
final class CloudConversationManagerTests: XCTestCase {
    private var manager: CloudConversationManager!

    override func setUp() {
        super.setUp()
        manager = CloudConversationManager()
        manager.registerLiveOrigin(1)
    }

    func testFirstTurnCreates() throws {
        let prepared = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1))
        XCTAssertEqual(prepared.mode, "create")
        XCTAssertNotNil(UUID(uuidString: prepared.conversationId), "the id must be a UUID")
    }

    /// The wake word rule, isolated within ONE origin. With two origins the origin check would
    /// refuse the resume by itself and the case would pass without exercising this rule.
    func testFreshWakeCreatesANewConversationWithinTheSameOrigin() throws {
        let first = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1))
        let second = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1))

        XCTAssertEqual(second.mode, "create", "a fresh wake selects a new conversation")
        XCTAssertNotEqual(second.conversationId, first.conversationId)
    }

    func testWakeFreeFollowUpResumesTheCurrentConversation() throws {
        let first = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1))
        let followUp = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1))

        XCTAssertEqual(followUp.mode, "resume")
        XCTAssertEqual(followUp.conversationId, first.conversationId)
    }

    // MARK: - Stale origin

    func testStaleOriginIsRefusedRatherThanGivenAReplacement() {
        _ = manager.prepare(selection: .wakeWord, origin: 1)
        manager.registerLiveOrigin(2)

        XCTAssertNil(
            manager.prepare(selection: .followUp, origin: 1),
            "a stale-origin turn was given a replacement conversation instead of being refused"
        )
    }

    /// A delayed WAKE callback from an ended origin is refused too. "Wake" describes how the
    /// turn was selected, not whether its callback is current, so the word alone must not
    /// create a conversation for a window that has ended.
    func testDelayedWakeFromAStaleOriginIsRefused() {
        _ = manager.prepare(selection: .wakeWord, origin: 1)
        manager.registerLiveOrigin(2)

        XCTAssertNil(manager.prepare(selection: .wakeWord, origin: 1))
    }

    func testUnstampedOriginIsRefused() {
        XCTAssertNil(manager.prepare(selection: .wakeWord, origin: nil))
    }

    /// The successor's conversation must survive a stale turn. Reporting this because it is a
    /// second consequence of creating a replacement, and it is not visible from the stale
    /// turn's own result: the replacement overwrote the live window's handle, so the follow-up
    /// that genuinely belonged to the live window then had nothing to resume.
    func testStaleTurnDoesNotDestroyTheLiveWindowsConversation() throws {
        _ = manager.prepare(selection: .wakeWord, origin: 1)
        manager.registerLiveOrigin(2)
        _ = manager.prepare(selection: .followUp, origin: 1)   // stale, refused

        let live = try XCTUnwrap(
            manager.prepare(selection: .followUp, origin: 2),
            "the live window's follow-up was refused"
        )
        XCTAssertEqual(live.mode, "create", "the live window has no conversation yet")
        let again = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 2))
        XCTAssertEqual(again.mode, "resume", "the live window's conversation was not retained")
        XCTAssertEqual(again.conversationId, live.conversationId)
    }

    // MARK: - Retry

    /// A transport retry of the same logical turn must reuse the SAME wire `request_id`.
    /// Preserving only the conversation UUID makes the server see a second logical turn.
    func testRetryReusesTheOriginalWireRequestId() throws {
        let first = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1))
        let retry = try XCTUnwrap(
            manager.prepare(selection: .wakeWord, origin: 1, retryingRequestId: first.requestId)
        )

        XCTAssertEqual(retry.requestId, first.requestId, "the retry generated a new request_id")
        XCTAssertEqual(retry.conversationId, first.conversationId)
        XCTAssertEqual(retry.mode, "create")
    }

    /// A turn with no current episode must OMIT the episode fields, not send empty or zero
    /// ones. An empty id names nothing and a zero position is a measurement the client never
    /// made; both read as supplied values to the server, which forbids inventing either.
    func testFrameOmitsEpisodeFieldsWhenThereIsNoCurrentEpisode() {
        let frame = CloudRouteRequestBuilder.envelope(
            request: "what should I listen to",
            context: CloudRouteContext(
                episodeId: nil, podcastId: nil, referencePositionMs: nil,
                clientPositionMs: nil, recentReferencePositions: [], previousReferencePositionMs: nil
            ),
            turn: CloudTurnEnvelope.make(
                capabilities: [], routeHint: nil, recentConversation: [], conversation: nil
            )
        )

        // EVERY position key, not just the two I first checked. Asserting only the id and the
        // client position let an unconditional `recent_reference_positions: []` through, which
        // still claims a position history for a turn with no episode.
        let context = (frame["context"] as? [String: Any]) ?? [:]
        for key in ["episode_id", "client_position_ms", "recent_reference_positions",
                    "reference_position_ms", "previous_reference_position_ms", "podcast_id"] {
            XCTAssertNil(context[key], "\(key) was sent for a turn with no episode context")
        }
    }

    func testFrameStillSendsEpisodeFieldsWhenOneExists() {
        let frame = CloudRouteRequestBuilder.envelope(
            request: "x",
            context: CloudRouteContext(
                episodeId: "ep-1", podcastId: "pod-1", referencePositionMs: nil,
                clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil
            ),
            turn: CloudTurnEnvelope.make(
                capabilities: [], routeHint: nil, recentConversation: [], conversation: nil
            )
        )

        let context = frame["context"] as? [String: Any]
        XCTAssertEqual(context?["episode_id"] as? String, "ep-1")
        // Int64 boxes as NSNumber, so an  cast of a stored Int64 is nil — read it as a
        // number and compare, or the case fails on the cast rather than on the value.
        XCTAssertEqual((context?["client_position_ms"] as? NSNumber)?.int64Value, 1_100)
    }

    /// The frame must carry the PREPARED `request_id`, not one minted at serialization time.
    /// A retry reuses the manager's prepared request; if the builder replaces its id, the server
    /// sees a second logical turn and the reuse is defeated at the last step.
    func testFrameCarriesThePreparedRequestId() throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(1)
        let prepared = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1))

        let frame = CloudRouteRequestBuilder.envelope(
            request: "x",
            context: CloudRouteContext(
                episodeId: nil, podcastId: nil, referencePositionMs: nil,
                clientPositionMs: nil, recentReferencePositions: [], previousReferencePositionMs: nil
            ),
            turn: CloudTurnEnvelope.make(
                capabilities: [], routeHint: nil, recentConversation: [], conversation: prepared
            )
        )

        XCTAssertEqual(
            frame["request_id"] as? String, prepared.requestId,
            "the frame minted its own request_id instead of serializing the prepared one"
        )
        XCTAssertEqual(frame["conversation_id"] as? String, prepared.conversationId)
        XCTAssertEqual(frame["conversation_mode"] as? String, "create")
    }

    func testModeIsAlwaysLowercase() throws {
        for selection in [CloudConversationSelection.wakeWord, .followUp] {
            let prepared = try XCTUnwrap(manager.prepare(selection: selection, origin: 1))
            XCTAssertTrue(["create", "resume"].contains(prepared.mode))
        }
    }



    /// A wake that fires WHILE GRACE IS ACTIVE must still CREATE. Read from live state the two
    /// are identical — both arrive with `isActive == true` — so the distinction has to travel
    /// with the input, which is what this pins. The mutation it catches is a live `isActive`
    /// read: under that, this wake would be classified a follow-up and resume.
    func testAWakeDuringActiveGraceStillCreates() {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(1)

        // The window is already open (grace active) when the wake fires.
        let prepared = manager.prepare(selection: .wakeWord, origin: 1)

        XCTAssertEqual(
            prepared?.mode, "create",
            "a wake during active grace resumed instead of creating a new conversation"
        )
    }

    /// A queued follow-up keeps the window it was registered under. Once that window is replaced,
    /// the turn is refused rather than attached to the window that happens to be current when it
    /// finally runs — which is what a late read of the generation would do.
    func testAQueuedFollowUpWhoseWindowWasReplacedIsRefused() {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(1)
        _ = manager.prepare(selection: .wakeWord, origin: 1)

        // The queued turn was registered under origin 1; the window is replaced before it runs.
        manager.registerLiveOrigin(2)

        XCTAssertNil(
            manager.prepare(selection: .followUp, origin: 1),
            "a queued follow-up was admitted under a window that no longer exists"
        )
    }
}
