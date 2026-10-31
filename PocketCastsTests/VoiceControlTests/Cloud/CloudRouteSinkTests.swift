/// The origin these cases dispatch under. The conversation bound refuses a turn whose origin
/// is not live, so a sink built for these cases must be given one — otherwise every turn would
/// be refused before it dials and the case would exercise the bound rather than the sink.
private let cloudTestOrigin = 1

private func testConversationManager() -> CloudConversationManager {
    let manager = CloudConversationManager()
    manager.registerLiveOrigin(cloudTestOrigin)
    return manager
}

import XCTest
import AVFoundation
@testable import podcasts

final class CloudRouteSinkTests: SocketCapturingTestCase {

    /// The identity the tests' turns are admitted under. Journal replay identity is owner +
    /// conversation + turn + the ORIGINAL action bytes; the first three are the sink's admitted
    /// turn, so a check that re-claims an operation must use the same triple the sink used. The
    /// bytes are empty here because these test doubles carry no raw payload.
    /// The identity the sink's OWN preparation mints for an utterance: the conversation manager
    /// mints a fresh conversation per origin window, so the conversation id is not known ahead of
    /// the turn — this asks the sink's manager for it rather than guessing.
    ///
    /// `bytes` must be the EXACT serialized `data:` payload the fixture delivers, because replay
    /// identity is byte equality on the received frame. `injectOperationIdentity` rewrites the
    /// fixture to insert the id pair, so the payload is not the fixture line verbatim — pass the
    /// post-injection payload.
    /// THE COMPLETE SERIALIZED ACTION PAYLOAD this control delivers, as a literal. Replay identity
    /// is byte equality on the exact payload the sink receives, so an id-only fragment would hash
    /// something that was never delivered and make every comparison meaningless.
    static func lateActionPayload(_ operationId: String) -> String {
        #"{"operation_id":"\#(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"\#(testEpisodeId)"}}"#
    }

    static func mintedIdentity(
        for utteranceId: String,
        manager: CloudConversationManager,
        bytes: String = ""
    ) -> OperationIdentity? {
        guard let prepared = manager.prepare(selection: .wakeWord, origin: cloudTestOrigin,
                                             utteranceId: utteranceId) else { return nil }
        return OperationIdentity(owner: "test-owner",
                                 conversation: prepared.conversationId,
                                 turn: prepared.requestId,
                                 actionBytes: Data(bytes.utf8))
    }

    static func turnIdentity(conversation: String, turn: String, bytes: String = "") -> OperationIdentity {
        OperationIdentity(owner: "test-owner", conversation: conversation, turn: turn,
                          actionBytes: Data(bytes.utf8))
    }
    private var playback: RecordingPlaybackSink!
    private var mapper: RecordingFingerprintMapper!
    private var contextState: CloudPlaybackContextState!
    private var analytics: RecordingAnalytics!
    private var voiceAnalytics: VoiceAnalytics!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        mapper = RecordingFingerprintMapper()
        contextState = CloudPlaybackContextState()
        analytics = RecordingAnalytics()
        voiceAnalytics = VoiceAnalytics(analytics: analytics)
        suiteName = "cloud_route_sink_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMixedStreamDispatchesSeekSpeaksTokensOnDone() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":1130000}}

            event: token
            data: {"text":"She"}

            event: token
            data: {"text":" is arguing."}

            event: done
            data: {"usage":{"input_tokens":10,"output_tokens":4}}

            """
        mapper.playbackSecondsForReference = [1130.0: 1200.0]
        playback.setPositionMs(500_000)

        let response = await makeSink(injectIdentity: false).routeToCloud(
            request: "What did she mean?",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-1")

        XCTAssertEqual(response.response, .silent, "cloud answers are played as audio, not spoken")
        XCTAssertTrue(playback.calls.contains(.pause))
        XCTAssertTrue(playback.calls.contains(.resume), "done must restore turn-owned auto-pause")
        XCTAssertEqual(playback.calls.filter { $0 == .seekTo(1200) }.count, 1)
        XCTAssertEqual(analytics.events.last?.0, "cloud_assistant_turn")
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "done")
        let snap = contextState.snapshot()
        XCTAssertEqual(snap.recentReferencePositions.last, 1_130_000)
        XCTAssertEqual(snap.previousReferencePositionMs, 500_000)
    }

    func testDoneResumesTurnOwnedAutoPause() async {
        self.pendingFixture =
            """
            event: token
            data: {"text":"Answer."}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """

        let response = await makeSink().routeToCloud(
            request: "summarize",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-2")

        XCTAssertEqual(response.response, .silent, "cloud answers are played as audio, not spoken")
        XCTAssertEqual(playback.calls.first, .pause)
        XCTAssertEqual(playback.calls.last, .resume)
        XCTAssertEqual(playback.calls.filter { $0 == .pause }.count, 1)
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1)
    }

    /// A turn must not start audio the user had stopped. With the host already
    /// paused the client takes no hold, so there is nothing for the turn's end
    /// to release.
    func testDoesNotPauseOrResumeWhenHostWasAlreadyPaused() async {
        self.pendingFixture =
            """
            event: token
            data: {"text":"Answer."}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        playback.setPlaying(false)

        let response = await makeSink().routeToCloud(
            request: "what was that about",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-3")

        XCTAssertEqual(response.response, .silent)
        XCTAssertFalse(playback.calls.contains(.pause), "the user's own pause is not ours to retake")
        XCTAssertFalse(playback.calls.contains(.resume), "the user asked for it to stop; the turn must not undo that")
    }

    /// The turn's hold must be released when the turn ends without speaking:
    /// a `done` with no audio restores the playback it stopped, so the user is
    /// left exactly as they were.
    func testTurnWithoutAudioRestoresTheHoldItTook() async {
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """

        _ = await makeSink().routeToCloud(request: "hi", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-4")

        XCTAssertEqual(playback.calls.filter { $0 == .pause }.count, 1, "the turn takes one hold")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1, "and releases it on done")
        XCTAssertEqual(playback.calls.last, .resume)
    }

    func testPlayQuoteAndStopQuoteRestorePosition() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":500000}}

            event: action
            data: {"tool":"playback","action":"stop_quote","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        mapper.playbackSecondsForReference = [500.0: 510.0]
        playback.setPositionMs(900_000)

        let response = await makeSink(injectIdentity: false).routeToCloud(
            request: "play that",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-5")

        XCTAssertEqual(response.response, .silent)
        XCTAssertTrue(playback.calls.contains(.seekTo(510)))
        XCTAssertTrue(playback.calls.contains(.seekTo(900)))
        XCTAssertTrue(playback.calls.contains(.resume))
        // The quote does not release the hold early: the server ducked playback
        // for the "play that" answer, and the turn's end is the release.
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1)
        XCTAssertEqual(playback.calls.last, .resume)
    }

    func testSeekRelativeExecutesAndCapturesPosition() async {
        self.pendingFixture =
            """
            event: action
            data:{"tool":"playback","action":"seek_relative","params":{"delta_seconds":15}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        playback.setPositionMs(120_000)

        // LEGACY CONTROL, stated explicitly: the fixture carries no identity fields and is
        // delivered verbatim, so this exercises the pre-v1 effect path rather than being promoted
        // into a v1 request that would demand a target precondition. No observer is needed —
        // target admission is a v1 concern and this frame never claims to be one.
        let sink = makeSink(injectIdentity: false)
        let response = await sink.routeToCloud(
            request: "forward 15 seconds",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-6")

        XCTAssertEqual(response.response, .silent)
        XCTAssertTrue(playback.calls.contains(.seekRelative(15, .forward)),
                      "the identified seek must run: \(playback.calls)")
        // Previous position must be captured so "go back to where I was" works.
        XCTAssertEqual(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count, 1)
    }

    func testSeekRelativeDirectionOnlyUsesForwardDefault() async {
        self.pendingFixture =
            """
            event: action
            data:{"tool":"playback","action":"seek_relative","params":{"direction":"backward"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        playback.setPositionMs(120_000)

        _ = await makeSink(injectIdentity: false).routeToCloud(
            request: "go back",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-7")

        // No delta manufactured — direction preserved as nil.
        XCTAssertTrue(playback.calls.contains(.seekRelative(nil, .backward)))
    }

    func testSeekRelativeNeitherDeltaNorDirectionUsesForwardDefault() async {
        self.pendingFixture =
            """
            event: action
            data:{"tool":"playback","action":"seek_relative","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        playback.setPositionMs(120_000)

        _ = await makeSink(injectIdentity: false).routeToCloud(
            request: "skip forward",
            tier: .free,
            context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-8")

        // Neither stated → (nil, FORWARD) so the sink applies its default interval.
        XCTAssertTrue(playback.calls.contains(.seekRelative(nil, .forward)))
    }

    func testUnknownActionIgnored() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"do_a_barrel_roll","params":{}}

            event: action
            data: {"tool":"bookmarks","action":"add","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """

        _ = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-9")
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0)
    }

    func testErrorClearsBufferRestoresPauseDoesNotRollbackSeek() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":100000}}

            event: token
            data: {"text":"partial"}

            event: error
            data: {"code":"rate_limited","message":"rate limited"}

            """
        mapper.playbackSecondsForReference = [100.0: 110.0]
        playback.setPositionMs(50_000)

        let response = await makeSink(injectIdentity: false).routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-10")

        // This case is about the ERROR PATH's buffer/seek rollback. The remote `message` is never
        // spoken (spec 961fab07) and `rate_limited` has no local template, so the user hears the
        // error earcon; the subject here is the buffer/seek/pause outcome below, not the wording.
        XCTAssertEqual(response.response, .earcon(.error))
        XCTAssertTrue(playback.calls.contains(.seekTo(110)))
        XCTAssertTrue(playback.calls.contains(.resume))
        XCTAssertEqual(analytics.events.last?.1["outcome"] as? String, "error")
    }

    /// The ordinary cloud seek form: position_seconds is SINK time and seeks directly, with
    /// no mapping involved. A mapper with no entries must not block it.
    func testOrdinarySeekToUsesSinkTimeDirectlyWithoutMapping() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"position_seconds":95}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // No mapping at all: the ordinary form must not depend on one.
        let sink = makeSink(injectIdentity: false)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-11")

        XCTAssertTrue(playback.calls.contains(.seekTo(95)))
        let unavailable = await MainActor.run { sink.unavailableReferenceSeek }
        XCTAssertNil(unavailable, "the ordinary form is not a reference seek")
    }

    /// Both forms at once is malformed: the request does not say which target governs.
    func testSeekToWithBothFormsIsRefused() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"position_seconds":95,"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink(injectIdentity: false)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-12")

        XCTAssertFalse(playback.calls.contains { if case .seekTo = $0 { return true }; return false })
        let rejection = await MainActor.run { sink.lastSeekRejection }
        XCTAssertEqual(rejection?.outcome, .refused)
        XCTAssertEqual(rejection?.reason, OperationReason.malformedSeekTarget)
    }

    /// Neither form is equally malformed: there is no default target to fall back to.
    func testSeekToWithNeitherFormIsRefused() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink(injectIdentity: false)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-13")

        XCTAssertFalse(playback.calls.contains { if case .seekTo = $0 { return true }; return false })
        let rejection = await MainActor.run { sink.lastSeekRejection }
        XCTAssertEqual(rejection?.reason, OperationReason.malformedSeekTarget)
    }

    /// A fractional position is not an integer position: it parses as neither form and is
    /// refused rather than truncated toward a value nobody asked for.
    func testSeekToWithFractionalPositionIsRefused() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"position_seconds":95.5}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink(injectIdentity: false)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-14")

        XCTAssertFalse(playback.calls.contains { if case .seekTo = $0 { return true }; return false })
        let rejection = await MainActor.run { sink.lastSeekRejection }
        XCTAssertEqual(rejection?.reason, OperationReason.malformedSeekTarget)
    }

    /// An unmapped reference target is NOT converted by assumption. Reference time is not
    /// playback time: falling back to the raw value seeks somewhere the server never asked for
    /// on a mapped episode, and nothing downstream can tell that apart from a correct seek. The
    /// operation is refused instead, and no position changes.
    func testUnmappedReferenceSeekIsRefusedAndDoesNotMove() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink(injectIdentity: false)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-15")

        XCTAssertFalse(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "an unmapped reference time must not become a playback position"
        )
        let unavailable = await MainActor.run { sink.unavailableReferenceSeek }
        XCTAssertEqual(unavailable?.outcome, .refused)
        XCTAssertEqual(unavailable?.reason, OperationReason.referenceMappingUnavailable)
    }

    /// The same gap through `play_quote`, which shares the conversion path.
    func testUnmappedReferencePlayQuoteIsRefusedAndDoesNotMove() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSink(injectIdentity: false)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-16")

        XCTAssertFalse(playback.calls.contains { if case .seekTo = $0 { return true }; return false })
        let unavailable = await MainActor.run { sink.unavailableReferenceSeek }
        XCTAssertEqual(unavailable?.reason, OperationReason.referenceMappingUnavailable)
    }

    // MARK: Seek-refusal surfacing (PR #49 review 4305981598)

    /// A recording consumer injected as the sink's result consumer. The wire contract
    /// (`app_operation_result`, rev da327e624) names this the production surface: a refusal the
    /// server can reason about must reach a consumer, not die in a stored field only tests read.
    private final class RecordingResultConsumer: CloudOperationResultConsuming {
        var consumed: [(result: OperationResult, context: String)] = []
        func consume(_ result: OperationResult, context: String) {
            consumed.append((result, context))
        }
    }

    /// Optional cancellation-insensitive park installed on the stub task BEFORE the client is
    /// constructed, so the producer's FIRST receive parks — no race with stream end.
    private var pendingProducerHold: HoldLatch?
    /// How many wires the sink actually dialled — the OWNERSHIP observable for request controls.
    private var clientCreationCount = 0
    /// Optional one-shot PRODUCTION-boundary park: armed onto the stub at construction; the sink
    /// installs it synchronously at the claim→effect seam via `effectEntered` (see
    /// `StubWebSocketTask.armReceiveHoldOnEntered`).
    private var pendingArmedReceiveHold: HoldLatch?
    /// Transport park installed at client creation (survives the whole turn) plus how many
    /// frames must be served before it engages.
    private var pendingDeclaredPark: HoldLatch?
    private var pendingDeclaredParkAfterFrames: Int?

    /// REQUEST OWNERSHIP (owner delta 3484cbc/5eca874, reviewer 724db1e8): while a dispatch for
    /// an utterance is genuinely HELD in flight, a duplicate invocation for the SAME utterance
    /// joins it — no second wire request is sent — and both callers observe the identical
    /// result once the held dispatch settles: the held-dispatch control. An INDEPENDENT
    /// utterance dispatches its own request concurrently.
    @MainActor
    func testDuplicateDispatchWhileOneIsHeldJoinsItAndIndependentUtterancesDispatchSeparately() async throws {
        let hold = HoldLatch()
        pendingProducerHold = hold
        let sink = makeSinkWithConsumer(RecordingResultConsumer())
        let clientBefore = clientCreationCount

        let shared = "utterance-shared"
        let duplicate = Task { await sink.routeToCloud(
            request: "same", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: shared) }
        // Wait until the owner is actually inside the held producer, then invoke the duplicate.
        try await Task.sleep(nanoseconds: 150_000_000)
        let joiner = Task { await sink.routeToCloud(
            request: "same", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: shared) }
        // An independent utterance must NOT be blocked by the held one.
        let independent = Task { await sink.routeToCloud(
            request: "other", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: "utterance-independent") }
        try await Task.sleep(nanoseconds: 150_000_000)

        hold.release()
        let first = await duplicate.value
        let joined = await joiner.value
        _ = await independent.value

        // The held dispatch is the OWNER: exactly one wire request was minted, and the joining
        // duplicate returned THAT dispatch's result rather than starting its own.
        XCTAssertEqual(
            joined, first,
            "a duplicate dispatch held in flight must join the SAME wire request and observe its result"
        )
        // Exactly TWO wires were dialled for the three invocations: one for the shared utterance
        // (joined by its duplicate) and one for the independent utterance.
        XCTAssertEqual(
            clientCreationCount - clientBefore, 2,
            "one wire per OWNED utterance: the shared duplicate joins, the independent dispatches"
        )
    }

    /// RETENTION BOUNDARY (reviewer 39beabc7): the sink's settled results are retained for the
    /// whole WINDOW — no cap. More than 16 settled utterances, then a RETAINED id is delivered
    /// again: it must be served from the retained result with NO new client, NO new admission
    /// and NO predecessor cancellation. An evicting cache would re-enter the owner path here.
    @MainActor
    func testRetainedSettledDispatchIsReplayedWithoutANewClientOrAdmission() async throws {
        let sink = makeSinkWithConsumer(RecordingResultConsumer())
        let clientBefore = clientCreationCount

        // 20 independent utterances settle — deliberately more than any 16-cap.
        for index in 0..<20 {
            _ = await sink.routeToCloud(
                request: "turn \(index)", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: nil, utteranceId: "utterance-\(index)"
            )
        }
        let clientAfterSettled = clientCreationCount
        XCTAssertEqual(clientAfterSettled - clientBefore, 20, "premise: 20 owns dialled 20 wires")

        // Re-deliver the FIRST (oldest) retained id: it must be a settled replay, not a new owner.
        let replayed = await sink.routeToCloud(
            request: "turn 0", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: "utterance-0"
        )
        XCTAssertEqual(
            clientCreationCount, clientAfterSettled,
            "a retained settled id is replayed with NO new client (no eviction-triggered re-dispatch)"
        )
        XCTAssertNotNil(replayed.response, "the retained result is returned")
    }

    /// HELD OWNER + JOINER ACROSS A WINDOW CLOSE (reviewer a2723c92): an owner is held in
    /// flight with a duplicate JOINER parked on it, then the window RETIRES (close) and a new
    /// window opens, all before the owner completes. The retirement must NOT discard the held
    /// joiner: releasing the old owner settles the JOINER with that owner's result, and the late
    /// owner's completion must NOT publish into the new window's map (the next dispatch for the
    /// SAME id in the new window is a fresh OWN, not a replay of the stale result).
    @MainActor
    func testHeldJoinerIsSettledByItsOwnerEvenAfterTheWindowRetires() async throws {
        let hold = HoldLatch()
        pendingProducerHold = hold
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)

        let shared = "utterance-held"
        let owner = Task { await sink.routeToCloud(
            request: "owner", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: shared) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let joiner = Task { await sink.routeToCloud(
            request: "duplicate", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: shared) }
        try await Task.sleep(nanoseconds: 150_000_000)

        // The window closes (old generation), then a NEW one opens — all while the owner is held.
        sink.retireRetainedDispatchesIfWindowChanged(to: nil)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin + 1)

        hold.release()
        let ownerResult = await owner.value
        let joinerResult = await joiner.value
        XCTAssertEqual(
            joinerResult, ownerResult,
            "the held joiner is settled by ITS owner even though the window retired mid-flight"
        )
        // The late owner must NOT have published into the NEW window: the SAME utterance id in
        // the new window is a FRESH dispatch (a new owner), not a replay of the stale result —
        // it must NOT return the stale owner's result. The new window is a live origin again.
        manager.registerLiveOrigin(cloudTestOrigin)
        let clientsBefore = clientCreationCount
        _ = await sink.routeToCloud(
            request: "new window turn", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared
        )
        XCTAssertGreaterThan(
            clientCreationCount, clientsBefore,
            "the fresh dispatch DIALED (a new client) rather than replaying the stale result — "
                + "a retained stale result would return before any client is minted"
        )
    }

    /// THE EXACT BOUNDARY (reviewer b2c09394). Owner A obtains its ownership token, then is held
    /// BEFORE its dispatch entry. Duplicate B arrives while A is held, and the WINDOW CHANGES
    /// (a real production transition: the live origin moves and the sink retires) before A is
    /// released. Requirements asserted:
    ///   - exactly ONE owner's immutable request reaches the wire (B never starts A's turn);
    ///   - B is refused/joined, never admitted as a second owner;
    ///   - the stale A does not admit a turn after the window changed; and
    ///   - every waiter is settled (nothing is abandoned).
    @MainActor
    func testOwnerHeldBetweenClaimAndDispatchIsNotPreemptedByADuplicateAcrossAWindowChange() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin)

        let shared = "utterance-race"
        // A obtains its token and is held BEFORE dispatch entry.
        let aOwnership = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        XCTAssertTrue(aOwnership.ownsDispatch, "A's admission owns the dispatch")

        // B arrives while A holds the token but has not entered dispatch: it must NOT own.
        let bOwnership = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        XCTAssertFalse(bOwnership.ownsDispatch, "a duplicate never obtains ownership of A's turn")
        if case .join = bOwnership {} else { XCTFail("B must JOIN the held owner, got \(bOwnership)") }

        // The window CHANGES before A is released: the live origin moves and the sink retires.
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin + 1)

        // A NEW-window caller for the SAME utterance id dispatches fresh and reaches the wire,
        // creating a NEW record under the same id while A's stale token is still outstanding.
        let clientsBefore = clientCreationCount
        _ = await sink.routeToCloud(
            request: "new window", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin + 1, selection: nil, utteranceId: shared
        )
        XCTAssertGreaterThan(clientCreationCount, clientsBefore, "the new window dispatches freshly")
        let freshInstance = sink.recordInstanceForTesting(utteranceId: shared)
        XCTAssertNotNil(freshInstance, "the new window owns its own record")

        // A NOW re-enters with its STALE token, while a DIFFERENT record (the new window's) owns
        // this utterance id. A must NOT run its request: the INSTANCE fence is what separates the
        // two owners. Observable at the sink boundary — the stale owner never mints a wire client.
        let wiresBeforeStale = sink.wireDispatchCountForTesting
        _ = await sink.routeToCloud(
            request: "owner request", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared, ownership: aOwnership
        )
        XCTAssertEqual(
            sink.wireDispatchCountForTesting, wiresBeforeStale,
            "the stale owner did not start a wire turn against the new window's record"
        )
        // The NEW window's record is untouched by the stale owner: a duplicate arriving now must
        // observe the NEW window's OWN result, not the stale owner's refusal. (Without the
        // instance fence the stale token would be accepted against THIS record and publish its
        // refusal into it — binding the wrong caller to the wrong owner.)
        XCTAssertEqual(
            sink.recordInstanceForTesting(utteranceId: shared), freshInstance,
            "the stale owner did not take over the new window's record"
        )
        let duplicate = await sink.routeToCloud(
            request: "duplicate in new window", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin + 1, selection: nil, utteranceId: shared
        )
        XCTAssertNotEqual(
            duplicate.outcome, .refused,
            "a duplicate in the new window observes the NEW window's outcome, not the stale owner's refusal"
        )
    }

    /// JOINER BOUND TO ITS OWN ADMISSION ACROSS A REAL CLOSE/REOPEN (reviewer 8501bd91). A joiner
    /// obtains `.join(token)` for owner A, PAUSES before dispatch, the window retires and the
    /// successor reuses the SAME utterance id, then the joiner resumes. It must resolve against
    /// COHERENT ADMISSION with an EXPLICIT INTERLEAVING BARRIER (review 5fa6e007): the admission
    /// is paused INSIDE the coherent block, before its liveness read; AT THAT MOMENT — mid-decision
    /// — the window moves and the origin retires. The resumed decision must observe the retirement
    /// and REFUSE. A pre-block snapshot implementation fails this control: its cached liveness
    /// would still admit. The discriminator is the admission outcome, not a timeout, and the whole
    /// retirement happens synchronously inside the barrier (no cross-queue hop, no deadlock).
    @MainActor
    func testAnAdmissionPausedMidDecisionObservesAMidDecisionRetirementAndRefuses() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        manager.registerLiveOrigin(cloudTestOrigin)

        var retiredMidDecision = false
        sink.admissionInterleavingBarrierForTesting = { [weak manager] in
            guard let manager, !retiredMidDecision else { return }
            retiredMidDecision = true
            // Mid-decision window move: the origin the parked admission is about to test is
            // retired right here, between block entry and the decision's own read.
            manager.registerLiveOrigin(cloudTestOrigin + 1)
            sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin + 1)
        }

        let admission = Task.detached { @MainActor in
            sink.beginDispatch(utteranceId: "utterance-barrier-race", origin: cloudTestOrigin)
        }
        let disposition = await admission.value
        sink.admissionInterleavingBarrierForTesting = nil
        XCTAssertTrue(retiredMidDecision, "the barrier must have executed mid-decision")
        XCTAssertTrue(disposition.isRefused,
                      "an admission whose origin retired mid-decision must refuse — a pre-block snapshot would admit")
    }



    /// COHERENT ADMISSION (review 086c0172): a retirement that lands between a pre-lock snapshot
    /// and publication must not admit the stale origin. `beginDispatch` now decides and publishes
    /// in ONE main-queue block, so a retirement preceding the block is OBSERVED by the decision:
    /// an origin retired before admission runs is refused even though an earlier read of the live
    /// origin (from any thread) might have seen it live.
    @MainActor
    func testAnOriginRetiredBeforeAdmissionRunsIsRefusedByTheCoherentDecision() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        let retiredOrigin = cloudTestOrigin
        manager.registerLiveOrigin(cloudTestOrigin + 1)

        // The window has MOVED: the old origin is no longer live and this turn holds no admitted
        // work under it. beginDispatch must refuse — the coherent main-queue decision sees the
        // retirement because it reads state INSIDE the decision block, never from a stale
        // pre-lock snapshot.
        let disposition = sink.beginDispatch(utteranceId: "utterance-retired-before-admission", origin: retiredOrigin)
        XCTAssertTrue(disposition.isRefused, "an origin retired before the admission block runs is refused, got \(disposition)")
    }

    /// ADMISSION ENTERED FROM A DETACHED TASK (review 086c0172/47328768/7443c3ea). The sink class
    /// is `@MainActor`-annotated, so its `routeToCloud` witness is MAIN-ISOLATED: a detached caller
    /// suspends and the body runs on main. There is no off-main admission branch to exercise, and
    /// this control does not claim one. What it verifies is what a remote caller sees: entering from
    /// a detached task still owns a fresh dispatch that completes against the stub consumer and
    /// publishes a record, and a retired-origin admission made the same way is refused. Review
    /// 7443c3ea: the second step calls `beginDispatch` directly (main-isolated) — this is the
    /// coherent-decision control, labelled as such.
    @MainActor
    func testADetachedCallerOwnsAFreshDispatchAndARetiredOriginAdmissionIsRefused() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        manager.registerLiveOrigin(cloudTestOrigin)

        // 1. A genuinely nonisolated task enters through the NONISOLATED witness (the concrete
        //    type's witness — not the @MainActor-concrete convenience) with a fresh utterance; the
        //    dispatch must complete (the stub consumer settles it) and leave an owned record.
        self.pendingFixture =
            """
            event: done
            data: {}

            """
        let context = sampleContext()
        let completed = await Task.detached { () -> Bool in
            let result = await sink.routeToCloud(
                request: "witness", tier: .free, context: context,
                origin: cloudTestOrigin, selection: nil, utteranceId: "utterance-witness"
            )
            return result.outcome == .completed
        }.value
        XCTAssertTrue(completed, "the witness-owned dispatch completes against the stub consumer")
        let witnessInstance = sink.recordInstanceForTesting(utteranceId: "utterance-witness")
        XCTAssertNotNil(witnessInstance, "the witness admission published its record")

        // 2. The window moves; an admission against the RETIRED origin is refused by the coherent
        //    decision (called on main, where that decision lives).
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin + 1)
        let refused: CloudDispatchOwnership = await Task.detached { @MainActor in
            sink.beginDispatch(utteranceId: "utterance-witness-2", origin: cloudTestOrigin)
        }.value
        XCTAssertTrue(refused.isRefused, "a witness admission against a retired origin is refused, got \(refused)")
    }

    /// ITS OWN admitted record, never the successor's — the token carries the instance precisely
    /// so a reused id cannot be mistaken for the same owner.
    @MainActor
    func testAHeldJoinerResolvedAgainstItsOwnAdmissionNotASuccessorThatReusedTheId() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin)

        let shared = "utterance-joiner"
        let aOwnership = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        XCTAssertTrue(aOwnership.ownsDispatch, "A owns the first window's dispatch")

        // The joiner admits against A and (in this control) holds its token before dispatch.
        let joinAdmission = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        guard case let .join(joinToken) = joinAdmission else {
            XCTFail("the duplicate must JOIN the held owner, got \(joinAdmission)")
            return
        }

        // The window CLOSES and REOPENS; a successor for the SAME id gets its OWN record.
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin + 1)
        _ = await sink.routeToCloud(
            request: "successor", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin + 1, selection: nil, utteranceId: shared
        )
        let successorInstance = sink.recordInstanceForTesting(utteranceId: shared)
        XCTAssertNotEqual(
            successorInstance, joinToken.instance,
            "premise: the successor owns a DIFFERENT record than the joiner was admitted against"
        )

        // A completes its (now stale) turn. Its OWN record settles with a DISTINCT marker, so the
        // joiner's result cannot be mistaken for the successor's (or for a generic refusal).
        let ownerSettlement = await sink.routeToCloud(
            request: "owner request", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared, ownership: aOwnership
        )
        // The owner's settlement is recorded ON ITS OWN record instance — not on the successor's.
        XCTAssertEqual(
            sink.tokenRecordInstanceForTesting(token: aOwnershipToken(aOwnership)), joinToken.instance,
            "premise: the owner and the joiner are bound to the SAME record"
        )
        XCTAssertEqual(
            sink.terminalResultForTesting(token: joinToken)?.outcome, ownerSettlement.outcome,
            "the ORIGINAL record carries the owner's settlement, not a successor's result"
        )
        XCTAssertEqual(
            sink.recordInstanceForTesting(utteranceId: shared), successorInstance,
            "the successor's record is untouched by the stale owner's settlement"
        )

        // The joiner resolves through the PRODUCTION route entry with its OLD admission, and must
        // observe its own owner's settlement.
        let joined = await sink.routeToCloud(
            request: "joiner resumes", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared, ownership: joinAdmission
        )
        XCTAssertEqual(
            joined.outcome, ownerSettlement.outcome,
            "the held joiner sees ITS OWN owner's settlement, never the successor's result"
        )
    }

    /// NO IMMORTAL SECOND MAP (reviewer be89233d) AND NO PRETENDED REFCOUNT (reviewer f3492082).
    /// (a) A completed utterance is DETACHED from the live map on a window change — not retained
    /// forever. (b) LIFETIME IS ARC: once the retiring detaches the map entry and EVERY reference
    /// to the record is gone, the record is DEALLOCATED — proved with a weak handle, not inferred
    /// from a counter. The `admitAndResolve` helper guarantees its token locals are dead before the
    /// assertion (Swift may keep frame locals alive to scope end, so the tokens live in a callee).
    @MainActor
    func testCompletedRecordIsReleasedOnceItsAdmittedCallersResolve() async throws {
        let manager = testConversationManager()
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager)
        sink.retireRetainedDispatchesIfWindowChanged(to: cloudTestOrigin)

        let shared = "utterance-release"
        // The helper admits an owner AND a joiner, drives both through the production route entry,
        // takes a weak handle, then RETURNS — so no token local of ours holds the record.
        let weakRecord = try await admitResolveAndAbandon(shared: shared, sink: sink, manager: manager)
        XCTAssertNotNil(weakRecord(), "premise: the record is still reachable from the live map")

        // The window change DETACHES the live map entry (the record is not retained forever), and
        // with no reference left it is DEALLOCATED.
        sink.retireRetainedDispatchesIfWindowChanged(to: nil)
        XCTAssertNil(
            sink.recordInstanceForTesting(utteranceId: shared),
            "a completed utterance is detached on the window change, not retained forever"
        )
        XCTAssertNil(
            weakRecord(),
            "the record is deallocated once the map entry and every caller's reference are gone"
        )
    }

    /// Admits an owner and a joiner for `shared`, resolves BOTH through the production route entry,
    /// and returns a weak handle to the record. Its token locals die when it returns.
    @MainActor
    private func admitResolveAndAbandon(
        shared: String, sink: CloudRouteSink, manager: CloudConversationManager
    ) async throws -> () -> CloudRouteSink.UtteranceRecord? {
        let owner = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        guard case let .owner(ownerToken) = owner else {
            XCTFail("admission must OWN the first dispatch; got \(owner)")
            return { nil }
        }
        let join = sink.beginDispatch(utteranceId: shared, origin: cloudTestOrigin)
        guard case let .join(joinToken) = join else {
            XCTFail("the duplicate must JOIN a held owner; got \(join)")
            return { nil }
        }
        let weakRecord = sink.weakRecordForTesting(token: ownerToken)

        _ = await sink.routeToCloud(
            request: "owner", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared, ownership: owner
        )
        _ = await sink.routeToCloud(
            request: "joiner", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: nil, utteranceId: shared,
            ownership: .join(joinToken)
        )
        XCTAssertNotNil(weakRecord(), "still held while the admitted tokens are alive")
        return weakRecord
    }

    private func aOwnershipToken(_ ownership: CloudDispatchOwnership) -> CloudDispatchOwnership.DispatchToken {
        if case let .owner(token) = ownership { return token }
        fatalError("expected an owner disposition")
    }

    /// The episode identity every identified playback fixture targets. The wire requires an
    /// episode-relative action to name its target, and requires that target to be the CURRENT one,
    /// so a fixture and the sink's live target must agree by construction.
    static let testEpisodeId = "ep-task67"

    /// The account these controls' operations are journaled under. One fixture for BOTH halves —
    /// credential and account — so the owner can only ever be the one that supplied the
    /// authenticate frame.
    static func pairedTestProvider() -> StubTokenProvider {
        StubTokenProvider(token: "test-credential", accountId: "test-owner")
    }

    /// Explicit fixture manifest for a test's OWN action(s). Tests exercising identified v1
    /// operations declare exactly what they test — an absent manifest refuses, per the
    /// declaration contract, and the shared helper never advertises by default.
    private func fixtureSupport(_ operations: String...) -> CloudAppOperationSupport? {
        CloudAppOperationSupport(operations: operations)
    }

    private func makeSinkWithConsumer(_ consumer: RecordingResultConsumer, conversationManager: CloudConversationManager? = nil, operationJournal: OperationJournal? = nil, audioPayloads: [Data] = [], episodeAvailable: (() -> Bool)? = nil, playbackManager: PlaybackManager? = nil, currentEpisodeId: @escaping () -> String? = { CloudRouteSinkTests.testEpisodeId }, appOperationSupport: CloudAppOperationSupport? = nil) -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                // EACH TURN TAKES ITS OWN FIXTURE AND ITS OWN HOLD, AT THE MOMENT ITS CLIENT IS
                // BUILT. Reading them once outside this closure wired the FIRST client only: a
                // second turn's hold and fixture were dropped on the floor, so the second turn
                // could never be parked at all.
                let producerHold = self.pendingProducerHold
                self.pendingProducerHold = nil
                let armedHold = self.pendingArmedReceiveHold
                self.pendingArmedReceiveHold = nil
                let declaredPark = self.pendingDeclaredPark
                self.pendingDeclaredPark = nil
                let parkAfterFrames = self.pendingDeclaredParkAfterFrames
                self.pendingDeclaredParkAfterFrames = nil
                let fixture = Self.injectOperationIdentity(self.pendingFixture ?? "")
                self.pendingFixture = nil
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl, fixture: fixture, audioPayloads: audioPayloads,
                    prepareTask: { task in
                        producerHold.map(task.holdUntilReleased)
                        if let armedHold { task.armReceiveHoldOnEntered = armedHold }
                        // Installed at CREATION so the park exists before the first frame is
                        // served, then engages only after the scripted frames ahead of it.
                        task.armedReceivePark = declaredPark
                        task.declaredParkAfterFrames = parkAfterFrames
                    },
                    // The authenticated account these operations are journaled under. The account
                    // and the credential are ONE fixture travelling through the REAL acquisition,
                    // so the owner recorded is necessarily the one that supplied the authenticate
                    // frame — never a session re-attached to the socket afterwards.
                    tokenProvider: Self.pairedTestProvider()
                )
                // MEASURED production parking point: the producer parks at the frame seam, not at
                // a later receive (the stub only receives twice for this fixture). After the
                // action frame (frame 2) the producer parks here, so the transport is genuinely
                // held when cancellation lands.
                // Production retirement seam: when the stub socket is cancelled, wake the
                // parked receive from the SAME cancellation — no polling, no race window.
                built.task.retiredParkNotifier = { declaredPark?.notifyRetired() }
                // MEASURED production parking point: the producer parks at the frame seam, not
                // at a later receive (the stub only receives twice for this fixture). After the
                // action frame (frame 2) the producer parks here, so the transport is genuinely
                // held when cancellation lands.
                built.client.onFrameReceived = { [weak task = built.task] in
                    guard let task, task.framesServedForPark >= (parkAfterFrames ?? 0) else { return }
                    task.declaredParkDidPark = true
                    Task { await declaredPark?.wait(untilRetired: { task.isCancelledSocket }) }
                }
                self.capturedTask = built.task
                // Capture the CLIENT for this turn too: a prior turn's result must travel on its
                // OWN transport, and proving that needs that turn's client — not whichever one
                // the sink used last.
                self.capturedClient = built.client
                self.clientCreationCount += 1
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackManager: playbackManager,
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            episodeAvailable: episodeAvailable,
            currentEpisodeIdProvider: currentEpisodeId,
            cloudPlaybackContextState: CloudPlaybackContextState(),
            analytics: VoiceAnalytics(analytics: analytics),
            operationResultConsumer: consumer,
            // A journal is REQUIRED for an identified operation to run at all (no journal = no
            // effect), so the default fixture supplies a working in-memory one. A case that wants
            // to observe durable state passes its own.
            operationJournal: operationJournal ?? OperationJournal(store: InMemoryOperationRecordStore()),
            conversationManager: conversationManager ?? testConversationManager(),
            appOperationSupportProvider: { appOperationSupport }
        )
    }

    /// An unmapped reference seek must reach the injected consumer with the refused outcome and
    /// the mapping-unavailable reason — the production read of the outcome that previously only
    /// landed in a test-only stored field.
    func testUnmappedReferenceSeekReachesTheOperationResultConsumer() async {
        // Same reasoning as the malformed-seek control above: an identified request is required
        // for there to be a result to consume at all, and the target must be stated.
        let operationId = "8a1f6c42-7b3d-4e09-a257-6d9e4b0c8315"
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"reference_position_ms":200000},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer, appOperationSupport: fixtureSupport("playback.seek_to"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-17")

        let refusals = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refusals.count, 1, "exactly one refused app_operation_result for one unmapped seek; got \(consumer.consumed)")
        XCTAssertEqual(refusals.first?.result.reason, OperationReason.referenceMappingUnavailable)
    }

    /// A malformed seek (BOTH target forms supplied) is answered on the turn's own socket with a
    /// TYPED refusal, and does not move playback.
    ///
    /// RENAMED from `…ReachesTheOperationResultConsumer`: `reportResult` sends through the retained
    /// route and never touches `RecordingResultConsumer`, so the consumer was the wrong observation
    /// surface and the control could not have passed however correct the product was.
    func testMalformedSeekIsRefusedWithTypedReasonOnTheTurnSocket() async {
        // EXPLICIT v1 IDENTITY: this control asserts a TYPED refusal (`malformed_seek_target`) on
        // the result path, which only exists for an identified operation. Relying on the injector
        // to add the identity would leave the precondition unstated as well, and the frame would
        // refuse `invalid_request` before the malformation was ever judged.
        let operationId = "4d2b8e17-3c95-4a60-b7f1-8e5c0d9a2631"
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":95,"reference_position_ms":200000},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        playback.setPositionMs(0)
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), appOperationSupport: fixtureSupport("playback.seek_to"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-18")

        // OBSERVATION SURFACE = THE ORIGINAL TURN'S SENT RESULT FRAME. `reportResult` sends through
        // the retained route and never calls `RecordingResultConsumer`, so asserting on the consumer
        // asserted on a surface this path does not use. The socket is where the refusal actually
        // goes.
        //
        // EVIDENCE LIMIT: a frame on the transport proves SUBMISSION, not server receipt.
        let frames = await Self.resultFrames(on: capturedTask)
        XCTAssertEqual(frames.count, 1, "exactly one result frame for one refused operation; got \(frames)")
        XCTAssertEqual(frames.first?["operation_id"] as? String, operationId)
        XCTAssertEqual(frames.first?["outcome"] as? String, "refused")
        XCTAssertEqual(frames.first?["reason"] as? String, OperationReason.malformedSeekTarget)
        // The refusal must not have moved playback.
        XCTAssertFalse(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "a malformed seek must not become a playback position; calls: \(playback.calls)"
        )
    }

    /// THROUGH-TRANSPORT control: an IDENTIFIED unmapped reference seek must send the
    /// `app_operation_result` frame on the turn's own captured socket, correlated to the
    /// server-issued operation id, with the refused outcome and mapping-unavailable reason.
    func testIdentifiedUnmappedSeekSendsRefusedResultFrameThroughTheSocket() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"acb9d6cc-0b7f-4710-ab0c-76e7f5f0fa64","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"reference_position_ms":200000},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // MATCHING LIVE OBSERVER: the frame states its target, so the sink must be able to confirm
        // it, or the refusal would be `stale_precondition` (a different fact) instead of the
        // mapping-unavailable reason this control exists to assert.
        let sink = makeSink(currentEpisodeId: { Self.testEpisodeId },
                            appOperationSupport: fixtureSupport("playback.seek_to"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-19")

        XCTAssertFalse(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "an unmapped reference time must not become a playback position"
        )
        let deadline = Date().addingTimeInterval(5)
        var resultFrame: [String: Any]?
        while Date() < deadline && resultFrame == nil {
            resultFrame = await MainActor.run {
                capturedTask?.sentTextFrames.compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }.first { ($0["type"] as? String) == "app_operation_result" }
            }
            if resultFrame == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let frame = try XCTUnwrap(resultFrame, "the refused outcome rode the turn socket")
        XCTAssertEqual(frame["operation_id"] as? String, "acb9d6cc-0b7f-4710-ab0c-76e7f5f0fa64")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.referenceMappingUnavailable)
    }

    /// THROUGH-TRANSPORT control: an identified MALFORMED seek sends the refused frame with the
    /// malformed-target reason.
    ///
    /// The malformation used is `position_seconds: null` — PRESENT (so action admission passes)
    /// but not a number, which is exactly a request the sink must refuse in its own terms rather
    /// than execute with a guessed target.
    ///
    /// CORRECTION: an earlier version of this comment claimed that supplying BOTH target forms
    /// would be dropped by the parser and never reach the sink. The measured trace contradicts
    /// that — the both-forms fixture reaches `executeCloudMutation` with
    /// `violation=ambiguousSeekTarget` and is refused there. The wrong-type fixture is kept
    /// regardless, because it exercises a DIFFERENT violation (`wrongType`) on the same path.
    func testIdentifiedMalformedSeekSendsRefusedResultFrameThroughTheSocket() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"66de3931-3507-47be-a2a2-7bb01e199fa6","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":null,"reference_position_ms":200000},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        playback.setPositionMs(0)
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), appOperationSupport: fixtureSupport("playback.seek_to"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-20")

        // OBSERVATION SURFACE = THE ORIGINAL TURN'S SENT RESULT FRAME, and EXACTLY ONE of them:
        // a duplicate send is a defect, so `first` would hide it.
        //
        // EVIDENCE LIMIT: a frame on the transport proves SUBMISSION, not server receipt.
        let frames = await Self.resultFrames(on: capturedTask)
        XCTAssertEqual(frames.count, 1, "exactly one result frame for one refused operation; got \(frames)")
        XCTAssertEqual(frames.first?["operation_id"] as? String, "66de3931-3507-47be-a2a2-7bb01e199fa6")
        XCTAssertEqual(frames.first?["outcome"] as? String, "refused")
        XCTAssertEqual(frames.first?["reason"] as? String, OperationReason.malformedSeekTarget)
        // The refusal must not have moved playback.
        XCTAssertFalse(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "a malformed seek must not become a playback position; calls: \(playback.calls)"
        )
    }

    /// LEGACY refusal case (explicit, per the runtime gate): an identity-less cloud mutation
    /// does NOT execute and sends NO result frame (there is no server identity to tie it to);
    /// the refusal is recorded for the executor surface.
    /// THE ESTABLISHED LEGACY BEHAVIOUR, asserted directly so the compatibility ruling has a
    /// control of its own.
    ///
    /// A frame with NEITHER identity field is pre-v1 playback: it executes, produces no journal
    /// record, and sends no result frame. It is deliberately NOT subject to v1 required
    /// preconditions — this fixture states none, and requiring `episode_id` here would break the
    /// compatibility path the ruling protects.
    func testLegacyIdentitylessFrameExecutesWithoutIdentityOrResultFrame() async throws {
        // THE FIXTURE MUST REACH THE SINK UNREWRITTEN. `makeSinkWithConsumer` injects the identity
        // pair into any action line carrying `"tool"`, so the previous revision's "identityless"
        // frame was delivered WITH `operation_id`/`capability_version` and took the v1 gate, not
        // the legacy path — the control was asserting about a frame it never sent. The
        // `LEGACY_ACTION` marker is the injector's documented opt-out.
        self.pendingFixture = """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"position_seconds":95},"note":"LEGACY_ACTION"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // What actually goes out: the post-injection fixture, which for this control must equal
        // the literal above.
        let deliveredFixture = Self.injectOperationIdentity(self.pendingFixture ?? "")
        playback.setPositionMs(0)
        let journal = OperationJournal(store: InMemoryOperationRecordStore())
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal, appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-22")

        // PREMISE FIRST: the action line the sink RECEIVED carries NEITHER identity key. Checking
        // the intended fixture instead of the delivered one is what hid the defect.
        let actionLine = try XCTUnwrap(
            deliveredFixture.split(separator: "\n")
                .first { $0.contains("\"action\"") && $0.contains("playback") },
            "the delivered fixture carries an action line")
        XCTAssertFalse(actionLine.contains("operation_id"),
                       "the delivered frame must have NO operation_id: \(actionLine)")
        XCTAssertFalse(actionLine.contains("capability_version"),
                       "the delivered frame must have NO capability_version: \(actionLine)")

        XCTAssertTrue(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "a frame with neither identity field is pre-v1 playback and still executes; calls: \(playback.calls)"
        )
        // Hoisted: `XCTAssertFalse`'s autoclosure is not async, so the awaited value is read first.
        let legacySentFrames = await MainActor.run { capturedTask?.sentTextFrames ?? [] }
        XCTAssertFalse(
            legacySentFrames.contains { $0.contains("app_operation_result") },
            "legacy playback has no operation to settle, so no result frame is sent"
        )
    }

    /// "MALFORMED v1 NEVER FALLS BACK" — the subject is an INCOMPLETE IDENTITY-BEARING v1 frame,
    /// not an identity-less one.
    ///
    /// The earlier version of this control sent no identity at all and asserted a refusal. That
    /// contradicted the compatibility ruling: a frame with neither field is the established
    /// pre-v1 playback path and is supposed to run. Here the frame DECLARES v1 by sending
    /// `operation_id` and omitting `capability_version`, so it is an app-operation attempt that
    /// cannot be admitted — it must refuse and never reach legacy playback.
    func testIncompleteIdentityBearingV1FrameRefusesWithoutExecutingAndWithoutALegacyEffect() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"3f8b2d61-4c07-4a93-9e15-7b02d8c64af0","tool":"playback","action":"seek_to","params":{"position_seconds":95}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-21")

        XCTAssertFalse(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "an incomplete v1 identity must not execute, by the v1 gate or as legacy playback"
        )
        // The parser drops a malformed identity entirely (`classify` → `.malformedIdentity` → no
        // event), so zero effects is the whole claim here; there is no consumed result to assert.
        XCTAssertTrue(consumer.consumed.isEmpty, "no result is consumed for a frame the server never admitted")
    }

    /// OBSERVED PAUSE — TRUE→FALSE TRANSITION (voice-intents.md @ 818c8f75): the engine is
    /// playing, the pause stops it, and the single fresh observation reads `false`, which is
    /// both the success gate AND the settled wire state.
    func testCloudPauseOnAPlayingEngineThatStopsSucceedsWithTheObservedState() async throws {
        playback.setPlaying(true)
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"41a8e5c2-77d3-4b09-a2f6-8c3e1d5b9a04","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), appOperationSupport: fixtureSupport("playback.pause"))
        // The ACTION boundary is the pre-effect gate: the answer-hold pause (legacy, contract-
        // preserved) has already run by then, so the engine is re-established to PLAYING and the
        // recorded calls are cleared there — what this control counts is the identified pause
        // alone, not the hold pause that precedes it.
        await MainActor.run {
            sink.effectGate = { _ in
                self.playback.setPlaying(true)
                self.playback.clearCalls()
            }
        }
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-pause-transition")
        let frame = try await awaitResultFrame(operationId: "41a8e5c2-77d3-4b09-a2f6-8c3e1d5b9a04")
        XCTAssertEqual(frame["outcome"] as? String, "succeeded")
        let state = try XCTUnwrap(frame["state"] as? [String: Any], "success carries the captured observation")
        XCTAssertEqual(state["playing"] as? Bool, false,
                       "the settled state IS the observation that gated success")
        XCTAssertEqual(playback.calls.filter { if case .pause = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(playback.observedPlayingReads, 1,
                       "classification and settlement must come from ONE post-pause observation")
    }

    /// OBSERVED PAUSE — ALREADY-PAUSED (voice-intents.md @ 818c8f75): an engine observed `false`
    /// before and after the pause satisfies the idempotent operation.
    func testCloudPauseOnAnAlreadyPausedEngineSucceedsWithAnObservedNotPlayingState() async throws {
        playback.setPlaying(false)
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"5f0d9a34-2b61-4e8d-a5c7-9e1f3b8d0a52","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-pause-idempotent")
        let frame = try await awaitResultFrame(operationId: "5f0d9a34-2b61-4e8d-a5c7-9e1f3b8d0a52")
        XCTAssertEqual(frame["outcome"] as? String, "succeeded",
                       "an already-paused engine is an idempotent success, not a refusal")
        let state = try XCTUnwrap(frame["state"] as? [String: Any])
        XCTAssertEqual(state["playing"] as? Bool, false)
        XCTAssertEqual(playback.calls.filter { if case .pause = $0 { return true }; return false }.count, 1)
    }

    /// OBSERVED PAUSE — STILL PLAYING (voice-intents.md @ 818c8f75): the pause sink completed
    /// but the fresh observation still reads `true` (a real engine can fail to stop). The
    /// result is `failed` with reason `pause_not_observed` — a FAILED pause, not a refusal —
    /// and carries NO state. The legacy VoiceResponse earcon behaviour of the pause itself is
    /// untouched.
    func testCloudPauseStillPlayingAfterTheSinkReportsFailedWithNoState() async throws {
        playback.setPlaying(true)
        playback.clearCalls()
        defer { playback.setSimulatesFailedPause(false) }
        self.pendingFixture = """
            event: action
            data: {"operation_id":"9c4e7b18-83a2-4f60-b1d4-2a7e5c9f6b31","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-not-observed-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal, appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        // Action boundary (pre-effect gate): the engine is PLAYING and the failed-pause knob is
        // armed HERE, after the legacy hold pause has run, and calls are cleared — the counted
        // pause is the identified user pause, whose engine genuinely fails to stop.
        await MainActor.run {
            sink.effectGate = { _ in
                self.playback.setPlaying(true)
                self.playback.setSimulatesFailedPause(true)
                self.playback.clearCalls()
            }
        }
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-pause-unobserved")
        let frame = try await awaitResultFrame(operationId: "9c4e7b18-83a2-4f60-b1d4-2a7e5c9f6b31")
        XCTAssertEqual(frame["outcome"] as? String, "failed",
                       "still playing after the pause is a FAILED pause, not a refusal and not a success")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.pauseNotObserved)
        XCTAssertNil(frame["state"],
                     "a non-success result carries no state — nothing was observed to report")
        XCTAssertEqual(playback.calls.filter { if case .pause = $0 { return true }; return false }.count, 1,
                       "the mutation was attempted exactly once")
    }

    /// OBSERVED PAUSE — UNAVAILABLE (voice-intents.md @ 818c8f75): no current engine reading
    /// exists (a missing engine — `PlaybackManager.isPlaying` collapses this into `false`,
    /// which the tri-state `observedPlaying` must not). The result is `unknown` with reason
    /// `playback_state_unavailable` and carries NO state: it must NOT report a success built
    /// from the collapsed reading.
    func testCloudPauseWithNoEngineObservationReportsUnknownWithNoState() async throws {
        playback.setPlaying(true)
        playback.clearCalls()
        defer { playback.setSimulateUnavailableObservation(false) }
        self.pendingFixture = """
            event: action
            data: {"operation_id":"c7b2f094-5e18-4d73-9a06-b4f8e2c1d7a3","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        // Action boundary (pre-effect gate): the engine's intended underlying reading is
        // established FALSE (a paused engine exists), and only THEN the observation is made
        // UNAVAILABLE — unavailable is not the same fact as observed-paused, and this order is
        // what the arm distinguishes. Calls are cleared so only the identified pause counts.
        await MainActor.run {
            sink.effectGate = { _ in
                self.playback.setPlaying(false)
                self.playback.setSimulateUnavailableObservation(true)
                self.playback.clearCalls()
            }
        }
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-pause-unavailable")
        let frame = try await awaitResultFrame(operationId: "c7b2f094-5e18-4d73-9a06-b4f8e2c1d7a3")
        XCTAssertEqual(frame["outcome"] as? String, "unknown",
                       "an unobservable engine is unknown, never a success from a collapsed reading")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.playbackStateUnavailable)
        XCTAssertNil(frame["state"], "a non-success result carries no state")
        XCTAssertEqual(playback.calls.filter { if case .pause = $0 { return true }; return false }.count, 1)
    }

    /// CROSS-TURN CONFLICTING ID (cloud-assistant.md @ bf5fb219): an operation id is
    /// turn-bound. The same id arriving in a LATER turn is a different operation — refined from
    /// the earlier turn's admission — so it is refused before any effect and never resolved
    /// against the earlier turn's record. What must NOT happen is the dangerous middle: executing
    /// a later turn's action under an identity the journal already holds.
    func testSameOperationIdInALaterTurnIsAConflictNotAReplay() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"d91271a2-15d3-49ab-aacc-ccbc9e01cfca","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cross-turn-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal, appOperationSupport: fixtureSupport("playback.pause"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-cross-1")
        let firstFrame = try await awaitResultFrame(operationId: "d91271a2-15d3-49ab-aacc-ccbc9e01cfca")
        XCTAssertEqual(firstFrame["outcome"] as? String, "succeeded")

        // A SECOND turn (its own request id and its own admitted turn) redelivers the same id.
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"d91271a2-15d3-49ab-aacc-ccbc9e01cfca","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-cross-2")
        let secondFrame = try await awaitResultFrame(operationId: "d91271a2-15d3-49ab-aacc-ccbc9e01cfca")
        XCTAssertEqual(secondFrame["outcome"] as? String, "refused",
                       "an id from another turn is not replayed as this turn's operation")
        XCTAssertEqual(secondFrame["reason"] as? String, OperationReason.invalidRequest)
        XCTAssertNoThrow(try XCTUnwrap(secondFrame))
    }

    // MARK: - Typed journal persistence/replay + action-outcome propagation

    /// Waits (bounded) for the app_operation_result frame named by `operationId` on the current
    /// captured transport.
    ///
    /// `on:` names the EXACT task to inspect. Defaulting to `capturedTask` is only correct when a
    /// suite's factory is the one assigning it; a test that builds its own client must hand over
    /// its own task, or the helper silently inspects nil and reports zero frames for a send that
    /// happened. The label is carried purely so a failure says which task was read.
    private func awaitResultFrame(operationId: String, timeout: TimeInterval = 5,
                                  on explicitTask: StubWebSocketTask? = nil,
                                  label taskLabel: String = "capturedTask") async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame: [String: Any]? = await MainActor.run {
                let task = explicitTask ?? self.capturedTask
                return task?.sentTextFrames.compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }.first { ($0["type"] as? String) == "app_operation_result" && ($0["operation_id"] as? String) == operationId }
            }
            if let frame { return frame }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // A MISSING FRAME IS A FAILURE, NOT A SKIP. This helper previously threw `XCTSkip`, which
        // silently converted "the operation was never answered" — the exact behavior these
        // controls exist to catch — into a green-looking skip. Six controls were reporting as
        // skipped for that reason alone.
        let sent = await MainActor.run { (explicitTask ?? self.capturedTask)?.sentTextFrames ?? [] }
        let label = await MainActor.run {
            (explicitTask ?? self.capturedTask)?.diagnosticLabel ?? "none"
        }
        XCTFail("""
            no app_operation_result frame arrived for \(operationId) within \(timeout)s.
            inspected task: \(taskLabel) (label \(label))
            frames on it (\(sent.count)): \(sent)
            """)
        throw CancellationError()
    }

    /// FULL TYPED REPLAY control: the same server-issued operation_id delivered across two turns
    /// is answered from the durable journal on the second delivery — the recorded outcome rides
    /// the real socket, and the effect does NOT run twice. Success replays with the ACTUAL
    /// resulting state (wire contract §3): a replayed success is not a bare outcome.
    // MARK: - Resume result-path controls (voice-intents.md @ df5def09; task67)

    // ENABLEMENT SLICE: these controls are bound to THE PRODUCTION CONSTANT
    // (`VoiceControlAssembly.declaredAppOperations`, now pause + resume) so the result table is
    // exercised on the branch declaration. ADVERTISEMENT IS NOT END-TO-END AVAILABILITY: server
    // eligibility is a separate Cloud slice, so nothing here claims resume is available
    // end-to-end. Result table: observed true (incl. already-playing) succeeds with the
    // captured state; false fails `resume_not_observed`; unavailable is
    // `unknown`/`playback_state_unavailable`; non-success carries no state. Replay replays the
    // recorded result with NO extra effect and NO new observation.

    /// EXECUTE (transition evidence): the engine is PAUSED before the action and the RESUME
    /// EFFECT ITSELF produces the false→true transition — the pre-action state is never
    /// already-playing, so this is not the idempotence case (that control is separate below).
    /// The identified resume runs once and succeeds from the ONE fresh post-sink observation —
    /// the same reading classifies the outcome and populates the state.
    func testIdentifiedResumeSucceedsWithTheCapturedPlayingTrueObservation() async throws {
        playback.setPlaying(false)
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"31e7c9a4-5b82-4d06-9f3a-7c1e8b2d4a59","capability_version":"app-ops/1","tool":"playback","action":"resume","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        // THE MATCHING TARGET OBSERVER... none needed (engine-level action). The ACTION boundary
        // is the pre-effect gate: re-establish PAUSED there (the answer hold has already run by
        // then) and clear the hold's calls, so what this control counts is the identified resume
        // alone — and resume ITSELF produces the false→true transition the observation reads.
        await MainActor.run {
            sink.effectGate = { _ in
                self.playback.setPlaying(false)
                self.playback.clearCalls()
            }
        }
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-resume-run")
        let frame = try await awaitResultFrame(operationId: "31e7c9a4-5b82-4d06-9f3a-7c1e8b2d4a59")
        XCTAssertEqual(frame["outcome"] as? String, "succeeded")
        let state = try XCTUnwrap(frame["state"] as? [String: Any], "success carries the captured observation")
        XCTAssertEqual(state["playing"] as? Bool, true,
                       "the settled state IS the observation that gated success")
        XCTAssertEqual(playback.calls.filter { if case .resume = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(playback.observedPlayingReads, 1,
                       "classification and settlement must come from ONE post-resume observation")
    }

    /// IDEMPOTENT: an already-playing engine satisfies resume with the observed true state.
    func testIdentifiedResumeOnAnAlreadyPlayingEngineSucceedsWithTheObservedState() async throws {
        playback.setPlaying(true)
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"5a93d2c7-84e1-4b5f-8a26-9d0e3f7c1b68","capability_version":"app-ops/1","tool":"playback","action":"resume","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        // Action boundary: re-establish PLAYING there so the answer hold cannot turn this into
        // another transition test — the engine is already playing when resume runs.
        await MainActor.run {
            sink.effectGate = { _ in
                self.playback.setPlaying(true)
                self.playback.clearCalls()
            }
        }
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-resume-idem")
        let frame = try await awaitResultFrame(operationId: "5a93d2c7-84e1-4b5f-8a26-9d0e3f7c1b68")
        XCTAssertEqual(frame["outcome"] as? String, "succeeded",
                       "an already-playing engine is an idempotent success, not a refusal")
        let state = try XCTUnwrap(frame["state"] as? [String: Any])
        XCTAssertEqual(state["playing"] as? Bool, true)
        XCTAssertEqual(playback.calls.filter { if case .resume = $0 { return true }; return false }.count, 1)
    }

    /// STILL PAUSED: the resume sink completed but the fresh observation still reads `false` —
    /// a FAILED resume (`resume_not_observed`), not a refusal, and it carries NO state.
    func testIdentifiedResumeStillPausedReportsFailedResumeNotObservedWithNoState() async throws {
        playback.setPlaying(false)
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"8c04e1b9-27f3-4a68-b95d-6e2a4c8f0d73","capability_version":"app-ops/1","tool":"playback","action":"resume","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        // The DOUBLE-ONLY failure knob: the resume sink completes but the engine stays paused,
        // so the fresh post-sink observation reads `false` — the resume_not_observed arm.
        await MainActor.run { self.playback.setSimulatesFailedResume(true) }
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-resume-notobs")
        let frame = try await awaitResultFrame(operationId: "8c04e1b9-27f3-4a68-b95d-6e2a4c8f0d73")
        XCTAssertEqual(frame["outcome"] as? String, "failed")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.resumeNotObserved)
        XCTAssertNil(frame["state"], "a non-success outcome carries no state")
        XCTAssertEqual(playback.calls.filter { if case .resume = $0 { return true }; return false }.count, 1,
                       "the mutation WAS attempted: failed, not refused")
        await MainActor.run { self.playback.setSimulatesFailedResume(false) }
    }

    /// UNAVAILABLE: no current observation before the deadline is `unknown` with
    /// `playback_state_unavailable`, NO state — never a success built on a cached read.
    func testIdentifiedResumeWithNoEngineObservationReportsUnknownWithNoState() async throws {
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"b47f6a02-9d15-4e83-a7c9-1f3b8e5d2a40","capability_version":"app-ops/1","tool":"playback","action":"resume","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        await MainActor.run { self.playback.setSimulateUnavailableObservation(true) }
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-resume-unavail")
        let frame = try await awaitResultFrame(operationId: "b47f6a02-9d15-4e83-a7c9-1f3b8e5d2a40")
        XCTAssertEqual(frame["outcome"] as? String, "unknown")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.playbackStateUnavailable)
        XCTAssertNil(frame["state"])
        // RESTORE the knob: the fixture sink is fresh per test, but an explicit restore keeps
        // this control from ever leaking the unavailable simulation into a later assertion.
        await MainActor.run { self.playback.setSimulateUnavailableObservation(false) }
    }

    /// NEGATIVE CASE 1 — SUPPLIED target that cannot be matched live: a stated episode_id other
    /// than the current one refuses at the `.claimed` gate (`stale_precondition` via the
    /// request's own validation), settles durably, and NEVER reaches the effect. Distinct guard
    /// from the no-stated-target case below.
    func testIdentifiedResumeWithMismatchedStatedTargetRefusesAtTheGateBeforeEffect() async throws {
        // HOST PLAYBACK STARTS PAUSED (same premise as the no-current-episode control): a turn
        // over playing audio takes an answer hold whose turn-end restore calls `resume` through
        // separate machinery — the confound the gate caught. Paused, the zero-resume assertion
        // below measures the OPERATION alone.
        await MainActor.run { self.playback.setPlaying(false) }
        playback.clearCalls()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-mismatch-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"d28a5f31-40c7-49be-8e64-b7a09c3d5e12","capability_version":"app-ops/1","tool":"playback","action":"resume","params":{},"precondition":{"episode_id":"ep-OTHER"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let resumeFixture = try XCTUnwrap(self.pendingFixture)
        let resumeBytes = try XCTUnwrap(Self.deliveredPayload(for: "d28a5f31-40c7-49be-8e64-b7a09c3d5e12", in: resumeFixture))
        let identity = try XCTUnwrap(Self.mintedIdentity(for: "u-resume-mismatch", manager: manager, bytes: resumeBytes))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                        operationJournal: journal,
                                        appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-resume-mismatch")
        let taskValue = await MainActor.run { capturedTask }
        let task = try XCTUnwrap(taskValue)
        let frame = try await awaitResultFrame(operationId: "d28a5f31-40c7-49be-8e64-b7a09c3d5e12", on: task)
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.stalePrecondition,
                       "a supplied target that cannot be matched live is a stale precondition at the gate")
        XCTAssertEqual(playback.calls.filter { if case .resume = $0 { return true }; return false }.count, 0,
                       "the mismatched target never reaches the effect")
        if case .alreadyRun = journal.claim("d28a5f31-40c7-49be-8e64-b7a09c3d5e12", identity: identity) {} else {
            XCTFail("the gate refusal must be settled durably")
        }
    }

    /// NEGATIVE CASE 2 — NO stated target and NO live episode: the retained sink-side
    /// availability precondition refuses `stale_precondition` BEFORE the effect. The mirror of
    /// the pause branch's engine-level contract: a silent no-op must never dress up as success.
    func testIdentifiedResumeWithNoCurrentEpisodeRefusesBeforeEffect() async throws {
        // HOST PLAYBACK STARTS PAUSED: a turn over playing audio takes an answer hold and its
        // turn-end restore calls `resume` through separate machinery — the exact confound the
        // gate caught. Paused, the turn takes no hold, so the zero-resume assertion below
        // measures the OPERATION alone.
        await MainActor.run { self.playback.setPlaying(false) }
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"ef013c58-7a29-4d4b-92f6-0c8e7b1a3d94","capability_version":"app-ops/1","tool":"playback","action":"resume","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer, episodeAvailable: { false },
                                        appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-resume-noep")
        let refusals = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refusals.count, 1, "exactly one refusal for the unavailable resume")
        XCTAssertEqual(refusals.first?.result.reason, OperationReason.stalePrecondition)
        XCTAssertEqual(playback.calls.filter { if case .resume = $0 { return true }; return false }.count, 0,
                       "the availability precondition runs BEFORE the effect")
    }

    /// DURABLE REPLAY: a settled identified resume redelivered on a FRESH journal over the SAME
    /// durable file replays the recorded succeeded state with NO extra effect and NO new
    /// observation — the recorded result rides the socket, never a re-decision.
    func testSettledResumeRedeliveryReplaysTheRecordedStateWithoutAnotherResume() async throws {
        playback.setPlaying(false)
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"f61b9e24-3c07-4d58-a9e2-84b6d0f7c315","capability_version":"app-ops/1","tool":"playback","action":"resume","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-replay-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        // RETAIN THE EXACT ORIGINAL FIXTURE AND ACTION BYTES: the replay turn reinstalls THESE
        // bytes — redelivery is proved by the identical presented payload, not by reusing the
        // utterance ID alone.
        let resumeFixture = try XCTUnwrap(self.pendingFixture)
        let resumeBytes = try XCTUnwrap(Self.deliveredPayload(for: "f61b9e24-3c07-4d58-a9e2-84b6d0f7c315", in: resumeFixture))
        let originalIdentity = try XCTUnwrap(Self.mintedIdentity(for: "u-resume-replay", manager: manager, bytes: resumeBytes))
        let sink1 = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                         operationJournal: journal,
                                         appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        await MainActor.run {
            sink1.effectGate = { _ in
                self.playback.setPlaying(false)
                self.playback.clearCalls()
            }
        }
        _ = await sink1.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-resume-replay")
        let firstFrame = try await awaitResultFrame(operationId: "f61b9e24-3c07-4d58-a9e2-84b6d0f7c315")
        XCTAssertEqual(firstFrame["outcome"] as? String, "succeeded")

        // REDELIVERY: same durable file, fresh journal, resumed playback state flipped back so a
        // NEW effect/observation would be visible if the replay re-executed.
        await MainActor.run {
            self.playback.setPlaying(false)
            self.playback.clearCalls()
        }
        // `clearCalls()` clears CALLS only — `observedPlayingReads` is cumulative. Capture the
        // baseline after the first settlement and assert the replay adds NOTHING to it.
        let readsBeforeReplay = await MainActor.run { self.playback.observedPlayingReads }
        let callsBeforeReplay = await MainActor.run { self.playback.calls.filter { if case .resume = $0 { return true }; return false }.count }
        let reloaded = OperationJournal(store: FileOperationRecordStore(url: url))
        // REINSTALL the original action fixture for the replay turn.
        self.pendingFixture = resumeFixture
        let rePresented = try XCTUnwrap(Self.mintedIdentity(for: "u-resume-replay", manager: manager, bytes: resumeBytes))
        let sink2 = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                         operationJournal: reloaded,
                                         appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        _ = await sink2.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-resume-replay")
        let replayFrame = try await awaitResultFrame(operationId: "f61b9e24-3c07-4d58-a9e2-84b6d0f7c315")
        XCTAssertEqual(replayFrame["outcome"] as? String, "succeeded",
                       "the recorded result replays byte-for-byte in outcome")
        // The COMPLETE recorded state replays — outcome, position AND playing — not a fresh
        // observation of the flipped engine and not a partial key.
        let firstState = try XCTUnwrap(firstFrame["state"] as? [String: Any])
        let replayState = try XCTUnwrap(replayFrame["state"] as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: replayState), NSDictionary(dictionary: firstState),
                       "the replayed state is the COMPLETE recorded observation, value-equal")
        XCTAssertEqual(rePresented.actionDigest, originalIdentity.actionDigest,
                       "the redelivered bytes are the original action bytes")
        let callsAfterReplay = await MainActor.run { self.playback.calls.filter { if case .resume = $0 { return true }; return false }.count }
        let readsAfterReplay = await MainActor.run { self.playback.observedPlayingReads }
        XCTAssertEqual(callsAfterReplay, callsBeforeReplay,
                       "replay must not invoke resume again")
        XCTAssertEqual(readsAfterReplay, readsBeforeReplay,
                       "replay must not take a new observation")
    }

    /// FOCUSED IDENTITYLESS RESUME LEGACY CONTROL (ruling @ 3c5576de): a resume frame with NO
    /// operation identity takes the legacy path exactly as before — the effect runs, and NO
    /// app-operation result frame is produced. General identityless separation remains covered
    /// by `testLegacyIdentitylessFrameExecutesWithoutIdentityOrResultFrame` (seek_to); this pins
    /// the resume-specific legacy behavior under the new identified branch.
    func testIdentitylessResumeExecutesWithoutIdentityOrResultFrame() async throws {
        playback.setPlaying(false)
        playback.clearCalls()
        // The `LEGACY_ACTION` marker is the injector's documented opt-out: without it,
        // `makeSinkWithConsumer` would inject the identity pair and the frame would take the v1
        // gate, not the legacy path.
        self.pendingFixture = """
            event: action
            data: {"tool":"playback","action":"resume","params":{},"note":"LEGACY_ACTION"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // PREMISE FIRST: what the sink RECEIVED carries NEITHER identity key — the injector
        // must have left the marked frame unwritten, exactly as the seek_to legacy control
        // asserts for its own fixture.
        let deliveredFixture = Self.injectOperationIdentity(self.pendingFixture ?? "")
        XCTAssertFalse(deliveredFixture.contains("operation_id"),
                       "the delivered legacy frame must carry no operation_id: \(deliveredFixture)")
        XCTAssertFalse(deliveredFixture.contains("capability_version"),
                       "the delivered legacy frame must carry no capability_version")
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-legacy-resume")
        XCTAssertEqual(playback.calls.filter { if case .resume = $0 { return true }; return false }.count, 1,
                       "the identityless resume executes the legacy effect")
        let frames = await Self.resultFrames(on: capturedTask)
        XCTAssertEqual(frames.count, 0, "a legacy turn never produces an app-operation result frame")
    }

    // MARK: - Declaration controls (app_operations_v1 negotiation, trainer-reduced-local-scope @ 818c8f75)

    /// THE ADVERTISED AUTHENTICATE FRAME: a turn whose declaration carries `playback.pause`
    /// serializes the token AND the exact support object on the REAL authenticate frame.
    func testAdvertisedTurnCarriesTokenAndSupportOnTheAuthenticateFrame() async throws {
        let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                        appOperationSupport: fixtureSupport("playback.pause"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-decl-frame")
        let authFrameValue = await MainActor.run { capturedTask?.sentAuthFrame }
        let frame = try XCTUnwrap(authFrameValue)
        XCTAssertEqual(frame["capabilities"] as? [String], ["app_operations_v1"],
                       "no renderer: the advertised token rides alone with the support manifest")
        let support = try XCTUnwrap(frame["app_operation_support"] as? [String: Any])
        XCTAssertEqual(support["schema_version"] as? String, "app-ops/1")
        XCTAssertEqual(support["operations"] as? [String], ["playback.pause"])
    }

    /// THE NON-ADVERTISING SHAPE IS TODAY'S SHAPE: neither app-ops key appears; nothing is
    /// silently flipped by the machinery existing.
    func testNonAdvertisingTurnOmitsBothAppOperationKeys() async throws {
        let sink = makeSinkWithConsumer(RecordingResultConsumer())
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-decl-absent")
        let authFrameValue = await MainActor.run { capturedTask?.sentAuthFrame }
        let frame = try XCTUnwrap(authFrameValue)
        XCTAssertNil(frame["capabilities"], "empty declaration: capabilities stay omitted")
        XCTAssertNil(frame["app_operation_support"], "no manifest, no support key")
    }

    /// `search_results_v1` IS INDEPENDENT: present exactly as before with the renderer, and
    /// unaffected by app-ops presence or absence.
    func testSearchResultsTokenIsIndependentOfAppOperationSupport() {
        let support = fixtureSupport("playback.pause")
        XCTAssertEqual(CloudClientCapabilities.advertised(rendersStructuredResults: true),
                       ["search_results_v1"], "absent support: legacy shape byte-preserved")
        XCTAssertEqual(CloudClientCapabilities.advertised(rendersStructuredResults: true, appOperationSupport: support),
                       ["search_results_v1", "app_operations_v1"])
        XCTAssertEqual(CloudClientCapabilities.advertised(rendersStructuredResults: false, appOperationSupport: support),
                       ["app_operations_v1"])
    }

    /// MALFORMED INPUT GRANTS NOTHING: every malformed shape fails closed to nil (no support,
    /// no token) — never a trap, never a repair. Duplicate keys are malformed by contract.
    func testMalformedAndDuplicateManifestsFailClosedToNoSupport() {
        XCTAssertNil(CloudAppOperationSupport(operations: []), "empty grants nothing")
        XCTAssertNil(CloudAppOperationSupport(operations: ["playback.pause", "playback.pause"]),
                     "duplicate keys are malformed")
        XCTAssertNil(CloudAppOperationSupport(operations: ["playback..pause"]), "empty segment")
        XCTAssertNil(CloudAppOperationSupport(operations: ["play back.pause"]), "whitespace inside key")
        XCTAssertNil(CloudAppOperationSupport(operations: ["playback.pause "]), "trailing whitespace")
        XCTAssertNil(CloudAppOperationSupport(operations: ["a.b.c"]), "arbitrary dotted string is not tool.action")
        XCTAssertNil(CloudAppOperationSupport(operations: [".pause"]), "empty tool")
        XCTAssertNil(CloudAppOperationSupport(operations: ["playback."]), "empty action")
        XCTAssertNotNil(CloudAppOperationSupport(operations: ["playback.pause"]), "well-formed exact shape")
    }

    /// PAIRING FAILS CLOSED AT SERIALIZATION: a constructed envelope carrying support WITHOUT
    /// the token serializes neither key — a manifest the frame does not declare must never
    /// leak onto the wire.
    func testSupportWithoutTheTokenIsDroppedAtSerialization() {
        let support = fixtureSupport("playback.pause")
        let turn = CloudTurnEnvelope.make(
            capabilities: [], routeHint: nil, recentConversation: [],
            conversation: CloudPreparedConversation(requestId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88",
                                                    conversationId: "1c4b9a70-6d2e-4f38-a511-9b7c2d0e54a3",
                                                    mode: "create"),
            appOperationSupport: support)
        let frame = CloudRouteRequestBuilder.envelope(request: "x", context: CloudRouteContext(from: sampleContext()), turn: turn)
        XCTAssertNil(frame["app_operation_support"],
                     "support without the token is dropped — never serialized unpaired")
    }

    /// C5' TWO SEPARATE ONE-UTTERANCE SOCKETS: each turn gets its OWN connection and its own
    /// snapshot built from the SAME declaration; the serialized support objects are
    /// byte-identical and each frame carries the token.
    func testSupportSnapshotIsIdenticalAcrossTwoSeparateOneUtteranceSockets() async throws {
        let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                        appOperationSupport: fixtureSupport("playback.pause"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-sock-a")
        let taskAValue = await MainActor.run { capturedTask }
        let taskA = try XCTUnwrap(taskAValue)
        let frameA = try XCTUnwrap(taskA.sentAuthFrame)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-sock-b")
        let taskBValue = await MainActor.run { capturedTask }
        let taskB = try XCTUnwrap(taskBValue)
        XCTAssertFalse(taskA === taskB, "each utterance rode its OWN one-utterance connection")
        let frameB = try XCTUnwrap(taskB.sentAuthFrame)
        XCTAssertEqual(frameA["capabilities"] as? [String], ["app_operations_v1"])
        XCTAssertEqual(frameB["capabilities"] as? [String], ["app_operations_v1"])
        let bytesA = try JSONSerialization.data(withJSONObject: try XCTUnwrap(frameA["app_operation_support"]),
                                                options: [.sortedKeys])
        let bytesB = try JSONSerialization.data(withJSONObject: try XCTUnwrap(frameB["app_operation_support"]),
                                                options: [.sortedKeys])
        XCTAssertEqual(bytesA, bytesB,
                       "two separate sockets serialize byte-identical support from the same declaration")
    }

    /// ABSENCE REFUSES AT EXECUTION, NOT JUST ON THE WIRE: an identified pause on a turn with
    /// NO manifest is refused `unsupported_operation`, settled durably, and runs no effect —
    /// serialization absence alone would not prove this half.
    func testAbsentManifestRefusesIdentifiedPauseAtExecution() async throws {
        playback.setPlaying(false)
        playback.clearCalls()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-manifest-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"a40b7c15-6d29-4e83-b1f7-90c4e5a2d836","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let fixtureBytes = try XCTUnwrap(Self.deliveredPayload(for: "a40b7c15-6d29-4e83-b1f7-90c4e5a2d836", in: self.pendingFixture ?? ""))
        let identity = try XCTUnwrap(Self.mintedIdentity(for: "u-absent", manager: manager, bytes: fixtureBytes))
        // NO appOperationSupport: the default empty declaration.
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                       operationJournal: journal,
                                       appOperationSupport: fixtureSupport("playback.seek_relative"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-absent")
        let taskValue = await MainActor.run { capturedTask }
        let task = try XCTUnwrap(taskValue)
        let frame = try await awaitResultFrame(operationId: "a40b7c15-6d29-4e83-b1f7-90c4e5a2d836", on: task)
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.unsupportedOperation,
                       "an absent manifest refuses identified v1 operations at the execution boundary")
        XCTAssertEqual(playback.calls.filter { if case .pause = $0 { return true }; return false }.count, 0,
                       "the refused identified pause never reaches an effect (engine not playing: no hold exists either)")
        if case .alreadyRun = journal.claim("a40b7c15-6d29-4e83-b1f7-90c4e5a2d836", identity: identity) {} else {
            XCTFail("the absence refusal must be settled durably")
        }
    }

    /// THE DECLARED ACTION SUCCEEDS ON THE SAME DECLARATION: a pause-only advertised turn
    /// executes `playback.pause` to a settled observed state — advertising gates, it does not
    /// disable.
    func testDeclaredPauseSucceedsOnAPauseOnlyAdvertisedTurn() async throws {
        playback.setPlaying(true)
        playback.clearCalls()
        let journal = OperationJournal(store: InMemoryOperationRecordStore())
        let manager = testConversationManager()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"e7c2a940-1b35-4d68-9f2a-3c8b7d5e0f14","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                        operationJournal: journal,
                                        appOperationSupport: fixtureSupport("playback.pause"))
        await MainActor.run {
            sink.effectGate = { _ in
                self.playback.setPlaying(true)
                self.playback.clearCalls()
            }
        }
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-decl-pause")
        let taskValue = await MainActor.run { capturedTask }
        let task = try XCTUnwrap(taskValue)
        let frame = try await awaitResultFrame(operationId: "e7c2a940-1b35-4d68-9f2a-3c8b7d5e0f14", on: task)
        XCTAssertEqual(frame["outcome"] as? String, "succeeded",
                       "the DECLARED action passes the negotiated gate and executes")
        let state = try XCTUnwrap(frame["state"] as? [String: Any])
        XCTAssertEqual(state["playing"] as? Bool, false)
        XCTAssertEqual(playback.calls.filter { if case .pause = $0 { return true }; return false }.count, 1)
    }

    /// C6' THE UNDECLARED ACTION ON A REAL ADVERTISED TURN: a pause-only manifest refuses
    /// `seek_to` with `unsupported_operation`, settles the refusal DURABLY (a redelivery
    /// replays it rather than re-deciding), and runs no effect — while a `playback.pause` on
    /// the same declaration passes the gate.
    func testUndeclaredSeekOnAPauseOnlyAdvertisedTurnIsRefusedDurablyAndReplays() async throws {
        playback.setPlaying(false)
        playback.clearCalls()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("undecl-seek-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"c581d3e2-94ab-4f07-a6c3-7b2e8d1f4a90","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":42},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // RETAIN THE EXACT ORIGINAL FIXTURE: the first route consumes `pendingFixture`, so the
        // replay reinstalls THESE bytes — not a rebuilt stand-in.
        let seekFixture = try XCTUnwrap(self.pendingFixture)
        let seekBytes = try XCTUnwrap(Self.deliveredPayload(for: "c581d3e2-94ab-4f07-a6c3-7b2e8d1f4a90", in: seekFixture))
        let identity = try XCTUnwrap(Self.mintedIdentity(for: "u-undecl", manager: manager, bytes: seekBytes))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                        operationJournal: journal,
                                        appOperationSupport: fixtureSupport("playback.pause"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-undecl")
        let firstTaskValue = await MainActor.run { capturedTask }
        let firstTask = try XCTUnwrap(firstTaskValue)
        let frame = try await awaitResultFrame(operationId: "c581d3e2-94ab-4f07-a6c3-7b2e8d1f4a90", on: firstTask)
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.unsupportedOperation,
                       "seek_to is implemented in contracts but OUTSIDE the negotiated manifest")
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0,
                       "the undeclared action never reaches an effect")
        if case .alreadyRun = journal.claim("c581d3e2-94ab-4f07-a6c3-7b2e8d1f4a90", identity: identity) {} else {
            XCTFail("the refusal must be settled durably")
        }

        // REDELIVERY of the same bytes on a FRESH journal over the SAME durable file replays
        // the recorded refusal — no re-decision, no effect.
        let reloaded = OperationJournal(store: FileOperationRecordStore(url: url))
        // REINSTALL the original action fixture for the replay turn and capture from its own task.
        self.pendingFixture = seekFixture
        let rePresented = try XCTUnwrap(Self.mintedIdentity(for: "u-undecl", manager: manager, bytes: seekBytes))
        XCTAssertEqual(rePresented.actionDigest, identity.actionDigest)
        let sink2 = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                         operationJournal: reloaded,
                                         appOperationSupport: fixtureSupport("playback.pause"))
        _ = await sink2.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-undecl")
        let replayTaskValue = await MainActor.run { capturedTask }
        let replayTask = try XCTUnwrap(replayTaskValue)
        let replayFrame = try await awaitResultFrame(operationId: "c581d3e2-94ab-4f07-a6c3-7b2e8d1f4a90", on: replayTask)
        XCTAssertEqual(replayFrame["outcome"] as? String, "refused")
        XCTAssertEqual(replayFrame["reason"] as? String, OperationReason.unsupportedOperation)
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0)
    }

    // MARK: - Production-declaration enablement controls (task67)

    // EVIDENCE BOUNDARY (rulings @ ff5c6621, 807e16b0): these controls bind THE PRODUCTION
    // CONSTANT (`VoiceControlAssembly.declaredAppOperations`) so the tested manifest is the
    // shipped value, but they run on test-built sinks — they prove the DECLARATION'S behavior,
    // not the assembly's wiring (direct review evidence). The RESULT/REPLAY evidence claimed for
    // this enablement is exercised on the same constant: `testCloudPauseOnAnAlreadyPausedEngine…`,
    // `testCloudPauseStillPlayingAfterTheSinkReportsFailedWithNoState`,
    // `testCloudPauseWithNoEngineObservationReportsUnknownWithNoState`, and the C1 control
    // `testSettledPauseRedeliveryReplaysTheRecordedStateWithoutAnotherPause` are all bound to it.
    // IDENTITYLESS LEGACY EXECUTION control (unchanged, empty declaration):
    // `testLegacyIdentitylessFrameExecutesWithoutIdentityOrResultFrame`. NOTE: the
    // nonadvertising-frame test is a FRAME-SHAPE control, not an execution control.

    /// THE PRODUCTION CONSTANT ADVERTISES EXACTLY PAUSE AND RESUME on the real authenticate
    /// frame: `app_operations_v1` plus a branch-declaration support manifest whose operations
    /// list is exactly those two. Binding is by name, so this control and the assembly cannot
    /// drift apart.
    func testProductionDeclarationAdvertisesExactlyPauseAndResumeOnTheAuthenticateFrame() async throws {
        let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                        appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-prod-frame")
        let authFrameValue = await MainActor.run { capturedTask?.sentAuthFrame }
        let frame = try XCTUnwrap(authFrameValue)
        XCTAssertEqual(frame["capabilities"] as? [String], ["app_operations_v1"])
        let support = try XCTUnwrap(frame["app_operation_support"] as? [String: Any])
        XCTAssertEqual(support["schema_version"] as? String, "app-ops/1")
        XCTAssertEqual(support["operations"] as? [String], ["playback.pause", "playback.resume"],
                       "the candidate is exactly pause and resume — no third operation")
    }

    /// IDENTIFIED PAUSE EXECUTES UNDER THE PRODUCTION CONSTANT and settles the SAME single
    /// observation that gated success — the result and the wire state cannot come from
    /// different readings.
    func testProductionDeclarationExecutesIdentifiedPauseAndSettlesTheCapturedObservation() async throws {
        playback.setPlaying(true)
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"7c2f1e88-3a54-4c19-b7d0-9e6a2f4b8c31","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                        appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        await MainActor.run {
            sink.effectGate = { _ in
                self.playback.setPlaying(true)
                self.playback.clearCalls()
            }
        }
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-prod-pause")
        let frame = try await awaitResultFrame(operationId: "7c2f1e88-3a54-4c19-b7d0-9e6a2f4b8c31")
        XCTAssertEqual(frame["outcome"] as? String, "succeeded")
        let state = try XCTUnwrap(frame["state"] as? [String: Any])
        XCTAssertEqual(state["playing"] as? Bool, false,
                       "the settled state IS the observation that gated success")
        XCTAssertEqual(playback.calls.filter { if case .pause = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(playback.observedPlayingReads, 1,
                       "one post-pause observation settles both the gate and the wire")
    }

    /// EVERYTHING OUTSIDE THE PRODUCTION DECLARATION REFUSES, DURABLY, WITH NO EFFECT — and a
    /// redelivery of the SAME bytes replays the recorded refusal. Bound to the production
    /// constant, so the negative rides the SHIPPED manifest, not a fixture twin.
    func testProductionDeclarationRefusesSeekRelativeDurablyAndReplaysTheRefusal() async throws {
        playback.setPlaying(false)
        playback.clearCalls()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prod-decl-refuse-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"9d4b7a15-62c8-4f30-a9e1-5c8b3d2f7a46","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let seekFixture = try XCTUnwrap(self.pendingFixture)
        let seekBytes = try XCTUnwrap(Self.deliveredPayload(for: "9d4b7a15-62c8-4f30-a9e1-5c8b3d2f7a46", in: seekFixture))
        let identity = try XCTUnwrap(Self.mintedIdentity(for: "u-prod-refuse", manager: manager, bytes: seekBytes))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                        operationJournal: journal,
                                        appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-prod-refuse")
        let firstTaskValue = await MainActor.run { capturedTask }
        let firstTask = try XCTUnwrap(firstTaskValue)
        let frame = try await awaitResultFrame(operationId: "9d4b7a15-62c8-4f30-a9e1-5c8b3d2f7a46", on: firstTask)
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.unsupportedOperation,
                       "seek_relative is contract-implemented but OUTSIDE the shipped pause+resume manifest")
        XCTAssertEqual(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count, 0,
                       "the undeclared action never reaches an effect")
        if case .alreadyRun = journal.claim("9d4b7a15-62c8-4f30-a9e1-5c8b3d2f7a46", identity: identity) {} else {
            XCTFail("the refusal must be settled durably")
        }

        // REDELIVERY on a FRESH journal over the SAME durable file replays the recorded refusal.
        let reloaded = OperationJournal(store: FileOperationRecordStore(url: url))
        self.pendingFixture = seekFixture
        let rePresented = try XCTUnwrap(Self.mintedIdentity(for: "u-prod-refuse", manager: manager, bytes: seekBytes))
        XCTAssertEqual(rePresented.actionDigest, identity.actionDigest)
        let sink2 = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                         operationJournal: reloaded,
                                         appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        _ = await sink2.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-prod-refuse")
        let replayTaskValue = await MainActor.run { capturedTask }
        let replayTask = try XCTUnwrap(replayTaskValue)
        let replayFrame = try await awaitResultFrame(operationId: "9d4b7a15-62c8-4f30-a9e1-5c8b3d2f7a46", on: replayTask)
        XCTAssertEqual(replayFrame["outcome"] as? String, "refused")
        XCTAssertEqual(replayFrame["reason"] as? String, OperationReason.unsupportedOperation)
        XCTAssertEqual(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count, 0)
    }

    /// THE PRODUCTION CONSTANT, BY VALUE: the shipped declaration supports pause and NOTHING
    /// else — so the constant the assembly wires is proven here, not re-typed. ASSEMBLY WIRING
    /// EVIDENCE BOUNDARY (ruling @ 807e16b0): that the constructor passes this constant as the
    /// sink's provider is DIRECT REVIEW EVIDENCE — inspected on the real production constructor,
    /// not proven here; the former source-mirror/string assertions were removed as a
    /// machine-specific stale-source dependency. Runtime behavior of a constant-declared sink is
    /// the three production-declaration controls above plus the constant-bound result/replay
    /// controls (already-paused, still-playing, unavailable observation, settled-pause replay).
    @MainActor
    func testTheProductionDeclarationConstantSupportsPauseAndResumeOnly() throws {
        let declared = try XCTUnwrap(VoiceControlAssembly.declaredAppOperations,
                                     "the shipped declaration literal must be well-formed, not nil")
        XCTAssertTrue(declared.supports(tool: "playback", action: "pause"))
        XCTAssertTrue(declared.supports(tool: "playback", action: "resume"))
        XCTAssertFalse(declared.supports(tool: "playback", action: "seek_relative"))
        XCTAssertFalse(declared.supports(tool: "playback", action: "seek_to"))
        XCTAssertFalse(declared.supports(tool: "playback", action: "play_quote"))
        XCTAssertFalse(declared.supports(tool: "playback", action: "stop_quote"))
    }

    /// PAUSE REPLAY EVIDENCE (declaration candidate C1): a settled `playback.pause` redelivered
    /// within its turn replays the SAME SETTLED STATE through the journal — never re-executing,
    /// and never answering from LIVE playback state. The replay turn starts NOT playing so no
    /// answer-hold pause exists; live position drifts after settlement and the ENTIRE settled
    /// state — including the originally settled position — must survive the replay. Each frame is
    /// captured from its own turn's transport task.
    func testSettledPauseRedeliveryReplaysTheRecordedStateWithoutAnotherPause() async throws {
        playback.setPlaying(true)
        playback.setPositionMs(77_000)
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"e39f52a7-8c04-4b16-9d78-5a2b1c4e6f80","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-replay-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let rehearsalManager = testConversationManager()
        let deliveredAction = try XCTUnwrap(
            Self.deliveredPayload(for: "e39f52a7-8c04-4b16-9d78-5a2b1c4e6f80", in: self.pendingFixture ?? ""))
        let originalIdentity = try XCTUnwrap(
            Self.mintedIdentity(for: "u-pause-replay", manager: rehearsalManager, bytes: deliveredAction))

        // Turn 1: the pause executes and settles with the OBSERVED post-action state.
        let sink1 = makeSinkWithConsumer(RecordingResultConsumer(),
                                         conversationManager: rehearsalManager,
                                         operationJournal: journal,
                                         appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        await MainActor.run {
            sink1.effectGate = { _ in
                self.playback.setPlaying(true)
                self.playback.clearCalls()
            }
        }
        _ = await sink1.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-pause-replay")
        let task1Value = await MainActor.run { capturedTask }
        let task1 = try XCTUnwrap(task1Value, "turn 1's transport was captured")
        let firstFrame = try await awaitResultFrame(operationId: "e39f52a7-8c04-4b16-9d78-5a2b1c4e6f80", on: task1)
        XCTAssertEqual(firstFrame["outcome"] as? String, "succeeded")
        let firstState = try XCTUnwrap(firstFrame["state"] as? [String: Any])
        XCTAssertEqual(firstState["playing"] as? Bool, false, "premise: the pause settled observed-not-playing")
        XCTAssertEqual(firstState["position_seconds"] as? Int, 77, "premise: settled at position 77")
        XCTAssertEqual(playback.calls.filter { if case .pause = $0 { return true }; return false }.count, 1)
        let preReplayRecord = journal.result(for: "e39f52a7-8c04-4b16-9d78-5a2b1c4e6f80")

        // LIVE STATE MOVES AFTER SETTLEMENT: position drifts, and the engine returns to playing.
        // If the replay read live playback instead of the record, this drift would leak into the
        // answered state.
        playback.setPlaying(true)
        playback.setPositionMs(4321_000)

        // Turn 2 (REPLAY): the engine starts NOT PLAYING — an already-paused engine suppresses
        // the answer-hold pause entirely, so any pause call in this turn would be a re-execution.
        playback.setPlaying(false)
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"e39f52a7-8c04-4b16-9d78-5a2b1c4e6f80","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // A FRESH journal INSTANCE over the SAME durable file: the replay answers from the RECORD.
        let reloadedJournal = OperationJournal(store: FileOperationRecordStore(url: url))
        let rePresentedIdentity = try XCTUnwrap(
            Self.mintedIdentity(for: "u-pause-replay", manager: rehearsalManager, bytes: deliveredAction))
        XCTAssertEqual(rePresentedIdentity.conversation, originalIdentity.conversation)
        XCTAssertEqual(rePresentedIdentity.turn, originalIdentity.turn)
        XCTAssertEqual(rePresentedIdentity.actionDigest, originalIdentity.actionDigest,
                       "replay compares digests, so the bytes must be the delivered pause verbatim")
        let sink2 = makeSinkWithConsumer(RecordingResultConsumer(),
                                         conversationManager: rehearsalManager,
                                         operationJournal: reloadedJournal,
                                         appOperationSupport: VoiceControlAssembly.declaredAppOperations)
        _ = await sink2.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-pause-replay")
        let task2Value = await MainActor.run { capturedTask }
        let task2 = try XCTUnwrap(task2Value, "turn 2's transport was captured")
        XCTAssertFalse(task1 === task2, "the replay rode its own turn transport")
        let secondFrame = try await awaitResultFrame(operationId: "e39f52a7-8c04-4b16-9d78-5a2b1c4e6f80", on: task2)
        XCTAssertEqual(secondFrame["outcome"] as? String, "succeeded", "the settled pause replays succeeded")
        let secondState = try XCTUnwrap(secondFrame["state"] as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: secondState), NSDictionary(dictionary: firstState),
                       "the ENTIRE settled state replays — position 77, not the drifted 4321; playing false, not live")
        XCTAssertEqual(playback.calls.filter { if case .pause = $0 { return true }; return false }.count, 0,
                       "the replay turn must not pause at all — no hold exists and no re-execution may fire")

        // THE DURABLE PROOF: a freshly reopened store over the same file must hold the SAME
        // settled record it held before the replay — `journal.result` on a live instance can be
        // a cached value and does not prove the file was unchanged.
        let reopened = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(reopened.result(for: "e39f52a7-8c04-4b16-9d78-5a2b1c4e6f80"), preReplayRecord,
                       "replay must not rewrite the durable record")
    }

    /// PAUSE CRASH-BOUNDARY EVIDENCE (declaration candidate C2): a previous process claimed a
    /// `playback.pause` on a DURABLE FILE store and died before completing. Recovery runs through
    /// a NEWLY constructed store and journal from the same path — the actual restart path — and
    /// the reconstructed unknown replays through the bound transport WITHOUT re-executing: the
    /// engine is not playing from the start, so ZERO pause calls exist to hide behind.
    func testRestartReconstructedPauseReplaysUnknownWithoutEffect() async throws {
        playback.setPlaying(false)
        playback.clearCalls()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"7d41c6b9-2e83-4a50-b927-8f6e3d0c5a14","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // The PRIOR process: claims on a durable file store and dies before completing.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-crash-\(UUID().uuidString).json")
        let manager = testConversationManager()
        let originalIdentity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-pause-crash", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: "7d41c6b9-2e83-4a50-b927-8f6e3d0c5a14", in: self.pendingFixture ?? ""))
        ))
        let priorJournal = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(priorJournal.claim("7d41c6b9-2e83-4a50-b927-8f6e3d0c5a14", identity: originalIdentity), OperationClaim.claimed)

        // THE RESTART: a NEW store AND journal built from the same path — not the same instances.
        let restartedJournal = OperationJournal(store: FileOperationRecordStore(url: url))
        let reconstructed = restartedJournal.reconstructInterrupted("7d41c6b9-2e83-4a50-b927-8f6e3d0c5a14")
        XCTAssertEqual(reconstructed?.outcome, .unknown)

        let identity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-pause-crash", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: "7d41c6b9-2e83-4a50-b927-8f6e3d0c5a14", in: self.pendingFixture ?? ""))
        ))
        XCTAssertEqual(identity.actionDigest, originalIdentity.actionDigest,
                       "recovery re-presents the EXACT delivered pause bytes")
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager, operationJournal: restartedJournal, appOperationSupport: fixtureSupport("playback.pause"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-pause-crash")

        // The engine was NOT playing from the start, so no answer-hold pause exists anywhere in
        // this turn: a re-executed pause would be the ONLY pause call on record.
        XCTAssertEqual(playback.calls.filter { if case .pause = $0 { return true }; return false }.count, 0,
                       "a reconstructed-unknown pause must never re-execute — zero pause calls")
        let crashTaskValue = await MainActor.run { capturedTask }
        let crashTask = try XCTUnwrap(crashTaskValue, "the restart turn's transport was captured")
        let frame = try await awaitResultFrame(operationId: "7d41c6b9-2e83-4a50-b927-8f6e3d0c5a14", on: crashTask,
                                               label: "restart turn")
        XCTAssertEqual(frame["operation_id"] as? String, "7d41c6b9-2e83-4a50-b927-8f6e3d0c5a14")
        XCTAssertEqual(frame["outcome"] as? String, "unknown")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.interruptedInFlight)
        XCTAssertNil(frame["state"], "unknown carries no state")
        if case .alreadyRun = restartedJournal.claim("7d41c6b9-2e83-4a50-b927-8f6e3d0c5a14", identity: identity) {} else {
            XCTFail("the reconstructed record must be settled")
        }
    }

    func testRedeliveredIdentifiedOperationReplaysTheRecordedOutcomeWithoutReExecution() async throws {
        // seek_to, not pause: the turn's own auto-duck also pauses, which would
        // contaminate a pause-call count. A seek has no such second writer.
        self.pendingFixture = """
            event: action
            data: {"operation_id":"283bc9cc-1700-4596-af9e-94b930efccfd","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":42},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        // A's SETTLED state S: position 77 at the moment A finishes.
        playback.setPositionMs(77_000)

        // ONE MANAGER FOR THE WHOLE CONTROL: the identity is prepared here, the initial claim is
        // recorded by a turn routed on THIS manager, and the replay re-presents it on the same one.
        // `prepare` retains every utterance prepared inside the live window, so re-preparing "u-22"
        // yields the SAME requestId and conversationId — the real preparation path, not a
        // fabricated identity and not two independently opened conversations.
        let rehearsalManager = testConversationManager()
        // BOTH identities carry the ACTUAL delivered action bytes. Omitting them would compare two
        // empty digests — agreement between two helper defaults, not evidence about the claim.
        let deliveredAction = try XCTUnwrap(
            Self.deliveredPayload(for: "283bc9cc-1700-4596-af9e-94b930efccfd", in: self.pendingFixture ?? ""))
        let originalIdentity = try XCTUnwrap(
            Self.mintedIdentity(for: "u-22", manager: rehearsalManager, bytes: deliveredAction))

        // Turn 1: executes and settles succeeded with the typed state.
        // THE ORIGINAL MANAGER: this is the turn whose identity the claim is recorded under, so the
        // rehearsal and the real claim must be the same manager, not two independently opened ones.
        let sink1 = makeSinkWithConsumer(RecordingResultConsumer(),
                                         conversationManager: rehearsalManager,
                                         operationJournal: journal,
                                         appOperationSupport: fixtureSupport("playback.pause", "playback.seek_to"))
        _ = await sink1.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-22")
        let firstFrame = try await awaitResultFrame(operationId: "283bc9cc-1700-4596-af9e-94b930efccfd")
        XCTAssertEqual(firstFrame["outcome"] as? String, "succeeded")
        let firstState = try XCTUnwrap(firstFrame["state"] as? [String: Any], "a success frame carries the resulting state")
        XCTAssertEqual(firstState["position_seconds"] as? Int, 77, "S: A settled at position 77")
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 1)

        // Turn 2: an UNRELATED operation B settles and moves the LIVE state (playing=false).
        self.pendingFixture = """
            event: action
            data: {"operation_id":"3e8af81c-fb7d-4f05-ae9b-9cf72b0b48b3","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sinkB = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal, appOperationSupport: fixtureSupport("playback.pause", "playback.seek_to"))
        _ = await sinkB.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-23")
        _ = try await awaitResultFrame(operationId: "3e8af81c-fb7d-4f05-ae9b-9cf72b0b48b3")
        // T: unrelated live drift AFTER A settled.
        playback.setPositionMs(9999_000)

        // Turn 3: the SAME operation_id A redelivered through a FRESH sink AND a FRESH journal
        // instance over the SAME durable file. The replay must answer A's SETTLED state S —
        // not the live state T that B created.
        self.pendingFixture = """
            event: action
            data: {"operation_id":"283bc9cc-1700-4596-af9e-94b930efccfd","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":42},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let reloadedJournal = OperationJournal(store: FileOperationRecordStore(url: url))
        // THE SAME RETAINED TURN RE-PRESENTING A: the replay arrives on the identity the claim was
        // recorded under — same owner, conversation, turn and delivered bytes. A DIFFERENT turn
        // redelivering the same id is a conflict, and the separate later-turn control asserts that.
        let sink2 = makeSinkWithConsumer(RecordingResultConsumer(),
                                         conversationManager: rehearsalManager,
                                         operationJournal: reloadedJournal,
                                         appOperationSupport: fixtureSupport("playback.pause", "playback.seek_to"))
        _ = await sink2.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-22")
        // THE REPLAY REALLY IS THE ORIGINAL IDENTITY, not merely a green frame: re-preparation of
        // the retained utterance must yield the very same request turn and conversation the claim
        // was recorded under. If this drifted, the replay control would be passing on a conflict
        // path rather than a replay path.
        let replayedIdentity = try XCTUnwrap(
            Self.mintedIdentity(for: "u-22", manager: rehearsalManager, bytes: deliveredAction))
        XCTAssertEqual(replayedIdentity.owner, originalIdentity.owner)
        XCTAssertEqual(replayedIdentity.conversation, originalIdentity.conversation,
                       "re-presenting a retained utterance keeps its conversation")
        XCTAssertEqual(replayedIdentity.turn, originalIdentity.turn,
                       "a redelivery is the SAME turn re-presenting, not a newly admitted one")
        XCTAssertEqual(replayedIdentity.actionDigest, originalIdentity.actionDigest,
                       "the delivered bytes are identical, so the digest is too")
        // REAL STORED CLAIM, not a helper self-comparison. The journal exposes no record reader, so
        // the claim itself is the probe: an identity that matches the durable record answers
        // `.alreadyRun` with the settled result, and anything else is `.identityConflict`.
        // The stored state is asserted as ITSELF, not merely as "some settled result": a replay that
        // matched the identity but answered with a different envelope would still be wrong.
        XCTAssertEqual(journal.claim("283bc9cc-1700-4596-af9e-94b930efccfd", identity: originalIdentity),
                       OperationClaim.alreadyRun(.succeeded(state: ["position_seconds": .int(77),
                                                                   "playing": .bool(false)])),
                       "the durable record is settled under exactly this identity and state")
        let replayFrame = try await awaitResultFrame(operationId: "283bc9cc-1700-4596-af9e-94b930efccfd")
        XCTAssertEqual(replayFrame["outcome"] as? String, "succeeded", "the recorded outcome replays")
        let replayState = try XCTUnwrap(replayFrame["state"] as? [String: Any], "a replayed success carries A's SETTLED state")
        XCTAssertEqual(replayState["position_seconds"] as? Int, 77, "A's SETTLED position S, not the live drift T")
        // SAME CAPTURED ENVELOPE: the first send, the settled record, and the fresh-store replay
        // all carry ONE captured state — no second live snapshot at send or replay time.
        XCTAssertEqual(firstState["position_seconds"] as? Int, replayState["position_seconds"] as? Int,
                       "the first send is the settled envelope, not a second snapshot")
        XCTAssertEqual(firstState["playing"] as? Bool, replayState["playing"] as? Bool,
                       "playing agrees between settlement and replay")
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 1, "the effect never runs twice")
    }

    /// POSITIVE live parser→sink case: a request whose stated episode IS the current one must
    /// EXECUTE exactly once. This is the control that the v5 defect failed — the parser attached a
    /// stale violation to every well-formed request, so nothing ever ran.
    func testMatchingEpisodeExecutesExactlyOnceThroughTheLivePath() async throws {
        let operationId = "5c8b1e40-7d92-4a36-b8f1-09c7d2e3a4b5"
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                       conversationManager: testConversationManager(),
                                       operationJournal: OperationJournal(store: InMemoryOperationRecordStore()),
                                       currentEpisodeId: { Self.testEpisodeId },
                                       appOperationSupport: fixtureSupport("playback.seek_relative"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-match")

        let relativeSeeks = playback.calls.filter {
            if case .seekRelative = $0 { return true }
            return false
        }
        XCTAssertEqual(relativeSeeks.count, 1, "a matching target must execute exactly once")
        let frame = try await awaitResultFrame(operationId: operationId)
        XCTAssertEqual(frame["outcome"] as? String, "succeeded",
                       "a valid request is not refused: \(String(describing: frame["reason"]))")
    }

    /// NEGATIVE: the same request with a target that is no longer current runs ZERO effects.
    func testNonMatchingEpisodeExecutesNothing() async throws {
        let operationId = "7e2d9f51-8a63-4b47-9c02-1d3e4f5a6b7c"
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"ep-abandoned"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                       conversationManager: testConversationManager(),
                                       operationJournal: OperationJournal(store: InMemoryOperationRecordStore()),
                                       currentEpisodeId: { "ep-now-playing" },
                                       appOperationSupport: fixtureSupport("playback.seek_relative"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-nomatch")

        XCTAssertTrue(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.isEmpty,
                      "a non-matching target must run nothing: \(playback.calls)")
        let frame = try await awaitResultFrame(operationId: operationId)
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.stalePrecondition)
    }

    /// A TURN THAT DIES BEFORE AUTHENTICATION MUST STILL TERMINATE the consumer. The owner is
    /// completed at first action, so nothing waits on it — but the previous design blocked stream
    /// consumption on a continuation that only the publish path resolved, and an invalid URL
    /// returns before publishing. This control pins the observable property either way: the turn
    /// completes and the identified operation is refused rather than hanging.
    func testInvalidURLTurnTerminatesWithoutPublishingAnOwner() async throws {
        let operationId = "9d41c7ba-50e3-4a62-b1f8-7c0d3e5a8b29"
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let store = InMemoryOperationRecordStore()
        let journal = OperationJournal(store: store)
        // A base URL that cannot be turned into a websocket URL: the client returns BEFORE it ever
        // acquires a credential, so the socket never publishes a session.
        let sink = CloudRouteSink(
            clientFactory: {
                CloudRouteClient(
                    baseURL: "not-a-url",
                    userId: "user_test",
                    requestTimeoutSeconds: 5,
                    tokenProvider: Self.pairedTestProvider()
                )
            },
            isConfigured: { true },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            operationJournal: journal,
            conversationManager: testConversationManager()
        )
        let completed = Task {
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-badurl")
        }
        let terminated = try await timeoutProbe(completed, nanoseconds: 5_000_000_000)
        XCTAssertTrue(terminated, "the turn must terminate, not strand the consumer")
        XCTAssertTrue(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.isEmpty,
                      "no principal ⇒ no effect: \(playback.calls)")
        XCTAssertNil(store.load()[operationId], "and nothing is journaled")
    }

    /// CANCELLATION WHILE THE ACQUISITION IS SUSPENDED. The provider never releases the gate, so
    /// the turn can only end by cancellation — and it must end for the consumer, not wait on
    /// provider cooperation that will never come.
    func testCancellationDuringAcquisitionStillTerminatesTheTurn() async throws {
        let provider = DelayedAcquisitionTokenProvider(
            credential: "never-released", accountId: "never-owner")
        let sink = CloudRouteSink(
            clientFactory: {
                CloudRouteClient.stubbed(
                    baseURL: "https://cloud.test",
                    fixture: "",
                    tokenProvider: provider
                ).client
            },
            isConfigured: { true },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            conversationManager: testConversationManager()
        )
        let turn = Task {
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-cancel-acq")
        }
        // Let it reach the acquisition, then cancel while the provider is still suspended.
        var reached = false
        for _ in 0..<200 {
            if provider.acquisitionCount > 0 { reached = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(reached, "the turn reached the acquisition seam")
        turn.cancel()
        let terminated = try await timeoutProbe(turn, nanoseconds: 5_000_000_000)
        XCTAssertTrue(terminated,
                      "cancellation must terminate the turn without waiting for the provider")
    }

    /// THE OWNER IS COMPLETED AT FIRST USE, NOT SAMPLED AT ADMISSION. `routeWithResultSocket`
    /// starts the transport in an unstructured Task and returns, so the validated acquisition can
    /// complete well after the sink resumed. Sampling the socket then binds an EMPTY owner to a
    /// turn that subsequently authenticates fine — the operation refuses, silently, for no reason
    /// the caller can see.
    ///
    /// This control holds the acquisition shut through admission, then releases it, and asserts
    /// the journaled owner came from that same late fixture — and that the credential on the wire
    /// is the fixture's, so owner and credential are provably one acquisition rather than two
    /// reads that happen to agree.
    /// THE TWO ANSWERS THAT MUST NOT BE CONFLATED. Before this turn acquires, the ownership
    /// question is OPEN and the box must stay incomplete; once the acquisition is frozen — even as
    /// an explicit nil, i.e. "this turn has no principal" — the question is SETTLED and asking
    /// again must not change the answer. Marking the box complete while the freeze is absent
    /// settled the identity as "no owner" before acquisition could ever be observed, which is how
    /// a late acquisition could never reach the gate.
    func testOwnerBoxDistinguishesNotYetAcquiredFromAnExplicitNoPrincipal() async throws {
        let box = await MainActor.run {
            CloudRouteSink.admittedTurnBoxForTesting(conversation: "c-notyet", turn: "t-notyet")
        }
        let socket = AppOperationResultSocket(requestId: "u-notyet")

        // (1) NOT YET ACQUIRED: asking is non-destructive and leaves the box open.
        let beforeAcquisition = await MainActor.run { box.completing(from: socket) }
        XCTAssertTrue(beforeAcquisition.owner.isEmpty,
                      "an unacquired turn has no owner yet — and that is NOT an answer")
        XCTAssertEqual(beforeAcquisition.conversation, "c-notyet")
        XCTAssertEqual(beforeAcquisition.turn, "t-notyet")
        XCTAssertEqual(beforeAcquisition.sessionCredential, "",
                       "no credential may be invented before any acquisition")

        // (2) THE ACQUISITION LANDS: now the SAME socket answers, proving (1) did not settle it.
        await MainActor.run { socket.freezeAcquisition(CloudAuthenticatedSession(
            accountId: "acct-late", accessToken: "credential-late")) }
        let afterAcquisition = await MainActor.run { box.completing(from: socket) }
        XCTAssertEqual(afterAcquisition.owner, "acct-late",
                       "a late acquisition completes the owner, so the earlier ask settled nothing")
        XCTAssertEqual(afterAcquisition.sessionCredential, "credential-late")

        // (3) AN EXPLICIT NO-PRINCIPAL IS A COMPLETED ANSWER on a box that has not completed.
        let blankBox = await MainActor.run {
            CloudRouteSink.admittedTurnBoxForTesting(conversation: "c-noprincipal", turn: "t-noprincipal")
        }
        let blankSocket = AppOperationResultSocket(requestId: "u-noprincipal")
        await MainActor.run { blankSocket.freezeAcquisition(nil) }
        let noPrincipal = await MainActor.run { blankBox.completing(from: blankSocket) }
        XCTAssertTrue(noPrincipal.owner.isEmpty,
                      "a frozen nil is no trusted owner, and the gate refuses it")
        // ...and it is STICKY: a principal arriving afterwards must not take over the answer.
        await MainActor.run { blankSocket.authenticatedSession = CloudAuthenticatedSession(
            accountId: "acct-intruder", accessToken: "credential-intruder") }
        let stillNoPrincipal = await MainActor.run { blankBox.completing(from: blankSocket) }
        XCTAssertEqual(stillNoPrincipal.owner, "",
                       "the completed no-principal answer must not be relabelled afterwards")
    }

    func testOwnerIsCompletedAtFirstActionWhenAcquisitionLandsAfterRouting() async throws {
        let operationId = "5c1e8f42-7a3b-4d05-9c68-2f4b7e9a1d03"
        let provider = DelayedAcquisitionTokenProvider(
            credential: "delayed-credential", accountId: "delayed-owner")
        let store = InMemoryOperationRecordStore()
        let journal = OperationJournal(store: store)
        let cloudConfig = CloudConfig(defaults: defaults)
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // CAPTURE THE TASK THE FACTORY BUILDS. Returning only `.client` discarded the transport the
        // frames were written to, so the later XCTUnwrap(capturedTask) inspected nil and the
        // credential assertion below could never have observed the wire.
        var turnTask: StubWebSocketTask?
        let sink = CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: Self.injectOperationIdentity(self.pendingFixture ?? ""),
                    tokenProvider: provider
                )
                turnTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            // THE MATCHING TARGET OBSERVER. The fixture's precondition names `ep-task67`, so without
            // a provider the sink cannot confirm the current target and the operation is refused as
            // unavailable — which would make the late-acquisition variable untestable here. The
            // missing-observer NEGATIVE lives in its own control
            // (`testSinkWithNoTargetObserverRefusesEpisodeRelativeEffect`) and stays untouched.
            // Declared in SIGNATURE order: the provider precedes the context state.
            currentEpisodeIdProvider: { Self.testEpisodeId },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            operationJournal: journal,
            conversationManager: testConversationManager(),
            appOperationSupportProvider: { self.fixtureSupport("playback.seek_relative") }
        )

        // The turn has been routed but the acquisition is still shut.
        let turn = Task {
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-delayed")
        }
        var observedWaiting = false
        for _ in 0..<200 {
            if provider.acquisitionCount > 0 { observedWaiting = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(observedWaiting, "the client did reach the acquisition seam")

        provider.release()
        _ = await turn.value
        // The refusal path is not what is being tested; if the action ran, ownership resolved.
        let seeks = playback.calls.filter { if case .seekRelative = $0 { return true }; return false }
        XCTAssertEqual(seeks.count, 1,
                       "ownership is completed at first use, so a late acquisition is not a denial: \(playback.calls)")
        // Read the DURABLE record, not an in-sink field: the owner that matters is the one the
        // exactly-once record carries, since that is what a restart replays against.
        let persisted = try XCTUnwrap(store.load()[operationId],
                                      "the operation was admitted, so it is durably recorded")
        guard case let .finished(identity, _) = persisted else {
            return XCTFail("expected a settled record, got \(persisted)")
        }
        XCTAssertEqual(identity.owner, "delayed-owner",
                       "the journaled owner is the one that supplied the credential")
        // THE NEGATIVE CASES STAY: the target observer is live (`ep-task67`), so this operation is
        // not refused for lack of a target, and the only thing under test is late ownership.
        let liveTarget = await MainActor.run { sink.activeResultSocketForTesting != nil }
        XCTAssertTrue(liveTarget, "the turn published a result socket, so admission completed")
        let captured = try XCTUnwrap(turnTask, "the factory returned the task this turn wrote to")
        let sent = await MainActor.run { captured.sentTextFrames }
        let authFrame = try XCTUnwrap(sent.first { $0.contains("\"type\":\"authenticate\"") })
        XCTAssertTrue(authFrame.contains("delayed-credential"),
                      "the transmitted credential is the SAME fixture: \(authFrame)")
    }

    /// POST-TERMINAL PREDECESSOR CLEANUP MUST NOT CLOSE THE SUCCESSOR.
    ///
    /// A successor can only become live through the contract's OWN acknowledgement path: the
    /// predecessor's `done` resolves the interruption (`markAcknowledgement(.acknowledged)`), and
    /// only then may B submit. An earlier revision of this control held A mid-receive with no
    /// terminal, which the production ordering can never acknowledge — B was built and then ended
    /// locally without ever receiving. This control therefore drives the real ordering:
    /// A runs a real action, A's `done` acknowledges, B parks at its own receive, and only THEN is
    /// A cancelled. The property is stated for what it is — post-terminal predecessor cleanup —
    /// and does NOT claim cancellation of an unfinished effect while B is live.
    func testPostTerminalPredecessorCleanupDoesNotCloseTheSuccessorSocket() async throws {
        let operationId = "d95b1e23-4f60-4c80-b137-a02e8d5f9c74"
        // A's action is held at the effect gate BEFORE its effect. `done` is already behind that
        // action in the same receive loop, so it cannot be consumed until the gate is released —
        // releasing the gate is what lets the acknowledgement happen at all.
        let entered = HoldLatch()
        let release = HoldLatch()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":120},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                        conversationManager: testConversationManager(),
                                        operationJournal: OperationJournal(store: InMemoryOperationRecordStore()),
                                        appOperationSupport: fixtureSupport("playback.seek_to"))
        await MainActor.run {
            sink.effectGate = { _ in
                entered.release()                      // bounded "entered" signal
                await release.waitUntilReleased()      // suspension, not a spin
            }
        }
        let clientsBeforeA = await MainActor.run { self.clientCreationCount }
        let owner = Task {
            await sink.routeToCloud(request: "a", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-held-prior")
        }
        let successorGate = HoldLatch()
        var successor: Task<CloudRouteResult, Never>?
        // AWAITED CLEANUP ON EVERY PATH, including a throw: `defer` cannot await, so the work
        // below is wrapped and the catch joins before rethrowing.
        func cleanupTurns() async {
            successorGate.release()
            release.release()
            owner.cancel()
            successor?.cancel()
            _ = await owner.value
            if let successor { _ = await successor.value }
        }
        do {
        await entered.waitUntilReleased()
        let socketA = try XCTUnwrap(capturedTask, "A's socket")
        let publishedASocket = await MainActor.run { sink.activeResultSocketForTesting }
        let resultSocketA = try XCTUnwrap(publishedASocket, "A published its own result socket")
        let aOpenWhileHeld = await MainActor.run { socketA.cancelled == nil }
        XCTAssertTrue(aOpenWhileHeld, "premise: A's socket is open while its effect is held")

        // B is admitted WHILE A is still held, so its interrupt is claimed against a live prior
        // turn — the real barge-in shape. B then waits for that interruption to be acknowledged.
        self.pendingFixture = """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        self.pendingDeclaredPark = successorGate
        self.pendingDeclaredParkAfterFrames = 0
        successor = Task {
            await sink.routeToCloud(request: "b", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-successor")
        }
        // B MUST HAVE ACTUALLY INTERRUPTED A LIVE A. Merely starting B's Task and releasing A's
        // gate at once proves nothing about ordering: the interrupt could be attempted after A had
        // already terminated. So wait, bounded, for the interrupt frame to LEAVE ON A'S SOCKET
        // while A is still held, and fail the premise if it never appears.
        var interruptSeen = false
        var waitedInterrupt = 0
        while !interruptSeen && waitedInterrupt < 500 {
            let held = await MainActor.run { socketA.cancelled == nil }
            if !held { break }
            interruptSeen = await MainActor.run { socketA.sentInterrupt }
            if !interruptSeen { try await Task.sleep(nanoseconds: 10_000_000) }
            waitedInterrupt += 1
        }
        guard interruptSeen else {
            await cleanupTurns()
            return XCTFail("premise failed: B never sent an interrupt on A's socket while A was live")
        }
        let aStillHeldAtInterrupt = await MainActor.run { socketA.cancelled == nil }
        XCTAssertTrue(aStillHeldAtInterrupt,
                      "the interrupt was sent while A was still live — a real barge-in, not a sequel")

        // RELEASING A'S EFFECT GATE IS WHAT PRODUCES THE ACKNOWLEDGEMENT: A's action completes,
        // A's receive loop reaches `done`, and that terminal marks the interruption acknowledged.
        release.release()
        _ = await owner.value

        // NOW B PROCEEDS — through the ordinary path, not a bypass — to its own receive park.
        var socketB: StubWebSocketTask?
        var waited = 0
        var premise = "no second client was ever built"
        while waited < 500 {
            let observation = await MainActor.run {
                (count: self.clientCreationCount,
                 task: self.capturedTask,
                 parked: self.capturedTask?.didParkInReceive ?? false)
            }
            if observation.count < clientsBeforeA + 2 {
                premise = "only \(observation.count - clientsBeforeA) of 2 client(s) built"
            } else if let task = observation.task, task !== socketA {
                if observation.parked {
                    socketB = task
                    break
                }
                premise = "B's own task is built but never parked in its receive"
            } else {
                premise = "a client was built but capturedTask is still A's"
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        guard let socketB else {
            await cleanupTurns()
            return XCTFail("premise failed after 5s: \(premise)")
        }
        XCTAssertFalse(socketA === socketB, "the turns have distinct sockets")
        let sentByBBefore = await MainActor.run { socketB.sentTextFrames.count }
        let bOpenWhileLive = await MainActor.run { socketB.cancelled == nil }
        XCTAssertTrue(bOpenWhileLive, "premise: B's socket is open while B is genuinely live")

        // REPEATED PREDECESSOR-REGISTRATION CLEANUP. `owner.cancel()` after the owner has already
        // RETURNED cancels a completed task and runs no cancellation handler, so it would not
        // execute the cleanup being claimed. Instead the turn's OWN retained result socket is
        // exercised through its existing idempotent `finishTurn()`, which is exactly what a
        // repeated post-terminal cleanup does to that registration.
        let aRetiredBefore = await MainActor.run { socketA.cancelled != nil }
        XCTAssertTrue(aRetiredBefore, "A's socket retired when its own turn ended")
        await MainActor.run { resultSocketA.finishTurn() }
        await MainActor.run { resultSocketA.finishTurn() }

        let bClosed = await MainActor.run { socketB.cancelled != nil }
        XCTAssertFalse(bClosed, "repeated predecessor-registration cleanup must not close the successor")
        let bStillOpenAfter = await MainActor.run { socketB.cancelled == nil }
        XCTAssertTrue(bStillOpenAfter, "B remains open after the predecessor's registration is cleaned")

        let sentByBAfter = await MainActor.run { socketB.sentTextFrames.count }
        XCTAssertEqual(sentByBAfter, sentByBBefore,
                       "no result for A's operation may be sent on B's socket")
        } catch {
            await cleanupTurns()
            throw error
        }
        await cleanupTurns()
    }

    /// TWO ACTIONS, ONE TURN, SESSION SWITCHED IN BETWEEN. The identity is completed once and
    /// stored, so the second action must be judged against the account the turn ADMITTED, not
    /// against whatever the socket names at the moment it is handled. A pure "complete per call"
    /// function passes this test only if the socket never changes — which is the case it misses.
    func testSecondActionOnOneTurnCannotRecaptureADifferentAccount() async throws {
        let manager = testConversationManager()
        let store = InMemoryOperationRecordStore()
        let journal = OperationJournal(store: store)
        let cloudConfig = CloudConfig(defaults: defaults)
        let firstId = "b73f9c01-2d4e-4a86-9f15-8c0e6b3d7a52"
        let secondId = "c84a0d12-3e5f-4b97-a026-9d1f7c4e8b63"
        let sink = CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: Self.injectOperationIdentity(""),
                    tokenProvider: Self.pairedTestProvider()
                )
                self.capturedTask = built.task
                self.capturedClient = built.client
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            operationJournal: journal,
            conversationManager: manager,
            appOperationSupportProvider: { self.fixtureSupport("playback.seek_relative") }
        )
        self.pendingFixture = """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        hookedSink = sink
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-two-actions")
        // Resolved into a local BEFORE XCTUnwrap: its argument is an autoclosure, which cannot
        // carry an `await`. Swept wherever this shape appears, not just here.
        let liveSocket = await MainActor.run { sink.activeResultSocketForTesting }
        let socket = try XCTUnwrap(liveSocket)
        let client = try XCTUnwrap(capturedClient)
        let box = await MainActor.run {
            CloudRouteSink.admittedTurnBoxForTesting(
                conversation: "2d5b0e81-7c3a-4f62-b904-18e3c5a9d7f1",
                turn: "8e0c35f6-9d4b-4a17-8f26-42c6b1f05e99")
        }

        // FIRST action: the turn's own account.
        await sink.executeActionForTesting(
            action: "seek_relative", params: ["delta_seconds": .int(5)],
            operationId: firstId, capabilityVersion: "app-ops/1",
            actionBytes: Self.deliveredPayload(for: firstId, in: """
                event: action
                data: {"operation_id":"\(firstId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

                """)?.data(using: .utf8),
            precondition: ["episode_id": .string(Self.testEpisodeId)],
            admittedTurnBox: box, admittedTurnSocket: socket, admittedTurnClient: client,
            negotiatedSupport: fixtureSupport("playback.seek_relative")
        )

        // The account on the live socket switches BEFORE the second action is handled.
        socket.authenticatedSession = CloudAuthenticatedSession(
            accountId: "account-SWITCHED", accessToken: "credential-SWITCHED")

        // SECOND action on the SAME turn and the SAME box.
        await sink.executeActionForTesting(
            action: "seek_relative", params: ["delta_seconds": .int(7)],
            operationId: secondId, capabilityVersion: "app-ops/1",
            actionBytes: Self.deliveredPayload(for: secondId, in: """
                event: action
                data: {"operation_id":"\(secondId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":7},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

                """)?.data(using: .utf8),
            precondition: ["episode_id": .string(Self.testEpisodeId)],
            admittedTurnBox: box, admittedTurnSocket: socket, admittedTurnClient: client,
            negotiatedSupport: fixtureSupport("playback.seek_relative")
        )

        let records = store.load()
        let first = try XCTUnwrap(records[firstId], "the first action was admitted")
        guard case let .finished(firstIdentity, _) = first else {
            return XCTFail("expected the first action to settle, got \(first)")
        }
        XCTAssertEqual(firstIdentity.owner, "test-owner",
                       "the first action belongs to the account that authenticated")
        // The second must ALSO be judged against that account. Under the switched socket, if the
        // identity were recaptured per call, it would be journaled under account-SWITCHED.
        if let second = records[secondId] {
            guard case let .finished(secondIdentity, _) = second else { return }
            XCTAssertEqual(secondIdentity.owner, "test-owner",
                           "a second action cannot be relabelled by a later account switch")
        }
        XCTAssertFalse(records.values.contains { record in
            if case let .finished(identity, _) = record { return identity.owner == "account-SWITCHED" }
            return false
        }, "no operation may be journaled under an account the turn never admitted: \(records)")
    }

    /// A DELAYED PRIOR-TURN ACTION MUST NOT RIDE THE SUCCESSOR. Turn A's action is delivered after
    /// turn B has been admitted and has replaced the live socket. The operation must be refused and
    /// answered on A's OWN socket — never attributed to B, never sent on B's socket.
    ///
    /// This is the control for reading the mutable `activeResultSocket` as evidence of ownership:
    /// with that read, A's late action would be checked against B's session, pass the
    /// "still the admitted one" test on the wrong turn, and send a result frame on B.
    /// BOUNDARY-LEVEL ACCOUNT CONTINUITY: THE CHECK MUST READ THE ADMITTED SOCKET, NOT THE LIVE ONE.
    ///
    /// A and B are admitted SEQUENTIALLY, so `activeResultSocket` now points at B while A's own
    /// socket is retained. If the session re-check read the sink's live socket instead of the one
    /// the identity was captured from, it would compare B's account against A's admitted owner and
    /// — when those happened to agree — authorise A's operation. Here they deliberately DISAGREE:
    /// A's mutable paired session is moved to a different account while B keeps the original, so a
    /// control that read the live socket would journal and execute, and this one must refuse.
    ///
    /// This is a BOUNDARY-LEVEL ACCOUNT-CONTINUITY test of that binding, nothing wider:
    /// `executeActionForTesting` enters below the turnLoop's cancellation/supersession guards, so
    /// nothing here asserts anything about delivery ordering or turn liveness in production.
    func testRetainedSocketAccountContinuityRefusesEvenWhenTheLiveSocketDisagrees() async throws {
        let manager = testConversationManager()
        let journal = OperationJournal(store: InMemoryOperationRecordStore())
        let aDelivery = HoldLatch()
        self.pendingDeclaredPark = aDelivery
        self.pendingDeclaredParkAfterFrames = 0
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                       operationJournal: journal,
                                       appOperationSupport: fixtureSupport("playback.seek_relative"))

        let operationId = "e07c4b23-6a1d-4f89-b5c2-3d8e9a0f1b47"
        self.pendingFixture = ""
        let clientsBeforeA = await MainActor.run { self.clientCreationCount }
        let turnA = Task {
            await sink.routeToCloud(request: "a", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-prior")
        }
        let successorGate = HoldLatch()
        var turnB: Task<CloudRouteResult, Never>?
        func cleanupTurns() async {
            aDelivery.release()
            successorGate.release()
            turnA.cancel()
            turnB?.cancel()
            _ = await turnA.value
            if let turnB { _ = await turnB.value }
        }
        do {
        var aParked = false
        var waitedA = 0
        while !aParked && waitedA < 500 {
            aParked = await MainActor.run { self.capturedTask?.didParkInReceive ?? false }
            if !aParked { try await Task.sleep(nanoseconds: 10_000_000) }
            waitedA += 1
        }
        guard aParked else {
            await cleanupTurns()
            return XCTFail("premise failed: A never parked, so it is not a live prior turn")
        }
        let transportA = try XCTUnwrap(capturedTask, "turn A's transport was captured")
        let clientA = try XCTUnwrap(capturedClient, "turn A's client was captured")
        let publishedSocketA = await MainActor.run { sink.activeResultSocketForTesting }
        let resultSocketA = try XCTUnwrap(publishedSocketA, "A published its own result socket")

        // A'S BOX AND IDENTITY ARE COMPLETED FROM A'S OWN FROZEN ACQUISITION, BEFORE ITS TERMINAL.
        let identity = try XCTUnwrap(Self.mintedIdentity(for: "u-prior", manager: manager,
                                                         bytes: Self.lateActionPayload(operationId)))
        let box = await MainActor.run {
            CloudRouteSink.admittedTurnBoxForTesting(
                conversation: identity.conversation, turn: identity.turn)
        }
        let aIdentity = await MainActor.run { box.completing(from: resultSocketA) }
        XCTAssertEqual(aIdentity.owner, "test-owner",
                       "A's box is completed from A's OWN frozen acquisition, not a later account")

        // A TERMINATES FIRST, ON ITS OWN. No B exists yet, so this is not an acknowledgement.
        await MainActor.run { transportA.appendInboundText(#"{"type":"done","usage":{"input_tokens":1,"output_tokens":0}}"#) }
        aDelivery.release()
        var aServed = false
        var waitedServed = 0
        while !aServed && waitedServed < 500 {
            aServed = await MainActor.run { transportA.servedInboundTexts.contains { $0.contains(#""type":"done""#) } }
            if !aServed { try await Task.sleep(nanoseconds: 10_000_000) }
            waitedServed += 1
        }
        XCTAssertTrue(aServed, "premise: A's own terminal was served, ending A's turn")
        _ = await turnA.value

        // ORDINARY SEQUENTIAL ADMISSION: B is simply the next turn and parks with the ORIGINAL
        // account, so a live-socket read would find a session that AGREES with A's admitted owner.
        self.pendingFixture = """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        self.pendingDeclaredPark = successorGate
        self.pendingDeclaredParkAfterFrames = 0
        turnB = Task {
            await sink.routeToCloud(request: "b", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-successor")
        }
        var transportB: StubWebSocketTask?
        var waitedB = 0
        var premise = "no second client was ever built"
        while waitedB < 500 {
            let observation = await MainActor.run {
                (count: self.clientCreationCount,
                 task: self.capturedTask,
                 parked: self.capturedTask?.didParkInReceive ?? false)
            }
            if observation.count < clientsBeforeA + 2 {
                premise = "only \(observation.count - clientsBeforeA) of 2 client(s) built"
            } else if let task = observation.task, task !== transportA {
                if observation.parked {
                    transportB = task
                    break
                }
                premise = "B's own task is built but never parked in its receive"
            } else {
                premise = "a client was built but capturedTask is still A's"
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            waitedB += 1
        }
        guard let transportB else {
            await cleanupTurns()
            return XCTFail("premise failed after 5s: \(premise)")
        }
        XCTAssertFalse(transportA === transportB, "the turns have distinct transports")
        let sentByBBefore = await MainActor.run { transportB.sentTextFrames.count }

        // THE DISAGREEMENT THIS CONTROL EXISTS FOR: the sink's live socket is now B's, and B still
        // holds the ORIGINAL account, so reading the live socket would authorise A's operation.
        let liveSocketIsB = await MainActor.run { sink.activeResultSocketForTesting !== resultSocketA }
        XCTAssertTrue(liveSocketIsB, "the live socket is B's, not A's — the contrast is real")
        let liveAccountIsOriginal = await MainActor.run {
            sink.activeResultSocketForTesting?.authenticatedSession?.accountId
        }
        XCTAssertEqual(liveAccountIsOriginal, "test-owner",
                       "a live-socket read would find an account that AGREES with A's owner")

        // ONLY A'S OWN MUTABLE SESSION MOVES. A's frozen identity and full payload are untouched.
        await MainActor.run { resultSocketA.authenticatedSession = CloudAuthenticatedSession(
            accountId: "account-CHANGED", accessToken: "credential-CHANGED") }

        await sink.executeActionForTesting(
            action: "seek_relative", params: ["delta_seconds": .int(5)],
            operationId: operationId, capabilityVersion: "app-ops/1",
            actionBytes: Data(Self.lateActionPayload(operationId).utf8),
            precondition: ["episode_id": .string(Self.testEpisodeId)],
            admittedTurnBox: box, admittedTurnSocket: resultSocketA, admittedTurnClient: clientA,
            negotiatedSupport: fixtureSupport("playback.seek_relative")
        )

        // A FRESH READ OF THE SAME BOX AFTER THE SESSION MOVED. Asserting on a local copy taken
        // before the change would only re-assert what was already true then, which proves nothing
        // about what the gate now sees; the box is asked again through the same socket.
        let afterChangeOwner = await MainActor.run { box.completing(from: resultSocketA).owner }
        XCTAssertEqual(afterChangeOwner, "test-owner",
                       "the admitted owner stays frozen from A's original acquisition despite the change")
        XCTAssertTrue(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.isEmpty,
                      "the changed session must refuse before any effect: \(playback.calls)")
        let sentByBAfter = await MainActor.run { transportB.sentTextFrames.count }
        XCTAssertEqual(sentByBAfter, sentByBBefore,
                       "nothing from A's operation may travel on B's socket")
        XCTAssertNil(journal.result(for: operationId),
                     "nothing may be settled under any account — including B's or the changed one")
        } catch {
            await cleanupTurns()
            throw error
        }
        await cleanupTurns()
    }

    /// ACCOUNT SWITCH: the session on the turn's own socket no longer names the admitted account,
    /// so the operation is refused rather than journaled under an identity that no longer holds.
    func testAccountSwitchAfterAdmissionRefusesWithoutExecuting() async throws {
    // Declared OUTSIDE `do` so the throwing path can release and join the turn.
    let turnGate = HoldLatch()
    var turn: Task<CloudRouteResult, Never>?
    do {
            let operationId = "a1d8e365-4f70-4c92-8b03-6e5f2a9d7c18"
            let journal = OperationJournal(store: InMemoryOperationRecordStore())
            // THE ORIGINAL ACTION FRAME, RETAINED INDEPENDENTLY OF ROUTING. `routeToCloud` CONSUMES
            // `pendingFixture`, so the previous revision derived `actionBytes` from a fixture that by
            // then contained only `done` — the bytes were nil and the operation was refused as
            // unaccountable without the switch ever being consulted. The payload is captured here from
            // the fixture text BEFORE routing hands it to the turn, and the routed turn itself carries
            // no action, so nothing executes during admission.
            let actionFixture = """
                event: action
                data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

                event: done
                data: {"usage":{"input_tokens":1,"output_tokens":0}}

                """
            let retainedActionBytes = try XCTUnwrap(
                Self.deliveredPayload(for: operationId, in: actionFixture),
                "the original action payload is retained for the whole control").data(using: .utf8)
            self.pendingFixture = """
                event: done
                data: {"usage":{"input_tokens":1,"output_tokens":0}}

                """
            // HOLD THE ORIGINAL TURN ALIVE AT AN AWAITED PARK, INSIDE `receive()`.
            // `armedReceivePark` is awaited by the producer itself, so it BLOCKS that producer. The
            // `onFrameReceived` hook that sets `declaredParkDidPark` only launches an unawaited Task
            // and blocks nothing — it is not the hold and must not be treated as one.
            // Threshold 0: `framesServedForPark` counts inbound `receive()` calls, and outbound
            // authenticate is not one of them. This fixture's only inbound frame is the terminal
            // `done`, so the FIRST `receive()` — which happens after credential acquisition — must
            // park. That is the ordering this control needs: acquired, not yet terminated.
            self.pendingDeclaredPark = turnGate
            self.pendingDeclaredParkAfterFrames = 0
            let manager = testConversationManager()
            let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                           conversationManager: manager,
                                           operationJournal: journal,
                                           appOperationSupport: fixtureSupport("playback.seek_relative"))
            // The turn is held inside the socket, so routing does NOT return yet.
            turn = Task {
                await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                        origin: cloudTestOrigin, selection: nil, utteranceId: "u-switch")
            }
            // RELEASE AND AWAIT ON EVERY EXIT: a failed assertion must not leave a parked producer, and
            // the released turn must be JOINED so it cannot leak into the next test.
            defer { turnGate.release() }
            // PARKED SIGNAL FROM THE AWAITED PARK ITSELF: `didParkInReceive` is set inside `receive()`
            // immediately before it suspends, so it reports the producer blocked AT the receive seam —
            // the sole inbound frame is `done` and it has not been served.
            var heldAtReceive = false
            var waited = 0
            while !heldAtReceive && waited < 500 {
                heldAtReceive = await MainActor.run { self.capturedTask?.didParkInReceive ?? false }
                if !heldAtReceive { try await Task.sleep(nanoseconds: 10_000_000) }
                waited += 1
            }
            XCTAssertTrue(heldAtReceive,
                          "the producer is parked inside the awaited receive() — the real hold")
            // Hoisted: `XCTUnwrap` takes an autoclosure, which cannot carry `await`.
            let publishedSocketValue = await MainActor.run { sink.activeResultSocketForTesting }
            let publishedSocket = try XCTUnwrap(
                publishedSocketValue, "the turn published a result socket")
            let liveTurn = try XCTUnwrap(turn as Task<CloudRouteResult, Never>?, "the turn was started")
            XCTAssertFalse(liveTurn.isCancelled, "the original turn is still live while the action is delivered")
            // THE IDENTITY THIS TURN WAS ADMITTED UNDER, read back through the manager's own retained
            // preparation (`prepare` memoises per utterance), so the gate is given the turn's REAL
            // conversation/turn rather than minted stand-ins.
            let admitted = try XCTUnwrap(Self.mintedIdentity(
                for: "u-switch", manager: manager, bytes: ""),
                "the turn's admitted identity is retained")
            let admittedConversation = admitted.conversation
            let admittedTurn = admitted.turn

            // PRECONDITION: routing alone ran no effect. Without this the gate below would be
            // unfalsifiable — an earlier execution would masquerade as this one's zero.
            XCTAssertTrue(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.isEmpty,
                          "the routed turn carried no action, so nothing executed: \(playback.calls)")

            // The published session now belongs to a different account than the admitted one. This is
            // the very object the turn published through, mutated WHILE THE TURN IS STILL LIVE and
            // before the action is handed to the gate.
            let liveSocket = publishedSocket
            let liveClient = try XCTUnwrap(capturedClient, "the turn's own client")
            // The ADMITTED account is still that of the turn that opened this socket; only now does the
            // live session disagree. Recorded so the assertion below is about a real divergence.
            let admittedAccount = await MainActor.run { liveSocket.authenticatedSession?.accountId }
            XCTAssertFalse(admittedAccount?.isEmpty ?? true,
                           "the turn admitted a real paired account to begin with")

            // COMPLETE THE TURN'S OWNER **BEFORE** THE SWITCH. `completingOwner` derives the owner from
            // the socket's CURRENT session, so completing after the switch would anchor the owner to
            // the account that arrived second — and the gate would then (rightly) call it a conflict
            // for the wrong reason. First completion wins and is sticky, so this capture is the turn's
            // original owner for the rest of the control.
            let turnBox = await MainActor.run {
                CloudRouteSink.admittedTurnBoxForTesting(
                    conversation: admittedConversation, turn: admittedTurn)
            }
            let completedOwner = await MainActor.run { turnBox.completing(from: liveSocket).owner }
            XCTAssertEqual(completedOwner, admittedAccount,
                           "the turn's completed owner IS the original account that opened this socket")

            // NOW the switch: same socket object, different account.
            liveSocket.authenticatedSession = CloudAuthenticatedSession(
                accountId: "acct-SWITCHED", accessToken: "credential-SWITCHED")
            let switchedAccount = await MainActor.run { liveSocket.authenticatedSession?.accountId }
            XCTAssertNotEqual(switchedAccount, admittedAccount,
                              "the live session genuinely diverged from the admitted one")
            let reCompletedOwner = await MainActor.run { turnBox.completing(from: liveSocket).owner }
            XCTAssertEqual(reCompletedOwner, completedOwner,
                           "the completed owner stays sticky across the switch — the box is not relabelled")
            let params: [String: CloudRouteJSONValue] = ["delta_seconds": .int(5)]
            await sink.executeActionForTesting(
                action: "seek_relative", params: params,
                operationId: operationId, capabilityVersion: "app-ops/1",
                actionBytes: retainedActionBytes,
                precondition: ["episode_id": .string(Self.testEpisodeId)],
                admittedTurnBox: turnBox,
                admittedTurnSocket: liveSocket,
                admittedTurnClient: liveClient,
                negotiatedSupport: fixtureSupport("playback.seek_relative")
            )

            XCTAssertTrue(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.isEmpty,
                          "an account switch must not execute under the old identity: \(playback.calls)")
            XCTAssertNil(journal.result(for: operationId),
                         "and must not be journaled under either account")

            // JOIN THE ORIGINAL TURN. It is still parked; release it and wait for it to finish so no
            // surviving task can leak into the next test.
            turnGate.release()
            _ = await turn?.value
            XCTAssertTrue(turnGate.released, "the park was released exactly once")

        } catch {
            turnGate.release()
            _ = await turn?.value
            throw error
        }
    }

    /// MATCHED-ACCOUNT POSITIVE CONTROL for the seam above: the SAME held-live turn, the SAME
    /// completed owner, the SAME retained bytes and the SAME direct injection — but the live session
    /// is never switched. It must EXECUTE once and settle durably. Without this, the zero-effect
    /// result in the switch control could be explained by the turn being retired or by the
    /// injection path being unable to run at all, neither of which is the account gate.
    func testAccountUnchangedAtTheSameSeamExecutesOnceAndSettles() async throws {
    // Declared OUTSIDE `do` so the throwing path can release and join the turn.
    let turnGate = HoldLatch()
    var turn: Task<CloudRouteResult, Never>?
    do {
            let operationId = "c4f2a9d8-1b63-4e07-8a52-6d9e3b0f7c15"
            let journal = OperationJournal(store: InMemoryOperationRecordStore())
            let actionFixture = """
                event: action
                data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

                event: done
                data: {"usage":{"input_tokens":1,"output_tokens":0}}

                """
            let retainedActionBytes = try XCTUnwrap(
                Self.deliveredPayload(for: operationId, in: actionFixture)).data(using: .utf8)
            self.pendingFixture = """
                event: done
                data: {"usage":{"input_tokens":1,"output_tokens":0}}

                """
            // IDENTICAL SEAM to the switch control: the SAME AWAITED park inside `receive()`, entered
            // by the first (post-acquisition) inbound receive, i.e. before the terminal `done`.
            self.pendingDeclaredPark = turnGate
            self.pendingDeclaredParkAfterFrames = 0
            let manager = testConversationManager()
            // ONE FROZEN VALUE at both boundaries: the routed sink's provider and the seam's
            // negotiatedSupport are the same support object, as the ruling requires.
            let declaredSupport = fixtureSupport("playback.seek_relative")
            let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                           conversationManager: manager,
                                           operationJournal: journal,
                                           appOperationSupport: declaredSupport)
            turn = Task {
                await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                        origin: cloudTestOrigin, selection: nil, utteranceId: "u-matched")
            }
            defer { turnGate.release() }
            // EXPLICIT PARKED SIGNAL from the awaited park, same as the switch control.
            var parked = false
            var waited = 0
            while !parked && waited < 500 {
                parked = await MainActor.run { self.capturedTask?.didParkInReceive ?? false }
                if !parked { try await Task.sleep(nanoseconds: 10_000_000) }
                waited += 1
            }
            XCTAssertTrue(parked, "the producer is parked inside the awaited receive()")
            let parkedSocketValue = await MainActor.run { sink.activeResultSocketForTesting }
            let liveSocket = try XCTUnwrap(
                parkedSocketValue, "the turn published a result socket")
            let liveTurnA = try XCTUnwrap(turn as Task<CloudRouteResult, Never>?, "the turn was started")
            XCTAssertFalse(liveTurnA.isCancelled, "the turn is still live when the action is delivered")

            let admitted = try XCTUnwrap(Self.mintedIdentity(
                for: "u-matched", manager: manager, bytes: ""))
            let turnBox = await MainActor.run {
                CloudRouteSink.admittedTurnBoxForTesting(
                    conversation: admitted.conversation, turn: admitted.turn)
            }
            let owner = await MainActor.run { turnBox.completing(from: liveSocket).owner }
            XCTAssertFalse(owner.isEmpty, "a paired account was established at admission")
            let liveAccount = await MainActor.run { liveSocket.authenticatedSession?.accountId }
            XCTAssertEqual(owner, liveAccount,
                           "the live session still names the admitted account — the ONLY difference")

            let params: [String: CloudRouteJSONValue] = ["delta_seconds": .int(5)]
            await sink.executeActionForTesting(
                action: "seek_relative", params: params,
                operationId: operationId, capabilityVersion: "app-ops/1",
                actionBytes: retainedActionBytes,
                precondition: ["episode_id": .string(Self.testEpisodeId)],
                admittedTurnBox: turnBox,
                admittedTurnSocket: liveSocket,
                admittedTurnClient: try XCTUnwrap(capturedClient),
                negotiatedSupport: declaredSupport
            )

            // THE POSITIVE: one effect, and a durable settlement under the same owner.
            XCTAssertEqual(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count, 1,
                           "with the account unchanged the operation executes exactly once: \(playback.calls)")
            XCTAssertNotNil(journal.result(for: operationId),
                            "and it settles durably — the seam is capable of a settlement")

            // JOIN THE TURN so a surviving task cannot leak into the next test.
            turnGate.release()
            _ = await turn?.value

        } catch {
            turnGate.release()
            _ = await turn?.value
            throw error
        }
    }

    /// NO PRINCIPAL: an identified app operation is REFUSED with zero effects and is NOT
    /// journaled under a fabricated owner. This is the production shape today — the TOT bearer
    /// carries the turn but establishes no principal — so it is a control, not a hypothetical.
    func testAppOperationWithoutAnEstablishedPrincipalIsRefusedAndNotJournaled() async throws {
        let operationId = "3f7b2c19-5d84-4e26-b093-8c1a7f4d6e02"
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let journal = OperationJournal(store: InMemoryOperationRecordStore())
        let cloudConfig = CloudConfig(defaults: defaults)
        // CAPTURE THIS SINK'S OWN STUB TASK. The factory previously returned only `.client`, so the
        // task the frames were written to was discarded and `awaitResultFrame` inspected a nil
        // `capturedTask` — reporting "no frame arrived" for a refusal that may well have been sent.
        // A nil observation is not the refusal outcome; the turn's own task has to be read.
        var turnTask: StubWebSocketTask?
        let sink = CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: Self.injectOperationIdentity(self.pendingFixture ?? ""),
                    // PRODUCTION SHAPE: no principal — the turn authenticates with a bare
                    // transport bearer, so the real acquisition yields no paired session.
                    tokenProvider: StubTokenProvider(token: "test_token", accountId: "")
                )
                turnTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            operationJournal: journal,
            conversationManager: testConversationManager(),
            appOperationSupportProvider: { self.fixtureSupport("playback.seek_relative") }
        )
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-noprincipal")

        XCTAssertTrue(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.isEmpty,
                      "no principal means no authority: \(playback.calls)")
        // THE ASSERTION SOURCE IS THE TURN'S OWN TASK, not the production diagnostic observer.
        let entry = try XCTUnwrap(turnTask, "the factory returned the task this turn wrote to")
        let frame = try await awaitResultFrame(
            operationId: operationId,
            on: entry,
            label: "the sink's own clientFactory task")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.invalidRequest,
                       "an unaccountable operation is invalid_request, not a fabricated success")
        XCTAssertNil(journal.result(for: operationId),
                     "nothing may be journaled under an owner that was never established")
    }

    /// FAIL CLOSED: a sink that cannot observe the current target must NOT authorize an
    /// episode-relative effect. "I cannot check whether this proposal is still for the current
    /// episode" is not permission — it is an unavailable target, refused with zero effects.
    func testSinkWithNoTargetObserverRefusesEpisodeRelativeEffect() async throws {
        let operationId = "8f3a5c62-1b94-4d68-a0e7-5c2d9b1f3a86"
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // Neither an injected provider nor a manager: this sink cannot answer the question.
        let cloudConfig = CloudConfig(defaults: defaults)
        // CAPTURE THIS SINK'S OWN STUB TASK. The factory used to return only `.client`, so nothing
        // recorded the task the frames were actually written to and the assertion inspected a nil
        // `capturedTask` — reporting 0 frames for a send that demonstrably happened.
        var turnTask: StubWebSocketTask?
        let sink = CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: Self.injectOperationIdentity(self.pendingFixture ?? ""),
                    tokenProvider: Self.pairedTestProvider()
                )
                turnTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            operationJournal: OperationJournal(store: InMemoryOperationRecordStore()),
            conversationManager: testConversationManager(),
            appOperationSupportProvider: { self.fixtureSupport("playback.seek_relative") }
        )
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-nobserve")
        XCTAssertTrue(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.isEmpty,
                      "an unverifiable target must not release an effect: \(playback.calls)")
        // THE ASSERTION SOURCE IS THE TURN'S OWN TASK, not the production diagnostic observer.
        let entry = try XCTUnwrap(turnTask, "the factory returned the task this turn wrote to")
        let frame = try await awaitResultFrame(
            operationId: operationId,
            on: entry,
            label: "the sink's own clientFactory task")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.stalePrecondition)
    }

    /// A REQUEST THAT CANNOT RUN IS STILL ANSWERED. A wrong-typed parameter must reach the sink,
    /// run ZERO effects, and settle a TYPED refusal the server can read — not disappear at the
    /// parser, which would leave the issued operation unanswered.
    func testInvalidParametersReachATypedRefusalWithNoEffect() async throws {
        let operationId = "b1a7c9d2-4e35-4c81-9f60-2d8e5a71c4fb"
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":"5"},"precondition":{"episode_id":"\(Self.testEpisodeId)"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-params-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        let identity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-invalid", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: operationId, in: self.pendingFixture ?? ""))
        ))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                       operationJournal: journal,
                                       appOperationSupport: fixtureSupport("playback.seek_relative"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-invalid")

        let relativeSeeks = playback.calls.filter {
            if case .seekRelative = $0 { return true }
            return false
        }
        XCTAssertTrue(relativeSeeks.isEmpty, "a string delta must never become a seek: \(playback.calls)")

        let frame = try await awaitResultFrame(operationId: operationId)
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.malformedSeekTarget)
        XCTAssertNil(frame["state"], "a refusal carries no state")
        // And the refusal is durable: a redelivery replays it instead of re-deciding.
        if case .alreadyRun(let recorded) = journal.claim(operationId, identity: identity) {
            XCTAssertEqual(recorded.outcome, .refused)
        } else {
            XCTFail("the refusal was not durably recorded")
        }
    }

    /// A MISSING TARGET IDENTITY is the wire's generic `invalid_request`, and it is a different
    /// answer from an unexecutable action — the distinction the server acts on.
    func testMissingEpisodeIdentityIsRefusedInvalidRequest() async throws {
        let operationId = "c4e18d73-9b26-4f50-8a17-6e2b3c9d0f5a"
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":42}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                       conversationManager: testConversationManager(),
                                       operationJournal: OperationJournal(store: InMemoryOperationRecordStore()),
                                       appOperationSupport: fixtureSupport("playback.seek_to"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-noep")
        let frame = try await awaitResultFrame(operationId: operationId)
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.invalidRequest)
        XCTAssertTrue(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.isEmpty,
                      "no effect for an unattributed target")
    }

    /// A TARGET THAT IS NO LONGER CURRENT is `stale_precondition`: the server can act on it,
    /// because the proposal was formed for an episode the user has left.
    func testStaleTargetIsRefusedStalePrecondition() async throws {
        let operationId = "d9f20a64-3c78-4b19-95ee-7a1f8b02c3d6"
        self.pendingFixture = """
            event: action
            data: {"operation_id":"\(operationId)","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":42},"precondition":{"episode_id":"ep-abandoned"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // The app has moved to a different episode since the proposal was formed.
        let sink = makeSinkWithConsumer(RecordingResultConsumer(),
                                       conversationManager: testConversationManager(),
                                       operationJournal: OperationJournal(store: InMemoryOperationRecordStore()),
                                       currentEpisodeId: { "ep-now-playing" },
                                       appOperationSupport: fixtureSupport("playback.seek_to"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-stale")
        let frame = try await awaitResultFrame(operationId: operationId)
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.stalePrecondition)
        XCTAssertTrue(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.isEmpty,
                      "a stale proposal must not seek in whatever episode is loaded now")
    }

    /// ACTION-OUTCOME PROPAGATION: an unknown action under the runtime gate is a REFUSAL
    /// (unsupported_operation) with nothing executed and no fabricated success — the server
    /// reads an honest outcome for an operation it identified.
    func testUnknownIdentifiedActionIsRefusedUnsupportedOperationNotFabricatedSuccess() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"02365fa8-ee9a-4000-a8bd-943c9da8859a","capability_version":"app-ops/1","tool":"playback","action":"teleport","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unknown-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        let identity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-25", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: "02365fa8-ee9a-4000-a8bd-943c9da8859a", in: self.pendingFixture ?? ""))
        ))
        let sink = makeSinkWithConsumer(consumer, conversationManager: manager, operationJournal: journal, appOperationSupport: fixtureSupport("playback.seek_to"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-25")

        // The turn's own auto-duck may pause/resume; the unknown action itself must effect nothing.
        let effectCalls = playback.calls.filter { switch $0 { case .pause, .resume: return false; default: return true } }
        XCTAssertTrue(effectCalls.isEmpty, "an unknown action executes nothing: \(playback.calls)")
        let frame = try await awaitResultFrame(operationId: "02365fa8-ee9a-4000-a8bd-943c9da8859a")
        XCTAssertEqual(frame["outcome"] as? String, "refused", "the server is not told an unknown action succeeded")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.unsupportedOperation)
        XCTAssertNil(frame["state"], "a refusal carries no state")
        // The refusal is also the journal's record: a redelivery replays the refusal.
        if case .alreadyRun(let recorded) = journal.claim("02365fa8-ee9a-4000-a8bd-943c9da8859a", identity: identity) {
            XCTAssertEqual(recorded.outcome, .refused)
        } else {
            XCTFail("the refusal was not durably recorded")
        }
    }

    // MARK: - Typed journal persistence/replay + action-outcome propagation

    /// Waits (bounded) for the app_operation_result frame named by `operationId` on the current
    /// captured transport.
        /// REAL PRECONDITION (review 5295572f): with NO current episode (zero duration), the
    /// system seek wrapper early-returns and its silent response is NOT a success — the honest
    /// durable outcome is a refusal, and no seek is attempted.
    func testSeekToWithNoCurrentEpisodeIsRefusedStalePrecondition() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"3933547d-c3c2-4003-a81f-94a43f67b972","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":42},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seek-noep-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        let identity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-26", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: "3933547d-c3c2-4003-a81f-94a43f67b972", in: self.pendingFixture ?? ""))
        ))
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            conversationManager: manager,
            operationJournal: journal,
            episodeAvailable: { false },
        appOperationSupport: fixtureSupport("playback.seek_to"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-26")
        let frame = try await awaitResultFrame(operationId: "3933547d-c3c2-4003-a81f-94a43f67b972")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.stalePrecondition)
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0,
                       "no seek is attempted without an episode")
        if case .alreadyRun(let recorded) = journal.claim("3933547d-c3c2-4003-a81f-94a43f67b972", identity: identity) {
            XCTAssertEqual(recorded.outcome, .refused)
        } else {
            XCTFail("the refusal was not durably settled")
        }
    }

    /// REAL PRECONDITION, reference form: seek_to reference_target ALSO refuses when no episode
    /// is available (it was bypassed before review fa03b7f9) — no mapping attempt, no seek.
    func testSeekToReferenceFormWithNoEpisodeIsRefusedBeforeMapping() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"1bf6d033-6a20-4cd7-ab32-a62548b2f17c","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"reference_position_ms":1000},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer, episodeAvailable: { false }, appOperationSupport: fixtureSupport("playback.seek_to"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-27")
        let refusals = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refusals.count, 1, "exactly one refusal for the reference-form seek")
        XCTAssertEqual(refusals.first?.result.reason, OperationReason.stalePrecondition)
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0)
    }

    /// REAL PRECONDITION: resume with NO current episode refuses — PlaybackManager.play
    /// early-returns on no episode, so the silent wrapper would be a no-op dressed as success.
    func testResumeWithNoEpisodeIsRefusedStalePrecondition() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"a6701e82-0fc1-40a9-a8c7-378f9301e1d4","capability_version":"app-ops/1","tool":"playback","action":"resume","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let consumer = RecordingResultConsumer()
        let sink = makeSinkWithConsumer(consumer, episodeAvailable: { false }, appOperationSupport: fixtureSupport("playback.resume"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-28")
        // The ACTION refused durably (the turn's own host-playback restore is separate
        // machinery and not observable here — the action-level outcome is what matters).
        let refusals = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refusals.count, 1, "exactly one refusal for the unavailable resume")
        XCTAssertEqual(refusals.first?.result.reason, OperationReason.stalePrecondition)
    }

    /// PRODUCTION DEFAULT availability (review 0846e993): with NO injected availability closure
    /// and the REAL manager reporting no current episode, the reference-form seek refuses on the
    /// production path (existing-episode-with-unknown-duration would be AVAILABLE — duration is
    /// not availability — but the test host has no episode, which is the absent branch).
    func testProductionDefaultNoEpisodeRefusesReferenceSeek() async throws {
        let consumer = RecordingResultConsumer()
        self.pendingFixture = """
            event: action
            data: {"operation_id":"fb36a011-ba98-418a-a177-39bcef233b16","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"reference_position_ms":1000},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(consumer, playbackManager: PlaybackManager.shared, appOperationSupport: fixtureSupport("playback.seek_to"))
        // ESTABLISH the premise against the REAL production state: the shared queue must have
        // no current episode. The test host's shared container can legitimately carry one from
        // launch, so the premise is established through the production queue API — never assumed.
        PlaybackManager.shared.queue.removeAllEpisodes()
        XCTAssertNil(PlaybackManager.shared.currentEpisode, "premise: no current episode after the reset")
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-29")
        let refusals = consumer.consumed.filter { $0.result.outcome == .refused }
        XCTAssertEqual(refusals.count, 1, "the production manager's absent episode refuses")
        XCTAssertEqual(refusals.first?.result.reason, OperationReason.stalePrecondition)
    }

    /// STOP-COMPLETION ORDER (review 24f236de): an error terminal WITH pending owned audio
    /// releases the host playback only after the ACTUAL stop the cancel requested — the resume
    /// never overlaps the un-stopped cloud output.
    func testErrorTerminalReleasesHostPlaybackOnlyAfterTheConfirmedStop() async throws {
        let fixture = """
            event: error
            data: {"message":"boom"}

            """
        self.pendingFixture = fixture
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            audioPayloads: (0..<40).map { Data([UInt8($0)]) }
        )
        // Withhold the ACTUAL stop: the error terminal's release must wait for it, not for the
        // cancel request. Delivery (and therefore the stop confirmation) happens only below.
        // The capture runs on the MAIN queue, so it must never block: it stores the delivery
        // continuation and the test drives it from its own thread.
        final class DeliveryBox: @unchecked Sendable {
            private let lock = NSLock()
            private var deliver: (() -> Void)?
            func store(_ d: @escaping () -> Void) {
                lock.lock(); deliver = d; lock.unlock()
            }
            func deliverIfStored() {
                lock.lock(); let d = deliver; deliver = nil; lock.unlock()
                d?()
            }
        }
        let delivery = DeliveryBox()
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                delivery.store(deliver)
            }
        }
        let turn = Task { await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-30") }
        // The turn cannot finish while the stop is unconfirmed: no resume, no confirmed epoch.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 0,
                       "an unconfirmed stop does not release the host playback")
        let confirmedBefore = await MainActor.run { sink.audioPlayerForTesting?.confirmedStopEpoch() ?? 0 }
        XCTAssertEqual(confirmedBefore, 0, "the stop is not confirmed before it completes")
        // Deliver the actual stop: NOW the release lands, exactly once.
        var delivered = false
        for _ in 0..<100 {
            await MainActor.run { delivery.deliverIfStored() }
            if await MainActor.run(body: { sink.audioPlayerForTesting?.confirmedStopEpoch() ?? 0 }) > 0 {
                delivered = true; break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(delivered, "the withheld stop was delivered")
        let result = await turn.value
        _ = result
        XCTAssertTrue(playback.awaitResume(timeout: 5), "the release lands at the confirmed stop")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1, "exactly one release")
        let confirmed = await MainActor.run { sink.audioPlayerForTesting?.confirmedStopEpoch() ?? 0 }
        XCTAssertGreaterThan(confirmed, 0, "the stop was confirmed")
        let pending = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? true }
        XCTAssertFalse(pending, "no owned audio survives the confirmed stop")
        await MainActor.run { sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil) }
    }

    /// PER-ACTION TRUE RESULT: play_quote WITHOUT a reference target refuses (malformed target)
    /// and settles durably — it is never reported as a success.
    ///
    /// Note the fixture carries `reference_position_ms` as `null`: the field is PRESENT, which is
    /// what action admission requires, but not a number, so the sink's own malformed-target
    /// refusal is what settles this. Omitting the field entirely would be refused by the PARSER
    /// (required-field violation), which would prove nothing about the sink's outcome.
    func testPlayQuoteWithoutReferenceIsRefusedAndDurablySettled() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"9433422b-78ee-4676-a1fe-71f898fcd638","capability_version":"app-ops/1","tool":"playback","action":"play_quote","params":{"reference_position_ms":null},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pq-noref-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        let identity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-31", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: "9433422b-78ee-4676-a1fe-71f898fcd638", in: self.pendingFixture ?? ""))
        ))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager, operationJournal: journal, appOperationSupport: fixtureSupport("playback.play_quote"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-31")
        let frame = try await awaitResultFrame(operationId: "9433422b-78ee-4676-a1fe-71f898fcd638")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.malformedSeekTarget)
        XCTAssertNil(frame["state"])
        if case .alreadyRun(let recorded) = journal.claim("9433422b-78ee-4676-a1fe-71f898fcd638", identity: identity) {
            XCTAssertEqual(recorded.outcome, .refused)
        } else {
            XCTFail("the refusal was not durably settled; claim=\(journal.claim("9433422b-78ee-4676-a1fe-71f898fcd638", identity: identity)) testIdentity=\(identity) inProgress=\(journal.interruptedOperationIDs()) result=\(String(describing: journal.result(for: "9433422b-78ee-4676-a1fe-71f898fcd638")))")
        }
    }

    /// PER-ACTION TRUE RESULT: stop_quote with NO saved position (no prior play_quote) refuses
    /// (stale precondition) — there is nothing to restore, and silence is not a success.
    func testStopQuoteWithoutASavedPositionIsRefusedStalePrecondition() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"df99ef63-7bbe-4c29-a608-576f6d645833","capability_version":"app-ops/1","tool":"playback","action":"stop_quote","params":{},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-nosave-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        let identity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-32", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: "df99ef63-7bbe-4c29-a608-576f6d645833", in: self.pendingFixture ?? ""))
        ))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager, operationJournal: journal, appOperationSupport: fixtureSupport("playback.stop_quote"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-32")
        let frame = try await awaitResultFrame(operationId: "df99ef63-7bbe-4c29-a608-576f6d645833")
        XCTAssertEqual(frame["outcome"] as? String, "refused")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.stalePrecondition)
        if case .alreadyRun(let recorded) = journal.claim("df99ef63-7bbe-4c29-a608-576f6d645833", identity: identity) {
            XCTAssertEqual(recorded.outcome, .refused)
        } else {
            XCTFail("the refusal was not durably settled")
        }
    }

    /// A known, NONZERO offset: the mapped position is used and it is not the raw reference
    /// value. A mapping that returned its input would satisfy an equality check by accident, so
    /// the offset is deliberate.
    func testMappedReferenceSeekUsesTheMappedPositionNotTheRawReferenceValue() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        mapper.playbackSecondsForReference = [200.0: 215.0]
        let sink = makeSink(injectIdentity: false)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-33")

        XCTAssertTrue(playback.calls.contains(.seekTo(215)))
        XCTAssertFalse(playback.calls.contains(.seekTo(200)), "the raw reference value is not the target")
        let unavailable = await MainActor.run { sink.unavailableReferenceSeek }
        XCTAssertNil(unavailable, "a successful mapping is not an unavailability")
    }

    /// And through `play_quote`, so both actions are shown to use the mapping rather than only
    /// the one that happens to be convenient.
    func testMappedReferencePlayQuoteUsesTheMappedPosition() async {
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":200000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        mapper.playbackSecondsForReference = [200.0: 215.0]
        let sink = makeSink(injectIdentity: false)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-34")

        XCTAssertTrue(playback.calls.contains(.seekTo(215)))
        XCTAssertFalse(playback.calls.contains(.seekTo(200)))
    }

    /// Per-turn state: a `stop_quote` in a turn that issued no `play_quote`
    /// must NOT seek to a previous turn's captured pre-quote position.
    func testStopQuoteWithoutPlayQuoteInLaterTurnDoesNotUseStalePosition() async {
        // RecordingFingerprintMapper is a struct — configure it before the sink copies it.
        mapper.playbackSecondsForReference = [500.0: 510.0]
        playback.setPositionMs(900_000)
        let sink = makeSink(injectIdentity: false)

        // Turn 1 captures a pre-quote position via play_quote.
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"play_quote","params":{"reference_position_ms":500000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        _ = await sink.routeToCloud(request: "play that", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-35")
        XCTAssertTrue(playback.calls.contains(.seekTo(510)))

        // Turn 2 (same sink): stop_quote without play_quote must be a no-op seek-wise.
        playback.clearCalls()
        self.pendingFixture =
            """
            event: action
            data: {"tool":"playback","action":"stop_quote","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        _ = await sink.routeToCloud(request: "stop", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-36")
        XCTAssertEqual(playback.calls.filter { if case .seekTo = $0 { return true }; return false }.count, 0)
    }

    /// Slice 1: the sink sends one turn envelope — request_id on the wire and
    /// capabilities only once a structured-results renderer exists.
    func testSinkSendsTurnEnvelopeWithRequestIdAndGatedCapabilities() async throws {
        self.pendingFixture =
            """
            event: token
            data: {"text":"ok"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """

        _ = await makeSink().routeToCloud(request: "what did they say?", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88")

        let body = try XCTUnwrap(capturedTask?.sentAuthFrame)
        let requestId = try XCTUnwrap(body["request_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: requestId), "request_id must be a client-assigned UUID")
        XCTAssertNil(body["capabilities"], "no renderer yet: capabilities must be omitted so the server uses token+done")
        XCTAssertNil(body["route_hint"], "free-text turns carry no hint")
    }

    /// MISSING-ID BOUNDARY (reviewer c580c42b item 4): a dispatch with NO admitted utterance
    /// identity is refused with NO wire frame, NO consumed result, and NO successor-state
    /// contamination — the next admitted id dispatches as a clean first turn.
    func testSinkRefusesAnUnidentifiedDispatchWithNoWireFrameAndCleanSuccessorState() async throws {
        let consumer = RecordingResultConsumer()
        self.pendingFixture = """
            event: token
            data: {"text":""}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let sink = makeSinkWithConsumer(consumer)

        let refused = await sink.routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: nil
        )
        XCTAssertEqual(refused.outcome, .refused, "a missing identity is refused, never dispatched")
        XCTAssertNil(capturedTask?.sentAuthFrame, "no identity, no client, no wire frame")
        XCTAssertTrue(consumer.consumed.isEmpty, "nothing reaches the successor consumer")

        // The refusal left NO half-built state: an admitted turn right after dispatches normally.
        let admitted = "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"
        let result = await sink.routeToCloud(
            request: "play the news", tier: .free, context: sampleContext(), origin: cloudTestOrigin,
            selection: nil, utteranceId: admitted
        )
        XCTAssertEqual(result.outcome, .completed, "the admitted turn after the refusal is a clean first dispatch")
        let frame = try XCTUnwrap(capturedTask?.sentAuthFrame)
        XCTAssertEqual(frame["request_id"] as? String, admitted, "the wire id is the admitted id, not something minted by the refused attempt")
    }

    func testSinkAdvertisesSearchResultsV1OnlyWhenRendererAvailable() async throws {
        self.pendingFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """

        _ = await makeSink(rendersStructuredResults: true, routeHint: CloudRouteHint(
            operation: "search_spoken_content",
            arguments: ["query": .string("climate")]
        )).routeToCloud(request: "find the climate bit", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-38")

        let body = try XCTUnwrap(capturedTask?.sentAuthFrame)
        XCTAssertEqual(body["capabilities"] as? [String], ["search_results_v1"])
        let hint = try XCTUnwrap(body["route_hint"] as? [String: Any])
        XCTAssertEqual(hint["operation"] as? String, "search_spoken_content")
    }

    // MARK: - deliveredPayload helper controls

    /// MULTIPLE EVENTS, MULTIPLE IDS: the helper must find the operation by id and not be defeated
    /// by the fixture also carrying a `done` event. The old implementation handed the whole SSE
    /// document to the JSON parser and returned nil for every such fixture.
    func testDeliveredPayloadFindsEachOperationAcrossAMultiEventFixture() {
        let first = "0b5e2d47-8a19-4c63-9f28-4d71c6e30ab5"
        let second = "5c83a1f6-2e07-4b94-8d51-7a39b0c26ef4"
        let fixture = """
            event: action
            data: {"operation_id":"\(first)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5}}

            event: action
            data: {"operation_id":"\(second)","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":7}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let firstPayload = Self.deliveredPayload(for: first, in: fixture)
        let secondPayload = Self.deliveredPayload(for: second, in: fixture)
        XCTAssertNotNil(firstPayload, "the first operation's payload must be found")
        XCTAssertNotNil(secondPayload, "the second operation's payload must be found")
        XCTAssertNotEqual(firstPayload, secondPayload, "each result belongs to its own operation")
        XCTAssertTrue(firstPayload?.contains("\"delta_seconds\":5") ?? false)
        XCTAssertTrue(secondPayload?.contains("\"delta_seconds\":7") ?? false)
        XCTAssertNil(
            Self.deliveredPayload(for: "00000000-0000-4000-8000-000000000000", in: fixture),
            "an absent operation id must return nil rather than some other frame's bytes"
        )
    }

    /// BYTE PRESERVATION: the returned string is the payload's own UTF-8, not a re-encoding. A
    /// reserialization would normalise key order and spacing and silently give one operation two
    /// different replay-identity digests.
    func testDeliveredPayloadReturnsTheFramesExactBytesWithoutReserialization() throws {
        let operationId = "9a47c1e8-6b02-4f35-a8d1-3c5e70b924fd"
        // Deliberately non-canonical: key order and interior spacing `JSONSerialization` would not
        // reproduce — `params` precedes `tool` rather than following `action`, a serialiser emits
        // `{"delta_seconds":5}` instead of `{ "delta_seconds" : 5 }`, and there are two spaces
        // before `"action"`. A re-encoding would normalise all of it.
        let rawPayload = #"{"operation_id":"\#(operationId)","capability_version":"app-ops/1","params":{ "delta_seconds" : 5 },"tool":"playback",  "action":"seek_relative"}"#
        let fixture = """
            event: action
            data: \(rawPayload)

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // INDEPENDENTLY WRITTEN EXPECTATION. `frames(fromFixture:)` merges the event name in as a
        // leading `"type"` field, so the payload the socket delivers is the fixture's payload with
        // that one member prepended and every other byte untouched. Written out as a literal here —
        // not rebuilt from the fixture and not produced by the code under test.
        let expectedSocketPayload = #"{"type":"action","operation_id":"\#(operationId)","capability_version":"app-ops/1","params":{ "delta_seconds" : 5 },"tool":"playback",  "action":"seek_relative"}"#
        let delivered = try XCTUnwrap(Self.deliveredPayload(for: operationId, in: fixture))
        XCTAssertEqual(delivered, expectedSocketPayload,
                       "the delivered payload is the socket frame's payload, byte for byte")
        // Kept separate: the helper's bytes must equal what the live converter actually yields.
        let liveFrames = StubWebSocketTask.frames(fromFixture: fixture)
        XCTAssertEqual(liveFrames.count, 2, "action + done become two socket frames")
        let extracted = try XCTUnwrap(
            liveFrames.compactMap { AppOperationRequest.actionPayloadBytes(rawFrame: Data($0.utf8)) }.first)
        XCTAssertEqual(Data(delivered.utf8), extracted,
                       "helper bytes == the bytes the socket actually delivers")
        XCTAssertEqual(Data(delivered.utf8), Data(expectedSocketPayload.utf8),
                       "and both equal the independently written literal")
    }

    // MARK: - Helpers

    /// The `app_operation_result` frames a turn actually put on ITS OWN socket.
    ///
    /// Waits briefly because the send is awaited inside the turn loop but the transport records it
    /// asynchronously. Returns every match so a control can require EXACTLY one — a duplicate send
    /// is a defect, and `first` would hide it.
    ///
    /// EVIDENCE LIMIT, stated once: a frame here proves the client SUBMITTED it on the transport.
    /// It is not evidence the server received or acted on it.
    static func resultFrames(
        on task: StubWebSocketTask?,
        timeout: TimeInterval = 5
    ) async -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        var frames: [[String: Any]] = []
        while Date() < deadline {
            frames = await MainActor.run {
                (task?.sentTextFrames ?? []).compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }.filter { ($0["type"] as? String) == "app_operation_result" }
            }
            if !frames.isEmpty { return frames }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return frames
    }


    /// Under the strict runtime gate (wire contract rev da327e624), valid cloud app operations
    /// carry the server-issued `operation_id` and `capability_version`. Fixtures are upgraded AT
    /// THE SOCKET BOUNDARY so every valid-operation case exercises the identified envelope; the
    /// explicit legacy/malformed refusal cases opt out with the `LEGACY_ACTION` marker.
    /// The EXACT replay-identity bytes the LIVE parser produces for the named operation.
    ///
    /// This must not rebuild JSON and must not trim framing or whitespace: it runs the production
    /// extractor over the same frame the socket delivers, so the bytes a case asserts on are, by
    /// construction, the bytes the sink journals. A second extractor is how one operation acquires
    /// two identities — which is exactly the mismatch this replaces.
    static func deliveredPayload(for operationId: String, in fixture: String) -> String? {
        // THE SAME CONVERSION THE LIVE STUB USES. The fixture is an SSE document with several
        // `event:`/`data:` pairs; the stub turns each `data:` pair into ONE socket frame. This
        // helper used to hand the whole document to `actionPayloadBytes` and then call
        // `JSONSerialization` on that document rather than on the extracted payload — a multi-event
        // SSE text is not a JSON object, so the object guard could never be satisfied and the
        // helper returned nil for every fixture with more than one event, regardless of operation.
        let injected = injectOperationIdentity(fixture)
        for frameText in StubWebSocketTask.frames(fromFixture: injected) {
            let frameData = Data(frameText.utf8)
            guard let payload = AppOperationRequest.actionPayloadBytes(rawFrame: frameData),
                  let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                  json["operation_id"] as? String == operationId
            else { continue }
            // RETURNED VERBATIM: no reserialization, so the bytes a case asserts on are exactly the
            // bytes the socket delivers and the sink journals.
            return String(data: payload, encoding: .utf8)
        }
        return nil
    }

    static func injectOperationIdentity(_ fixture: String) -> String {
        guard fixture.contains("event: action"), !fixture.contains("LEGACY_ACTION") else { return fixture }
        var counter = 0
        var lines: [String] = []
        for raw in fixture.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("data:"),
               line.contains("\"tool\""), line.contains("playback"),
               !line.contains("operation_id"),
               let toolRange = line.range(of: "\"tool\"") {
                counter += 1
                line.replaceSubrange(
                    toolRange,
                    // A REAL UUID per operation: the wire pins `operation_id` to a server-issued
                    // UUID, so a fixture must emit one or it is not a frame a conforming server
                    // could send. Counter keeps them distinct within a fixture.
                    with: "\"operation_id\":\"77d9ee31-a3b8-47cd-a43e-\(String(format: "%012d", counter))\",\"capability_version\":\"app-ops/1\",\"tool\""
                )
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// `currentEpisodeId` is OPT-IN and defaults to `nil`, which is the existing behaviour for
    /// every caller: a sink with no observer must fail closed at the effect boundary, and silently
    /// giving all sinks a target would erase that control. A test that needs the sink to confirm a
    /// stated `episode_id` passes the observer explicitly.
    /// `injectIdentity: false` delivers the fixture VERBATIM, so a control written against the
    /// pre-v1 protocol actually exercises it.
    ///
    /// The default stays `true` because the identity-injecting path is what most cases want, but
    /// the implicit promotion is precisely why the legacy controls broke: a frame written with no
    /// identity fields was rewritten into an identified v1 request that then had to state
    /// `precondition.episode_id`, and refused when it did not. A legacy control must say so.
    private func makeSink(
        rendersStructuredResults: Bool = false,
        routeHint: CloudRouteHint? = nil,
        currentEpisodeId: (() -> String?)? = nil,
        injectIdentity: Bool = true,
        appOperationSupport: CloudAppOperationSupport? = nil
    ) -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let raw = self.nextFixture()
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: injectIdentity ? Self.injectOperationIdentity(raw) : raw
                )
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            // Declared order in `CloudRouteSink.init`: `currentEpisodeIdProvider` precedes
            // `cloudPlaybackContextState`.
            currentEpisodeIdProvider: currentEpisodeId,
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            rendersStructuredResults: rendersStructuredResults,
            routeHintProvider: { routeHint },
            operationJournal: OperationJournal(store: InMemoryOperationRecordStore()),
            conversationManager: testConversationManager(),
            appOperationSupportProvider: { appOperationSupport }
        )
    }



    private func sampleContext() -> PlaybackContext {
        PlaybackContext(
            episodeId: "ep",
            podcastId: "pod",
            referencePositionMs: 1_000,
            clientPositionMs: 1_100,
            recentReferencePositions: [],
            previousReferencePositionMs: nil
        )
    }
    // MARK: - Terminal outcome
    //
    // The turn's OUTCOME must be reported separately from how it is rendered. A spoken
    // error and a silent success are both "no earcon", so any caller deciding what
    // happened from the response shape gets these exactly backwards — which is how a
    // failed turn was recorded as a completed cloud route and reopened the grace window.

    func testDoneReportsCompleted() async {
        self.pendingFixture = """
        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":1}}

        """
        let result = await makeSink().routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-39")
        XCTAssertEqual(result.outcome, .completed)
    }

    func testSpokenServerErrorReportsFailureNotCompletion() async {
        // An error frame is a FAILED turn — never the completion shape the executor once read.
        // The code has no local template, so it renders as the error earcon; the subject here is
        // the OUTCOME, not the wording.
        self.pendingFixture = """
        event: error
        data: {"code":"rate_limited","message":"slow down"}

        """
        defaults.set("de", forKey: "AppleLanguages")
        let result = await makeSink().routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-40")
        XCTAssertNotEqual(
            result.outcome, .completed,
            "a spoken server error was reported as a completed turn"
        )
        XCTAssertEqual(result.outcome, .failed(code: "rate_limited"))
    }

    func testStreamEndWithoutDoneReportsEarlyCloseNotCompletion() async {
        // A stream that closes after tokens but never sends `done` is a truncated turn.
        self.pendingFixture = """
        event: token
        data: {"text":"partial"}

        """
        let result = await makeSink().routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-41")
        // The client surfaces a truncated stream as an explicit transport failure, so the
        // outcome may be `failed(connection_lost)` rather than a bare early close. What
        // must hold either way is that it is NOT a completion: an ended stream that never
        // sent `done` must not restore the allowance as though the model answered.
        XCTAssertNotEqual(
            result.outcome, .completed,
            "a stream that ended without done was reported as a completed turn"
        )
        if case .earlyClose = result.outcome {
            // reached only when the client reports the close without a code
        } else {
            XCTAssertEqual(
                result.outcome, .failed(code: "connection_lost"),
                "an unterminated stream was classified as neither an early close nor a "
                    + "transport failure: \(result.outcome)"
            )
        }
    }

    func testUnconfiguredReportsRefusedNotCompletion() async {
        // Premise must be genuinely unconfigured at BOTH layers. Removing only the UserDefaults
        // override left the build-time default (Info.plist AurisCloudBaseURL, non-empty in the
        // StagingDebug test host) active — the sink was actually CONFIGURED and correctly routed
        // to the stub transport, whose empty-fixture connection failure was the RIGHT answer for
        // the route it actually took. The old assertion measured a wrong premise, not wrong
        // production. Neutralise the build default via CloudConfig's injected buildDefaultGatewayURL.
        defaults.removeObject(forKey: CloudConfig.baseURLKey)
        let unconfiguredConfig = CloudConfig(defaults: defaults, buildDefaultGatewayURL: "")
        let sink = CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: unconfiguredConfig.baseUrl, fixture: "")
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !unconfiguredConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            rendersStructuredResults: false,
            routeHintProvider: { nil },
            conversationManager: testConversationManager()
        )
        let result = await sink.routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-42")
        XCTAssertEqual(
            result.outcome, .refused,
            "the coming-soon refusal was reported as a completed cloud turn"
        )
    }


    /// ACTUAL held-work owning-Task cancellation boundary with production prompt cleanup:
    /// cancellation is delivered ONLY by cancelling the real owning Task; the sink's own
    /// `withTaskCancellationHandler` retires the ORIGINAL registration synchronously while the
    /// consumer is suspended. Asserted: live original registration BEFORE cancel, actual socket
    /// cancellation BEFORE hold release, zero effects after release, and mandatory THIRD-store
    /// persisted settled unknown with no in-progress id.
    func testHeldWorkOwnerCancellationMidOperationNeverExecutesAfterRelease() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"1a59989a-5e54-44cf-a59c-3c06b9f34658","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        // TRANSPORT PARK, INSTALLED AT CREATION. It engages after the two scripted frames (auth
        // send + the action frame carrying the claim), so the turn reaches the claim/effect
        // boundary first and the park then holds the transport while the consumer is suspended
        // in the effect hold. Measured earlier design defect: arming this from `effectEntered`
        // meant the transport had already served its frames, so the park never engaged and the
        // "retirement woke the park" assertion could not be true. The park must therefore exist
        // BEFORE the frames, and `declaredParkDidPark` below proves it actually engaged.
        let receivePark = HoldLatch()
        pendingDeclaredPark = receivePark
        pendingDeclaredParkAfterFrames = 2
        let manager = testConversationManager()
        // THE DIGEST MUST DESCRIBE THE DELIVERED ACTION. `mintedIdentity` defaults `bytes` to "",
        // so the earlier revision recorded a digest of nothing while the turn claimed with the real
        // payload — any later claim for the same turn was then an identity conflict. Derived here
        // from the exact bytes the socket delivers, through the same conversion the stub performs.
        let heldIdentity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-43", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: "1a59989a-5e54-44cf-a59c-3c06b9f34658", in: self.pendingFixture ?? ""))
        ))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                        operationJournal: journal,
                                        appOperationSupport: fixtureSupport("playback.seek_relative"))
        // CANCELLATION-INSENSITIVE effect hold: no cancellation handler of any kind. ONLY
        // `release.release()` frees it, so owner cancellation cannot open it.
        let release = HoldLatch()
        // Bounded entry signal: set the moment the OWNER is actually inside the awaited hold, so
        // the external cancel below lands mid-suspension rather than racing the turn's start.
        let entered = HoldLatch()
        // External cancellation of the REAL owning task — the only mechanism, no side channel.
        let ownerRef = ControlCanceller()
        var gateEntryCount = 0
        // The owner's completion is observed by a NON-BLOCKING bounded race that never awaits the
        // owner itself as a child. A structured wait on `owner.value` would have to await the very
        // suspension the assertion is about, and its wait-for-all-children would never return.
        /// True once the owner has finished. NON-BLOCKING: the check is a bounded alarm raced
        /// against a completion PROMISE, so no branch ever leaves a child blocked on the owner's
        /// unbounded suspension (a task-group over `owner.value` would block the drain forever,
        /// which is exactly how this hung when first written).
        func ownerHasCompleted() async -> Bool {
            let completionPromise = Promise<Bool>()
            let watcher = Task {
                _ = await owner.value
                completionPromise.resolve(true)
            }
            defer { watcher.cancel() }
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                completionPromise.resolve(false)
            }
            defer { timeout.cancel() }
            return await completionPromise.value()
        }
        await MainActor.run {
            sink.effectGate = { _ in
                gateEntryCount += 1
                entered.release()
                await release.waitUntilReleased()
            }
        }

        let owner = Task {
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-43")
        }
        ownerRef.bind(owner)
        // Wait until the OWNER is provably inside the awaited hold: the suspension is the owner's.
        await entered.waitUntilReleased()
        XCTAssertEqual(gateEntryCount, 1, "the owner itself must enter the awaited gate exactly once")
        XCTAssertEqual(journal.interruptedOperationIDs(), ["1a59989a-5e54-44cf-a59c-3c06b9f34658"], "operation durably claimed while held")
        XCTAssertTrue(capturedTask?.declaredParkDidPark ?? false,
                      "the declared transport park must actually engage, or the wake assertion is vacuous")
        XCTAssertEqual(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count, 0,
                       "no effect may run while held")
        // Ordered, non-blocking suspension checks: this helper never blocks on the owner.
        let heldInsideGate = await ownerHasCompleted()
        XCTAssertFalse(heldInsideGate, "the owner must still be held inside the awaited gate")
        // Cancel the REAL owning task — the only cancellation mechanism here.
        ownerRef.cancel()
        // ACTUAL RETIREMENT BEFORE RELEASE: the production onCancel path retires the ORIGINAL
        // registration synchronously while the owner remains suspended in the held work.
        let retiredBeforeRelease = await capturedTask?.awaitCancellation(timeout: 1.0) ?? false
        XCTAssertTrue(retiredBeforeRelease,
                      "cancellation itself must retire the original registration while suspended, before release")
        XCTAssertTrue(receivePark.releasedByRetirement,
                      "the parked receive may wake ONLY on socket retirement, never task cancellation")
        let completedBeforeRelease = await ownerHasCompleted()
        XCTAssertFalse(completedBeforeRelease, "completion must stay false until the explicit release")
        XCTAssertFalse(release.released, "effect hold must remain parked until explicit test release")
        release.release()
        let outcome = await owner.value
        // MANDATORY EXACT OUTCOME: the owner cancelled mid-operation must surface exactly
        // `earlyClose` — not a bare failure, not a completion. The width of this assertion is the
        // point: any other outcome means the cancelled turn was misclassified on its way out.
        guard case .earlyClose = outcome.outcome else {
            XCTFail("cancelled mid-operation must report exactly earlyClose; got \(outcome.outcome)")
            return
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let effectsTotal = playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count
        XCTAssertEqual(effectsTotal, 0, "cancelled-before-start must NEVER execute after release")
        // Mandatory recovery through RECREATED stores: second reconstructs persisted unknown,
        // THIRD reload proves the settlement itself is durable with no in-progress id.
        let recreated = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(recreated.interruptedOperationIDs(), ["1a59989a-5e54-44cf-a59c-3c06b9f34658"], "claimed interrupted case stays in progress")
        XCTAssertEqual(recreated.reconstructInterrupted("1a59989a-5e54-44cf-a59c-3c06b9f34658")?.outcome, .unknown)
        let third = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertTrue(third.interruptedOperationIDs().isEmpty, "settled unknown must be durable, no in-progress id")
        XCTAssertEqual(third.claim("1a59989a-5e54-44cf-a59c-3c06b9f34658", identity: heldIdentity),
                       OperationClaim.alreadyRun(.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight)))
    }


    /// Distinct behavior #2: a CONFIGURED route whose connection fails must report the
    /// transport failure — not be relabeled as a pre-transport refusal. This is what the old
    /// broken-premise test accidentally measured; it belongs here explicitly.
    func testConfiguredTransportFailureReportsConnectionLossNotRefusal() async {
        self.pendingFixture = ""   // configured stub whose socket closes before any event
        let result = await makeSink().routeToCloud(
            request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-44")
        XCTAssertEqual(result.outcome, .failed(code: "connection_lost"),
                       "a configured route with a dead connection reports transport failure")
    }

    /// Owning-Task cancellation regression, attribution-corrected: an identified pause turn has
    /// EXPECTED lifecycle auto-pause (CloudRouteSink.swift:315, when playing before hold) plus the
    /// action effect (line 551). Cancellation must not add a second effect execution: total pauses
    /// ≤ 1 lifecycle + 1 effect, and a claimed-but-interrupted operation stays reconstructable
    /// unknown, never re-executed, never `cancelled`.
    func testOwnerTaskCancellationDoesNotDoubleExecuteTheIdentifiedMutation() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"e96e71aa-a6ca-4f05-ad2d-9bb9fb7bdb6e","capability_version":"app-ops/1","tool":"playback","action":"pause","params":{}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let journal = OperationJournal(store: InMemoryOperationRecordStore())
        let manager = testConversationManager()
        let identity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-45", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: "e96e71aa-a6ca-4f05-ad2d-9bb9fb7bdb6e", in: self.pendingFixture ?? ""))
        ))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager, operationJournal: journal, appOperationSupport: fixtureSupport("playback.pause"))
        let owner = Task {
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-45")
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        owner.cancel()
        _ = await owner.value
        try await Task.sleep(nanoseconds: 150_000_000)
        // Distinguish lifecycle from effect by ORDER: the lifecycle auto-pause always precedes
        // action handling, so pauses[0] is the lifecycle call and the rest are effect executions.
        let pauses = playback.calls.filter { if case .pause = $0 { return true }; return false }
        let effectPauses = pauses.dropFirst()
        XCTAssertLessThanOrEqual(effectPauses.count, 1, "the identified effect executes at most once")
        if case .alreadyRun = journal.claim("e96e71aa-a6ca-4f05-ad2d-9bb9fb7bdb6e", identity: identity) {
            // The turn completed before cancellation: the effect MUST have executed exactly once.
            XCTAssertEqual(effectPauses.count, 1, "a completed operation's effect ran exactly once")
        }
        if journal.claim("e96e71aa-a6ca-4f05-ad2d-9bb9fb7bdb6e", identity: identity) == OperationClaim.inProgress {
            XCTAssertEqual(journal.reconstructInterrupted("e96e71aa-a6ca-4f05-ad2d-9bb9fb7bdb6e")?.outcome, .unknown)
            if case .alreadyRun = journal.claim("e96e71aa-a6ca-4f05-ad2d-9bb9fb7bdb6e", identity: identity) {} else {
                XCTFail("reconstructed record must settle")
            }
        }
    }

func testOwnerTaskCancelDuringIdentifiedOperationEffectOnceAndRecoveryByRecordState() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"f0c729f0-ff82-4cf0-a314-657f0056b6d4","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let manager = testConversationManager()
        // THE EXPECTED IDENTITY MUST CARRY THE SAME BYTES THE SINK ACTUALLY PERSISTED. The previous
        // revision omitted `bytes`, so `mintedIdentity` hashed an EMPTY payload while the sink
        // hashed the real delivered one. `OperationIdentity` equality covers the digest, so the
        // recreated journal answered `.identityConflict` — and the control reported that as
        // "durable record lost", conflating two different outcomes.
        let operationId = "f0c729f0-ff82-4cf0-a314-657f0056b6d4"
        let deliveredBytes = try XCTUnwrap(
            Self.deliveredPayload(for: operationId, in: self.pendingFixture ?? ""),
            "the exact payload this control delivers is retained before routing")
        let identity = try XCTUnwrap(
            Self.mintedIdentity(for: "u-46", manager: manager, bytes: deliveredBytes))
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager, operationJournal: journal, appOperationSupport: fixtureSupport("playback.seek_relative"))
        let owner = Task {
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-46")
        }
        // Deterministic premise WITHOUT a verification-side claim: wait until the durable store
        // itself shows the operation's record (in progress or already finished), so the cancel
        // always lands at a known-observed point. The recreated record's state decides the
        // expectation below; a mid-effect retirement claim is NOT made here (held-work control
        // is separately assigned).
        let durable = FileOperationRecordStore(url: url)
        let observed = await Task.detached {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if !durable.load().isEmpty { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return false
        }.value
        XCTAssertTrue(observed, "operation record never became durable within 5s")
        owner.cancel()
        _ = await owner.value
        try await Task.sleep(nanoseconds: 150_000_000)
        let effectCount = playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count
        XCTAssertLessThanOrEqual(effectCount, 1, "the identified effect must not duplicate")
        // Recreate store + journal (restart simulation). The record's state decides the
        // expectation: completed-before-cancel must be settled (alreadyRun, nil reconstruction —
        // bytes persisted proves the durable round trip); a still-in-progress record must
        // reconstruct as persisted unknown.
        let restarted = OperationJournal(store: FileOperationRecordStore(url: url))
        let effectPausesOrRelatives = effectCount
        // A RECREATED STORE WITH NO ROWS IS THE ONLY "RECORD LOST". `.identityConflict` means the
        // row IS there but was claimed under a different identity, which is a WEAKER and different
        // complaint — reporting both as "record lost" hid which had actually happened.
        switch restarted.claim(operationId, identity: identity) {
        case .alreadyRun:
            XCTAssertLessThanOrEqual(effectPausesOrRelatives, 1)
        case .inProgress:
            XCTAssertEqual(restarted.reconstructInterrupted(operationId)?.outcome, .unknown)
            if case .alreadyRun = restarted.claim(operationId, identity: identity) {} else {
                XCTFail("reconstructed record must settle")
            }
        case .identityConflict:
            XCTFail("the recreated record exists but was claimed under a DIFFERENT identity — "
                    + "the expected identity must carry the exact persisted bytes, not an empty digest")
        case .claimed:
            XCTFail("durable record lost across recreation: the recreated store claims the "
                    + "operation as NEW, so nothing was persisted")
        case .interrupted:
            // A RECREATED STORE REPORTING `interrupted` PROVES THE ROUND TRIP SUCCEEDED. A previous
            // process claimed it and died without recording an outcome; `claim` surfaces that as
            // explicitly unknowable rather than re-executing it. That is exactly the recovery the
            // durability requirement asks for, so it is a PASS, not a lost record.
            XCTAssertEqual(restarted.result(for: operationId)?.outcome, .unknown,
                           "an interrupted operation must surface as unknown, never as a replay")
        case .persistenceUnavailable:
            // A THIRD, DISTINCT OUTCOME — neither "wrong identity" nor "nothing persisted". The
            // recreated store could not be READ or WRITTEN at all, so this control cannot conclude
            // anything about the round trip: the record's fate is unknown, not lost.
            XCTFail("the recreated store could not be accessed or persisted, so the durable round "
                    + "trip is UNPROVEN rather than lost — this is not an identity mismatch and not "
                    + "a fresh claim")
        }
    }

    /// Recreated-store recovery, deterministic (no sink race): a process that claimed and died
    /// leaves `.inProgress` on disk; a RECREATED store+journal reconstructs persisted unknown,
    /// settles it, and never replays it as executable.
    func testRecreatedDurableStoreReconstructsUnknownWithoutReplay() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
        let diedIdentity = OperationIdentity(owner: "test-owner", conversation: "c-died",
                                             turn: "u-died", actionBytes: Data(#"{"a":1}"#.utf8))
        let first = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(first.claim("eb6cd868-9ac4-482d-abfb-2ebe86a44666", identity: diedIdentity), OperationClaim.claimed)
        // Process death: no complete() ever runs. A NEW store+journal over the same URL:
        let restarted = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertEqual(restarted.interruptedOperationIDs(), ["eb6cd868-9ac4-482d-abfb-2ebe86a44666"])
        XCTAssertEqual(restarted.reconstructInterrupted("eb6cd868-9ac4-482d-abfb-2ebe86a44666")?.outcome, .unknown)
        if case .alreadyRun = restarted.claim("eb6cd868-9ac4-482d-abfb-2ebe86a44666", identity: diedIdentity) {} else {
            XCTFail("reconstructed record must settle")
        }
        // THIRD store+journal: the settlement itself must be durable, not just in the second
        // journal's memory.
        let third = OperationJournal(store: FileOperationRecordStore(url: url))
        XCTAssertTrue(third.interruptedOperationIDs().isEmpty, "no in-progress id may survive settlement")
        XCTAssertEqual(
            third.claim("eb6cd868-9ac4-482d-abfb-2ebe86a44666", identity: diedIdentity),
            OperationClaim.alreadyRun(.nonSuccess(.unknown, reason: OperationReason.interruptedInFlight))
        )
    }

    /// A store whose writes fail: claim persistence failure must prevent the effect fail-closed.
    func testFailingClaimPersistenceRefusesEffectWithoutExecution() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"14c7a45d-b3b2-4b4c-a5ce-0cbfc5b0b1c9","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let journal = OperationJournal(store: AlwaysFailingOperationRecordStore())
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), operationJournal: journal, appOperationSupport: fixtureSupport("playback.seek_relative"))
        await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-47")
        let effectCount = playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count
        XCTAssertEqual(effectCount, 0, "a failed claim write must prevent the effect entirely")
    }

    /// A settlement write that fails after the effect ran, observed through the store's ACTUAL
    /// write path: complete returns false, live memory stays unsettled (never replayable as
    /// succeeded), and a recreated store still holds the in-progress id.
    func testFailingSettlementWriteNeverReplaysTheOperation() async {
        let store = SettlementFailingOperationRecordStore()
        let journal = OperationJournal(store: store)
        let settleIdentity = OperationIdentity(owner: "test-owner", conversation: "c-settle",
                                               turn: "u-settle", actionBytes: Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(journal.claim("475d2d01-52f3-4f90-a7df-02e15aca195d", identity: settleIdentity), OperationClaim.claimed)
        XCTAssertFalse(journal.complete("475d2d01-52f3-4f90-a7df-02e15aca195d", identity: settleIdentity,
                                        result: .succeeded(state: ["position_seconds": .int(0)])), "failed settlement must be reported")
        // Live-memory observation: the record did NOT publish as finished-succeeded.
        XCTAssertNil(journal.result(for: "475d2d01-52f3-4f90-a7df-02e15aca195d"), "failed settlement must not publish success")
        XCTAssertEqual(journal.claim("475d2d01-52f3-4f90-a7df-02e15aca195d", identity: settleIdentity), OperationClaim.inProgress, "unsettled operation stays in progress, never replayable")
        // Recreated-store observation through the same write path:
        let recreated = OperationJournal(store: SettlementFailingOperationRecordStore(backing: store))
        XCTAssertEqual(recreated.interruptedOperationIDs(), ["475d2d01-52f3-4f90-a7df-02e15aca195d"], "durable record must still be in progress")
        XCTAssertNil(recreated.reconstructInterrupted("475d2d01-52f3-4f90-a7df-02e15aca195d"), "failed recovery settlement must not report settled unknown")
        XCTAssertEqual(recreated.claim("475d2d01-52f3-4f90-a7df-02e15aca195d", identity: settleIdentity), OperationClaim.inProgress)
    }

    /// Semantically corrupt durable history (bogus outcome, unknown state) must fail closed:
    /// no id in it may silently re-claim and execute.
    func testSemanticallyCorruptHistoryIsUnreadableNeverExecutable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).json")
        try? Data("{\"33206aea-bc23-42d4-ac36-16d8d3f9fec0\":{\"state\":\"weird\"},\"0bc20d23-3dc7-4cd2-adb5-25d026015620\":{\"state\":\"finished\",\"outcome\":\"bogus\"}}".utf8)
            .write(to: url)
        let journal = OperationJournal(store: FileOperationRecordStore(url: url))
        let corruptProbe = OperationIdentity(owner: "test-owner", conversation: "c", turn: "u",
                                             actionBytes: Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(journal.claim("33206aea-bc23-42d4-ac36-16d8d3f9fec0", identity: corruptProbe), .persistenceUnavailable, "unknown-state history must refuse, not re-claim")
        XCTAssertEqual(journal.claim("0bc20d23-3dc7-4cd2-adb5-25d026015620", identity: corruptProbe), .persistenceUnavailable, "bogus-outcome history must refuse, not re-claim")
    }

    /// RESTART RECOVERY, production shape: an operation a previous process left in progress is
    /// reconstructed as persisted `unknown` (the assembly does this at launch), and the sink then
    /// replays that recorded unknown through the bound transport WITHOUT re-executing the effect.
    func testRestartReconstructedUnknownReplaysThroughTransportWithoutReExecution() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"7138bc14-6823-45bc-a8a2-4a90f47ab9eb","capability_version":"app-ops/1","tool":"playback","action":"seek_to","params":{"position_seconds":30},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        // A previous process died after claiming and before completing.
        let store = InMemoryOperationRecordStore()
        let journal = OperationJournal(store: store)
        // The previous process claimed under the identity of the turn it was serving — the REAL
        // prepared identity and the EXACT delivered action bytes. An earlier revision used a
        // different conversation/turn plus an id-only JSON stand-in here, so the digest described
        // bytes the socket never carried and any later claim could only ever be an identity
        // conflict. RECOVERY is not identity-bound, but REPLAY of the reconstructed record is.
        let manager = testConversationManager()
        let originalIdentity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-48", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: "7138bc14-6823-45bc-a8a2-4a90f47ab9eb", in: self.pendingFixture ?? ""))
        ))
        let diedIdentity = originalIdentity
        XCTAssertEqual(journal.claim("7138bc14-6823-45bc-a8a2-4a90f47ab9eb", identity: diedIdentity), OperationClaim.claimed)
        // The restart recovery path the assembly runs at launch:
        let reconstructed = journal.reconstructInterrupted("7138bc14-6823-45bc-a8a2-4a90f47ab9eb")
        XCTAssertEqual(reconstructed?.outcome, .unknown)

        let consumer = RecordingResultConsumer()
        // RE-PRESENT THE ORIGINAL IDENTITY: the same manager (which retains the prepared turn) and
        // the same utterance, so owner/conversation/turn and delivered bytes all match the record.
        let identity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-48", manager: manager,
            bytes: try XCTUnwrap(Self.deliveredPayload(for: "7138bc14-6823-45bc-a8a2-4a90f47ab9eb", in: self.pendingFixture ?? ""))
        ))
        XCTAssertEqual(identity.conversation, originalIdentity.conversation,
                       "the restart case re-presents the identity the record was claimed under")
        XCTAssertEqual(identity.turn, originalIdentity.turn)
        XCTAssertEqual(identity.actionDigest, originalIdentity.actionDigest,
                       "replay compares digests, so the bytes must be the delivered action verbatim")
        let sink = makeSinkWithConsumer(consumer, conversationManager: manager, operationJournal: journal, appOperationSupport: fixtureSupport("playback.seek_to"))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-48")

        // The effect must NOT have run: no seek reached playback.
        XCTAssertFalse(
            playback.calls.contains { if case .seekTo = $0 { return true }; return false },
            "a reconstructed-unknown operation must never re-execute its effect"
        )
        // The recorded unknown replays through the bound transport.
        let deadline = Date().addingTimeInterval(5)
        var resultFrame: [String: Any]?
        while Date() < deadline && resultFrame == nil {
            resultFrame = await MainActor.run {
                capturedTask?.sentTextFrames.compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }.first { ($0["type"] as? String) == "app_operation_result" }
            }
            if resultFrame == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let frame = try XCTUnwrap(resultFrame, "the reconstructed unknown must ride the turn socket")
        XCTAssertEqual(frame["operation_id"] as? String, "7138bc14-6823-45bc-a8a2-4a90f47ab9eb")
        XCTAssertEqual(frame["outcome"] as? String, "unknown")
        XCTAssertEqual(frame["reason"] as? String, OperationReason.interruptedInFlight)
        // And the record stays settled: a further claim replays, not re-claims.
        if case .alreadyRun = journal.claim("7138bc14-6823-45bc-a8a2-4a90f47ab9eb", identity: identity) {} else {
            XCTFail("the reconstructed record must be settled")
        }
    }

    /// AN ORDINARY TURN THAT SETTLES WITH BUFFERED AUDIO BINDS OWNERSHIP, AND A SUCCESSOR'S STOP
    /// CREATES ITS REPORT — executed through the real turn lifecycle, not by poking state.
    ///
    /// The state-only controls this replaces asserted the read-and-clear helpers directly, so the
    /// production sequence (done -> audio still playing -> successor stops it -> report) was never
    /// executed. Here turn A runs to `done` with audio payloads still outstanding, and the binding
    /// is asserted as a consequence of that turn.
    func testAnOrdinaryTurnWithBufferedAudioBindsPlaybackOwnershipAtDone() async throws {
        try await checkBufferedPlaybackNextAuth(drainBeforeFollowUp: false)
    }

    func testDrainedBufferedPlaybackSendsNoInterruptionReportOnNextAuth() async throws {
        try await checkBufferedPlaybackNextAuth(drainBeforeFollowUp: true)
    }

    private func checkBufferedPlaybackNextAuth(drainBeforeFollowUp: Bool) async throws {
        // A REAL OUTPUT IS REQUIRED for the binding to exist at all: with no available output the
        // player consumes frames silently, `hasPendingAudio` is false, and `done` correctly binds
        // nothing (measured — the first version of this control failed for exactly that reason and
        // was reporting on the silent-consume case, not the buffered-playback one).
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        defer { CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil }
        self.pendingFixture = """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let sink = makeSinkWithConsumer(
            RecordingResultConsumer(),
            audioPayloads: (0..<40).map { Data([UInt8($0)]) }
        )
        let turn = Task {
            await sink.routeToCloud(
                request: "x", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: nil, utteranceId: "u-settled"
            )
        }
        _ = await turn.value

        // THE PRODUCTION CONSEQUENCE: `done` with audio still outstanding binds the owner. An
        // ordinary turn has NO interruption id, which is why gating the binding on one left this
        // case with no producer at all.
        let bound = await MainActor.run {
            sink.interruptionStateForTesting.bufferedPlaybackOwnerRequestIdForTesting
        }
        XCTAssertEqual(
            bound, "u-settled",
            "a turn that settles with buffered audio must BIND ownership at done, so a later stop "
            + "has a producer for its report"
        )
        let owesReport = await MainActor.run {
            sink.interruptionStateForTesting.hasPendingReport
        }
        XCTAssertFalse(owesReport, "nothing is owed yet: the user has not stopped hearing it")
        if drainBeforeFollowUp {
            let player = await MainActor.run { sink.audioPlayerForTesting }
            let actualPlayer = try XCTUnwrap(player)
            let epoch = actualPlayer.finish()
            let drained = await actualPlayer.awaitActualStop(after: epoch, timeout: 5)
            XCTAssertTrue(drained, "natural finish must confirm its physical drain")
            let binding = await MainActor.run {
                sink.interruptionStateForTesting.bufferedPlaybackOwnerRequestIdForTesting
            }
            XCTAssertNil(binding, "the production drain callback must clear buffered ownership")
        }

        pendingFixture = """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        _ = await sink.routeToCloud(
            request: "follow up", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp, utteranceId: "u-next"
        )
        let frames = capturedTask?.sentTextFrames.compactMap { text -> [String: Any]? in
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } ?? []
        let auth = try XCTUnwrap(frames.first { $0["type"] as? String == "authenticate" })
        XCTAssertEqual(auth["request_id"] as? String, "u-next")
        if drainBeforeFollowUp {
            XCTAssertNil(auth["interrupts"], "fully heard playback owes no interruption report")
        } else {
            let report = try XCTUnwrap(auth["interrupts"] as? [String: Any])
            XCTAssertEqual(report["request_id"] as? String, "u-settled")
        }
        let stillPending = await MainActor.run { sink.interruptionStateForTesting.hasPendingReport }
        XCTAssertFalse(stillPending)
    }

    // MARK: - operation gate: refuse BEFORE any effect when identity is incomplete

    /// No journal at all = no durable record of the operation, so an identified operation must
    /// not run. This used to be replaced with a fabricated `.claimed`.
    func testIdentifiedActionWithoutAJournalRefusesBeforeAnyEffect() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"7e14606e-e88e-4c39-a857-12294cd9dd32","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let cloudConfig = CloudConfig(defaults: defaults)
        let sink = CloudRouteSink(
            clientFactory: {
                CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: Self.injectOperationIdentity(self.pendingFixture ?? ""),
                    tokenProvider: Self.pairedTestProvider()
                ).client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            conversationManager: testConversationManager()
        )
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-no-journal")
        XCTAssertEqual(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count, 0,
                       "without durable storage the mutation must not run")
    }

    /// A missing trusted owner is a refusal, never an empty-string owner in the journal: an
    /// operation journaled under "" could not be told apart from another account's.
    func testIdentifiedActionWithoutATrustedOwnerRefusesBeforeAnyEffect() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"9df43bff-7093-4c40-a12b-d339d50e949d","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let journal = OperationJournal(store: InMemoryOperationRecordStore())
        let cloudConfig = CloudConfig(defaults: defaults)
        let sink = CloudRouteSink(
            clientFactory: {
                CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: Self.injectOperationIdentity(self.pendingFixture ?? ""),
                    tokenProvider: StubTokenProvider(token: "test_token", accountId: "")
                ).client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            operationJournal: journal,
            conversationManager: testConversationManager()
        )
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-no-owner")
        XCTAssertEqual(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count, 0,
                       "an unowned operation must not run")
        XCTAssertEqual(journal.interruptedOperationIDs(), [],
                       "a refused operation must not be journaled")
        XCTAssertNil(journal.result(for: "9df43bff-7093-4c40-a12b-d339d50e949d"))
    }

    /// AN ACCOUNT SWITCH MID-TURN must not get its operation journaled under the account that
    /// opened the turn. The owner is captured at admission, so the gate has to re-check the LIVE
    /// session before claiming — a stale captured owner alone would happily settle under the old
    /// account.
    func testAccountSwitchAfterAdmissionRefusesBeforeAnyEffect() async throws {
        self.pendingFixture = """
            event: action
            data: {"operation_id":"132b2d8b-c918-4062-a684-59b1e314944d","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let journal = OperationJournal(store: InMemoryOperationRecordStore())
        let manager = testConversationManager()
        let cloudConfig = CloudConfig(defaults: defaults)
        let operationId = "132b2d8b-c918-4062-a684-59b1e314944d"
        // ORIGINAL BYTES, taken from the fixture BEFORE routing: the admission path consumes
        // `pendingFixture`, so reading it afterwards would describe a frame that was never sent.
        let originalActionBytes = try XCTUnwrap(
            Self.deliveredPayload(for: operationId, in: self.pendingFixture ?? "")).data(using: .utf8)
        // THE TURN'S OWN TASK, captured on its own first build.
        var turnTask: StubWebSocketTask?
        // THE ORDERING SEAM IS THE AWAITED RECEIVE PARK, NOT A SENDABLE CLOSURE.
        // `CloudRouteSink` is `@MainActor`, so a `@Sendable` `onFrameReceived` closure cannot read or
        // mutate the sink's socket, and a `Task { @MainActor }` hop would be unordered. Instead the
        // producer PARKS inside `receive()` after acquisition; while it is parked the TEST reads the
        // original socket on MainActor, switches its lock-guarded session there, and only then
        // releases the producer to deliver the action. Switch strictly precedes action, with no
        // actor-isolated state touched from the producer's task.
        let actionDeliveryGate = HoldLatch()
        let sink = CloudRouteSink(
            clientFactory: {
                // THIS METHOD BUILDS THE SINK DIRECTLY, so it must install the park itself: a
                // `self.pendingDeclaredPark` assignment is only read by `makeSinkWithConsumer` and
                // would hold nothing here. Installed at CREATION so the park exists before the
                // first frame is served; threshold 0 parks the first inbound receive, which is the
                // action frame arriving after credential acquisition.
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: Self.injectOperationIdentity(self.pendingFixture ?? ""),
                    prepareTask: { task in
                        task.armedReceivePark = actionDeliveryGate
                        task.declaredParkAfterFrames = 0
                    },
                    tokenProvider: Self.pairedTestProvider()
                )
                // Retirement wake: a cancelled socket releases the parked receive from the SAME
                // cancellation, so cleanup cannot hang on a hold nobody releases.
                built.task.retiredParkNotifier = { actionDeliveryGate.notifyRetired() }
                turnTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            // THE MATCHING TARGET OBSERVER, so the ONLY variable in this control is the account
            // switch. Without it `targetMatch` is `.absent` and an episode-relative action is
            // refused `stale_precondition` BEFORE any effect (CloudRouteSink.swift:1930-1936) and
            // that refusal is then settled into the journal (:1990-1993) — a target-unavailable
            // refusal wearing the switch's clothes. Declared in SIGNATURE order: after
            // `playbackPositionMs`, before `cloudPlaybackContextState`.
            // The missing-observer NEGATIVE lives in its own control
            // (`testSinkWithNoTargetObserverRefusesEpisodeRelativeEffect`) and stays untouched.
            currentEpisodeIdProvider: { Self.testEpisodeId },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            operationJournal: journal,
            conversationManager: manager
        )
        // The turn is held inside `receive()`, so routing does NOT return yet.
        let turn = Task {
            await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-switched")
        }
        defer { actionDeliveryGate.release() }
        // Wait, bounded, for the AWAITED park to report itself.
        var parked = false
        var waited = 0
        while !parked && waited < 500 {
            parked = await MainActor.run { turnTask?.didParkInReceive ?? false }
            if !parked { try await Task.sleep(nanoseconds: 10_000_000) }
            waited += 1
        }
        XCTAssertTrue(parked, "the producer is parked inside the awaited receive()")
        // ACQUISITION HAS HAPPENED, and the action has NOT been delivered. Switch the session on the
        // turn's OWN socket, on MainActor, while the producer is parked.
        let parkedSocket = await MainActor.run { sink.activeResultSocketForTesting }
        let preSwitchAccount = await MainActor.run { parkedSocket?.authenticatedSession?.accountId }
        XCTAssertEqual(preSwitchAccount, "test-owner",
                       "the turn acquired a real session before the park")
        await MainActor.run {
            parkedSocket?.authenticatedSession = CloudAuthenticatedSession(
                accountId: "account-b", accessToken: "test-credential")
        }
        let switched = await MainActor.run { parkedSocket?.authenticatedSession?.accountId }
        XCTAssertEqual(switched, "account-b", "the live session was switched after admission")
        // ONLY NOW release the producer so the action frame is delivered under the new session.
        actionDeliveryGate.release()
        _ = await turn.value

        // THE SWITCH ACTUALLY HAPPENED, and it happened on this turn's own socket. Without this
        // the zero-effect result below would be equally consistent with a switch that never ran.
        let publishedSession = await MainActor.run { sink.activeResultSocketForTesting?.authenticatedSession }
        XCTAssertEqual(publishedSession?.accountId, "account-b",
                       "the socket that would carry the result now names a different account")
        XCTAssertNotNil(turnTask, "the turn's own transport was captured")
        let sentFrames = await MainActor.run { turnTask?.sentTextFrames ?? [] }
        XCTAssertTrue(sentFrames.contains { $0.contains(operationId) },
                      "the operation was delivered to this turn, so its refusal is about the switch")

        XCTAssertEqual(playback.calls.filter { if case .seekRelative = $0 { return true }; return false }.count, 0,
                       "an operation whose session changed under it must not run")
        // KEPT AS SPECIFIED: a refusal may still be SENT on the original authorised route, but it
        // must not SETTLE under either account. The assertion is on the journal, not the wire.
        XCTAssertNil(journal.result(for: operationId),
                     "and must not be settled under either account")
        XCTAssertTrue(originalActionBytes?.isEmpty == false,
                      "the control carries the original delivered bytes, not a re-encoded stand-in")
    }

    /// The SECOND turn of one sink must not inherit the first turn's identity: the identity is
    /// captured per admitted turn, so turn 2's settlement is bound to turn 2.
    func testTwoTurnsOnOneSinkJournalUnderTheirOwnIdentities() async throws {
        let manager = testConversationManager()
        let journal = OperationJournal(store: InMemoryOperationRecordStore())
        self.pendingFixture = """
            event: action
            data: {"operation_id":"1bcc78d9-a144-4f8b-a04f-146c49aa9f81","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":5},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let sink = makeSinkWithConsumer(RecordingResultConsumer(), conversationManager: manager,
                                        operationJournal: journal,
                                        appOperationSupport: fixtureSupport("playback.seek_relative"))
        let firstPayload = try XCTUnwrap(
            Self.deliveredPayload(for: "1bcc78d9-a144-4f8b-a04f-146c49aa9f81", in: self.pendingFixture ?? ""))
        let firstIdentityOrNil = Self.mintedIdentity(
            for: "u-turn-1", manager: manager, bytes: firstPayload)
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-turn-1")

        self.pendingFixture = """
            event: action
            data: {"operation_id":"b426dd7e-28e0-43a1-aaf1-14846dba4065","capability_version":"app-ops/1","tool":"playback","action":"seek_relative","params":{"delta_seconds":6},"precondition":{"episode_id":"ep-task67"}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let secondPayload = try XCTUnwrap(
            Self.deliveredPayload(for: "b426dd7e-28e0-43a1-aaf1-14846dba4065", in: self.pendingFixture ?? ""))
        let secondIdentity = try XCTUnwrap(Self.mintedIdentity(
            for: "u-turn-2", manager: manager, bytes: secondPayload))
        _ = await sink.routeToCloud(request: "x", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: nil, utteranceId: "u-turn-2")

        let firstIdentity = try XCTUnwrap(firstIdentityOrNil)
        XCTAssertNotEqual(firstIdentity.turn, secondIdentity.turn, "the two turns are distinct")
        if case .alreadyRun = journal.claim("1bcc78d9-a144-4f8b-a04f-146c49aa9f81", identity: firstIdentity) {} else {
            XCTFail("turn 1's operation must be settled under turn 1's identity")
        }
        if case .alreadyRun = journal.claim("b426dd7e-28e0-43a1-aaf1-14846dba4065", identity: secondIdentity) {} else {
            XCTFail("turn 2's operation must be settled under turn 2's identity")
        }
        // Cross-turn: the same id under the other turn's identity is a conflict, not a replay.
        XCTAssertEqual(journal.claim("1bcc78d9-a144-4f8b-a04f-146c49aa9f81", identity: secondIdentity), OperationClaim.identityConflict)
    }
}

private final class NoOpCloudStatsQuerySink: VoiceStatsQuerySink {
    func listeningTime(period: String?) -> VoiceResponse { .silent }
    func topPodcasts(period: String?) -> VoiceResponse { .silent }
    func episodesFinished(period: String?) -> VoiceResponse { .silent }
    func listeningStreak() -> VoiceResponse { .silent }
    func subscriptionCount() -> VoiceResponse { .silent }
    func unplayedTotal() -> VoiceResponse { .silent }
    func downloadStats() -> VoiceResponse { .silent }
    func newEpisodes(timeframe: String?) -> VoiceResponse { .silent }
    func timeSinceLastListen() -> VoiceResponse { .silent }
}


/// A playback double whose reads and writes are SYNCHRONIZED.
///
/// The sink calls it from its own serial task while a test reads it from the test task, so the
/// unlocked `var calls` / `var isPlaying` this replaces were a data race: a resume could land
/// after a read and the same assertion then saw 1 or 0 across identical runs. Everything below is
/// behind one lock, and `awaitResume()` waits on the lock rather than polling a copied array, so a
/// test observes the state the double actually holds.
private final class RecordingPlaybackSink: VoicePlaybackSink, @unchecked Sendable {

    /// voice-intents.md @ 818c8f75 knob: no current engine reading exists (a missing engine),
    /// so the observation is UNAVAILABLE rather than observed-paused.
    private var simulateUnavailableObservation = false
    func setSimulateUnavailableObservation(_ on: Bool) {
        lock.lock(); simulateUnavailableObservation = on; lock.unlock()
    }

    /// The single observation the identified pause path reads: unavailable, observed playing,
    /// or observed paused — never collapsing a missing engine into `false`.
    private var storedObservedPlayingReads = 0
    /// voice-intents.md @ 818c8f75 guard: classification and settlement must come from ONE
    /// observation, so the identified pause path may read this EXACTLY ONCE after its pause.
    var observedPlayingReads: Int {
        lock.lock(); defer { lock.unlock() }
        return storedObservedPlayingReads
    }
    var observedPlaying: Bool? {
        lock.lock()
        storedObservedPlayingReads += 1
        let unavailable = simulateUnavailableObservation
        let playing = storedIsPlaying
        lock.unlock()
        if unavailable { return nil }
        return playing
    }

    /// Host playing at the moment the turn reads it. `pause()` and `resume()`
    /// keep it true to playback: a constant `true` hides a lost hold, because a
    /// turn that inherits an outstanding pause would still read "playing".
    private let lock = NSLock()
    private var storedIsPlaying = true
    private var storedCalls: [Call] = []
    private var storedPositionMs: Int64 = 0
    /// Signalled each time `resume()` records a call, so a test can AWAIT restoration rather than
    /// poll a snapshot that may predate it.
    private let resumeLatch = NSCondition()

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedIsPlaying
    }

    enum Call: Equatable {
        case pause, resume, seekRelative(Int?, SeekDirection), seekTo(Int), nextEpisode
    }

    /// Models the state before a turn: a user who paused before speaking, or a
    /// player that is running. `pause()`/`resume()` maintain it thereafter.
    func setPlaying(_ playing: Bool) {
        lock.lock(); storedIsPlaying = playing; lock.unlock()
    }

    /// voice-intents.md @ 818c8f75 control knob: a real engine can fail to stop. When set,
    /// `pause()` records the call but leaves the engine playing, so the sink's fresh post-sink
    /// observation reads `true` — the only way the `pause_not_observed` arm is reachable.
    private var simulatesFailedPause = false
    /// voice-intents.md @ df5def09 knob (TEST DOUBLE ONLY): the resume sink "completed" but the
    /// engine stayed paused, so the post-sink observation still reads `false` — the
    /// `resume_not_observed` arm is otherwise unreachable because this double always flips
    /// `storedIsPlaying` to true in `resume()`.
    private var simulatesFailedResume = false
    func setSimulatesFailedResume(_ on: Bool) {
        lock.lock(); simulatesFailedResume = on; lock.unlock()
    }
    func setSimulatesFailedPause(_ on: Bool) {
        lock.lock(); simulatesFailedPause = on; lock.unlock()
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return storedCalls
    }

    var positionMs: Int64 {
        lock.lock(); defer { lock.unlock() }
        return storedPositionMs
    }

    func setPositionMs(_ value: Int64) {
        lock.lock(); storedPositionMs = value; lock.unlock()
    }

    func clearCalls() {
        lock.lock(); storedCalls = []; lock.unlock()
    }

    /// Waits until a resume has been RECORDED, or the deadline passes. This is the observable
    /// settled signal: it reads the double's own synchronised state instead of polling a copy.
    @discardableResult
    func awaitResume(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            lock.lock()
            let seen = storedCalls.contains(.resume)
            lock.unlock()
            if seen { return true }
            usleep(2_000)
        }
        return false
    }

    func pause() -> VoiceResponse {
        lock.lock()
        storedCalls.append(.pause)
        if !simulatesFailedPause { storedIsPlaying = false }
        lock.unlock()
        return .earcon(.success)
    }

    func resume() -> VoiceResponse {
        lock.lock()
        storedCalls.append(.resume)
        if !simulatesFailedResume { storedIsPlaying = true }
        lock.unlock()
        resumeLatch.broadcast()
        return .silent
    }

    private func record(_ call: Call) {
        lock.lock(); storedCalls.append(call); lock.unlock()
    }

    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse {
        record(.seekRelative(deltaSeconds, direction))
        return .silent
    }

    func seekTo(positionSeconds: Int) -> VoiceResponse {
        record(.seekTo(positionSeconds))
        return .silent
    }

    /// A negative position resolves back from the episode end, as the real sink
    /// does; the double records the resolved absolute position.
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse {
        let resolved = positionSeconds < 0
            ? max(episodeDurationSeconds + positionSeconds, 0)
            : positionSeconds
        record(.seekTo(resolved))
        return .silent
    }

    func nextEpisode() -> VoiceResponse {
        record(.nextEpisode)
        return .silent
    }
}

private struct RecordingFingerprintMapper: FingerprintMappingProviding {
    var playbackSecondsForReference: [TimeInterval: TimeInterval] = [:]

    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { nil }

    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? {
        playbackSecondsForReference[referenceTime]
    }
}

private final class RecordingAnalytics: AnalyticsService {
    var events: [(String, [String: Any])] = []
    func track(_ event: String, properties: [String: Any]) {
        events.append((event, properties))
    }
}

// MARK: - Slice 4: superseded turns

/// A second turn (double wake / barge-in) supersedes the first: the older turn
/// must stop consuming its stream and must not touch playback state, analytics,
/// or late actions after the new turn takes over.
/// Independent completion flag for bounded completion probes (review 9fc2603e).

final class CloudRouteSupersedeTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var mapper: RecordingFingerprintMapper!
    private var analytics: RecordingAnalytics!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        mapper = RecordingFingerprintMapper()
        analytics = RecordingAnalytics()
        suiteName = "cloud_route_supersede_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    func testDoneKeepsTheHoldWhileOnlyScheduledAudioRemains() async throws {
        try await exerciseScheduledOnlyDone(coalesceBeforeDone: false)
    }

    @MainActor
    func testCoalescedDoneReleasesTheHoldOnItsBoundPhysicalStop() async throws {
        try await exerciseScheduledOnlyDone(coalesceBeforeDone: true)
    }

    @MainActor
    private func exerciseScheduledOnlyDone(coalesceBeforeDone: Bool) async throws {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        CloudAudioPlayer.configureEngineForTesting = { engine in
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        }
        addTeardownBlock {
            CloudAudioPlayer.configureEngineForTesting = nil
            CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        }
        let producerRelease = DispatchSemaphore(value: 0)
        blockProducerAfterFrames = (8, producerRelease) // Seven binary PCM messages, then park before done.
        nextTurnFixture = Self.doneOnlyFixture
        nextTurnAudioPayloads = (0..<7).map { _ in Data(repeating: 0x11, count: 4_800 * 2) }
        holdCounters = (AtomicInteger(), AtomicInteger())
        playback.setPlaying(true)
        let sink = makeSink(withHoldCounters: true)
        let player = try XCTUnwrap(sink.audioPlayerForTesting)
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        player.emittedPCMReference = reference
        player.echoReferenceHandoff = handoff
        addTeardownBlock { @MainActor in
            producerRelease.signal()
            player.openPhysicalStopGateForTesting()
            let stop = player.cancel()
            let settled = await player.awaitActualStop(after: stop)
            XCTAssertTrue(settled, "cleanup must settle before resetting the shared offline hook")
            withExtendedLifetime(handoff) {}
            withExtendedLifetime(sink) {}
        }
        let turn = Task {
            await sink.routeToCloud(request: "scheduled audio", tier: .free, context: sampleContext(),
                                    origin: cloudTestOrigin, selection: .wakeWord, utteranceId: "scheduled-only")
        }
        try await waitUntil("audio reached the real player before done", timeout: 3) {
            reference.streamIndex == 22_400 && player.bufferedFrameCountForTesting == 0
        }
        let engine = try XCTUnwrap(player.engineForTesting)
        let node = try XCTUnwrap(player.playerNodeForTesting)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        XCTAssertEqual(try engine.renderOffline(128, to: output), .success)
        XCTAssertLessThan(try XCTUnwrap(player.renderPosition(of: node)).renderedFrames, 33_600)
        XCTAssertFalse(player.hasPendingAudio, "premise: no Swift buffer remains; the pending audio is already scheduled")
        XCTAssertTrue(player.hasOutstandingOutput)
        XCTAssertEqual(holdCounters?.begin.value, 1)
        let releasesBeforeDone = try XCTUnwrap(holdCounters?.end.value) // Admission also reports an absent predecessor.
        let priorDrain = coalesceBeforeDone ? player.finishWithStopBinding() : nil
        producerRelease.signal()
        let result = await turn.value
        XCTAssertEqual(result.outcome, .completed)
        if let priorDrain {
            XCTAssertEqual(player.currentDrainEpoch, priorDrain.requestEpoch + 1,
                           "premise: done allocated a distinct request coalesced on the pending drain")
        }
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 0,
                       "done must not resume host playback over the queued response tail")
        XCTAssertEqual(holdCounters?.end.value, releasesBeforeDone, "done must retain its existing grace playback hold")
        let deadline = Date().addingTimeInterval(2)
        while (player.renderPosition(of: node)?.renderedFrames ?? 0) < 33_600 && Date() < deadline {
            XCTAssertEqual(try engine.renderOffline(1_024, to: output), .success)
        }
        do {
            try await waitUntil("the actual owned stop releases the hold") {
                playback.calls.filter { $0 == .resume }.count == 1 && holdCounters?.end.value == releasesBeforeDone + 1
            }
        } catch {
            XCTFail("the notifiable physical stop did not release the retained hold: \(error)")
        }
        if let priorDrain {
            XCTAssertEqual(player.confirmedStopEpochForTesting, priorDrain.stopEpoch,
                           "the superseded done request must not be relabelled as a physical stop")
        }
    }

    /// OWNER-CANCEL STOP ORDERING (review dee03708/fa03b7f9, reworked for 14f66b72): a
    /// superseded turn with NO pending playback owes no await — it returns earlyClose, never
    /// restores (the successor owns the window), and the successor's single resume is intact.
    func testSupersededTurnAwaitsItsOwnedStopAndLeavesTheReleaseToTheSuccessor() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            """
        let gate = holdNextTurn()
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-49") }
        try await Task.sleep(nanoseconds: 200_000_000)
        // B supersedes A FIRST: A's cleanup must observe the transfer (still no stop is
        // requested — A owned no pending playback at supersession).
        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-50")
        gate.release()
        let aResult = await slow.value
        XCTAssertEqual(aResult.outcome, .earlyClose, "the superseded turn is an incomplete turn")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1,
                       "only the winning turn restores playback")
        let cancels = await MainActor.run { sink.audioPlayerForTesting?.cancelRequestCountForTesting ?? -1 }
        XCTAssertEqual(cancels, 0, "no stop was REQUESTED: nothing was pending at supersession")
    }

    /// ADMISSION AWAITS PREDECESSOR QUIESCENCE (review 14f66b72): B's retire only QUEUES a
    /// runner stop, so B must not admit (or even build) its stream until A's stop is CONFIRMED.
    /// A's producer is parked after its audio frames (all enqueued, A still running); B
    /// supersedes; with the retire stop's confirmation withheld, B has neither built its client
    /// nor completed; delivery releases B, which then completes normally.
    func testSuccessorAdmissionAwaitsPredecessorQuiescence() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        // A's frames are held IN THE BUFFER (drain-hold parks dequeue without consuming), so
        // "A owns playback output" is deterministic, not a race against the engine.
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let aGate = DispatchSemaphore(value: 0)
        self.blockProducerAfterFrames = (40, aGate)
        let sink = makeSink()
        hookedSink = sink
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
        }
        let box = Box()
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(true) }
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-51") }
        var aEnqueued = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aEnqueued = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aEnqueued, "A's audio is enqueued while its producer is parked")
        let aTask = capturedTask
        // Withhold stf6241f37-b493-47f2-aaf4-6dcdf6120103 delivery: B's admission await suspends on the retire stop.
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"fast"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        let fast = Task { await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-52") }
        // B must be SUSPENDED at admission: no client built, no completion.
        let bFinishedEarly = try await timeoutProbe(fast, nanoseconds: 200_000_000)
        XCTAssertFalse(bFinishedEarly, "B is suspended at admission while A's stop is unconfirmed")
        // A's frames were retired synchronously; nothing new is admitted while B waits.
        let pendingNow: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? true }
        XCTAssertFalse(pendingNow, "no successor audio is buffered while A's stop is unconfirmed")
        // Release the drain hold FIRST: the runner is parked inside the hold and must process
        // the queued retire stop (and issue its notification) before anything can confirm.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        // Deliver the retire stop: B proceeds, admits ITS OWN audio, and completes. The capture
        // hook is uninstalled first so B's OWN drain stop delivers normally.
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            box.deliverAll()
        }
        let bResult = await fast.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes once the predecessor is quiescent")
        // A's producer unblocked: its cleanup awaits the CAPTURED retire identity (already
        // confirmed) and returns an incomplete turn without touching B's window.
        aGate.signal()
        let aResult = await slow.value
        XCTAssertEqual(aResult.outcome, .earlyClose, "the superseded turn is an incomplete turn")
        // B's deferring drain restores asynchronously — bounded poll, never an instant assert.
        var resumes = 0
        for _ in 0..<60 {
            resumes = playback.calls.filter { $0 == .resume }.count
            if resumes == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(resumes, 1, "only B restores the window")
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            sink.audioPlayerForTesting?.setDrainHoldForTesting(false)
        }
    }

    /// SUCCESS-PATH OWNERSHIP (review 4fc59e2c / spec dbf71ccf): the scoped rollback defer must
    /// fire ONLY on early return. On a successful A-retire, B keeps its active ownership,
    /// playback ownership, and admitted hold through its live stream and drain — snapshot at
    /// B's first frame (exactly one hold end: A's transfer) and after B completes (two).
    func testSuccessfulRetireKeepsBOwnershipAndHoldThroughStreamAndDrain() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        holdCounters = (AtomicInteger(), AtomicInteger())
        let sink = makeSink(withHoldCounters: true)
        hookedSink = sink
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setDrainHoldForTesting(true)
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-53") }
        var aBuffered = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aBuffered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aBuffered, "A's audio is buffered under the drain hold")
        // B supersedes successfully: retire A, confirm, then stream.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"B"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        firstFrameActionForNextBuild = { [holdCounters] in
            // Snapshot BEFORE B's done: exactly one end (A's at the transfer) must have
            // fired — an early-return-style rollback here would be a second.
            Self.successSnapshot.bump(holdCounters?.end.value ?? -1)
        }
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-54") }
        // Confirm A's stop so B is admitted for real: the runner must leave its park to
        // process the retire stop, then the withheld notification is delivered.
        try await Task.sleep(nanoseconds: 120_000_000)
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            box.deliverAll()
        }
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes after a successful retire")
        _ = await a.value
        // A's own end may legitimately fire once its drain stop confirms — the invariant is
        // that B's OWN hold ends exactly once AFTER its first frame: n2 == n1 + 1. Under the
        // rollback bug the scoped defer ends B's hold at admission and the real end no-ops
        // (heldPlaybackToken already cleared), so n2 == n1 there.
        let endsAtFirstFrame = Self.successSnapshot.value
        XCTAssertGreaterThanOrEqual(endsAtFirstFrame, 1, "A's transfer end fired")
        var ends = 0
        for _ in 0..<60 {
            ends = holdCounters?.end.value ?? -1
            if ends == endsAtFirstFrame + 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(ends, endsAtFirstFrame + 1,
                       "B's own hold ends at its real drain/stop, exactly once after its first frame")
    }
    /// Hold-end count captured at B's first frame (success-path ownership control).
    static let successSnapshot = SnapshotInt()

    final class SnapshotInt: @unchecked Sendable {
        private let lock = NSLock(); private var v = 0
        func bump(_ n: Int) { lock.lock(); v = n; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// ROLLBACK HOLD RESPONSIBILITY (review 8eb9fb44): when a TIMED-OUT admission rolls back,
    /// it is still the active owner and its hold is the LAST live one over the predecessor's
    /// still-unconfirmed output — ending it at rollback would re-arm the allowance mid-flight.
    /// The hold must stay live until the retire stop CONFIRMS, and end exactly then.
    /// (A superseded-while-waiting rollback needs no such handling: the successor's atomic
    /// transfer already moved the hold before the rollback runs.)
    func testRolledBackAdmissionKeepsItsHoldLiveUntilTheRetireStopConfirms() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        holdCounters = (AtomicInteger(), AtomicInteger())
        let sink = makeSink(withHoldCounters: true)
        hookedSink = sink
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setDrainHoldForTesting(true)
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-55") }
        var aBuffered = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aBuffered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aBuffered, "A's audio is buffered under the drain hold")
        // B supersedes A; the retire stop stays unconfirmed (runner parked, notification
        // withheld) until B's admission bounds expire and B rolls back.
        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-56") }
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .earlyClose, "B's admission times out and rolls back")
        // THE PIN: exactly two ends have fired — the nil-predecessor transfer at A's admission
        // and A's transfer at B's admission. B's OWN hold (the last live one) is NOT ended
        // while its retire stop is unconfirmed (the bug ended it at rollback: 3).
        XCTAssertEqual(holdCounters?.end.value ?? -1, 2,
                       "the rolled-back admission's hold is NOT ended while its retire stop is unconfirmed")
        // Precondition: the host was auto-paused for the cloud audio and B inherited that
        // responsibility at the transfer.
        let pauses = playback.calls.filter { $0 == .pause }.count
        XCTAssertGreaterThanOrEqual(pauses, 1, "the host was auto-paused for A's cloud audio")
        // Confirm E1: B's release responsibility fires exactly here.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            box.deliverAll()
        }
        var ends = 0
        var resumesAfterConfirm = 0
        for _ in 0..<100 {
            ends = holdCounters?.end.value ?? -1
            resumesAfterConfirm = playback.calls.filter { $0 == .resume }.count
            if ends == 3 && resumesAfterConfirm == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(ends, 3, "B's hold ends exactly when the retire stop confirms")
        XCTAssertEqual(resumesAfterConfirm, 1,
                       "exactly ONE host resume: the confirmation restores the inherited pause")
    }

    /// CLAIMED-DRAIN CANCEL (review 0585959a): a cancel landing while A's drain is claimed
    /// must be CONSUMED by the drain's own physical stop — no second physical stop may follow
    /// it. Premise: A's drain is claimed and parked; the gate parks the SUBSEQUENT stop. After
    /// the first confirmation delivers and B admits with its audio buffered, no queued stop
    /// may exist (the bug left the cancel's flag set: a second stop pending over live B
    /// output). Releasing the gate then lets B's own drain finish normally.
    func testCancelDuringClaimedDrainIsConsumedByTheDrainsPhysicalStop() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let sink = makeSink()
        hookedSink = sink
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var epochs: [Int] = []
            func record(_ epoch: Int) { lock.lock(); epochs.append(epoch); lock.unlock() }
            var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return epochs }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { epoch, deliver in
                box.record(epoch)
                deliver() // auto-confirm: the first stop's confirmation reaches B immediately
            }
        }
        // Premise: the runner is parked INSIDE the claimed drain (claim seam) when B's cancel
        // lands. The seam is installed BEFORE A runs so the drain claim cannot be missed.
        let claimReached = DispatchSemaphore(value: 0)
        let claimRelease = DispatchSemaphore(value: 0)
        await MainActor.run {
            sink.audioPlayerForTesting?.claimReached = claimReached
            sink.audioPlayerForTesting?.claimRelease = claimRelease
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-57") }
        let aResult = await a.value
        XCTAssertEqual(aResult.outcome, .completed, "A completed; its drain is claimed")
        // The runner is parked inside the CLAIMED drain.
        XCTAssertEqual(claimReached.wait(timeout: .now() + 2), .success,
                       "the runner reached the claimed drain")
        // B supersedes: the retire cancel lands while A's drain is claimed/parked.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"B"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-58") }
        try await Task.sleep(nanoseconds: 120_000_000)
        // Park the SUBSEQUENT stop: the first physical stop (the drain end, which IS the
        // cancel's stop) passes; any later stop parks.
        await MainActor.run { sink.audioPlayerForTesting?.armPhysicalStopGateForTesting(allow: 1) }
        claimRelease.signal()
        // THE PIN: exactly TWO physical stops carry confirmations — the drain end (which IS
        // the cancel's stop) and B's own done-drain. The defect ran a THIRD stop (the
        // unconsumed cancel flag) between them.
        await MainActor.run { sink.audioPlayerForTesting?.openPhysicalStopGateForTesting() }
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes once its own drain stop passes the gate")
        _ = await a.value
        // Epochs must be STRICTLY INCREASING: the defect re-processed the unconsumed cancel
        // flag as a second stop with the SAME identity (a duplicate), shedding whatever a
        // successor had admitted on the first confirmation.
        // The gate may still be parking the defect's second stop (or B's own drain): open it
        // and let every pending physical stop settle before reading the log.
        try await Task.sleep(nanoseconds: 300_000_000)
        let recorded = box.snapshot
        let strictlyIncreasing = zip(recorded, recorded.dropFirst()).allSatisfy { $0 < $1 }
        XCTAssertTrue(strictlyIncreasing && recorded.count >= 1,
                      "no stop identity is confirmed twice (got \(recorded))")
        // (No resume pin here: with no engine ever started, transient restore is a no-op by
        // design — the discriminator is the stff4cd5fe-3b75-400a-a2cd-7ede3e65ff57 log above.)
    }

    /// PHYSICAL STOP OPERATION HELD (spec ea755ba1; reviewer 6453dfaa/3d4f5619/76215282):
    /// the stop NOTIFICATION is not the physical contract — the actual `stopEngine()` operation
    /// is, so this control parks the REAL stop and asserts the ordering that falls out of it.
    ///
    /// WHAT THIS CONTROL MEASURES (scoped honestly, per reviewer 76215282/2542e2/wording and
    /// spec 43f8f003):
    ///   * the stop operation reaches the armed gate and genuinely PARKS (`allow == 0`, arrival
    ///     recorded) while B's supersede is in flight;
    ///   * while parked: no stop is CONFIRMED, B does not COMPLETE, and the host is not resumed;
    ///   * on release the park ends by RELEASE, not bound expiry (`outcome == .released`);
    ///   * the parked stop confirms the retire identity (2), and exactly one host resume follows.
    ///
    /// ORDERING (precise): B is launched while the drain is HELD, so B's retire cancel lands
    /// first; the hold is then released and the real stop parks. B is therefore already in flight
    /// when the stop parks — this control does not claim "park first, then B", only that the
    /// parked stop's settlement is not preceded by confirmation/completion/resume.
    ///
    /// WHAT IT DOES NOT MEASURE, and does not claim: that B SCHEDULED or RENDERED audio. In this
    /// test host with the drain hold set before the turn, the runner parks inside the claimed
    /// drain and frames stay BUFFERED and UNSCHEDULED (`buffered=40 scheduled=0` measured). A
    /// live-engine/B-output proof is a device integration check (`physical-output-device-check.md`);
    /// the confirmation identity here is evidence of the STOP, not of audio.
    func testSuccessorAdmissionWaitsForThePhysicalEngineStopItself() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let sink = makeSink()
        hookedSink = sink
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let bDone = Flag()
        playback.setPlaying(true)
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        // Arm the gate FIRST: the very next physical stop parks.
        await MainActor.run { sink.audioPlayerForTesting?.armPhysicalStopGateForTesting(allow: 0) }
        // A's drain hold keeps the runner away from A's stop until the cancel has landed.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(true) }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-59") }
        var aBuffered = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aBuffered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aBuffered, "premise: A's audio is buffered")
        let aResult = await a.value
        XCTAssertEqual(aResult.outcome, .completed, "A completed; its drain stop is queued")
        // B supersedes while the drain is still HELD: the retire cancel lands first.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"B"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        let b = Task {
            let result = await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-60")
            bDone.set()
            return result
        }
        var cancelled = false
        for _ in 0..<600 {
            let count: Int = await MainActor.run { sink.audioPlayerForTesting?.cancelRequestCountForTesting ?? 0 }
            if count >= 1 { cancelled = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(cancelled, "B's retire cancel landed while the drain is still held")
        // Release the hold: the runner reaches the claimed drain and its REAL stop parks.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        var parked = false
        var bDoneEarly = false
        for _ in 0..<600 {
            let arrivals: Int = await MainActor.run { sink.audioPlayerForTesting?.physicalStopGateArrivalsForTesting ?? 0 }
            if arrivals >= 1 { parked = true; break }
            if bDone.isSet { bDoneEarly = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let arrivalsAtPark: Int = await MainActor.run { sink.audioPlayerForTesting?.physicalStopGateArrivalsForTesting ?? -1 }
        let outcomeAtPark: String = await MainActor.run {
            switch sink.audioPlayerForTesting?.physicalStopGateOutcomeForTesting {
            case .released: return "released"
            case .timedOut: return "timedOut"
            case .admitted: return "admitted"
            default: return "unarmed"
            }
        }
        XCTAssertTrue(parked, "premise: the REAL stop operation reached the armed gate and parked (no B completion first: \(bDoneEarly)) [arrivals=\(arrivalsAtPark) outcome=\(outcomeAtPark)]")
        let outcomeParked: String = await MainActor.run {
            switch sink.audioPlayerForTesting?.physicalStopGateOutcomeForTesting {
            case .released: return "released"
            case .timedOut: return "timedOut"
            case .admitted: return "admitted"
            default: return "unarmed"
            }
        }
        // Bounded: the runner clears the gate flag AFTER the stop body completes (it needs the
        // lock back), so the outcome may still read `.unarmed` at the instant of arrival.
        // The parked premise IS the arrival: the gate is still armed and parking (allow == 0).
        // The outcome only becomes `released` once the wait ENDS, so it is asserted AFTER the
        // release below — asserting it here would read a value that cannot exist yet.
        let allowWhileParked: Int = await MainActor.run { sink.audioPlayerForTesting?.physicalStopGateAllowProbeForTesting ?? -99 }
        XCTAssertEqual(allowWhileParked, 0, "the gate is still armed and parking (allow=\(allowWhileParked))")
        // While parked, NOTHING is admitted or confirmed. (No scheduled-frame reading here: the
        // runner-owned scheduling counter has no synchronized publish path, so a cross-thread
        // read would be unsynchronized evidence — see reviewer 76215282.)
        let confirmedParked: Int = await MainActor.run { sink.audioPlayerForTesting?.confirmedStopEpoch() ?? -1 }
        let resumesParked: Int = await MainActor.run { playback.calls.filter { $0 == .resume }.count }
        XCTAssertLessThan(confirmedParked, 2, "no stop is confirmed before the physical stop ran")
        XCTAssertFalse(bDone.isSet, "B has not completed while the stop is parked")
        XCTAssertEqual(resumesParked, 0, "no host resume precedes the physical stop")
        // Release: the physical stop RUNS and confirms the retire cancel's identity.
        await MainActor.run { sink.audioPlayerForTesting?.openPhysicalStopGateForTesting() }
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes once its own drain settles")
        let confirmedFinal: Int = await MainActor.run { sink.audioPlayerForTesting?.confirmedStopEpoch() ?? -1 }
        XCTAssertEqual(confirmedFinal, 2, "the physical stop confirmed the retire cancel's identity (2); got \(confirmedFinal)")
        // Gate-exit cause (reviewer 6453dfaa): the park ended because the gate was RELEASED,
        // not because its bound expired and the runner proceeded anyway.
        let outcomeFinal: String = await MainActor.run {
            switch sink.audioPlayerForTesting?.physicalStopGateOutcomeForTesting {
            case .released: return "released"
            case .timedOut: return "timedOut"
            case .admitted: return "admitted"
            default: return "unarmed"
            }
        }
        XCTAssertEqual(outcomeFinal, "released", "the parked stop ended by release, not a bound expiry (outcome=\(outcomeFinal))")
        // EXACTLY ONE host resume, after the physical stop ran.
        var resumes = 0
        for _ in 0..<100 {
            resumes = await MainActor.run { playback.calls.filter { $0 == .resume }.count }
            if resumes >= 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(resumes, 1, "the host resumed exactly once, after the physical stop ran")
    }

    /// COALESCED STOP ACCOUNTING (review 4fc59e2c): cancel coalesces through the runner's
    /// flags — B and C's stops behind a parked runner share ONE processed stop/notification.
    /// Request-per-increment accounting would strand the counter positive and refuse every
    /// later admission; transition-only accounting settles to zero and D runs normally.
    func testCoalescedStopsSettleAndLaterAdmissionIsNotRefused() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let sink = makeSink()
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setDrainHoldForTesting(true)
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-61") }
        var aBuffered = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aBuffered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aBuffered, "A's audio is buffered under the drain hold")
        let plainDone =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnFixture = plainDone
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-62") }
        try await Task.sleep(nanoseconds: 80_000_000)
        self.nextTurnFixture = plainDone
        let c = Task { await sink.routeToCloud(request: "C", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-63") }
        try await Task.sleep(nanoseconds: 150_000_000)
        // Process the coalesced stop: ONE notification for B's and C's queued requests.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            box.deliverAll()
        }
        let cResult = await c.value
        let bResult = await b.value
        _ = await a.value
        XCTAssertEqual(bResult.outcome, .earlyClose, "B was superseded while waiting on the coalesced stop")
        XCTAssertEqual(cResult.outcome, .completed, "C completes once the coalesced stop confirms")
        // THE PIN: with per-request accounting the counter would still be positive here and
        // D would be refused; with transition-only accounting it settles and D runs.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"D"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (80..<90).map { Data([UInt8($0)]) }
        // Accounting settles eventually: wait (bounded) for the counter to drain before D.
        var settled = false
        for _ in 0..<200 {
            let q: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasQueuedStop ?? true }
            if !q { settled = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(settled, "stop accounting settles after the coalesced pair")
        let cancelsBeforeD: Int = await MainActor.run { sink.audioPlayerForTesting?.cancelRequestCountForTesting ?? -1 }
        let d = Task { await sink.routeToCloud(request: "D", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-64") }
        let dResult = await d.value
        XCTAssertEqual(dResult.outcome, .completed, "a later admission is not refused by stranded stop accounting")
        // Settled accounting: D's admission sees nothing outstanding and issues NO stop request.
        // Per-request increment accounting strands the counter positive, so D would spuriously
        // retire (an extra stop identity shift) even with nothing to stop.
        let cancelsAfterD: Int = await MainActor.run { sink.audioPlayerForTesting?.cancelRequestCountForTesting ?? -1 }
        XCTAssertEqual(cancelsAfterD, cancelsBeforeD, "D's admission issues no stop request when nothing is outstanding")
    }

    /// QUEUED-STOP VISIBILITY (review 05d27ddb): a stop that is queued but not yet processed is
    /// invisible to buffer/isPlaying — a THIRD turn (C) superseding B must still wait, because
    /// the queued stop would shed anything C admits. With A buffered and the runner parked, B
    /// and C both queue stops; neither may complete before the runner processes them.
    func testThirdTurnAdmissionWaitsForTheQueuedStopsItCannotSee() async throws {
        await MainActor.run { } // keep symmetry with sibling controls
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = [Data([0])] // one frame: below the play threshold — the
        // engine never starts (isPlaying false), which is exactly the cleared-buffer window.
        let sink = makeSink()
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setDrainHoldForTesting(true)
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-65") }
        var aBuffered = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aBuffered = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aBuffered, "A's audio is buffered under the drain hold")
        let aPlaying: Bool = await MainActor.run { sink.audioPlayerForTesting?.isPlaying ?? true }
        XCTAssertFalse(aPlaying, "A's engine never started: the window is buffer-only")
        // B supersedes A (retire E1 queued behind the parked runner), then C supersedes B
        // (retire E2): with the queued stop invisible to buffer/isPlaying, only the explicit
        // queued-stop signal can hold C.
        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-66") }
        try await Task.sleep(nanoseconds: 60_000_000)
        // B is suspended on E1's confirmation BEFORE C even starts.
        let bFinishedEarly = try await timeoutProbe(b, nanoseconds: 200_000_000)
        XCTAssertFalse(bFinishedEarly, "B is suspended on E1's confirmation")
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"C"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        let c = Task { await sink.routeToCloud(request: "C", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-67") }
        // C may not complete while the queued stops are unprocessed — and in particular not
        // while the runner is still parked (a C that "completed" here admitted over the stop
        // the runner has not yet processed).
        let cFinishedParked = try await timeoutProbe(c, nanoseconds: 800_000_000)
        XCTAssertFalse(cFinishedParked,
                       "C is suspended: the queued stop it cannot see holds its admission while the runner is parked")
        // And C RETIRED before admitting: E1's clear (A's leftovers) plus C's own retire clear.
        // A C that skipped its wait (queued stop invisible) never performs the second clear.
        let clears: Int = await MainActor.run { sink.audioPlayerForTesting?.bufferClearCountForTesting ?? 0 }
        XCTAssertEqual(clears, 2, "C retired B's queued-st8447de34-fd39-4d9d-a94b-e174f39a3d24 output before admitting")
        // Process the queue: the runner handles E1 then E2; confirmations withheld until now.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            box.deliverAll()
        }
        let cResult = await c.value
        XCTAssertEqual(cResult.outcome, .completed, "C completes once the queued stops are processed")
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .earlyClose, "B was superseded while waiting and is an incomplete turn")
        var resumes = 0
        for _ in 0..<60 {
            resumes = playback.calls.filter { $0 == .resume }.count
            if resumes == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(resumes, 1, "only C restores the window")
    }

    /// NETWORK-COMPLETED PREDECESSOR (review ea755ba1/05d27ddb): A finished its NETWORK work
    /// (done returned, deferral recorded) with playback still pending under the drain hold. B's
    /// admission must still await A's quiescence — playback ownership outlives the Task.
    func testAdmissionAwaitsQuiescenceOfANetworkCompletedPredecessor() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"A"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let sink = makeSink()
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverAll() { lock.lock(); let all = deliveries; deliveries = []; lock.unlock(); all.forEach { $0() } }
            func pendingCount() -> Int { lock.lock(); defer { lock.unlock() }; return deliveries.count }
        }
        let box = Box()
        await MainActor.run {
            sink.audioPlayerForTesting?.setDrainHoldForTesting(true)
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        let a = Task { await sink.routeToCloud(request: "A", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-68") }
        let aResult = await a.value
        XCTAssertEqual(aResult.outcome, .completed, "A completed its network work")
        let aPending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
        XCTAssertTrue(aPending, "A's playback is still pending (network-complete ≠ quiescent)")
        // B supersedes the network-COMPLETED A: its admission must await A's quiescence.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"B"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        let b = Task { await sink.routeToCloud(request: "B", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-69") }
        let bFinishedEarly = try await timeoutProbe(b, nanoseconds: 200_000_000)
        XCTAssertFalse(bFinishedEarly, "B is suspended: A's pending playback must quiesce first")
        // MIXED FLAGS (spec d2561f9b): A's finish (drain) was queued FIRST and B's retire-
        // cancel SECOND — the one processed stop must be the CANONICAL end: no second drain
        // stop may follow B's admission. From here every stop is recorded and delivered
        // immediately, so the total count over the rest of the test is exact.
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
                deliver()
            }
            sink.audioPlayerForTesting?.setDrainHoldForTesting(false)
        }
        let bResult = await b.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes once A is quiescent")
        _ = await a.value
        // THE PIN: the coalesced stop (A's finish + B's retire share ONE processing) plus at
        // most B's own done-drain — two recorded stops. Under the bug a SECOND drain stop ran
        // right after the cancel's stop: three. (B's done-drain exists only if frames were
        // still pending at its done; either way the bug's extra stop is not among them.)
        let recordedStops = box.pendingCount()
        XCTAssertTrue(recordedStops == 1 || recordedStops == 2,
                      "the cancel's stop canonically supersedes the queued drain: no extra physical stop (got \(recordedStops))")
        var resumes = 0
        for _ in 0..<60 {
            resumes = playback.calls.filter { $0 == .resume }.count
            if resumes == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(resumes, 1, "only B restores the window")
        let pending = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? true }
        XCTAssertFalse(pending, "no audio survives")
    }

    /// CAPTURED RETIRE IDENTITY (review 14f66b72): the superseded turn's cleanup awaits the
    /// identity captured for ITS token at the transfer — never the shared latest counter. A
    /// test-injected stop (E2) moves the counter AFTER B's admission; A must still resolve on
    /// E1's confirmation and return while E2's confirmation is still withheld.
    func testSupersededCleanupAwaitsItsCapturedRetireIdentity() async throws {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        // A's frames are held IN THE BUFFER (drain-hold parks dequeue without consuming), so
        // "A owns playback output" is deterministic, not a race against the engine.
        self.nextTurnAudioPayloads = (0..<40).map { Data([UInt8($0)]) }
        let aGate = DispatchSemaphore(value: 0)
        self.blockProducerAfterFrames = (40, aGate)
        let sink = makeSink()
        hookedSink = sink
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var deliveries: [() -> Void] = []
            func store(_ d: @escaping () -> Void) { lock.lock(); deliveries.append(d); lock.unlock() }
            func deliverOldest() { lock.lock(); let d = deliveries.isEmpty ? nil : deliveries.removeFirst(); lock.unlock(); d?() }
            func pendingCount() -> Int { lock.lock(); let c = deliveries.count; lock.unlock(); return c }
        }
        let box = Box()
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(true) }
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-70") }
        var aEnqueued = false
        for _ in 0..<600 {
            let pending: Bool = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio ?? false }
            if pending { aEnqueued = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(aEnqueued, "A's audio is enqueued while its producer is parked")
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting { _, deliver in
                box.store(deliver)
            }
        }
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"fast"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        self.nextTurnAudioPayloads = (40..<80).map { Data([UInt8($0)]) }
        // B's FIRST-frame hook injects a test stop (E2) — only once B is actually admitted,
        // i.e. strictly after E1's confirmation.
        self.cancelPlayerOnFirstFrameForNextBuild = true
        let fast = Task { await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-71") }
        try await Task.sleep(nanoseconds: 200_000_000)
        // Release the drain hold so the runner processes the retire stop, then deliver E1:
        // B is admitted and its FIRST-frame hook injects E2.
        await MainActor.run { sink.audioPlayerForTesting?.setDrainHoldForTesting(false) }
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run { box.deliverOldest() }
        let bResult = await fast.value
        XCTAssertEqual(bResult.outcome, .completed, "B completes after E1 quiescence")
        // Withheld confirmations exist (E2 among them — B's own drain may also be captured);
        // E2 is definitely not confirmed yet. Bounded wait: notification capture hops to main,
        // so under load it may land a beat after B's frames flow.
        var withheldAny = false
        for _ in 0..<200 {
            if box.pendingCount() >= 1 { withheldAny = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(withheldAny, "the injected stop's confirmation is withheld")
        // Release A's producer: its cleanup reads the CAPTURED identity (E1, already
        // confirmed) and returns WITHOUT waiting on E2.
        aGate.signal()
        let aFinished = try await timeoutProbe(slow, nanoseconds: 2_000_000_000)
        XCTAssertTrue(aFinished, "A resolved on its CAPTURED identity, not the moved counter")
        let aResult = await slow.value
        XCTAssertEqual(aResult.outcome, .earlyClose, "the superseded turn is an incomplete turn")
        XCTAssertGreaterThanOrEqual(box.pendingCount(), 1,
                                    "A resolved without needing the later stop's confirmation")
        // Cleanup: deliver E2 and release the drain hold so nothing stays stranded.
        await MainActor.run {
            sink.audioPlayerForTesting?.setCapturedStopNotificationForTesting(nil)
            sink.audioPlayerForTesting?.setDrainHoldForTesting(false)
            box.deliverOldest()
        }
    }

    func testSupersededTurnDoesNotRestoreOrRecordAnalytics() async throws {
        // Turn A: held open, so it is still running when B starts. Its fixture is
        // bound to A's client explicitly, because B's turn is built in between.
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            """
        let gate = holdNextTurn()
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-72") }

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(playback.calls.contains(.pause), "the first turn paused playback")
        gate.release()

        // Turn B supersedes A and completes cleanly.
        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-73")
        _ = await slow.value

        // Exactly one resume: the superseding turn's. A must not restore after B.
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1, "only the winning turn restores playback")
        // Analytics records only the winning turn's outcome.
        XCTAssertEqual(analytics.events.count, 1)
        // The losing turn's socket is closed rather than left running: the client
        // closes the socket on every exit path, and a superseded turn that kept it
        // open would bill for a stream nobody reads and hold the connection until
        // the server's own idle timeout.
        XCTAssertEqual(
            heldTurn?.task.sentTextFrames.count, 1,
            "the held turn sent its auth frame and is the turn these assertions are about"
        )
        // Asserted on the producer, not on consumer completion: only the client
        // setting `cancelled` proves the losing turn's socket was closed, and a
        // bounded wait turns an intermittent miss into a deterministic failure on
        // that same property rather than making the ordering guaranteed.
        let heldTask = try XCTUnwrap(heldTurn?.task, "the case held a turn open")
        let closed = await heldTask.awaitCancellation()
        XCTAssertTrue(closed, "the superseded turn's socket is closed")
    }

    func testSupersededTurnDoesNotExecuteLateActions() async {
        // Turn A: its action arrives only after it has already been superseded.
        self.nextTurnFixture =
            """
            event: action
            data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":100000}}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let gate = holdNextTurn()
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-74") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        gate.release()

        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-75")
        _ = await slow.value

        let seeks = playback.calls.filter { if case .seekTo = $0 { return true }; return false }
        XCTAssertTrue(seeks.isEmpty, "a superseded turn must not execute actions that arrive after it lost the turn")
    }

    /// A barge-in must not leave the podcast paused. Turn A pauses for its hold
    /// and is superseded before it finishes; B inherits that hold and is the
    /// turn that releases it. With a test double whose `isPlaying` ignored
    /// `pause()` this could not fail — which is why the double now models
    /// playback state faithfully.
    func testBargeInResumesPlaybackHeldByTheSupersededTurn() async {
        self.nextTurnFixture =
            """
            event: token
            data: {"text":"slow"}

            """
        let gate = holdNextTurn()
        let sink = makeSink()
        let slow = Task { await sink.routeToCloud(request: "first", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-76") }

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(playback.calls.contains(.pause), "the first turn paused playback")
        XCTAssertFalse(playback.isPlaying, "the hold is in effect while the first turn runs")
        gate.release()

        self.nextTurnFixture =
            """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":1}}

            """
        _ = await sink.routeToCloud(request: "second", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-77")
        _ = await slow.value

        XCTAssertTrue(playback.isPlaying, "the winning turn must release the hold taken for the superseded one")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 1, "exactly one resume")
    }

    /// The turn held open by `holdNextTurn()`, so a case can assert on the socket
    /// the superseding turn closed. A stub that answers instantly cannot express
    /// "A is still in flight when B starts", which is the whole premise of these
    /// cases; the socket is also where "the losing turn was closed, not left
    /// running" is observable (`StubWebSocketTask.cancelled`).
    private var heldTurn: (task: StubWebSocketTask, gate: Gate)?

    private func holdNextTurn() -> Gate {
        let gate = Gate()
        pendingHeldGate = gate
        return gate
    }

    private var pendingHeldGate: Gate?
    /// Consumed by the next `makeSink()`: the fixture that sink's turn carries.
    /// Explicit because these cases run two turns at once and the shared
    /// `pendingFixture` handoff would let the second overwrite the first's.
    private var nextTurnFixture: String?

    /// OPT-IN binary audio for the next built turn, mirroring `nextTurnFixture`. Empty means the
    /// turn carries no audio, so every existing case is unaffected.
    private var nextTurnAudioPayloads: [Data] = []
    /// Producer-side park (review 14f66b72 controls): blocks the NEXT built client's producer
    /// after N frames — A's audio is enqueued while A is still running.
    private var blockProducerAfterFrames: (count: Int, semaphore: DispatchSemaphore)?
    /// Install a first-frame hook on the NEXT built client that cancels the player (a stop the
    /// test itself injects, to move the shared latest identity AFTER a captured retire).
    private var cancelPlayerOnFirstFrameForNextBuild = false
    private var injectedStopDone = false
    /// Opt-in action on the NEXT built client's first frame (ownership-snapshot probes).
    private var firstFrameActionForNextBuild: (@Sendable () -> Void)?
    /// Grace hold lifecycle counters for ownership controls.
    private var holdCounters: (begin: AtomicInteger, end: AtomicInteger)?


    final class AtomicInteger: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func makeSink(conversationManager: CloudConversationManager? = nil, withHoldCounters: Bool = false) -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let fixture = CloudRouteSinkTests.injectOperationIdentity(self.nextTurnFixture ?? self.nextFixture())
                self.nextTurnFixture = nil
                let audio = self.nextTurnAudioPayloads
                self.nextTurnAudioPayloads = []
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl, fixture: fixture, audioPayloads: audio
                )
                if let gate = self.pendingHeldGate {
                    // The held turn waits for frames; the test releases it later.
                    built.task.holdUntilReleased(gate)
                    self.heldTurn = (built.task, gate)
                    self.pendingHeldGate = nil
                }
                if let block = self.blockProducerAfterFrames {
                    self.blockProducerAfterFrames = nil
                    // SYNC park on the producer's own task (never the main queue): the control
                    // holds A's producer AFTER its audio frames are enqueued, with a bounded
                    // wait so a lost release fails promptly instead of hanging.
                    let sem = block.semaphore
                    final class Counter: @unchecked Sendable {
                        private let lock = NSLock(); private var n = 0
                        func next() -> Int { lock.lock(); n += 1; let v = n; lock.unlock(); return v }
                    }
                    let counter = Counter()
                    built.client.onFrameReceived = {
                        // Block the producer AFTER the Nth frame (frames keep flowing to the
                        // sink before that). Bounded waits: a lost release fails promptly.
                        if counter.next() >= block.count {
                            while sem.wait(timeout: .now() + 0.05) == .timedOut {}
                        }
                    }
                }
                if let action = self.firstFrameActionForNextBuild {
                    self.firstFrameActionForNextBuild = nil
                    let inner = built.client
                    built.client.onFrameReceived = { action() }
                    _ = inner
                }
                if self.cancelPlayerOnFirstFrameForNextBuild {
                    self.cancelPlayerOnFirstFrameForNextBuild = false
                    built.client.onFrameReceived = { [weak self] in
                        guard let self else { return }
                        let sink = self.hookedSink
                        Task { @MainActor in
                            guard !(self.injectedStopDone) else { return }
                            self.injectedStopDone = true
                            sink?.audioPlayerForTesting?.cancel()
                        }
                    }
                }
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            analytics: VoiceAnalytics(analytics: analytics),
            conversationManager: conversationManager ?? testConversationManager(),
            onGracePlaybackHoldBegin: withHoldCounters ? { origin in
                self.holdCounters?.begin.bump()
                return GracePeriodSignal.PlaybackHoldToken(generation: origin ?? -1)
            } : nil,
            onGracePlaybackHoldEnd: withHoldCounters ? { _ in
                self.holdCounters?.end.bump()
            } : nil
        )
    }

    private func sampleContext() -> PlaybackContext {
        PlaybackContext(
            episodeId: "ep",
            podcastId: "pod",
            referencePositionMs: 1_000,
            clientPositionMs: 1_100,
            recentReferencePositions: [],
            previousReferencePositionMs: nil
        )
    }

    /// A refused stale turn must not disturb the LIVE SUCCESSOR'S state, observed on ONE sink.
    ///
    /// The first version of this case used two sink instances and awaited the first turn to
    /// completion, so it never held a live successor and could not observe `activeTurn`
    /// cancellation at all — it passed while the defect it named was present. This one holds the
    /// successor in flight on the same sink (through the gate the harness already provides) and
    /// then dispatches the stale turn against that same sink.
    func testARefusedStaleTurnDoesNotCancelTheHeldLiveSuccessor() async {
        // The successor is held mid-turn: it has claimed activeTurn and is still running.
        // The sink's manager is held so the live origin can MOVE while the successor is in
        // flight — otherwise both turns share a live origin and the second is not stale at all,
        // which is exactly how the first version of this case proved nothing.
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        // A REAL completion fixture, so the held turn can finish and be observed finishing.
        nextTurnFixture = """
            event: token
            data: {"text":"live answer"}

            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let gate = holdNextTurn()
        let sink = makeSink(conversationManager: manager)

        let live = Task {
            await sink.routeToCloud(
                request: "live", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord
            , utteranceId: "u-78")
        }
        // Give the live turn time to reach the socket and hold there. `Task.yield()` is not
        // enough: the turn has to get through the pause hold and into the socket, which the
        // sibling barge-in case does with a 200 ms sleep.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let heldTask = heldTurn?.task
        XCTAssertNotNil(heldTask, "the live turn never reached the socket, so nothing was held")

        // The window moves on while the successor is still in flight, so the next turn's
        // captured origin is genuinely stale.
        manager.registerLiveOrigin(cloudTestOrigin + 1)

        // The SAME sink now receives a turn whose origin is no longer live, while the held
        // successor is genuinely in flight and owns `activeTurn`.
        let staleResult = await sink.routeToCloud(
            request: "stale", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp
        , utteranceId: "u-79")

        XCTAssertEqual(staleResult.outcome, .refused)

        // The discriminator: RELEASE the held turn and observe whether it can still COMPLETE.
        // Reading the sink's current `activeTurn` cannot work — the bad ordering cancels the held
        // token and REPLACES activeTurn with the stale turn's, so that read returns the
        // replacement's flag and never the successor's. The successor's own outcome is the thing
        // that distinguishes the two orderings.
        gate.release()
        let liveResult = await live.value
        XCTAssertEqual(
            liveResult.outcome, .completed,
            "a refused stale turn prevented the held successor from completing"
        )
        // The transport close-code assertion is deliberately NOT made. In the full suite the held
        // socket carries a normal close code even when the successor completes, so a non-nil code
        // does not separate "cancelled by the stale attempt" from "closed by its own completion"
        // — it passed in isolation and failed under suite load, which is the signature of an
        // assertion reading a state the case does not control. The successor's OUTCOME above is
        // the discriminator that does separate the two orderings.
    }

    /// POSITIVE CONTROL: with the mapper configured and the turn NOT superseded, the same fixture
    /// DOES seek. Without this, "no seek happened" cannot be distinguished from "the mapping was
    /// missing, so the action was refused before any seek" — which is exactly why the earlier
    /// late-action assertion could not discriminate.
    func testTheLateActionFixtureActuallySeeksWhenNotSuperseded() async throws {
        mapper.playbackSecondsForReference = [100.0: 110.0]
        self.nextTurnFixture = Self.actionThenDoneFixture
        let sink = makeSink()
        _ = await sink.routeToCloud(
            request: "solo", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        , utteranceId: "u-80")
        XCTAssertTrue(
            playback.calls.contains(.seekTo(110)),
            "the fixture must produce a real seek when the turn is not superseded, otherwise the "
            + "absence of a seek proves nothing"
        )
    }

    /// A superseded turn's LATE ACTION must be suppressed, observed on the ACTION OUTPUT.
    ///
    /// Ordering is CONTROLLED: A's output is held, the case waits on an EXPLICIT BARRIER until B
    /// has reached the transport, then releases A — so A's action arrives after A lost the turn.
    /// A's stream is fed one event per receive, so releasing A delivers its ACTION.
    func testSupersededTurnsLateActionIsSuppressedAfterSuccessorInstallsItsToken() async throws {
        defer { self.heldTurn = nil }

        // A VALID mapping, so the action would seek if it were allowed to run.
        mapper.playbackSecondsForReference = [100.0: 110.0]
        self.nextTurnFixture = Self.actionThenDoneFixture
        let gate = holdNextTurn()
        let sink = makeSink()

        let a = Task {
            await sink.routeToCloud(
                request: "A", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord
            , utteranceId: "u-81")
        }
        let maybeHeld = await waitForHeldTurn()
        let heldA = try XCTUnwrap(maybeHeld, "turn A never reached the socket")
        XCTAssertFalse(heldA.task.sentTextFrames.isEmpty, "A must have submitted its frame")

        // B replaces the active turn while A is still held.
        self.nextTurnFixture = Self.doneOnlyFixture
        let b = Task {
            await sink.routeToCloud(
                request: "B", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .followUp
            , utteranceId: "u-82")
        }
        // EXPLICIT BARRIER on B'S OWN TASK, read INSIDE the poll.
        // NOTE: `CloudRouteTestURLProtocol.requestCount` is NOT usable here — it counts
        // URLProtocol startLoading, and the route path uses URLSessionWebSocketTask, which never
        // goes through URLProtocol. An earlier version used it and the condition was never true,
        // so the "barrier" silently fell through its timeout and the ordering was really a sleep.
        //
        // `capturedTask` is replaced when a turn builds its task, and is nil until then, so it must
        // be sampled inside the poll. B's task is distinguishable from A's by identity.
        var bTask: StubWebSocketTask?
        try await waitUntil("B built and submitted its own task") {
            guard let latest = self.capturedTask, latest !== heldA.task else { return false }
            guard latest.sentAuthFrame != nil else { return false }
            bTask = latest
            return true
        }
        let bPreparedTask = try XCTUnwrap(bTask, "B must have built and submitted its own task")
        let bRequestId = try XCTUnwrap(
            bPreparedTask.sentAuthFrame?["request_id"] as? String,
            "B's prepared frame must carry a client-assigned request_id"
        )
        XCTAssertEqual(bRequestId, "u-82", "B's wire request_id IS B's admitted utterance id (delta f47e972)")
        // A and B are genuinely distinct turns, shown by their own prepared frames.
        let aRequestId = try XCTUnwrap(
            heldA.task.sentAuthFrame?["request_id"] as? String,
            "A's prepared frame must carry a client-assigned request_id"
        )
        XCTAssertEqual(aRequestId, "u-81", "A's wire request_id IS A's admitted utterance id (delta f47e972)")
        XCTAssertNotEqual(aRequestId, bRequestId, "A and B must be distinguishable by their frames")

        gate.release()
        _ = await a.value
        _ = await b.value

        XCTAssertFalse(
            playback.calls.contains(.seekTo(110)),
            "a superseded turn's late action must not execute, though the same fixture seeks when "
            + "the turn is not superseded (see the positive control)"
        )
    }

    // MARK: - Fixtures and barriers for the controlled-ordering cases

    /// An action followed by a terminal event: the action is the late output under test.
    static let actionThenDoneFixture = """
        event: action
        data: {"tool":"playback","action":"seek_to","params":{"reference_position_ms":100000}}

        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":0}}

        """

    static let doneOnlyFixture = """
        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":0}}

        """

    /// Polls the harness's held-turn state rather than sleeping a fixed interval.
    private func waitForHeldTurn(timeout: TimeInterval = 2) async -> (task: StubWebSocketTask, gate: Gate)? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let held = heldTurn { return held }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return nil
    }

    /// Polls `condition` until it holds: an EXPLICIT BARRIER, not an elapsed sleep.
    private func waitUntil(_ description: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        if condition() { return }
        struct BarrierNotReached: Error, CustomStringConvertible {
            let label: String
            var description: String { "barrier never satisfied: \(label)" }
        }
        throw BarrierNotReached(label: description)
    }

    /// POSITIVE CONTROL for the audio path: a turn carrying binary audio must actually put
    /// NONEMPTY audio in front of the player. Without this, "no audio pending" afterwards cannot
    /// be distinguished from "no audio ever arrived", which is exactly how the first version of
    /// the output assertion was vacuous.
    func testATurnCarryingBinaryAudioActuallyReachesThePlayer() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let sink = makeSink()

        _ = await sink.routeToCloud(
            request: "audio", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        , utteranceId: "u-83")

        // The player must have been given audio: the enqueue path ran, and by the end of the turn
        // the audio has drained rather than been dropped.
        let enqueued = await MainActor.run { sink.audioPlayerForTesting?.framesEnqueuedForTesting }
        let pending = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio }
        XCTAssertTrue(
            (enqueued ?? 0) > 0,
            "binary audio must be DELIVERED to the player — otherwise an output assertion proves nothing"
        )
        // SCOPE: this is DELIVERY and buffer state, not proof that speech was RENDERED. The player's
        // decode/render path is not observed here, so a case reading these two facts must not be
        // described as showing that audio was heard.
        XCTAssertEqual(pending, false, "the turn completed, so its audio buffer must be empty")
    }

    /// A refused STALE turn must leave the held live successor's AUDIO OUTPUT intact.
    ///
    /// Distinct from `testARefusedStaleTurnDoesNotCancelTheHeldLiveSuccessor`, which asserts the
    /// successor still COMPLETES. Completion is not output: a successor could finish while its
    /// audio was never delivered or was discarded.
    func testARefusedStaleTurnLeavesTheHeldSuccessorsAudioOutputIntact() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let gate = holdNextTurn()
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        let live = Task {
            await sink.routeToCloud(
                request: "live", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord
            , utteranceId: "u-84")
        }
        let maybeHeld = await waitForHeldTurn()
        _ = try XCTUnwrap(maybeHeld, "the live turn never reached the socket")

        // The window moves on, so the next turn's captured origin is genuinely stale.
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        let staleResult = await sink.routeToCloud(
            request: "stale", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp
        , utteranceId: "u-85")
        XCTAssertEqual(staleResult.outcome, .refused, "the stale turn must be refused")

        gate.release()
        let liveResult = await live.value
        XCTAssertEqual(liveResult.outcome, .completed, "the held successor must still complete")

        // THE OUTPUT ASSERTION: the successor's audio actually reached the player and drained,
        // so the stale refusal neither suppressed nor discarded the live turn's output.
        //
        // The drain is observed with a BOUNDED WAIT rather than a single read: playback drains on
        // the player's own task, so a read taken straight after completion can still see the last
        // frames and the case then failed intermittently with no code change.
        var enqueued: Int?
        var pending: Bool?
        let drainDeadline = Date().addingTimeInterval(5)
        while Date() < drainDeadline {
            enqueued = await MainActor.run { sink.audioPlayerForTesting?.framesEnqueuedForTesting }
            pending = await MainActor.run { sink.audioPlayerForTesting?.hasPendingAudio }
            if (enqueued ?? 0) > 0 && pending == false { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // SCOPE: DELIVERY, not rendering — see the note in the positive control above. What these
        // two facts establish together is that the successor's audio was still handed to the
        // player after the stale refusal, and that the buffer was not left holding it.
        XCTAssertTrue(
            (enqueued ?? 0) > 0,
            "the held successor's audio must still be DELIVERED to the player despite the stale refusal"
        )
        XCTAssertEqual(pending, false, "the successor's audio buffer must be empty, not left holding frames")
    }

    /// A small, valid binary payload: the transport treats any `.data` frame as audio.
    static let audioPayload = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

    /// The HELD-LIVE / STALE-REFUSAL ordering, deterministic by driving the REAL drain event.
    ///
    /// The completion is deliberately SPLIT: when audio is still pending at `done`, the sink returns
    /// `.completed` and defers restoration to `audioPlayerDidStop`, so the answer is not played over
    /// the resumed episode. Awaiting the route's return therefore stops BEFORE restoration, which is
    /// why an earlier attempt saw the resume appear on some runs and not others. This case drives
    /// the drain event the player actually sends, so restoration is awaited rather than raced.
    func testHeldLiveStaleRefusalOrderingIsDeterministicAndRestoresPlayback() async throws {
        self.nextTurnFixture = Self.doneOnlyFixture
        let gate = holdNextTurn()
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        // Playback RUNNING before the hold, so the live turn takes one.
        playback.setPlaying(true)
        playback.setPositionMs(60_000)

        self.nextTurnAudioPayloads = [Self.audioPayload]
        let live = Task {
            await sink.routeToCloud(
                request: "live", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .wakeWord
            , utteranceId: "u-86")
        }

        // BARRIER: the live turn acquired its hold.
        try await waitUntil("the live turn acquired its hold") {
            playback.calls.contains(.pause)
        }
        XCTAssertEqual(playback.calls.filter { $0 == .pause }.count, 1, "one hold")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 0, "nothing resumes yet")
        XCTAssertFalse(playback.isPlaying, "the hold is in effect")

        // A stale request is refused while the successor is held.
        manager.registerLiveOrigin(cloudTestOrigin + 1)
        let staleResult = await sink.routeToCloud(
            request: "stale", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp
        , utteranceId: "u-87")
        XCTAssertEqual(staleResult.outcome, .refused, "the stale turn must be refused")

        // THE REFUSED REQUEST CHANGED NEITHER THE HOLD NOR THE COUNTS.
        XCTAssertEqual(playback.calls.filter { $0 == .pause }.count, 1, "refusal must not pause")
        XCTAssertEqual(playback.calls.filter { $0 == .resume }.count, 0, "refusal must not resume")
        XCTAssertFalse(playback.isPlaying, "the refusal must not release the successor's hold")

        // Release the successor: it delivers its audio and returns .completed.
        gate.release()
        let liveResult = await live.value
        XCTAssertEqual(liveResult.outcome, .completed, "the held successor must complete")

        // THE SUCCESSOR'S AUDIO WAS DELIVERED, and because it was still pending at `done` the
        // restoration is deferred — so drive the drain event the player sends.
        let enqueued = await MainActor.run { sink.audioPlayerForTesting?.framesEnqueuedForTesting }
        XCTAssertTrue((enqueued ?? 0) > 0, "the successor's audio must reach the player")
        let currentEpoch = await MainActor.run { sink.audioPlayerForTesting?.currentDrainEpoch ?? 0 }
        await MainActor.run { sink.audioPlayerDidStop(drainEpoch: currentEpoch) }

        // ONLY NOW must restoration have happened: the live owner released its hold exactly once.
        XCTAssertEqual(
            playback.calls.filter { $0 == .pause }.count, 1,
            "exactly one pause: the live turn's, with nothing added by the refused request"
        )
        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, 1,
            "exactly one resume: the live owner's, on drain"
        )
        XCTAssertTrue(
            playback.isPlaying,
            "playback must return to its pre-hold (running) state"
        )
    }

    /// The SINGLE-OWNER deferred-restoration positive.
    ///
    /// One turn, owned end to end: its own task, its own prepared frame's request_id, its binary
    /// audio, its `done`, and its own drain. With audio still pending at `done` the sink defers
    /// restoration, and the release of the drain lets the player's REAL stop notification run —
    /// asserted on the same turn, so a mismatch between the turn that carried the audio and the
    /// turn the assertions read would fail.
    func testSingleOwnerPendingAudioDefersRestorationUntilItsOwnDrain() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        playback.setPlaying(true)
        playback.setPositionMs(60_000)

        let maybePlayer = await MainActor.run { sink.audioPlayerForTesting }
        let owningPlayer = try XCTUnwrap(maybePlayer, "the sink must own an audio player")
        await MainActor.run { owningPlayer.setDrainHoldForTesting(true) }
        defer { Task { @MainActor in owningPlayer.setDrainHoldForTesting(false) } }

        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let result = await sink.routeToCloud(
            request: "audio", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        , utteranceId: "u-88")

        // IDENTITY: the turn that ran is the turn this case built, named by its own prepared frame.
        let task = try XCTUnwrap(capturedTask, "the turn must have built its own transport task")
        let frame = try XCTUnwrap(task.sentAuthFrame, "the turn's own prepared frame must be readable")
        let requestId = try XCTUnwrap(frame["request_id"] as? String, "the frame carries a request_id")
        XCTAssertEqual(requestId, "u-88", "the wire request_id IS the turn's admitted utterance id (delta f47e972)")
        XCTAssertEqual(result.outcome, .completed, "this turn completes at `done`")

        let pending = await MainActor.run { owningPlayer.hasPendingAudio }
        XCTAssertTrue(pending, "this turn's audio is still PENDING at its `done`")

        // DEFERRAL: this turn completed, and nothing has resumed for it yet.
        XCTAssertTrue(playback.calls.contains(.pause), "this turn took its hold")
        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, 0,
            "restoration is DEFERRED while this turn's audio is pending"
        )
        XCTAssertFalse(playback.isPlaying, "the hold is still in effect before the drain")

        // RELEASE the drain. The player then drains for real and emits its OWN stop notification —
        // no manual st5d348fc7-d46c-4c64-a4be-9b24093c93d4 invocation, so the deferred callback is reached through the
        // production path rather than being called by the test.
        await MainActor.run { owningPlayer.setDrainHoldForTesting(false) }

        // The restoration is signalled by the resume landing, awaited rather than read once.
        try await waitUntil("the deferred restoration ran after the real drain") {
            playback.calls.filter { $0 == .resume }.count == 1
        }
        XCTAssertTrue(playback.isPlaying, "playback returns to its pre-hold running state")
    }

    /// A's CAPTURED, REAL stop notification must not restore once B owns the hold.
    ///
    /// Per @reviewer's interleaving, with no second pause required:
    ///   1. A completes with audio pending, so its restoration is deferred;
    ///   2. A's real drain produces its notification, which is CAPTURED rather than delivered;
    ///   3. B starts and INHERITS the outstanding hold (by design), held before its `done`;
    ///   4. the captured notification is released while B is in flight;
    ///   5. zero resumes while B still owns the hold.
    ///
    /// Clearing the shared flag prevents a DUPLICATE restoration; this asks whether the FIRST
    /// notification restores too early, which is the obligation the case names.
    func testACapturedOlderTurnNotificationDoesNotRestoreWhileTheInheritorIsInFlight() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        let maybePlayer = await MainActor.run { sink.audioPlayerForTesting }
        let player = try XCTUnwrap(maybePlayer, "the sink must own an audio player")

        // CAPTURE A's real notification instead of letting it be delivered.
        var capturedNotification: (() -> Void)?
        await MainActor.run {
            player.setCapturedStopNotificationForTesting { _, deliver in capturedNotification = deliver }
        }
        defer { Task { @MainActor in player.setCapturedStopNotificationForTesting(nil) } }

        // (1) TURN A: completes with audio pending -> deferred.
        playback.setPlaying(true)
        playback.setPositionMs(60_000)
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let a = await sink.routeToCloud(
            request: "A", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        , utteranceId: "u-89")
        XCTAssertEqual(a.outcome, .completed, "turn A returns")
        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, 0,
            "turn A defers: its drain has not produced a notification yet"
        )

        // (2) A's REAL drain produces its notification, captured.
        await MainActor.run { player.setDrainHoldForTesting(false) }
        try await waitUntil("turn A's real drain produced its stop notification") {
            capturedNotification != nil
        }
        let deliverAsNotification = try XCTUnwrap(capturedNotification, "A's notification must exist")

        // (3) TURN B: starts and INHERITS the hold, held before its `done`.
        let gate = holdNextTurn()
        self.nextTurnFixture = Self.doneOnlyFixture
        let b = Task {
            await sink.routeToCloud(
                request: "B", tier: .free, context: sampleContext(),
                origin: cloudTestOrigin, selection: .followUp
            , utteranceId: "u-90")
        }
        let maybeHeldB = await waitForHeldTurn()
        let heldB = try XCTUnwrap(maybeHeldB, "turn B must be in flight and holding")
        // B's distinct identity, from ITS OWN prepared frame.
        let bFrame = try XCTUnwrap(heldB.task.sentAuthFrame, "B's prepared frame must be readable")
        let bRequestId = try XCTUnwrap(bFrame["request_id"] as? String, "B carries a request_id")
        XCTAssertEqual(bRequestId, "u-90", "B's wire request_id IS B's admitted utterance id (delta f47e972)")

        let resumesBeforeNotification = playback.calls.filter { $0 == .resume }.count
        XCTAssertFalse(playback.isPlaying, "the inherited hold is in effect while B is in flight")

        // (4) Release A's captured notification WHILE B is in flight and owning.
        await MainActor.run { deliverAsNotification() }

        // (5) Zero resumes for a notification that is not B's.
        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, resumesBeforeNotification,
            "A's captured notification must not restore while its INHERITOR is still in flight"
        )
        XCTAssertFalse(
            playback.isPlaying,
            "the inheriting turn's hold must survive an older turn's notification"
        )

        gate.release()
        _ = await b.value
    }

    /// @reviewer's conjunct case: B has ITSELF deferred, then A's OLD notification arrives.
    ///
    /// At `7e8e7fde8` this passed the owner check, because both `activeTurn` and the deferred record
    /// contained B — so A's notification restored and CLEARED B's deferred record. Identity of the
    /// arriving stop is what distinguishes them, so the notification carries the identity captured
    /// when it was scheduled.
    func testAnOldNotificationDoesNotClearTheDeferringSuccessorsRecord() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        let maybePlayer = await MainActor.run { sink.audioPlayerForTesting }
        let player = try XCTUnwrap(maybePlayer, "the sink must own an audio player")

        var capturedNotifications: [() -> Void] = []
        await MainActor.run {
            player.setCapturedStopNotificationForTesting { _, deliver in capturedNotifications.append(deliver) }
        }
        defer { Task { @MainActor in player.setCapturedStopNotificationForTesting(nil) } }

        // A DEFERS.
        playback.setPlaying(true)
        playback.setPositionMs(60_000)
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let a = await sink.routeToCloud(
            request: "A", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord
        , utteranceId: "u-91")
        XCTAssertEqual(a.outcome, .completed, "turn A returns")
        await MainActor.run { player.setDrainHoldForTesting(false) }
        try await waitUntil("A produced its stop notification") { !capturedNotifications.isEmpty }
        let aNotification = capturedNotifications[0]

        // B ALSO DEFERS, so `activeTurn` and the deferred record both name B.
        await MainActor.run { player.setDrainHoldForTesting(true) }
        playback.setPlaying(true)
        self.nextTurnFixture = Self.doneOnlyFixture
        self.nextTurnAudioPayloads = [Self.audioPayload]
        let b = await sink.routeToCloud(
            request: "B", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp
        , utteranceId: "u-92")
        XCTAssertEqual(b.outcome, .completed, "turn B returns")
        let resumesBeforeA = playback.calls.filter { $0 == .resume }.count

        // A's OLD notification arrives while B is the deferred owner.
        await MainActor.run { aNotification() }

        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, resumesBeforeA,
            "A's old notification must not restore: B is the deferring owner"
        )

        // B's OWN drain must still be able to restore — the old notification must leave B's record
        // intact rather than clearing it.
        await MainActor.run { player.setDrainHoldForTesting(false) }
        try await waitUntil("B's own drain produced its notification") { capturedNotifications.count >= 2 }
        let bNotification = capturedNotifications[1]
        await MainActor.run { bNotification() }

        XCTAssertEqual(
            playback.calls.filter { $0 == .resume }.count, resumesBeforeA + 1,
            "B's own notification must still restore, so A's arrival did not clear B's record"
        )
    }

    /// SEQUENTIAL OWNERSHIP (NOT overlap): two dispatches in turn on ONE sink, each carrying its OWN
    /// observer, must each capture their own prepared identity.
    ///
    /// SCOPE, measured rather than assumed: this case does NOT demonstrate that OVERLAPPING
    /// dispatches are isolated. It was falsified against a shared-slot mutation and SURVIVED, because
    /// the two turns run sequentially — a shared slot agrees with the correct value when nothing
    /// overlaps. Demonstrating overlap would need a second dispatch to publish between A's
    /// preparation and A's observation; the socket gate parks downstream of preparation, so this
    /// arrangement cannot create that window. Do not cite this case as overlap isolation.
    @MainActor
    func testSequentialDispatchesEachCaptureTheirOwnPreparedIdentity() async throws {
        let manager = CloudConversationManager()
        manager.registerLiveOrigin(cloudTestOrigin)
        let sink = makeSink(conversationManager: manager)

        var preparedA: CloudPreparedConversation?
        var preparedB: CloudPreparedConversation?

        // Each dispatch needs its own fixture: the handoff is consumed per built turn.
        self.nextTurnFixture = Self.doneOnlyFixture
        // A: a wake-word turn under the live generation.
        let a = await sink.routeToCloud(
            request: "A", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .wakeWord,
            utteranceId: "u-93",
            preparedObserver: { prepared in preparedA = prepared })
        XCTAssertEqual(a.outcome, .completed, "turn A completes")

        // B: a second dispatch on the SAME sink, with its OWN observer.
        self.nextTurnFixture = Self.doneOnlyFixture
        let b = await sink.routeToCloud(
            request: "B", tier: .free, context: sampleContext(),
            origin: cloudTestOrigin, selection: .followUp,
            utteranceId: "u-94",
            preparedObserver: { prepared in preparedB = prepared })
        XCTAssertEqual(b.outcome, .completed, "turn B completes")

        // The two observations DIFFER, which proves they are distinct observations. It does NOT
        // prove attribution — that each observer received ITS OWN turn's value — and it does not
        // rule out a shared slot read per dispatch. This sequential arrangement does not test overlap.
        let aValue = try XCTUnwrap(preparedA, "A's observer must have captured A's prepared identity")
        let bValue = try XCTUnwrap(preparedB, "B's observer must have captured B's prepared identity")
        XCTAssertNotEqual(
            aValue.requestId, bValue.requestId,
            "each dispatch must capture its OWN prepared identity; equal values mean a shared slot"
        )
    }
}

/// The client-generated-diagnostic convention (PR #19 review): a code with an
/// empty message maps to a localized template when one exists, and to the error
/// earcon when it doesn't — both branches exercised, so neither is inert.
final class CloudRouteSinkErrorLocalizationTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        suiteName = "cloud_error_loc_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTemplatedCodeIsSpoken() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"connection_lost","message":""}

            """
        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-95")

        XCTAssertEqual(response.response, .spoken("Connection lost. Please try again."), "a code with a template is spoken")
    }

    func testCodeWithoutATemplateUsesTheErrorEarcon() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"invalid_response","message":""}

            """
        let response = await makeSink().routeToCloud(request: "x", tier: .free, context: sampleContext(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-96")

        XCTAssertEqual(response.response, .earcon(.error), "an internal diagnostic stays an earcon, never English prose")
    }

    private func makeSink() -> CloudRouteSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let session = URLSession(configuration: config)
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: self.nextFixture())
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: RecordingFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            conversationManager: testConversationManager()
        )
    }

    private func sampleContext() -> PlaybackContext {
        PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000, clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil)
    }
}

/// Spec ruling (2026-09-24): a client-authored message is spoken **only** in the
/// user's own locale; an untranslated key falls back to the error earcon rather
/// than to base-language English.
final class CloudRouteSinkLocaleRuleTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        suiteName = "cloud_locale_rule_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSink(localeBundle: Bundle?) -> CloudRouteSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: self.nextFixture())
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: RecordingFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            spokenTemplates: SpokenTemplateResolver(localeBundle: localeBundle),
            conversationManager: testConversationManager()
        )
    }

    private func stubError(code: String) {
        self.pendingFixture =
            """
            event: error
            data: {"code":"\(code)","message":""}

            """
    }

    private func context() -> PlaybackContext {
        PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000, clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil)
    }

    func testUntranslatedKeyFallsBackToTheEarconRatherThanBaseLanguageSpeech() async {
        // A **real** localization that exists but carries no VoiceTemplates table
        // (ca.lproj ships InfoPlist/Intents/Localizable but no VoiceTemplates) —
        // the production shape, rather than an empty directory (PR #19 review).
        let caPath = Bundle.main.path(forResource: "ca", ofType: "lproj")
        let empty = caPath.flatMap { Bundle(path: $0) } ?? Bundle(path: NSTemporaryDirectory()) ?? Bundle(for: type(of: self))
        stubError(code: "connection_lost")
        let response = await makeSink(localeBundle: empty).routeToCloud(request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-97")
        XCTAssertEqual(response.response, .earcon(.error), "no translation in the user's locale ⇒ earcon, never English speech")
    }

    /// The default resolver discovers the user's own locale: in this test host that
    /// is English, whose bundle carries the key, so the message is spoken.
    func testDefaultResolverUsesTheUsersOwnLocale() {
        let resolver = SpokenTemplateResolver()
        XCTAssertEqual(
            resolver.resolveForUserLocale("cloud_error_connection_lost"),
            "Connection lost. Please try again."
        )
    }

    func testTranslatedKeyInTheUserLocaleIsSpoken() async {
        stubError(code: "connection_lost")
        // The test host's own bundle carries the en.lproj translation.
        let enBundle = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "") ?? Bundle.main
        let response = await makeSink(localeBundle: enBundle).routeToCloud(request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil, utteranceId: "u-98")
        XCTAssertEqual(response.response, .spoken("Connection lost. Please try again."))
    }
}

/// Spec clarification 27ced9b: a `limit_exceeded` turn must reach the user as the CLIENT's own
/// localized daily-limit template, exactly once, naming Auris and its daily allowance — and the
/// remote frame's `message` is DIAGNOSTIC-ONLY for this code, so it must not replace that
/// explanation.
final class CloudRouteSinkLimitExceededFeedbackTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        suiteName = "cloud_limit_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSink() -> CloudRouteSink {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let cloudConfig = CloudConfig(defaults: defaults)
        // The test host's own bundle carries en.lproj/VoiceTemplates.strings.
        let enBundle = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "") ?? Bundle.main
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: self.nextFixture())
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: RecordingFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            spokenTemplates: SpokenTemplateResolver(localeBundle: enBundle),
            conversationManager: testConversationManager()
        )
    }

    private func context() -> PlaybackContext {
        PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000, clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil)
    }

    /// The refusal frame the server actually sends carries a GENERIC message ("this turn was not
    /// admitted"). The user must still hear WHICH limit was hit, exactly once.
    func testLimitExceededSpeaksTheClientTemplateNotTheGenericRemoteMessage() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"limit_exceeded","message":"this turn was not admitted"}

            """
        let response = await makeSink().routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil
        , utteranceId: "u-99")
        XCTAssertEqual(
            response.response,
            .spoken("You have reached your Auris free daily limit. Please try again tomorrow."),
            "limit_exceeded must speak the client's own template naming Auris and the daily limit"
        )
        // EXACTLY ONCE, not merely "contains": the response is a single .spoken value, and it is
        // not the generic remote text.
        guard case let .spoken(text) = response.response else {
            XCTFail("expected a single .spoken response, got \(response.response)")
            return
        }
        XCTAssertNotEqual(text, "this turn was not admitted", "the remote diagnostic must not be spoken")
        XCTAssertEqual(text.components(separatedBy: "Auris").count - 1, 1, "Auris is named exactly once")
    }

    /// THE REMOTE MESSAGE IS NEVER SPOKEN (spec 961fab07) — and not only for `limit_exceeded`.
    /// A non-limit code whose frame carries a nonempty `message` must NOT speak that text: the
    /// old pass-through behaviour is superseded by the diagnostic-only contract.
    func testNonLimitRemoteMessageIsNotSpoken() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"provider_error","message":"upstream 502 from model-vendor-a"}

            """
        let response = await makeSink().routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil
        , utteranceId: "u-100")
        // `provider_error` is Generic with no local template ⇒ the error earcon. What must NOT
        // happen is the operator diagnostic reaching the speaker.
        XCTAssertEqual(
            response.response, .earcon(.error),
            "a remote operator diagnostic must never be spoken"
        )
        if case let .spoken(text) = response.response {
            XCTAssertFalse(
                text.contains("model-vendor-a"),
                "the remote message leaked into speech: \(text)"
            )
        }
    }

    /// An UNKNOWN code (not in the vocabulary) follows the same local feedback policy: never the
    /// remote text.
    func testUnknownRemoteCodeNeverSpeaksTheRemoteMessage() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"some_unmapped_code","message":"secret operator detail 42"}

            """
        let response = await makeSink().routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil
        , utteranceId: "u-101")
        XCTAssertEqual(response.response, .earcon(.error), "an unknown code gets local feedback, not remote text")
        if case let .spoken(text) = response.response {
            XCTAssertFalse(text.contains("42"), "the remote message leaked into speech: \(text)")
        }
        XCTAssertEqual(response.outcome, .failed(code: "some_unmapped_code"))
    }

    /// A client-authored code reaches the user as a failed turn, never a completion (the
    /// pre-existing regression guard, re-asserted for this code).
    func testLimitExceededIsAFailedTurnNotACompletion() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"limit_exceeded","message":""}

            """
        let response = await makeSink().routeToCloud(
            request: "x", tier: .free, context: context(), origin: cloudTestOrigin, selection: nil
        , utteranceId: "u-102")
        XCTAssertEqual(response.outcome, .failed(code: "limit_exceeded"))
    }

    /// SERVICE-TO-RENDERER, DUPLICATE AND TERMINAL-CLOSE (spec a8580c0c). An executor return
    /// value from an always-owner mock does not establish exactly-once USER FEEDBACK, so this
    /// runs the whole path against the REAL sink and the REAL AudioFeedbackRenderer: an owner
    /// refusal turn, a DUPLICATE of the same utterance, and a terminal-close variant. The user must
    /// hear the daily-limit line EXACTLY ONCE, and a refused turn must not extend grace.
    @MainActor
    /// E2E REQUEST-ID PROPAGATION (reviewer d16c0246): the utterance-admitted identity must
    /// reach the wire VERBATIM. ASR mints the id at admission, the sink prepares the conversation
    /// with it, and the socket auth frame presents THAT literal string — no hop downstream may
    /// mint a fresh one. A duplicate dispatch of the SAME utterance observes the settled outcome
    /// and never opens a second wire dispatch under a second identity.
    func test_admittedUtteranceIdReachesTheWireVerbatimAndDuplicateNeverMintsAnother() async throws {
        self.pendingFixture = """
            event: done
            data: {"usage":{"input_tokens":1,"output_tokens":0}}

            """
        let context = PlaybackContext(
            episodeId: "ep", podcastId: "pod",
            referencePositionMs: 1_000, clientPositionMs: 1_100,
            recentReferencePositions: [], previousReferencePositionMs: nil
        )
        let sink = makeSink()
        let owner = await sink.routeToCloud(
            request: "play the news", tier: .free, context: context,
            origin: cloudTestOrigin, selection: nil, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"
        )
        let ownerFrame = try XCTUnwrap(capturedTask?.sentAuthFrame)
        XCTAssertEqual(
            ownerFrame["request_id"] as? String, "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88",
            "the wire request_id is the ADMITTED utterance UUID, not a freshly minted one"
        )

        // Duplicate of the SAME utterance: the settled result, no new dispatch, no second id.
        capturedTask = nil
        let duplicate = await sink.routeToCloud(
            request: "play the news", tier: .free, context: context,
            origin: cloudTestOrigin, selection: nil, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"
        )
        XCTAssertEqual(duplicate, owner, "the duplicate observes the owner's settled outcome")
        XCTAssertNil(
            capturedTask?.sentAuthFrame,
            "a settled duplicate must not open a second wire dispatch"
        )
    }

    func test_dailyLimitFeedbackRendersExactlyOnceAcrossDuplicateAndTerminalClose() async throws {
        let grace = GracePeriodSignal()
        grace.onWakeWordDetected()
        let generation = grace.currentGeneration()
        XCTAssertTrue(grace.claimRefusalTone(), "a refusal was announced (window spent)")

        self.pendingFixture =
            """
            event: error
            data: {"code":"limit_exceeded","message":"this turn was not admitted"}

            """
        let sink = makeSink()
        let executor = VoiceIntentExecutor(
            playbackSink: NoOpCloudPlaybackSink(),
            effectsSink: NoOpCloudEffectsSink(),
            volumeSink: NoOpCloudVolumeSink(),
            sleepSink: NoOpCloudSleepSink(),
            chapterSink: NoOpCloudChapterSink(),
            bookmarkSink: NoOpCloudBookmarkSink(),
            queueSink: NoOpCloudQueueSink(),
            playbackQuerySink: NoOpCloudPlaybackQuerySink(),
            statsQuerySink: NoOpCloudStatsQuerySink(),
            cloudRouteSink: sink,
            playbackContextProvider: NoOpCloudPlaybackContextProvider(),
            gracePeriodSignal: grace
        )
        let tts = CountingDailyLimitTtsEngine()
        let renderer = AudioFeedbackRenderer(
            earconPlayer: SilentCloudEarconPlayer(), ttsEngine: tts, ducker: NoOpCloudDucker()
        )

        let utterance = "limit-utterance-\(UUID().uuidString)"
        // OWNER turn: renders the daily-limit line.
        let owner = await executor.execute(CloudRouteIntent(
            request: "play something", tier: .free,
            utteranceId: utterance, origin: .modelCall, generation: generation
        ))
        renderer.render(owner)
        XCTAssertEqual(
            owner,
            .spoken("You have reached your Auris free daily limit. Please try again tomorrow.")
        )
        // DUPLICATE of the SAME utterance: the sink settles it and the executor renders nothing.
        let duplicate = await executor.execute(CloudRouteIntent(
            request: "play something", tier: .free,
            utteranceId: utterance, origin: .modelCall, generation: generation
        ))
        renderer.render(duplicate)
        // TERMINAL CLOSE on a FRESH utterance (stream ends without a terminal frame).
        self.pendingFixture = ""
        let closeResponse = await executor.execute(CloudRouteIntent(
            request: "play something", tier: .free,
            utteranceId: "limit-close-\(UUID().uuidString)", origin: .modelCall, generation: generation
        ))
        renderer.render(closeResponse)

        // Let any late render land, then assert the TOTAL is exactly one.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            tts.dailyLimitUtterances, 1,
            "the daily-limit line must be rendered EXACTLY ONCE across owner, duplicate and close"
        )
        XCTAssertFalse(
            grace.windowIsRenewedForTesting(),
            "a refused turn must not extend the grace window"
        )
    }

    /// EVERY SUPPORTED RESPONSE LANGUAGE CARRIES THE DAILY-LIMIT KEY (spec c259dc64). The scope is
    /// exactly en/de/es/fr/ja/ko/zh/yue: an English entry alone does not satisfy localized
    /// daily-limit feedback, and a Chinese turn must not be answered by an English earcon. This
    /// uses the REAL resolver's own locale discovery (`SpokenTemplateResolver(locale:)`), not a
    /// forced en bundle.
    func test_dailyLimitKeyResolvesInEverySupportedResponseLanguage() {
        // Every locale name the resolver can be handed. "zh" is covered by zh-Hans/zh-Hant.
        let cases: [(locale: String, bundleName: String)] = [
            ("en", "en"), ("de", "de"), ("es", "es"), ("fr", "fr"),
            ("ja", "ja"), ("ko", "ko"), ("zh-Hans", "zh-Hans"), ("zh-Hant", "zh-Hant"),
            ("yue", "yue"),
        ]
        for c in cases {
            guard let bundle = Bundle.main.path(forResource: c.bundleName, ofType: "lproj").flatMap({ Bundle(path: $0) }) else {
                XCTFail("\(c.bundleName).lproj is missing from the app bundle")
                continue
            }
            let resolver = SpokenTemplateResolver(localeBundle: bundle)
            let text = resolver.resolveForUserLocale("cloud_error_limit_exceeded")
            XCTAssertFalse(
                text.isEmpty,
                "\(c.locale) has no daily-limit template: a non-English user would hear only an earcon"
            )
            XCTAssertTrue(
                text.contains("Auris"),
                "\(c.locale) daily-limit text must name Auris (got: \(text))"
            )
        }
    }

    /// The RESOLVER FINDS each of those languages from the user's own locale — the production
    /// discovery path, not an injected bundle.
    func test_dailyLimitKeyResolvesInRegionalLocaleVariantsSelectedByRealDiscovery() {
        // Reviewer cffd67d1: the app ships fr-CA.lproj and es-MX.lproj, and REAL locale
        // discovery hands the resolver those regional bundles for fr_CA/es_MX users — a
        // base-identifier-only list misses them and returns empty. Both regional variants
        // must carry the key AND discovery must select them from the user's own locale.
        for localeID in ["fr_CA", "es_MX"] {
            // lproj directories are named with a HYPHEN ("fr-CA.lproj"), so the resource
            // lookup uses the hyphenated form even for an underscore Locale identifier.
            let dirName = localeID.replacingOccurrences(of: "_", with: "-")
            guard let path = Bundle.main.path(forResource: dirName, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                XCTFail("\(dirName).lproj is missing from the app bundle")
                continue
            }
            let resolver = SpokenTemplateResolver(locale: Locale(identifier: localeID))
            let text = resolver.resolveForUserLocale("cloud_error_limit_exceeded")
            XCTAssertFalse(
                text.isEmpty,
                "\(localeID) discovers a bundle without the daily-limit template: a regional user would hear only an earcon"
            )
            XCTAssertTrue(
                text.contains("Auris"),
                "\(localeID) daily-limit text must name Auris (got: \(text))"
            )
        }
    }

    func test_dailyLimitKeyIsFoundByRealLocaleDiscovery() {
        for identifier in ["en", "de", "es", "fr", "ja", "ko", "zh-Hans", "yue"] {
            let resolver = SpokenTemplateResolver(locale: Locale(identifier: identifier))
            let text = resolver.resolveForUserLocale("cloud_error_limit_exceeded")
            XCTAssertFalse(
                text.isEmpty,
                "the resolver did not discover a daily-limit template for \(identifier)"
            )
            XCTAssertTrue(text.contains("Auris"), "\(identifier) text must name Auris: \(text)")
        }
    }

    /// The template ships with the app, so it resolves through the SAME code-keyed route every
    /// other client failure uses (no special-case lookup that could go missing).
    func testLimitExceededTemplateResolvesThroughTheCodeKeyedRoute() {
        let enBundle = Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj") ?? "") ?? Bundle.main
        let resolver = SpokenTemplateResolver(localeBundle: enBundle)
        XCTAssertEqual(
            resolver.resolveForUserLocale("cloud_error_limit_exceeded"),
            "You have reached your Auris free daily limit. Please try again tomorrow."
        )
    }
}

/// A whitespace-only server message is treated as absent (PR #19 review): it must
/// not be spoken as silence, and it follows the same localized-template/earcon
/// route as a missing message.
final class CloudRouteSinkWhitespaceMessageTests: SocketCapturingTestCase {
    private var playback: RecordingPlaybackSink!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        playback = RecordingPlaybackSink()
        suiteName = "cloud_ws_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testWhitespaceOnlyServerMessageIsNotSpokenAsSilence() async {
        self.pendingFixture =
            """
            event: error
            data: {"code":"invalid_response","message":"   "}

            """
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let cloudConfig = CloudConfig(defaults: defaults)
        let sink = CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(baseURL: cloudConfig.baseUrl, fixture: self.nextFixture())
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: RecordingFingerprintMapper(),
            playbackPositionMs: { 0 },
            cloudPlaybackContextState: CloudPlaybackContextState(),
            conversationManager: testConversationManager()
        )
        let context = PlaybackContext(episodeId: "ep", podcastId: "pod", referencePositionMs: 1_000, clientPositionMs: 1_100, recentReferencePositions: [], previousReferencePositionMs: nil)

        let response = await sink.routeToCloud(request: "x", tier: .free, context: context, origin: cloudTestOrigin, selection: nil, utteranceId: "u-103")

        XCTAssertEqual(response.response, .earcon(.error), "a spaces-only message follows the code route, never spoken as silence")
    }
}

/// The locale rule must not fall back to the app's default bundle: an unsupported
/// non-English locale hears the earcon, not English (PR #19 review).
final class SpokenTemplateLocaleFallbackTests: XCTestCase {
    func testUnsupportedNonEnglishLocaleDoesNotFallBackToEnglish() {
        // The app ships en.lproj; a locale with no matching bundle must not get it.
        let resolver = SpokenTemplateResolver(locale: Locale(identifier: "xx-XX"))
        XCTAssertEqual(resolver.resolveForUserLocale("cloud_error_connection_lost"), "",
                       "no bundle for the user's language ⇒ nothing to speak ⇒ the caller uses the earcon")
    }

    func testSupportedLocaleStillResolves() {
        let resolver = SpokenTemplateResolver(locale: Locale(identifier: "en-US"))
        XCTAssertEqual(resolver.resolveForUserLocale("cloud_error_connection_lost"), "Connection lost. Please try again.")
    }

    /// Asserts the **discovered bundle**, not a translation: `zh-Hans.lproj` ships
    /// no VoiceTemplates table, so a behavioural assertion would pass whether or
    /// not the hyphenated candidate matched anything (PR #19 review).
    func testHyphenatedLocaleSelectsItsOwnBundle() {
        let resolver = SpokenTemplateResolver(locale: Locale(identifier: "zh-Hans-CN"))
        XCTAssertEqual(resolver.resolvedLocalization, "zh-Hans", "the language-script candidate must match the shipped zh-Hans bundle")
    }

    func testExactHyphenatedTagMatchesItsOwnBundle() {
        // pt-BR ships its own `.lproj`, so this exercises the full-tag candidate
        // without depending on any script inference (reviewer's point: a zh-CN
        // assertion would rest on Foundation inferring `Hans`).
        let resolver = SpokenTemplateResolver(locale: Locale(identifier: "pt-BR"))
        XCTAssertEqual(resolver.resolvedLocalization, "pt-BR", "a shipped hyphenated tag matches exactly")
    }

    func testLanguageSubtagCandidateMatchesAShippedBundle() {
        // fr-FR: no fr-FR.lproj, and no script to infer — only the bare-language
        // candidate can match, and fr.lproj ships. This exercises that candidate
        // without resting on Foundation's script inference (PR #19 review).
        let resolver = SpokenTemplateResolver(locale: Locale(identifier: "fr-FR"))
        XCTAssertEqual(resolver.resolvedLocalization, "fr", "the bare-language candidate finds the shipped fr bundle")
}
}

/// A minimal delegate: `notifyDidStop` returns early when `delegate` is nil, so a directly
/// constructed player emits nothing without one.
private final class RecordingAudioPlayerDelegate: CloudAudioPlayer.Delegate {
    func audioPlayerDidStartPlaying() {}
    func audioPlayerDidPause() {}
    func audioPlayerDidStop(drainEpoch: Int) {}
}

/// The IDENTITY-PLACEMENT control, driven against the REAL `CloudAudioPlayer` directly.
final class CloudAudioPlayerClaimIdentityTests: XCTestCase {

    /// Prerequisites asserted, then the two snapshot placements separated.
    ///
    /// ORDERING CONSTRAINT: the runner releases `runnerLock` BEFORE signalling arrival or waiting on
    /// release, so no lock spans the barrier. Both waits are BOUNDED and cleanup signals the
    /// semaphores BEFORE clearing the references, so a setup error fails in seconds rather than
    /// consuming the runner.
    @MainActor
    func testAClaimedDrainKeepsItsAllocatedIdentityWhenASuccessorSchedulesInsideTheWindow() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        var emittedIdentities: [Int] = []
        player.setCapturedStopNotificationForTesting { identity, completion in
            emittedIdentities.append(identity)
            completion() // the REAL notification continuation: records the physical confirmation
        }

        // PREREQUISITE: nonempty audio is enqueued and pending.
        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertEqual(player.framesEnqueuedForTesting, 1, "a frame must be enqueued")
        XCTAssertTrue(player.hasPendingAudio, "the frame must still be pending")

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        // CLEANUP SIGNALS BEFORE CLEARING: nil cannot release a runner already waiting.
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        // PREREQUISITE: finish allocates an identity and schedules the drain.
        let aAllocated = player.finish()
        XCTAssertGreaterThan(aAllocated, 0, "finish must allocate an identity")

        // BOUNDED arrival wait: a setup error must fail fast.
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime, "the runner must reach the claim within the bound")

        // INSIDE THE WINDOW: B schedules; its allocated identity must differ.
        let bAllocated = player.finish()
        XCTAssertNotEqual(bAllocated, aAllocated, "B's identity must differ from A's")

        release.signal()

        try await waitUntilCondition(timeout: 5) { !emittedIdentities.isEmpty }

        // THE RELEASE IS ASSERTED, not merely bounded: a bound only prevents an infinite block.
        XCTAssertEqual(
            player.claimReleaseOutcome, .released,
            "the runner's bounded wait must end RELEASED, not timed out"
        )

        // THE ASSERTION, on the EMITTED identity: A's notification carries A's allocated identity.
        XCTAssertEqual(
            emittedIdentities, [aAllocated],
            "emitted=\(emittedIdentities) aAllocated=\(aAllocated) bAllocated=\(bAllocated)"
        )
        assertNoStrandedStopNotifications(player, "parked A + successor B finish")
    }


    /// REVIEWER-SPECIFIED CONTROL (dc70303d): parked-A → mid-drain CANCEL. The cancel arrives
    /// while A's drain holds the claim window. The physical stop IS the cancel's stop, so the
    /// cancel's own identity must be emitted exactly once, A's claimant identity must NOT be
    /// relabelled onto it, and A's unperformed identity must never be promoted by a later stop.
    @MainActor
    func testAMidDrainCancelEmitsTheCancelIdentityExactlyOnceAndNeverRelabelsA() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        var emittedIdentities: [Int] = []
        player.setCapturedStopNotificationForTesting { identity, _ in
            emittedIdentities.append(identity)
        }

        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio, "a frame must be pending for the drain to be scheduled")

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        // A schedules its drain and reaches the claim.
        let aAllocated = player.finish()
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime, "the runner must reach A's claim within the bound")

        // CANCEL INSIDE THE WINDOW: the cancel's identity supersedes A's queued drain.
        let cRequested = player.cancel()
        XCTAssertNotEqual(cRequested, aAllocated, "the cancel must allocate its own identity")

        release.signal()

        try await waitUntilCondition(timeout: 5) { !emittedIdentities.isEmpty }

        XCTAssertEqual(
            player.claimReleaseOutcome, .released,
            "the runner's bounded wait must end RELEASED, not timed out"
        )
        // EXACTLY the cancel's identity, exactly once — not A's, not both.
        XCTAssertEqual(
            emittedIdentities, [cRequested],
            "emitted=\(emittedIdentities) aAllocated=\(aAllocated) cRequested=\(cRequested): the physical stop belongs to the cancel"
        )
        assertNoStrandedStopNotifications(player, "mid-drain cancel")
    }

    /// REVIEWER-SPECIFIED CONTROL (dc70303d): combined B.finish + cancel. A successor's
    /// independently queued finish must NOT be recorded as stopped merely because the
    /// cancel's stop is newer: its own notification identity stays distinct and no
    /// second stop fires for it.
    @MainActor
    func testCombinedSuccessorFinishAndCancelKeepDistinctIdentitiesWithoutASecondStop() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        var emittedIdentities: [Int] = []
        player.setCapturedStopNotificationForTesting { identity, _ in
            emittedIdentities.append(identity)
        }

        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio, "a frame must be pending for the drain to be scheduled")

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        let aAllocated = player.finish()
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime, "the runner must reach A's claim within the bound")

        // BOTH, inside the window: B queues a finish, then a cancel supersedes the queue.
        let bAllocated = player.finish()
        let cRequested = player.cancel()
        XCTAssertNotEqual(bAllocated, aAllocated)
        XCTAssertNotEqual(cRequested, bAllocated)

        release.signal()

        try await waitUntilCondition(timeout: 5) { !emittedIdentities.isEmpty }

        XCTAssertEqual(player.claimReleaseOutcome, .released)
        // ONE physical stop: the cancel's identity. B's queued finish was SUPERSEDED — it must
        // neither steal the emitted identity nor fire a second notification of its own.
        XCTAssertEqual(
            emittedIdentities, [cRequested],
            "emitted=\(emittedIdentities) a=\(aAllocated) b=\(bAllocated) c=\(cRequested): exactly one stop, the cancel's"
        )
        assertNoStrandedStopNotifications(player, "combined B finish + cancel")
    }

    /// REVIEWER 47f67d4d: coalesced accounting must include in-flight claim work — the
    /// pending-stf6241f37-b493-47f2-aaf4-6dcdf6120103 counter must return to ZERO after every parked scenario,
    /// or a stranded increment refuses every future admission.
    private func assertNoStrandedStopNotifications(_ player: CloudAudioPlayer, _ label: String) {
        XCTAssertEqual(
            player.pendingStopNotificationsForTesting, 0,
            "\(label): pending stop notifications must settle to zero"
        )
    }

    /// REVIEWER 47f67d4d: a cancelled drain's displaced owner must appear in the EXPLICIT
    /// settlement record — and an identity NOT in that record must not be implicitly settled
    /// by it. A waiter on a lower, never-performed identity stays stranded (returning false
    /// on its bound), proving the exact-set settlement does not promote bystanders.
    @MainActor
    func testMidDrainCancelSettlesTheDisplacedOwnerExplicitlyAndNeverABystanderLowerIdentity() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio)

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        // THE BYSTANDER: an identity ABOVE the cancel's (it will allocate cancel+1 implicitly? no —
        // identities allocate only on request), so use the identity the cancel WILL take: register
        // the bystander waiter on `aAllocated + 1` AFTER the cancel (so the value is known), while
        // the runner is still parked mid-stop? The stop fires on release. Simpler: take the bystander
        // as an identity allocated but never satisfied — cancel() BEFORE the bystander registration
        // is released? We register the bystander waiter AFTER the cancel request and BEFORE the
        // release: the bystander's epoch = cancelEpoch (performed ⇒ settles true, useless) — so use
        // bystander = aAllocated - 1 relative to a RAISED floor: perform one full turn first.
        let firstAllocated = player.finish()
        let settledFirst = await player.awaitActualStop(after: firstAllocated, timeout: 5)
        XCTAssertTrue(settledFirst, "setup: the first turn must fully stop to raise the floor to \(firstAllocated)")
        // Now floor == firstAllocated. The bystander must be ABOVE the floor (else it answers
        // immediately) and NEVER requested. Identities allocate sequentially on request, so the
        // next request takes firstAllocated+1. The bystander takes the identity AFTER the cancel's:
        // request A (takes +1), cancel (+2, performed), bystander (+3, never performed, above floor 2).
        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio, "setup: a frame must be pending for A's drain")
        let aAllocated = player.finish()
        XCTAssertNotEqual(aAllocated, firstAllocated)
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime)

        let cancelEpoch = player.cancel() // supersedes A's in-flight claim
        let bystanderEpoch = cancelEpoch + 1 // never requested; floor is firstAllocated < it
        XCTAssertGreaterThan(bystanderEpoch, firstAllocated, "bystander must sit above the confirmed floor")
        var bystanderSettled = false
        async let bystander: Bool = player.awaitActualStop(after: bystanderEpoch, timeout: 1)
        try await Task.sleep(nanoseconds: 100_000_000) // let it register
        release.signal()

        // A's waiter settles EXPLICITLY via the displaced record.
        let aSettled = await player.awaitActualStop(after: aAllocated, timeout: 5)
        XCTAssertTrue(aSettled, "the displaced owner's waiter settles via the explicit record")

        bystanderSettled = await bystander
        XCTAssertFalse(
            bystanderSettled,
            "a lower identity outside the displaced record must NOT be implicitly promoted"
        )
        assertNoStrandedStopNotifications(player, "mid-drain cancel")
    }

    /// REVIEWER 82714c29, deterministic: a coalesced B.finish settles under A's physical stop;
    /// a waiter on B that registers ONLY AFTER the settlement must still resolve from B's
    /// retained explicit settlement fact — not strand because the confirmed floor is A's.
    @MainActor
    func testLatelyRegisteredWaiterOnACoalescedFinishResolvesFromItsRetainedSettlement() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio)

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        let aAllocated = player.finish()
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime)

        // B coalesces onto A's physical stop.
        let bAllocated = player.finish()
        XCTAssertNotEqual(bAllocated, aAllocated)

        release.signal()

        // A's notification terminal, observed FIRST.
        var aEmitted = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !aEmitted {
            aEmitted = player.confirmedStopEpochForTesting >= aAllocated
            if !aEmitted { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(aEmitted, "A's physical stop must be confirmed before B's waiter registers")

        // NOW register B's waiter — after settlement. It must resolve from the retained fact.
        let bSettled = await player.awaitActualStop(after: bAllocated, timeout: 5)
        XCTAssertTrue(
            bSettled,
            "a late waiter on a coalesced finish resolves from its explicit settlement, never strands"
        )
        assertNoStrandedStopNotifications(player, "late B waiter after settlement")
    }

    /// REVIEWER 20ec6eaa: the retained settlement set must be BOUNDED — a repeated
    /// coalesce→physical-stop lifecycle drives it back to the empty baseline, while a late
    /// settled waiter still resolves BEFORE retirement gets to its entry.
    @MainActor
    func testRepeatedCoalesceStopCyclesKeepTheRetainedSettlementSetBounded() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate
        defer { player.setDrainHoldForTesting(false) }

        // EXACTLY-ONCE LEDGER (reviewer 38dffe3e): every notification identity across ALL
        // cycles — a second physical stop for a coalesced request would show up here.
        var emittedIdentities: [Int] = []
        player.setCapturedStopNotificationForTesting { identity, completion in
            emittedIdentities.append(identity)
            completion() // the REAL notification continuation: records the physical confirmation
        }

        // Before any stop, the baseline is empty.
        XCTAssertEqual(player.settledDisplacedIdentitiesForTesting, [], "baseline: nothing settled")

        for cycle in 1...4 {
            player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
            XCTAssertTrue(player.hasPendingAudio, "cycle \(cycle): a frame must be pending")

            let arrived = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            player.claimReached = arrived
            player.claimRelease = release
            defer {
                release.signal()
                arrived.signal()
                player.claimReached = nil
                player.claimRelease = nil
            }

            let aAllocated = player.finish()
            let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
            XCTAssertTrue(claimedInTime, "cycle \(cycle): the runner must reach the claim")

            // B coalesces onto A's physical stop; C ALSO coalesces — two retained facts.
            let bAllocated = player.finish()
            let cAllocated = player.finish()
            XCTAssertNotEqual(bAllocated, aAllocated)
            XCTAssertNotEqual(cAllocated, bAllocated)

            // LATE-BUT-PRE-RETIREMENT proof: register B's waiter BEFORE the release so it
            // resolves from the retained fact even if a later physical stop retires it after.
            async let bWaiter: Bool = player.awaitActualStop(after: bAllocated, timeout: 5)

            release.signal()

            let bSettled = await bWaiter
            XCTAssertTrue(bSettled, "cycle \(cycle): the coalesced finish's late waiter resolves")

            // Let the physical stop confirm and retire.
            let physicalConfirmed = await player.awaitActualStop(after: aAllocated, timeout: 5)
            XCTAssertTrue(physicalConfirmed, "cycle \(cycle): A's physical stop confirms")
            try await Task.sleep(nanoseconds: 200_000_000)

            // BOUNDEDNESS, per cycle: this cycle retained at most its own coalesced requests
            // (b, c) — earlier cycles' entries were retired by this cycle's physical floor.
            // The exact membership can lag the confirmation (async notification delivery), so
            // assert the BOUND, not a specific set.
            XCTAssertLessThanOrEqual(
                player.settledDisplacedIdentitiesForTesting.count, 2,
                "cycle \(cycle): retained settlements must stay within this cycle's coalesced requests"
            )
            assertNoStrandedStopNotifications(player, "cycle \(cycle)")
        }

        // FINAL RETIREMENT: one more plain physical stop confirms a floor above every retained
        // identity from all cycles — storage must return to the EMPTY baseline.
        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        let lastAllocated = player.finish()
        let lastSettled = await player.awaitActualStop(after: lastAllocated, timeout: 5)
        XCTAssertTrue(lastSettled, "setup: the final turn must fully stop")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !player.settledDisplacedIdentitiesForTesting.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(
            player.settledDisplacedIdentitiesForTesting, [],
            "a physical floor above every retained identity retires them all — bounded storage"
        )
        assertNoStrandedStopNotifications(player, "final retirement")

        // EXACTLY ONCE (reviewer 38dffe3e), asserted AFTER all notifications settled: one
        // physical stop per cycle plus the final one; the coalesced b/c requests never
        // produced notifications of their own.
        XCTAssertEqual(
            emittedIdentities, [1, 4, 7, 10, 13],
            "exactly one physical stop per cycle plus the final one: emitted=\(emittedIdentities)"
        )
    }

    /// THE TIMEOUT PATH, deterministically: the release is WITHHELD, so the runner's bounded wait
    /// must record `.timedOut` and the case asserting `.released` must fail. This does not depend on
    /// scheduling luck the way a shortened bound does.
    @MainActor
    func testAWithheldReleaseTimesOutSoTheSuccessAssertionIsLoadBearing() async throws {
        let player = CloudAudioPlayer()
        let delegate = RecordingAudioPlayerDelegate()
        player.delegate = delegate

        player.enqueue(CloudAudioFrame(data: Data(repeating: 0x01, count: 320)))
        XCTAssertTrue(player.hasPendingAudio, "a frame must be pending for the drain to be scheduled")

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        player.claimReached = arrived
        player.claimRelease = release
        defer {
            release.signal()
            arrived.signal()
            player.claimReached = nil
            player.claimRelease = nil
        }

        _ = player.finish()

        // Wait for the claim, then deliberately DO NOT release: the runner's bounded wait must end
        // `.timedOut`.
        let claimedInTime = await Task.detached { arrived.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(claimedInTime, "the runner must reach the claim")

        // Give the runner's bound time to expire, then read the recorded outcome.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if player.claimReleaseOutcome != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(
            player.claimReleaseOutcome, .timedOut,
            "WITHHELD release must be recorded as TIMED OUT — this is what makes the success "
                + "assertion load-bearing rather than a bound that silently swallows a timeout"
        )
    }
    private func waitUntilCondition(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Store that fails every write and reports unreadable history — fail-closed fixtures.
final class AlwaysFailingOperationRecordStore: OperationRecordStore {
    private var records: [String: StoredRecord] = [:]
    func load() -> [String: StoredRecord] { records }
    func save(_ records: [String: StoredRecord]) -> Bool { false }
    func loadResult() -> OperationRecordLoadResult { .loaded([:]) }
}


/// Store that persists in-progress claims but FAILS every finished-record write — settlement
/// failure observed through the real write path. A `backing` store is consulted for loads so a
/// recreated journal can observe the same durable state.
final class SettlementFailingOperationRecordStore: OperationRecordStore {
    private let backing: SettlementFailingOperationRecordStore?
    private var records: [String: StoredRecord] = [:]
    init(backing: SettlementFailingOperationRecordStore? = nil) { self.backing = backing }
    func load() -> [String: StoredRecord] { backing?.records ?? records }
    func save(_ records: [String: StoredRecord]) -> Bool {
        guard !records.values.contains(where: { if case .finished = $0 { return true }; return false }) else { return false }
        self.records = records
        return true
    }
    func loadResult() -> OperationRecordLoadResult { .loaded(load()) }
}


// MARK: - Service-to-renderer helpers (spec a8580c0c)

/// Counts daily-limit utterances so "exactly once" is measured, not inferred from a substring.
private final class CountingDailyLimitTtsEngine: TtsEngineProtocol {
    private(set) var dailyLimitUtterances = 0
    func warmUp(language: String) {}
    func speak(text: String, language: String) async {
        if text.contains("Auris") && text.contains("daily limit") { dailyLimitUtterances += 1 }
    }
    func cancel() {}
    func releaseEngine() {}
}

/// A silent earcon player: the daily-limit response is SPOKEN, so no earcon asset is needed and
/// no audio graph is built.
private final class SilentCloudEarconPlayer: EarconPlayer {
    init() { super.init(engine: nil) }
    override func hasEarcon(_ id: EarconId) -> Bool { false }
    override func play(_ id: EarconId) {}
}

private struct NoOpCloudDucker: AudioSessionDucking {
    func duck() {}
    func unduck() {}
}

private struct NoOpCloudPlaybackContextProvider: PlaybackContextProvider {
    func current() -> PlaybackContext? {
        PlaybackContext(
            episodeId: "ep", podcastId: "pod", referencePositionMs: 0, clientPositionMs: 0,
            recentReferencePositions: [], previousReferencePositionMs: nil
        )
    }
}

private final class NoOpCloudPlaybackSink: VoicePlaybackSink {

    /// App-operation observation (voice-intents.md @ 818c8f75): this double has no notion of an
    /// unavailable engine, so it mirrors `isPlaying`.
    var observedPlaying: Bool? { isPlaying }

    var isPlaying: Bool { false }
    func pause() -> VoiceResponse { .silent }
    func resume() -> VoiceResponse { .silent }
    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse { .silent }
    func nextEpisode() -> VoiceResponse { .silent }
}

private final class NoOpCloudEffectsSink: VoiceEffectsSink {
    func setSpeed(_ speed: Double) -> VoiceResponse { .silent }
    func adjustSpeed(delta: Double) -> VoiceResponse { .silent }
    func setTrimMode(_ mode: TrimMode) -> VoiceResponse { .silent }
    func setVolumeBoost(enabled: Bool) -> VoiceResponse { .silent }
    func queryEffects() -> VoiceResponse { .silent }
}

private final class NoOpCloudVolumeSink: VoiceVolumeSink {
    func setVolume(_ volume: Int) -> VoiceResponse { .silent }
    func adjustVolume(delta: Int) -> VoiceResponse { .silent }
    func queryVolume() -> VoiceResponse { .silent }
}

private final class NoOpCloudSleepSink: VoiceSleepSink {
    func set(minutes: Int) -> VoiceResponse { .silent }
    func endOfEpisode() -> VoiceResponse { .silent }
    func endOfChapter() -> VoiceResponse { .silent }
    func addTime(minutes: Int) -> VoiceResponse { .silent }
    func cancel() -> VoiceResponse { .silent }
    func query() -> VoiceResponse { .silent }
}

private final class NoOpCloudChapterSink: VoiceChapterSink {
    func next() -> VoiceResponse { .silent }
    func previous() -> VoiceResponse { .silent }
    func byIndex(_ index: Int) -> VoiceResponse { .silent }
    func byTitle(_ title: String) -> VoiceResponse { .silent }
    func openLink(index: Int?, query: String?) -> VoiceResponse { .silent }
    func queryList() -> VoiceResponse { .silent }
    func queryCurrent() -> VoiceResponse { .silent }
    func queryCount() -> VoiceResponse { .silent }
    func queryNext() -> VoiceResponse { .silent }
}

private final class NoOpCloudBookmarkSink: VoiceBookmarkSink {
    func add(title: String?) -> VoiceResponse { .silent }
    func rename(ref: String, title: String) -> VoiceResponse { .silent }
    func play(ref: String) -> VoiceResponse { .silent }
    func delete(ref: String) -> VoiceResponse { .silent }
    func deleteAll() -> VoiceResponse { .silent }
    func queryList() -> VoiceResponse { .silent }
    func queryCount() -> VoiceResponse { .silent }
    func queryNearby() -> VoiceResponse { .silent }
}

private final class NoOpCloudQueueSink: VoiceQueueSink {
    func addTop(episode: String) -> VoiceResponse { .silent }
    func addBottom(episode: String) -> VoiceResponse { .silent }
    func remove(episode: String) -> VoiceResponse { .silent }
    func moveToTop(episode: String) -> VoiceResponse { .silent }
    func moveToBottom(episode: String) -> VoiceResponse { .silent }
    func clear() -> VoiceResponse { .silent }
    func removeByPodcast(podcast: String) -> VoiceResponse { .silent }
    func sort(sortOrder: podcasts.SortOrder) -> VoiceResponse { .silent }
    func queryContents() -> VoiceResponse { .silent }
    func queryNext() -> VoiceResponse { .silent }
    func queryLength() -> VoiceResponse { .silent }
    func queryIsQueued(episode: String) -> VoiceResponse { .silent }
}

private final class NoOpCloudPlaybackQuerySink: VoicePlaybackQuerySink {
    func whatsPlaying() -> VoiceResponse { .silent }
    func position() -> VoiceResponse { .silent }
    func timeRemaining() -> VoiceResponse { .silent }
    func episodeDuration() -> VoiceResponse { .silent }
    func publishDate() -> VoiceResponse { .silent }
    func episodeDescription() -> VoiceResponse { .silent }
    func downloadStatus() -> VoiceResponse { .silent }
    func episodeTitle() -> VoiceResponse { .silent }
}
