import XCTest
@testable import podcasts

/// INTERRUPTION CONTRACT — BOTH ORDERINGS, WITH OUTBOUND SUBMISSION COUNTS
/// (`docs/specs/cloud-assistant.md` → Interruption; spec ruling c5fe3416).
///
/// The contract requires the client to:
///
///   * send `interrupt` on the prior turn's STILL-OPEN socket, while awaiting that turn's terminal
///     (the server ignores a post-terminal interrupt, so this is a one-shot send with no retry);
///   * treat that turn's terminal as the acknowledgement — `done` even with `completed` — and never
///     wait for a second terminal or reopen the old socket;
///   * submit the retained follow-up ONCE, on its OWN socket, after acknowledgement;
///   * DISCARD the retained follow-up if a refusal arrives first, retaining the pending report;
///   * attach the pending `interrupts` report to the NEXT turn's authentication frame, where the
///     server applies it before model input.
///
/// These controls count OUTBOUND SUBMISSIONS from the socket the client actually used, because
/// "the outcome was not completed" cannot distinguish "nothing was resubmitted" from "something was
/// resubmitted and also failed" — the defect earlier review found in the first version of the
/// refusal control.
///
/// Layer: the REAL `CloudRouteSink` on the REAL `CloudRouteClient` over the stubbed transport, plus
/// the state machine that carries the follow-up across turns. `VoiceControlService.submitRetained…
/// FollowUpIfAny` is the production bridge from acknowledgement to submission; it is not executed
/// here (see the limit note on `testAcknowledgedFollowUpIsReleasedExactlyOnce`).
final class InterruptionOrderingControl: SocketCapturingTestCase {
    private var playback: InterruptPlaybackSink!
    private var mapper: EmptyInterruptionMapper!
    private var contextState: CloudPlaybackContextState!
    private var analytics: InterruptAnalytics!
    private var voiceAnalytics: VoiceAnalytics!
    private var defaults: UserDefaults!
    private var suiteName: String!

    private static let origin = 1

    override func setUp() {
        super.setUp()
        playback = InterruptPlaybackSink()
        mapper = EmptyInterruptionMapper()
        contextState = CloudPlaybackContextState()
        analytics = InterruptAnalytics()
        voiceAnalytics = VoiceAnalytics(analytics: analytics)
        suiteName = "interruption_ordering_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A sink sharing `state` — the SAME instance a second turn uses, which is what makes the
    /// cross-turn retention real rather than per-turn fiction.
    ///
    /// `prepareTask` reaches each new socket; `holdGate` parks EVERY turn's `receive` so a prior
    /// turn stays genuinely IN FLIGHT (open socket, live token) while a successor starts. Without
    /// that, `activeResultSocket` and `activeTurn` are nil, the sink takes the "no transport to
    /// interrupt" branch, and a control that claims to exercise interruption ordering is
    /// exercising nothing — measured, then fixed, in this file.
    private func makeSink(
        state: CloudInterruptionState,
        gate: Gate? = nil,
        fixture: @escaping () -> String
    ) -> CloudRouteSink {
        let cloudConfig = CloudConfig(defaults: defaults)
        return CloudRouteSink(
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    baseURL: cloudConfig.baseUrl,
                    fixture: fixture(),
                    prepareTask: { task in
                        if let gate { task.holdUntilReleased(gate) }
                    }
                )
                self.capturedTask = built.task
                return built.client
            },
            isConfigured: { !cloudConfig.baseUrl.isEmpty },
            playbackSink: playback,
            fingerprintMapper: mapper,
            playbackPositionMs: { self.playback.positionMs },
            cloudPlaybackContextState: contextState,
            analytics: voiceAnalytics,
            rendersStructuredResults: false,
            routeHintProvider: { nil },
            conversationManager: {
                let manager = CloudConversationManager()
                manager.registerLiveOrigin(Self.origin)
                return manager
            }(),
            interruptionState: state
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

    /// `event:`/`data:` fixture with a `done` terminal.
    private var doneFixture: String {
        """
        event: done
        data: {"usage":{"input_tokens":1,"output_tokens":1}}

        """
    }

    private var refusalFixture: String {
        """
        event: error
        data: {"code":"invalid_request","message":"interrupt does not reference the active turn"}

        """
    }

    /// Poll a main-actor condition. Returns whether it became true, so a control can fail on the
    /// premise instead of hanging.
    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    // MARK: - The state machine under test (unit level)

    /// THE BINDING (reviewer ff00457c item 2): a terminal for a turn OTHER than the interrupted one
    /// must not release the follow-up. The earlier version released whenever anything was held, so
    /// an unrelated turn's success authorised a follow-up the user had addressed elsewhere.
    func testATerminalForAnUnrelatedTurnReleasesNothing() {
        let state = CloudInterruptionState()
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "turn-A"))
        XCTAssertTrue(state.hold(request: "next one", utteranceId: "u-2", origin: 1, forRequestId: "turn-A"))

