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

    /// REQUEST OWNERSHIP (owner delta 3484cbc/5eca874, reviewer 724db1e8): duplicate
    /// preparation for the SAME utterance reuses the prepared wire request identity; an
    /// independent utterance mints its own. This is the duplicate-dispatch protection the
    /// removed window budget was replaced by — asserted at the ACTUAL request owner.
    func testDuplicatePreparationForTheSameUtteranceReusesTheWireIdentity() throws {
        let first = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-1"))
        let duplicate = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-1"))
        XCTAssertEqual(
            duplicate.requestId, first.requestId,
            "a repeated callback for the SAME utterance must reuse the prepared wire request id"
        )
        XCTAssertEqual(duplicate.conversationId, first.conversationId)
        XCTAssertEqual(duplicate.mode, first.mode)

        // An independent utterance (different id) mints a DIFFERENT request.
        let independent = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-2"))
        XCTAssertNotEqual(
            independent.requestId, first.requestId,
            "an independent utterance in the same window dispatches its own request"
        )
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

    // MARK: - Replay admission: (unknown ∨ failed) ∧ idempotent

    /// The conjunct that matters: a NON-IDEMPOTENT operation that FAILED must not be replayed.
    /// The app tried, so its effect may already have landed, and `failed` read as a bare label
    /// would admit exactly that replay.
    func testAFailedNonIdempotentOperationIsNotReplayed() {
        XCTAssertFalse(
            OperationOutcome.failed.admitsReplay(isIdempotent: false),
            "a non-idempotent failed operation was admitted for replay"
        )
    }

    func testAFailedIdempotentOperationMayBeReplayed() {
        XCTAssertTrue(OperationOutcome.failed.admitsReplay(isIdempotent: true))
    }

    /// `unknown` is the case the predicate exists for: nothing was established.
    func testAnUnknownOperationMayBeReplayedWhenIdempotent() {
        XCTAssertTrue(OperationOutcome.unknown.admitsReplay(isIdempotent: true))
    }

    /// A `refused` is a settled DECISION — the app heard and said no.
    func testARefusedOperationIsNeverReplayed() {
        XCTAssertFalse(OperationOutcome.refused.admitsReplay(isIdempotent: true))
        XCTAssertFalse(OperationOutcome.refused.admitsReplay(isIdempotent: false))
    }

    /// A `succeeded` empty state is a settled FACT, not an absence.
    func testASucceededOperationIsNeverReplayed() {
        XCTAssertFalse(OperationOutcome.succeeded.admitsReplay(isIdempotent: true))
    }

    /// Nothing is replayable without idempotence, whatever the outcome.
    func testNothingIsReplayableWhenNotIdempotent() {
        for outcome in OperationOutcome.allCases {
            XCTAssertFalse(
                outcome.admitsReplay(isIdempotent: false),
                "\(outcome) was admitted for replay without idempotence"
            )
        }
    }

    func testModeIsAlwaysLowercase() throws {
        for selection in [CloudConversationSelection.wakeWord, .followUp] {
            let prepared = try XCTUnwrap(manager.prepare(selection: selection, origin: 1))
            XCTAssertTrue(["create", "resume"].contains(prepared.mode))
        }
    }



    /// The MANAGER's wake-resume rule: a wake must create even when a conversation is already
    /// open, so it has something it could wrongly resume.
    ///
    /// SCOPE, stated narrowly because the comment previously claimed more: this drives the
    /// manager with an explicit selection, so **it cannot exercise the service's selection
    /// derivation** and does NOT catch a live `isActive` read in `VoiceControlService`. What it
    /// catches is the manager resuming on a wake — independently executed by @reviewer, where
    /// changing the manager to resume on wake fails both assertions here.
    ///
    /// The service-level control — a wake during active grace driven through the real caller —
    /// remains OPEN, and this case is not a substitute for it.
    func testAWakeDuringActiveGraceStillCreates() throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(1)

        // A conversation must ALREADY EXIST, or "create" is inevitable and the case proves
        // nothing — it would pass whether or not the wake rule is honoured. Opening a
        // follow-up first puts a conversation in place that a wake could wrongly resume.
        let existing = try XCTUnwrap(
            manager.prepare(selection: .followUp, origin: 1),
            "the setup conversation was refused"
        )
        XCTAssertEqual(existing.mode, "create", "the first turn of a window creates")
        let resumed = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1))
        XCTAssertEqual(resumed.mode, "resume", "setup precondition: the conversation is open")
        XCTAssertEqual(resumed.conversationId, existing.conversationId)

        // Now a WAKE fires while that conversation is open and grace is active.
        let afterWake = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1))

        XCTAssertEqual(
            afterWake.mode, "create",
            "a wake during active grace resumed an open conversation instead of creating"
        )
        XCTAssertNotEqual(
            afterWake.conversationId, existing.conversationId,
            "a wake resumed the open conversation rather than starting a new one"
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
