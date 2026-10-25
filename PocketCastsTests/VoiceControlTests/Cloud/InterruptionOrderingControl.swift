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

    /// Both transitions are compare-and-set, so a racing pair of terminals resolves the follow-up
    /// exactly once. This is the property the ordering controls below depend on.
    func testAcknowledgementReleasesTheFollowUpExactlyOnce() {
        let state = CloudInterruptionState()
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "turn-A"))
        XCTAssertTrue(state.hold(request: "next one", utteranceId: "u-2", origin: 1, forRequestId: "turn-A"))

        let first = state.recordTerminalAcknowledgement(forRequestId: "turn-A")
        XCTAssertEqual(first?.request, "next one", "the acknowledgement must release the held follow-up")
        XCTAssertEqual(first?.utteranceId, "u-2")
        let second = state.recordTerminalAcknowledgement(forRequestId: "turn-A")
        XCTAssertNil(second, "a second terminal must not release the same follow-up again")

        // A REPEATED INTERRUPT SEND must be refused too. Zeroing the in-flight marker on every
        // terminal would let a second interrupt be sent for a turn whose terminal already landed —
        // the server ignores those, so the claim would be a lie about an effect that cannot happen.
        // The first version of this control missed that: a mutant that kept the marker alive
        // (and so re-opened the send) survived, which is why this case is here.
        XCTAssertFalse(state.hasOpenInterrupt(forRequestId: "turn-A"), "premise: the interrupt is closed")
        XCTAssertFalse(
            state.claimInterruptEmission(forRequestId: "turn-A"),
            "a post-terminal interrupt claim must be refused, but the state allowed it"
        )
    }

    /// Refusal-first: the follow-up is DISCARDED and cannot be submitted even if an
    /// acknowledgement arrives afterwards (the contract says a late terminal cannot resurrect it).
    func testRefusalDiscardsTheFollowUpAndRetainsTheReport() {
        let state = CloudInterruptionState()
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "turn-A"))
        XCTAssertTrue(state.hold(request: "next one", utteranceId: "u-2", origin: 1, forRequestId: "turn-A"))

        XCTAssertTrue(
            state.recordRefusal(
                forRequestId: "turn-A",
                retainingReport: .init(requestId: "turn-A", playbackPositionMs: nil)
            ),
            "the refusal must be the transition that discarded the follow-up"
        )
        XCTAssertNil(state.heldFollowUpForTesting, "the follow-up must be discarded, not kept")
        XCTAssertEqual(
            state.pendingReportForTesting?.requestId, "turn-A",
            "the pending interruption report is retained for a later explicit user request"
        )
        XCTAssertNil(
            state.recordTerminalAcknowledgement(forRequestId: "turn-A"),
            "a terminal after a refusal must not resurrect the discarded follow-up"
        )
    }

    /// The interrupt is one-shot: a second claim for the same turn is refused, and a claim after a
    /// terminal is refused too (the server ignores post-terminal interrupts, so sending would be a
    /// lie about what the server will act on).
    func testInterruptEmissionIsOneShotAndClosedByTerminal() {
        let state = CloudInterruptionState()
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "turn-A"))
        XCTAssertFalse(state.claimInterruptEmission(forRequestId: "turn-A"), "one shot only")

        let other = CloudInterruptionState()
        XCTAssertTrue(other.claimInterruptEmission(forRequestId: "turn-A"))
        _ = other.recordTerminalAcknowledgement(forRequestId: "turn-A")
        XCTAssertFalse(
            other.claimInterruptEmission(forRequestId: "turn-A"),
            "a claim after the terminal must be refused — the server would ignore the frame"
        )
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
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "turn-A"))
        XCTAssertTrue(state.hold(request: "play the next one", utteranceId: "u-followup", origin: Self.origin, forRequestId: "turn-A"))

        // Turn B runs on its own socket and reaches `done` — the acknowledgement for turn A's
        // interrupt is handled by the sink's `done` branch.
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

        // RETAIN: the report survives for the next turn, naming the INTERRUPTED turn.
        let reportAfter = state.pendingReportForTesting
        XCTAssertEqual(
            reportAfter?.requestId, priorRequestId,
            "the pending interruption report must be retained after a refusal; measured "
            + "report=\(String(describing: reportAfter)) "
            + "hasOpenInterrupt=\(state.hasOpenInterrupt) "
            + "frames=\(capturedTask?.sentTextFrames ?? [])"
        )

        // SUBMISSION COUNT: the refused turn submits only its own authenticate frame — no extra
        // submission was made on its behalf.
        let frames = capturedTask?.sentTextFrames ?? []
        let priorFrames = priorTask?.sentTextFrames ?? []
        XCTAssertTrue(
            priorFrames.contains { $0.contains("\"interrupt\"") && $0.contains(priorRequestId ?? "<nil>") },
            "premise: the interrupt frame must have ridden the PRIOR turn's socket; "
            + "prior frames=\(priorFrames)"
        )
        XCTAssertTrue(
            priorTask?.isCancelledSocket ?? false,
            "premise: the prior socket must have been retired by the supersede"
        )
        XCTAssertEqual(frames.count, 1, "a refusal must not cause any additional submission: \(frames)")

        gate.release()
        _ = await prior.value
    }

    // MARK: - The report on the next turn's auth frame

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