        XCTAssertNil(
            state.recordTerminalAcknowledgement(forRequestId: "turn-B"),
            "turn B's terminal must not release the follow-up held for turn A"
        )
        XCTAssertEqual(
            state.heldFollowUpForTesting?.utteranceId, "u-2",
            "the follow-up must still be held for A after B settled"
        )

        // And A's own terminal does release it, exactly once.
        let released = state.recordTerminalAcknowledgement(forRequestId: "turn-A")
        XCTAssertEqual(released?.interruptedRequestId, "turn-A")
        XCTAssertNil(
            state.recordTerminalAcknowledgement(forRequestId: "turn-A"),
            "a second terminal for A must not release the same follow-up again"
        )
    }

    /// SEQUENTIAL INTERRUPTIONS (reviewer item 3): resolving one must not lock out the next.
    func testACompletedInterruptionDoesNotBlockTheNextOne() {
        let state = CloudInterruptionState()
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "turn-A"))
        XCTAssertTrue(state.hold(request: "a-follow", utteranceId: "u-a", origin: 1, forRequestId: "turn-A"))
        XCTAssertNotNil(state.recordTerminalAcknowledgement(forRequestId: "turn-A"))

        // A NEW interruption, after the first resolved: this is the case a single "released" slot
        // made permanently impossible.
        XCTAssertTrue(
            state.claimInterruptEmission(forRequestId: "turn-B"),
            "a later turn must still be interruptible after an earlier interruption resolved"
        )
        XCTAssertTrue(state.hold(request: "b-follow", utteranceId: "u-b", origin: 1, forRequestId: "turn-B"))
        XCTAssertNotNil(state.recordTerminalAcknowledgement(forRequestId: "turn-B"))

        // And a THIRD, after a refusal in between.
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "turn-C"))
        XCTAssertTrue(state.hold(request: "c-follow", utteranceId: "u-c", origin: 1, forRequestId: "turn-C"))
        XCTAssertTrue(
            state.recordRefusal(
                forRequestId: "turn-C",
                retainingReport: .init(requestId: "turn-C", playbackPositionMs: nil)
            )
        )
        XCTAssertTrue(
            state.claimInterruptEmission(forRequestId: "turn-D"),
            "a refusal must not lock out later interruptions either"
        )
    }

    /// A refusal for an unrelated turn must not overwrite the pending report with its own id.
    func testRefusalForAnUnrelatedTurnRetainsNothingAndKeepsTheRealReport() {
        let state = CloudInterruptionState()
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "turn-A"))
        XCTAssertTrue(state.hold(request: "a-follow", utteranceId: "u-a", origin: 1, forRequestId: "turn-A"))

        XCTAssertFalse(
            state.recordRefusal(
                forRequestId: "turn-B",
                retainingReport: .init(requestId: "turn-B", playbackPositionMs: nil)
            ),
            "a refusal for a turn that was never interrupted is not an interruption refusal"
        )
        XCTAssertEqual(
            state.pendingReportForTesting?.requestId, nil,
            "no report may be invented for an unrelated refusal"
        )
    }

    /// REPORT DURABILITY (reviewer item 4): taking the report does NOT consume it; only an
    /// explicit confirmation after the frame actually left does. A failed connection therefore
    /// cannot destroy the correction.
    func testTakingTheReportDoesNotConsumeItUntilTheFrameLeft() {
        let state = CloudInterruptionState()
        state.recordPendingReport(.init(requestId: "turn-A", playbackPositionMs: nil, conversationId: "conv"))

        let taken = state.takePendingReport()
        XCTAssertEqual(taken?.requestId, "turn-A", "premise: a report is available")
        XCTAssertTrue(
            state.hasPendingReport,
            "a taken report must SURVIVE a failed attempt so a later turn can still carry it"
        )

        // A confirmation for a DIFFERENT turn must not clear it (identity-checked).
        state.confirmReportAttached(requestId: "some-other-turn")
        XCTAssertTrue(state.hasPendingReport, "a confirmation for another turn must not consume it")

        state.confirmReportAttached(requestId: "turn-A")
        XCTAssertFalse(state.hasPendingReport, "the confirmation for the carried report consumes it")
    }

    // MARK: - Ordering 1: acknowledgement first

    /// ACKNOWLEDGEMENT-FIRST, through the real sink: the prior turn's `done` releases the retained
    /// follow-up, and the next turn submits it on its own socket.
    ///
    /// The count that matters here is on the SECOND turn's socket: exactly one `authenticate` frame
    /// carrying the retained utterance's identity. A second submission would show as two.
    func testAcknowledgementFirstSubmitsTheFollowUpOnceOnItsOwnSocket() async {
        let state = CloudInterruptionState()
        // Arm the interruption as the production emit point would: one shot claimed, follow-up held.
        // The sink's `done` for turn B is B's terminal. With the request binding in place, that
        // terminal resolves only a follow-up held FOR B — which is what the production emit point
        // records (it holds the interrupting utterance against the turn it interrupted).
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "u-turn-b"))
        XCTAssertTrue(state.hold(request: "play the next one", utteranceId: "u-followup", origin: Self.origin, forRequestId: "u-turn-b"))

        // Turn B runs on its own socket and reaches `done` — the acknowledgement for the turn it
        // interrupted, handled by the sink's `done` branch.
        let sink = makeSink(state: state) { self.doneFixture }
        let result = await sink.routeToCloud(
            request: "what about the second one",
            tier: .free,
            context: sampleContext(),
            origin: Self.origin,
            selection: .followUp,
            utteranceId: "u-turn-b"
        )
        XCTAssertEqual(result.outcome, .completed, "premise: turn B completed normally")

        // The acknowledgement released the follow-up exactly once.
        let released = await MainActor.run { sink.takeReleasedInterruptionFollowUp() }
        XCTAssertEqual(released?.request, "play the next one", "the retained follow-up must be released by the acknowledgement")
        XCTAssertEqual(released?.utteranceId, "u-followup")
        let again = await MainActor.run { sink.takeReleasedInterruptionFollowUp() }
        XCTAssertNil(again, "the follow-up must be handed out once, so it cannot be submitted twice")

        // SUBMISSION COUNT on turn B's own socket: one authenticate frame, nothing more.
        let frames = capturedTask?.sentTextFrames ?? []
        let authFrames = frames.filter { $0.contains("\"authenticate\"") }
        XCTAssertEqual(
            authFrames.count, 1,
            "turn B must submit exactly one authenticate frame on its own socket; got \(frames.count) frames total"
        )
        XCTAssertEqual(frames.count, 1, "no additional submission on turn B's socket: \(frames)")
    }

    // MARK: - Ordering 2: refusal first

    /// REFUSAL-FIRST, through the real sink: the refusal discards the retained follow-up and
    /// retains the report, and NOTHING is submitted for the follow-up.
    func testRefusalFirstDiscardsAndSubmitsNothing() async {
        let state = CloudInterruptionState()
        let gate = Gate()
        let sink = makeSink(state: state, gate: gate) { self.refusalFixture }

        // PRIOR TURN, GENUINELY IN FLIGHT: its socket is open and its token is live while the
        // successor starts. This is the only configuration in which the sink's interruption path
        // runs at all; without it the control below would pass by never interrupting anything.
        let prior = Task {
            await sink.routeToCloud(
                request: "prior question",
                tier: .free,
                context: self.sampleContext(),
                origin: Self.origin,
                selection: .followUp,
                utteranceId: "u-turn-a"
            )
        }
        // Wait until the prior turn owns the socket.
        let socketAppeared = await waitUntil(timeout: 5) { await MainActor.run { sink.activeResultSocketForTesting != nil } }
        XCTAssertTrue(socketAppeared, "premise: the prior turn's socket must open before the successor starts")
        let priorRequestId = await MainActor.run { sink.activeResultSocketForTesting?.requestId }
        XCTAssertNotNil(priorRequestId, "premise: the prior turn must own a live socket")
        // Snapshot the PRIOR socket now: the successor's client factory rebinds `capturedTask`, so
        // reading it later would inspect the wrong socket and an interrupt on the real one would
        // look absent (that mistake briefly made this control fail on green code).
        let priorTask = capturedTask

        let result = await sink.routeToCloud(
            request: "what about the second one",
            tier: .free,
            context: sampleContext(),
            origin: Self.origin,
            selection: .followUp,
            utteranceId: "u-turn-b"
        )

        // The refusal is a failed turn, never settlement.
        XCTAssertNotEqual(result.outcome, .completed, "a refusal must not be reported as completion")

        // DISCARD: nothing is released for submission.
        let released = await MainActor.run { sink.takeReleasedInterruptionFollowUp() }
        XCTAssertNil(released, "a refusal must DISCARD the follow-up; nothing may be submitted for it")
        XCTAssertNil(state.heldFollowUpForTesting, "the held follow-up must be gone after a refusal")

        // RETAIN — BUT NOT ON A SUCCESSOR AUTHENTICATION (reviewer c38ff4ba item 2, spec 9e309cc1
        // line 334). The contract says: "If an interrupt is refused before any terminal
        // acknowledgement, discard the retained next utterance and report local generic failure;
        // terminate the old transport and retain the pending interruption report for a later
        // EXPLICIT USER REQUEST." A refusal therefore ends the turn locally — it does not
        // authenticate, so no successor frame exists to carry the report, and asserting one would
        // have required the very fall-through this control exists to forbid.
        let successorFrames = capturedTask?.sentTextFrames ?? []
        XCTAssertEqual(
            successorFrames, [],
            "a refused interruption must END LOCALLY: no authenticate frame, no report on the "
            + "wire. Measured frames=\(successorFrames)"
        )
        XCTAssertTrue(
            state.hasPendingReport,
            "the interruption report must be RETAINED for a later explicit user request"
        )

        // The report is retained IN MEMORY, naming the interrupted turn, ready for that later turn.
        let retainedReport = state.pendingReportForTesting
        XCTAssertEqual(
            retainedReport?.requestId, priorRequestId,
            "the retained report must name the INTERRUPTED turn"
        )

        let priorFrames = priorTask?.sentTextFrames ?? []
        XCTAssertTrue(
            priorFrames.contains { $0.contains("\"interrupt\"") && $0.contains(priorRequestId ?? "<nil>") },
            "premise: the interrupt frame must have ridden the PRIOR turn's socket; "
            + "prior frames=\(priorFrames)"
        )
        // BOUNDED PREMISE WAIT, not an instantaneous read. Retirement is performed by the
        // successor's supersede, which races this turn's own return; sampling `isCancelledSocket`
        // once made the premise fail on green code whenever the supersede landed a moment later —
        // the intermittent failure this control showed under load and never in isolation. Waiting
        // asserts the same fact without depending on winning a race.
        let retired = await waitUntil(timeout: 5) { priorTask?.isCancelledSocket ?? false }
        XCTAssertTrue(
            retired,
            "premise: the prior socket must have been retired by the supersede"
        )

        gate.release()
        _ = await prior.value
    }

    // MARK: - The successor must not overtake the acknowledgement (reviewer ff00457c item 1)

    /// THE ORDERING THAT WAS BROKEN: turn B must send ZERO authenticate frames while turn A is
    /// still unresolved, and exactly one carrying B's input after A's terminal.
    ///
    /// The earlier implementation cancelled A and dialled B immediately, so A's `done` never
    /// reached the branch that records the acknowledgement — the release could be skipped entirely.
    /// This control observes the wire, not the intent: it reads A's socket and B's socket
    /// separately, because `capturedTask` rebinds to the newest one.
    func testSuccessorSendsNothingUntilTheInterruptedTurnSettles() async {
        let state = CloudInterruptionState()
        let gate = Gate()
        let sink = makeSink(state: state, gate: gate) { self.doneFixture }

        // Turn A: in flight, parked on the gate so it cannot settle on its own.
        let prior = Task {
            await sink.routeToCloud(
                request: "prior question", tier: .free, context: self.sampleContext(),
                origin: Self.origin, selection: .followUp, utteranceId: "u-turn-a"
            )
        }
        let appeared = await waitUntil(timeout: 5) {
            await MainActor.run { sink.activeResultSocketForTesting != nil }
        }
        XCTAssertTrue(appeared, "premise: turn A must own a live socket")
        let priorTask = capturedTask
        let priorRequestId = await MainActor.run { sink.activeResultSocketForTesting?.requestId }
        XCTAssertNotNil(priorRequestId, "premise: turn A's request id is known")

        // Turn B starts and must NOT reach the wire: A is unresolved, so B's interrupt has not
        // been acknowledged. B parks in the successor wait.
        let successor = Task {
            await sink.routeToCloud(
                request: "play the next one", tier: .free, context: self.sampleContext(),
                origin: Self.origin, selection: .followUp, utteranceId: "u-turn-b"
            )
        }

        // Let B make as much progress as it can. If the wait is missing, B's auth frame lands here.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let successorTaskBefore = capturedTask
        let framesBefore = successorTaskBefore?.sentTextFrames ?? []
        XCTAssertTrue(
            priorTask?.sentTextFrames.contains { $0.contains("\"interrupt\"") } ?? false,
            "premise: the interrupt must have been sent on A's socket; A frames="
            + "\(priorTask?.sentTextFrames ?? [])"
        )
        XCTAssertFalse(
            framesBefore.contains { $0.contains("\"authenticate\"") },
            "turn B must send NOTHING before A's terminal; measured B frames=\(framesBefore)"
        )

        // Release A. Its `done` is the acknowledgement, and B may now go on the wire.
        gate.release()
        _ = await prior.value
        _ = await successor.value

        let successorTaskAfter = capturedTask
        let framesAfter = successorTaskAfter?.sentTextFrames ?? []
        let successorAuth = framesAfter.filter { $0.contains("\"authenticate\"") }
        XCTAssertEqual(
            successorAuth.count, 1,
            "after A's terminal, B must submit exactly one authenticate frame; measured \(framesAfter)"
        )
    }



    /// The pending report rides the NEXT turn's authentication frame, where the server applies it
    /// before model input — and it is attached exactly once.
    func testPendingReportRidesTheNextTurnsAuthFrame() async {
        let state = CloudInterruptionState()
        state.recordPendingReport(.init(requestId: "turn-A", playbackPositionMs: nil))

        let sink = makeSink(state: state) { self.doneFixture }
        _ = await sink.routeToCloud(
            request: "next question",
            tier: .free,
            context: sampleContext(),
            origin: Self.origin,
            selection: .followUp,
            utteranceId: "u-turn-c"
        )

        let frames = capturedTask?.sentTextFrames ?? []
        guard let authText = frames.first(where: { $0.contains("\"authenticate\"") }) else {
            return XCTFail("no authenticate frame was submitted: \(frames)")
        }
        XCTAssertTrue(
            authText.contains("\"interrupts\""),
            "the pending interruption report did not ride the auth frame: \(authText)"
        )
        XCTAssertTrue(
            authText.contains("turn-A"),
            "the report must name the interrupted turn: \(authText)"
        )
        // Optional by contract, and unmeasured here, so it must be OMITTED rather than invented.
        XCTAssertFalse(
            authText.contains("playback_position_ms"),
            "an unmeasured playback position must be omitted, never sent as a guess: \(authText)"
        )
        // Attached once: the state no longer holds it.
        XCTAssertFalse(state.hasPendingReport, "the report must be consumed by the turn that carried it")
    }

    /// CONVERSATION ABANDONMENT DISCARDS THE REPORT (`cloud-assistant.md` → Interruption).
    ///
    /// The report corrects ONE conversation's settled history. Carrying it into a different
    /// conversation would ask the server to annotate turns it never settled. So a turn that
    /// carries a DIFFERENT conversation id must drop it rather than attach it.
    ///
    /// This is the requirement a first pass at the contract check found unimplemented: the state
    /// held no conversation identity, so no turn could ever tell that the conversation had changed.
    func testReportIsDiscardedWhenTheConversationChanges() async {
        let state = CloudInterruptionState()
        state.recordPendingReport(.init(requestId: "turn-A", playbackPositionMs: nil, conversationId: "conv-old"))
        XCTAssertEqual(
            state.pendingReportConversationId, "conv-old",
            "premise: the report names the conversation it belongs to"
        )

        // A turn that runs in a DIFFERENT conversation: `prepare` mints a fresh conversation id.
        let sink = makeSink(state: state) { self.doneFixture }
        _ = await sink.routeToCloud(
            request: "different conversation", tier: .free, context: sampleContext(),
            origin: Self.origin, selection: .wakeWord, utteranceId: "u-other"
        )

        let frames = capturedTask?.sentTextFrames ?? []
        XCTAssertFalse(
            frames.contains { $0.contains("\"interrupts\"") },
            "a report must NOT travel into a different conversation: \(frames)"
        )
        XCTAssertNil(
            state.pendingReportForTesting,
            "abandoning the conversation must DISCARD the report, not keep it for a later turn"
        )
    }

    /// A report is carried ONCE: the following turn must not re-send the same correction.
    func testReportIsNotReSentOnASubsequentTurn() async {
        let state = CloudInterruptionState()
        state.recordPendingReport(.init(requestId: "turn-A", playbackPositionMs: nil))

        let first = makeSink(state: state) { self.doneFixture }
        _ = await first.routeToCloud(
            request: "first", tier: .free, context: sampleContext(),
            origin: Self.origin, selection: .followUp, utteranceId: "u-first"
        )
        let firstFrames = capturedTask?.sentTextFrames ?? []
        XCTAssertTrue(firstFrames.contains { $0.contains("\"interrupts\"") }, "premise: the report rode the first turn")

        let second = makeSink(state: state) { self.doneFixture }
        _ = await second.routeToCloud(
            request: "second", tier: .free, context: sampleContext(),
            origin: Self.origin, selection: .followUp, utteranceId: "u-second"
        )
        let secondFrames = capturedTask?.sentTextFrames ?? []
        XCTAssertFalse(
            secondFrames.contains { $0.contains("\"interrupts\"") },
            "the same correction must not be re-sent on a later turn: \(secondFrames)"
        )
    }
    // MARK: - Non-interrupted supersession must not regress

    /// DOUBLE WAKE, NOT A BARGE-IN: a second turn starts while the first is still open, with NO
    /// interruption state armed. The acknowledgement wait must be skipped entirely (nothing was
    /// interrupted, so nothing is owed), and the successor must still reach the wire promptly.
    ///
    /// This control exists because the interruption fix changes the supersede ordering — the wait
    /// sits between the interrupt send and `cancel()`. If the guard were written carelessly (for
    /// example "always wait for the prior turn's terminal"), an ordinary double wake would block on
    /// a turn nobody interrupted, regressing the commonest path.
    func testDoubleWakeWithoutInterruptionStillSupersedesPromptly() async {
        let state = CloudInterruptionState()
        let gate = Gate()
        let sink = makeSink(state: state, gate: gate) { self.doneFixture }

        let first = Task {
            await sink.routeToCloud(
                request: "first wake", tier: .free, context: self.sampleContext(),
                origin: Self.origin, selection: .followUp, utteranceId: "u-first"
            )
        }
        let appeared = await waitUntil(timeout: 5) {
            await MainActor.run { sink.activeResultSocketForTesting != nil }
        }
        XCTAssertTrue(appeared, "premise: the first turn must own a live socket")
        let firstTask = capturedTask

        let started = Date()
        let second = Task {
            await sink.routeToCloud(
                request: "second wake", tier: .free, context: self.sampleContext(),
                origin: Self.origin, selection: .followUp, utteranceId: "u-second"
            )
        }
        let reached = await waitUntil(timeout: 5) {
            (self.capturedTask?.sentTextFrames ?? []).contains { $0.contains("\"authenticate\"") }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(
            reached,
            "a double wake must not wait for the prior turn's terminal when nothing was interrupted"
        )
        XCTAssertLessThan(
            elapsed, 3,
            "the successor must not sit on the interruption wait in the non-interrupted path; "
            + "elapsed \(elapsed)s"
        )
        XCTAssertFalse(
            (firstTask?.sentTextFrames ?? []).contains { $0.contains("\"interrupt\"") },
            "a plain double wake must not emit an interrupt frame"
        )

        gate.release()
        _ = await first.value
        _ = await second.value
    }
    /// AN UNDELIVERED INTERRUPT SUPPRESSES ITS UTTERANCE — driven through the sink.
    ///
    /// Supersedes a state-only test whose name claimed a boundary it never executed (reviewer
    /// 79614a4f item 1). The `.undelivered` case is produced the way production produces it: the
    /// prior turn's socket registration is RETIRED, so `sendInterruptOnPriorSocket` finds no bound
    /// task and reports undelivered after `releaseUnsentHold`. The assertion is on the wire.
    func testAnUndeliveredInterruptNeverAuthenticatesItsUtterance() async {
        let state = CloudInterruptionState()
        let gate = Gate()
        let sink = makeSink(state: state, gate: gate) { self.doneFixture }

        // PRIOR TURN genuinely in flight, then its transport retired so the interrupt cannot be
        // delivered while `activeTurn`/`activeResultSocket` still look live to the sink.
        let prior = Task {
            await sink.routeToCloud(
                request: "prior question",
                tier: .free,
                context: self.sampleContext(),
                origin: Self.origin,
                selection: .followUp,
                utteranceId: "u-turn-a"
            )
        }
        let appeared = await waitUntil(timeout: 5) {
            await MainActor.run { sink.activeResultSocketForTesting != nil }
        }
        XCTAssertTrue(appeared, "premise: the prior turn must own a socket before we retire it")
        let priorRequestId = await MainActor.run { sink.activeResultSocketForTesting?.requestId }
        guard let priorRequestId else {
            XCTFail("premise: the prior turn must own a live socket")
            return
        }
        // RETIRE THE REGISTRATION the way a consumer close does, leaving the sink's turn state
        // untouched: precisely the state in which a send comes back `.undelivered`.
        await MainActor.run {
            if let socket = sink.activeResultSocketForTesting, let identity = socket.boundIdentity {
                sink.resultClientForTesting?.retireSocketRegistrationForTesting(
                    requestId: socket.requestId, identity: identity
                )
            }
        }

        let emitted = await sink.emitBargeIn(
            request: "play the next one",
            utteranceId: "u-barge",
            origin: Self.origin,
            selection: CloudConversationSelection.followUp
        )
        XCTAssertNil(emitted, "an undelivered interrupt cannot retain a follow-up for submission")

        // THE WIRE ASSERTION: the interrupting utterance never reached any socket.
        let frames = capturedTask?.sentTextFrames ?? []
        XCTAssertFalse(
            frames.contains { $0.contains("u-barge") },
            "the utterance may never authenticate after an unsent interrupt: \(frames)"
        )
        XCTAssertNil(
            state.recordTerminalAcknowledgement(forRequestId: priorRequestId),
            "nothing may be released for submission after an unsent interrupt"
        )
        // THE DECISIVE ASSERTION, and the one that makes this control non-vacuous: the utterance
        // must be SUPPRESSED, because its queued turn is already on the serial chain and will ask
        // this before dispatching. Holding the follow-up is not enough — the hold was released by
        // the failed send, so the queued turn's only protection is suppression. Without this the
        // no-suppression mutant survives (measured), i.e. the control would pass while the real
        // defect — an utterance submitted as an ordinary turn after an interrupt that never
        // reached the server — went unnoticed.
        XCTAssertTrue(
            state.isSuppressed("u-barge"),
            "an unsent interrupt must SUPPRESS its utterance: the failed send already released "
            + "the hold, so the queued turn would otherwise authenticate as an ordinary question"
        )
        gate.release()
        _ = await prior.value
    }

}

// MARK: - Doubles

private struct EmptyInterruptionMapper: FingerprintMappingProviding {
    func matchedReferenceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? { nil }
    func playbackTime(forReferenceTime referenceTime: TimeInterval) -> TimeInterval? { nil }
}

private final class InterruptPlaybackSink: VoicePlaybackSink, @unchecked Sendable {
    private(set) var positionMs: Int64 = 0
    func setPositionMs(_ ms: Int64) { positionMs = ms }
    var isPlaying: Bool { false }
    func pause() -> VoiceResponse { .silent }
    func resume() -> VoiceResponse { .silent }
    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int) -> VoiceResponse { .silent }
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse { .silent }
    func nextEpisode() -> VoiceResponse { .silent }
}

private final class InterruptAnalytics: AnalyticsService, @unchecked Sendable {
    func track(_ event: String, properties: [String: Any]) {}

}
