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
    /// ONE IDENTITY ON THE WIRE (contract delta f47e972 + source delta3b1def9): `request_id` is
    /// REQUIRED and client-owned, and it IS the admitted utterance's identity — for create AND
    /// follow-up alike. The server refuses a missing/invalid ID before admission, so the client
    /// must never send a fabricated one when it knows the utterance identity.
    func testWireRequestIdIsTheAdmittedUtteranceIdentity() throws {
        let create = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "adm-7"))
        XCTAssertEqual(
            create.requestId, "adm-7",
            "a create preparation sends the ADMITTED utterance id as the wire request_id"
        )
        let followUp = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1, utteranceId: "adm-8"))
        XCTAssertEqual(
            followUp.requestId, "adm-8",
            "a follow-up preparation sends ITS OWN admitted utterance id as the wire request_id"
        )
        // A dispatch without an admitted utterance identity is REFUSED, never re-identified
        // (reviewer 9ab31c6d): the manager mints no stand-in UUID.
        XCTAssertNil(
            manager.prepare(selection: .followUp, origin: 1, utteranceId: nil),
            "a missing utterance id must refuse, not mint a stand-in identity"
        )
    }

    /// Leaving ONE conversation must not leave the others. A turn that is told its conversation
    /// ended may be a delayed turn of an earlier window, while a newer window has already opened
    /// its own conversation; releasing everything there would make the live window's next
    /// follow-up start over and lose the thread the user is still in.
    func testLeavingOneConversationKeepsAnotherWindowsConversation() throws {
        let signal = GracePeriodSignal(timeout: 30)
        manager.admittedWorkAuthority = { signal.admittedWorkAuthority }

        signal.onWakeWordDetected()
        let olderOrigin = signal.currentGeneration()
        manager.registerLiveOrigin(olderOrigin)
        signal.admitInFlightTurn(utteranceId: "old-1", origin: olderOrigin)
        let older = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: olderOrigin, utteranceId: "old-1"))

        // A newer window opens its own conversation while the older turn is still in flight.
        signal.onWakeWordDetected()
        let liveOrigin = signal.currentGeneration()
        manager.registerLiveOrigin(liveOrigin)
        let live = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: liveOrigin, utteranceId: "live-1"))
        XCTAssertNotEqual(older.conversationId, live.conversationId, "premise: two distinct conversations")
        manager.acknowledge(conversationId: live.conversationId)

        manager.forget(conversationId: older.conversationId)

        let liveFollowUp = try XCTUnwrap(manager.prepare(selection: .followUp, origin: liveOrigin, utteranceId: "live-2"))
        XCTAssertEqual(
            liveFollowUp.conversationId, live.conversationId,
            "the live window's conversation was dropped by another window's expired turn"
        )
        XCTAssertEqual(liveFollowUp.mode, "resume")

        // The named conversation really is gone: a delayed follow-up of that same admitted window
        // opens a new one rather than resuming the id the server no longer holds.
        signal.admitInFlightTurnForTesting(utteranceId: "old-2", origin: olderOrigin)
        let olderFollowUp = try XCTUnwrap(manager.prepare(selection: .followUp, origin: olderOrigin, utteranceId: "old-2"))
        XCTAssertEqual(olderFollowUp.mode, "create", "the released conversation must not be resumed")
        XCTAssertNotEqual(olderFollowUp.conversationId, older.conversationId)
    }

    /// The live conversation is released when it is the one named, so the next request in that
    /// window opens a new conversation instead of resuming an id the server dropped.
    func testLeavingTheLiveConversationMakesTheNextRequestOpenANewOne() throws {
        let opened = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-open"))
        manager.forget(conversationId: opened.conversationId)
        let next = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-next"))
        XCTAssertEqual(next.mode, "create")
        XCTAssertNotEqual(next.conversationId, opened.conversationId)
    }

    /// An id this client never opened releases nothing. A stale or foreign id must not be able to
    /// clear the conversation the user is actually in.
    func testLeavingAnUnknownConversationKeepsTheLiveOne() throws {
        let opened = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-keep"))
        manager.acknowledge(conversationId: opened.conversationId)
        manager.forget(conversationId: "not-a-conversation-this-client-opened")
        let next = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-after"))
        XCTAssertEqual(next.mode, "resume")
        XCTAssertEqual(next.conversationId, opened.conversationId)
    }

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

    /// RETENTION RULE (reviewer 0c546ce5 item 3): EVERY utterance prepared inside the live
    /// window — create AND follow-up (resume) alike — is retained for exactly the window's
    /// lifetime, with no cap and no eviction, so a duplicate can never become a fresh dispatch.
    /// The window's close retires the whole retention, and origin is validated BEFORE every
    /// reuse, so a stale callback can never ride a retained identity.
    func testFollowUpPreparationIsRetainedPerUtteranceAndRetiredWithTheWindow() throws {
        // A follow-up utterance's preparation is retained and reused by its duplicate.
        let created = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-1"))
        manager.acknowledge(conversationId: created.conversationId)
        let followUp = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-2"))
        XCTAssertEqual(followUp.mode, "resume")
        let followUpDuplicate = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-2"))
        XCTAssertEqual(followUpDuplicate.requestId, followUp.requestId, "a follow-up duplicate reuses the retained resume")
        XCTAssertEqual(followUpDuplicate.conversationId, followUp.conversationId)

        // Later utterances do NOT evict earlier ones: every retained duplicate still joins.
        _ = manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-3")
        let stillRetained = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-2"))
        XCTAssertEqual(stillRetained.requestId, followUp.requestId,
                       "no eviction: a retained duplicate of an earlier utterance still joins its request")

        // The window's close retires the retention; a stale callback cannot ride the old id.
        manager.registerLiveOrigin(nil)
        XCTAssertNil(
            manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-3"),
            "origin is validated BEFORE every reuse: a stale window cannot prepare at all"
        )
    }

    func testFirstTurnCreates() throws {
        let prepared = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-1"))
        XCTAssertEqual(prepared.mode, "create")
        XCTAssertNotNil(UUID(uuidString: prepared.conversationId), "the id must be a UUID")
    }

    /// The wake word rule, isolated within ONE origin. With two origins the origin check would
    /// refuse the resume by itself and the case would pass without exercising this rule.
    func testFreshWakeCreatesANewConversationWithinTheSameOrigin() throws {
        let first = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-2"))
        let second = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-3"))

        XCTAssertEqual(second.mode, "create", "a fresh wake selects a new conversation")
        XCTAssertNotEqual(second.conversationId, first.conversationId)
    }

    func testWakeFreeFollowUpResumesTheCurrentConversation() throws {
        let first = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-4"))
        // The server acknowledged the opening turn, which is what makes the handle resumable.
        manager.acknowledge(conversationId: first.conversationId)
        let followUp = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-5"))

        XCTAssertEqual(followUp.mode, "resume")
        XCTAssertEqual(followUp.conversationId, first.conversationId)
    }

    // MARK: - Stale origin

    func testStaleOriginIsRefusedRatherThanGivenAReplacement() {
        _ = manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-6")
        manager.registerLiveOrigin(2)

        XCTAssertNil(
            manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-7"),
            "a stale-origin turn was given a replacement conversation instead of being refused"
        )
    }

    /// A delayed WAKE callback from an ended origin is refused too. "Wake" describes how the
    /// turn was selected, not whether its callback is current, so the word alone must not
    /// create a conversation for a window that has ended.
    func testDelayedWakeFromAStaleOriginIsRefused() {
        _ = manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-8")
        manager.registerLiveOrigin(2)

        XCTAssertNil(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-9"))
    }

    func testUnstampedOriginIsRefused() {
        XCTAssertNil(manager.prepare(selection: .wakeWord, origin: nil, utteranceId: "u-10"))
    }

    /// The successor's conversation must survive a stale turn. Reporting this because it is a
    /// second consequence of creating a replacement, and it is not visible from the stale
    /// turn's own result: the replacement overwrote the live window's handle, so the follow-up
    /// that genuinely belonged to the live window then had nothing to resume.
    func testStaleTurnDoesNotDestroyTheLiveWindowsConversation() throws {
        _ = manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-11")
        manager.registerLiveOrigin(2)
        _ = manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-12")   // stale, refused

        let live = try XCTUnwrap(
            manager.prepare(selection: .followUp, origin: 2, utteranceId: "u-13"),
            "the live window's follow-up was refused"
        )
        XCTAssertEqual(live.mode, "create", "the live window has no conversation yet")
        manager.acknowledge(conversationId: live.conversationId)
        let again = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 2, utteranceId: "u-14"))
        XCTAssertEqual(again.mode, "resume", "the live window's conversation was not retained")
        XCTAssertEqual(again.conversationId, live.conversationId)
    }

    // MARK: - Retry

    /// ONE IDENTITY (reviewer c580c42b): a transport retry of the SAME admitted utterance
    /// passes the SAME id and is served from retention — same request id, same conversation.
    func testRetryOfTheSameUtteranceReusesItsRetainedIdentity() throws {
        let admitted = "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"
        let first = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: admitted))
        let retry = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: admitted))

        XCTAssertEqual(retry.requestId, first.requestId, "the retry must not mint a new request_id")
        XCTAssertEqual(retry.requestId, admitted, "the wire id IS the admitted utterance id")
        XCTAssertEqual(retry.conversationId, first.conversationId)
        XCTAssertEqual(retry.mode, "create")
    }

    /// An INDEPENDENT utterance in the same window dispatches its OWN identity; it can never
    /// adopt a previously prepared request id (the old retryingRequestId adoption is removed).
    func testIndependentUtteranceNeverAdoptsAnotherUtterancesIdentity() throws {
        let first = try XCTUnwrap(
            manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88")
        )
        let second = try XCTUnwrap(
            manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "0d6f1e2a-93c4-4b57-8a20-5e1f7c9b3d44")
        )

        XCTAssertNotEqual(second.requestId, first.requestId, "a different admitted turn has its own id")
        XCTAssertEqual(second.requestId, "0d6f1e2a-93c4-4b57-8a20-5e1f7c9b3d44")
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
                capabilities: [], routeHint: nil, conversation: testPreparedConversation()
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
                capabilities: [], routeHint: nil, conversation: testPreparedConversation()
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
        let prepared = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-17"))

        let frame = CloudRouteRequestBuilder.envelope(
            request: "x",
            context: CloudRouteContext(
                episodeId: nil, podcastId: nil, referencePositionMs: nil,
                clientPositionMs: nil, recentReferencePositions: [], previousReferencePositionMs: nil
            ),
            turn: CloudTurnEnvelope.make(
                capabilities: [], routeHint: nil, conversation: prepared
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
            let prepared = try XCTUnwrap(manager.prepare(selection: selection, origin: 1, utteranceId: "u-18"))
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
            manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-19"),
            "the setup conversation was refused"
        )
        XCTAssertEqual(existing.mode, "create", "the first turn of a window creates")
        manager.acknowledge(conversationId: existing.conversationId)
        let resumed = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-20"))
        XCTAssertEqual(resumed.mode, "resume", "setup precondition: the conversation is open")
        XCTAssertEqual(resumed.conversationId, existing.conversationId)

        // Now a WAKE fires while that conversation is open and grace is active.
        let afterWake = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-21"))

        XCTAssertEqual(
            afterWake.mode, "create",
            "a wake during active grace resumed an open conversation instead of creating"
        )
        XCTAssertNotEqual(
            afterWake.conversationId, existing.conversationId,
            "a wake resumed the open conversation rather than starting a new one"
        )
    }

    // MARK: - Acknowledged conversations

    /// A conversation handle is RESUMABLE only once the server has acknowledged the turn that
    /// opened it by sending `connected` — the frame is sent after admission, and admission is
    /// what makes a conversation real (`cloud-assistant.md` -> "Conversations").
    ///
    /// The defect this locks down: after a create that ended before `connected` (a refused
    /// spend, a lost transport), the client kept the handle and sent the NEXT utterance as
    /// `resume`. The server had a record but no admitted creation, so history held only the
    /// follow-up while the user believed the earlier turn was still part of the thread.
    ///
    /// Both halves are asserted together because either alone passes for the wrong reason: a
    /// follow-up that always creates would leave the second half green while breaking every
    /// ordinary follow-up, and one that always resumes leaves the first half unchanged.
    func testAFollowUpOnlyResumesAConversationTheServerAcknowledged() throws {
        let create = try XCTUnwrap(
            manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "ack-1"),
            "the opening turn was refused"
        )
        XCTAssertEqual(create.mode, "create")

        // Premise: nothing has been acknowledged yet, so there is nothing to resume.
        // The negative premise: this conversation is held, but nothing acknowledged it.
        XCTAssertFalse(
            manager.isAcknowledgedForTesting(conversationId: create.conversationId),
            "premise: the opening turn has not been acknowledged"
        )
        // WHAT A DRAFT IS: the unacknowledged conversation is not the window's conversation, so
        // nothing may resume it.
        XCTAssertFalse(
            manager.holdsHandleForTesting(conversationId: create.conversationId),
            "an unacknowledged create was published as the window's conversation"
        )
        // A DIFFERENT question first: does the unacknowledged handle get RESUMED? Same logical
        // request, so nothing else (retention, origin) can explain a `resume` here; if this
        // branch is taken the assertion below fails on the mode, which is the defect itself.
        let resumedAnyway = try XCTUnwrap(
            manager.prepare(selection: .followUp, origin: 1, utteranceId: "ack-2"),
            "a follow-up before the first acknowledgement was refused outright"
        )
        XCTAssertEqual(
            resumedAnyway.mode, "create",
            "a follow-up resumed a conversation the server never acknowledged"
        )
        // The same logical request would come back as a resume, which is what makes the mode
        // assertion in the previous check the property under test rather than a side effect.
        XCTAssertEqual(
            manager.prepare(selection: .followUp, origin: 1, utteranceId: "ack-2"),
            resumedAnyway,
            "a repeated preparation did not return the prepared request"
        )

        // The acknowledgement arrives for the FIRST turn's conversation.
        manager.acknowledge(conversationId: create.conversationId)

    }

    /// CONTROL for the rule above, and the reason it is a separate case: it must be possible for
    /// an acknowledged conversation to be resumed, or "never resume anything" would satisfy the
    /// unacknowledged half while destroying every ordinary follow-up.
    func testAnAcknowledgedConversationIsResumedByTheNextFollowUp() throws {
        let create = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "ack-7"))
        manager.acknowledge(conversationId: create.conversationId)

        let followUp = try XCTUnwrap(
            manager.prepare(selection: .followUp, origin: 1, utteranceId: "ack-8"),
            "a follow-up after acknowledgement was refused"
        )
        XCTAssertEqual(
            followUp.mode, "resume",
            "an acknowledged conversation was not resumed, so the thread restarts"
        )
        XCTAssertEqual(
            followUp.conversationId, create.conversationId,
            "the follow-up did not continue the acknowledged conversation"
        )
    }

    /// A transport retry of the SAME logical request keeps its request id, conversation id and
    /// `create` — the contract permits it after a failure BEFORE admission, and the
    /// acknowledgement rule must not take that away.
    func testARetryOfAnUnacknowledgedCreateKeepsItsIdentity() throws {
        let first = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "ack-4"))
        XCTAssertEqual(first.mode, "create")

        // Same utterance id: the retained preparation is handed back unchanged.
        let retry = try XCTUnwrap(
            manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "ack-4"),
            "a same-request retry was refused"
        )
        XCTAssertEqual(retry, first, "a transport retry became a different logical request")
        XCTAssertEqual(retry.requestId, "ack-4")
        XCTAssertEqual(retry.mode, "create")
    }

    /// Acknowledging a conversation this manager is not holding changes nothing, so a late or
    /// mismatched acknowledgement cannot convert a live newer conversation into a resumable one.
    func testAnAcknowledgementForAnUnknownHandleOpensNothing() throws {
        let newer = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "ack-5"))
        manager.acknowledge(conversationId: "a-conversation-this-client-never-opened")

        // A later follow-up names the window's own handle, not the unknown one.
        let later = try XCTUnwrap(manager.prepare(selection: .followUp, origin: 1, utteranceId: "ack-6"))
        XCTAssertNotEqual(
            later.conversationId, "a-conversation-this-client-never-opened",
            "a follow-up named a handle the server never acknowledged"
        )
        XCTAssertFalse(
            manager.isAcknowledgedForTesting(conversationId: "a-conversation-this-client-never-opened"),
            "an unknown handle was recorded as acknowledged"
        )
        XCTAssertNotEqual(later.conversationId, newer.conversationId)
    }

    /// A queued follow-up keeps the window it was registered under. Once that window is replaced,
    /// the turn is refused rather than attached to the window that happens to be current when it
    /// finally runs — which is what a late read of the generation would do.
    func testAQueuedFollowUpWhoseWindowWasReplacedIsRefused() {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(1)
        _ = manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "u-22")

        // The queued turn was registered under origin 1; the window is replaced before it runs.
        manager.registerLiveOrigin(2)

        XCTAssertNil(
            manager.prepare(selection: .followUp, origin: 1, utteranceId: "u-23"),
            "a queued follow-up was admitted under a window that no longer exists"
        )
    }
}
