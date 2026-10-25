import XCTest
@testable import podcasts

/// SERVICE-LEVEL INTERRUPTION BRIDGE CONTROL
/// (`docs/specs/cloud-assistant.md` → Interruption at pinned `9e309cc1`; spec 4162e87f/bdebbe2f;
/// reviewer ff00457c/cf5017be).
///
/// WHY THIS EXISTS. `InterruptionOrderingControl` drives `CloudRouteSink` DIRECTLY. That proves the
/// sink's own ordering but NOT the bridge from "the acknowledgement released the follow-up" to "the
/// service submitted it": the sink control never executes `VoiceControlService`'s call sites. Both
/// @spec and @reviewer require this control separately, and it already earned its keep — the sink
/// controls could not see that `submitRetainedFollowUpIfAny` was wired into only one of three
/// `executor.execute` paths.
///
/// WHAT MAKES IT DETERMINISTIC. The service runs routing inputs through a SERIAL CHAIN
/// (`enqueueRoutingInput` → `transcriptSerialTask`) and reports `onInputTerminal` for every turn.
/// So:
///   - turn 1 is parked in its OWN receive, which keeps it in flight;
///   - turn 2 is enqueued behind it and cannot race it;
///   - the test delivers turn 1's terminal deliberately, then awaits the terminal signal.
/// No polls decide correctness; the bounded waits only bound FAILURE.
///
/// EVERY CASE ASSERTS THE BRIDGE WAS REACHED. An earlier version of this file passed five times
/// while the bridge never ran at all (gate never listening; then both turns ran to completion; then
/// the park woke only on retirement and the prior turn ended in a REFUSAL; then the park swallowed
/// the terminal; then the interrupt stopped firing). The premises below are hard failures, never
/// skips, so "zero submissions" cannot be satisfied by never reaching the service.
@MainActor
final class ServiceInterruptionBridgeControl: XCTestCase {
    /// Touched from the client factory (`@Sendable`, not main-isolated), so a lock-guarded box.
    private final class SocketRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sockets: [StubWebSocketTask] = []
        private var built = 0
        func record(_ task: StubWebSocketTask) -> Int {
            lock.lock(); defer { lock.unlock() }
            sockets.append(task)
            built += 1
            return built
        }
        var all: [StubWebSocketTask] {
            lock.lock(); defer { lock.unlock() }
            return sockets
        }
    }

    private let recorder = SocketRecorder()
    /// Releases the FIRST turn's parked receive exactly once, delivering its real terminal.
    ///
    /// Recreated per test: a shared latch was RELEASED by the previous case's `tearDown`, so the
    /// next case's park was already open and its "still in flight" premise was really "already
    /// settled" — the acknowledgement fired before the test released anything.
    private var firstTurnLatch = HoldLatch()
    /// The ASR engine the assembly built. `onRoutingInput` is the service's REAL admission entry —
    /// the seam a capture actually crosses — so the control drives turns through it.
    private var asr: VoiceAsrEngine?
    private var defaultsSuite: String!
    /// Terminal signals recorded from the assembly's `@Sendable` hook, so a lock-guarded box.
    private final class TerminalRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(id: String, outcome: VoiceControlService.InputTerminalOutcome)] = []
        func record(_ id: String, _ outcome: VoiceControlService.InputTerminalOutcome) {
            lock.lock(); entries.append((id, outcome)); lock.unlock()
        }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.id) }
        /// HOW EACH LINK ENDED, per utterance. Two tasks can carry the same utterance id (the
        /// queued link and the bridge's recursive dispatch), so a count of ids alone cannot say
        /// whether both settled — the dispositions can.
        func outcomes(for id: String) -> [VoiceControlService.InputTerminalOutcome] {
            lock.lock(); defer { lock.unlock() }
            return entries.filter { $0.id == id }.map(\.outcome)
        }
        func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return entries.contains { $0.id == id } }
    }

    private let terminals = TerminalRecorder()
    /// Bridge takes, recorded by the service via `onFollowUpTakenForTesting`.
    private let bridgeTakes = TerminalRecorder()
    /// Dispatch ownership decisions, recorded by the executor: "utterance:owner|duplicate".
    private let dispatches = TerminalRecorder()
    /// Records that the bridge actually ran, with the utterance it carried.
    private let bridgeEntries = TerminalRecorder()

    override func setUp() {
        super.setUp()
        VoiceControlTestObservers.dispatchOwnership = { [dispatches] value in dispatches.record(value, .routed) }
        VoiceControlTestObservers.followUpTaken = { [bridgeTakes] value in bridgeTakes.record(value, .routed) }
        firstTurnLatch = HoldLatch()
        defaultsSuite = "bridge_\(UUID().uuidString)"
        UserDefaults(suiteName: defaultsSuite)!
            .set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        VoiceControlTestObservers.dispatchOwnership = nil
        VoiceControlTestObservers.followUpTaken = nil
        // UNCONDITIONAL RELEASE: a case that fails mid-way must not leave a turn parked forever
        // and wedge later cases in this file.
        firstTurnLatch.release()
        CloudRouteTestURLProtocol.reset()
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    // MARK: - Fixtures

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

    /// The #48 gate needs an isolated external mic to reach `.listening`. This is the same shape
    /// `ServiceSelectionProvenance` uses. `selectionTakesEffect` is REQUIRED: without it the
    /// acquisition never confirms, the gate stays `off(noMicrophone)`, `isListening` stays false and
    /// every case passes while `handleRoutingInput` returns immediately.
    private func gatedSession() -> FakeAudioSessionControlling {
        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "bridge-bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = [AudioPort(portType: .bluetoothHFP, uid: "bridge-bt-mic")]
        session.selectionTakesEffect = true
        return session
    }

    private func permissiveMonitor() -> LiveConditionMonitor {
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.conflicts = GateConflicts(
            notOnCall: .allowed, notCasting: .allowed,
            batteryOk: .allowed, otherAppPlaying: .allowed
        )
        return monitor
    }

    private func buildService(fixture: @escaping () -> String) -> VoiceControlService? {
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='play the next one')]<|tool_call_end|>"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_bridge_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)

        let built = VoiceControlAssembly().buildVoiceControlService(
            audioSession: gatedSession(),
            conditionMonitor: permissiveMonitor(),
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: { [recorder, firstTurnLatch] in
                let built = CloudRouteClient.stubbed(
                    baseURL: "https://cloud.test",
                    fixture: fixture(),
                    prepareTask: { task in
                        let index = recorder.record(task)
                        // ONE-SHOT on the FIRST turn only: park its first receive so the turn is
                        // genuinely IN FLIGHT. Every later receive (and every later turn) runs
                        // normally, so releasing the latch lets the scripted `done` be served and
                        // the turn settles through its REAL terminal rather than a cancellation.
                        //
                        // Two traps measured here, both of which produced green-but-vacuous runs:
                        // `holdUntilReleased(_ gate:)` wakes only when the socket is RETIRED, so
                        // the turn ended `connection_lost` (a refusal, never the acknowledgement);
                        // `holdUntilReleased(_ latch:)` parks EVERY receive, so the terminal was
                        // never reached.
                        if index == 1 {
                            task.holdFirstReceiveUntilReleased(firstTurnLatch)
                        }
                    }
                )
                return built.client
            },
            cloudConfig: CloudConfig(defaults: UserDefaults(suiteName: self.defaultsSuite)!),
            onInputTerminal: { [terminals] input, outcome in
                terminals.record(input.utteranceId, outcome)
            }
        )
        if let built {
            asr = built.asrEngineForTesting
        }
        return built
    }

    // MARK: - Observation

    private func allFrames() -> [String] { recorder.all.flatMap(\.sentTextFrames) }
    private func authenticateFrames() -> [String] { allFrames().filter { $0.contains("\"authenticate\"") } }
    private func interruptFrames() -> [String] { allFrames().filter { $0.contains("\"interrupt\"") } }
    private func authFrames(for utteranceId: String) -> [String] {
        authenticateFrames().filter { $0.contains("\"request_id\":\"\(utteranceId)\"") }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private func waitForTerminal(_ utteranceId: String, timeout: TimeInterval = 15) async -> Bool {
        await waitUntil(timeout: timeout) { self.terminals.contains(utteranceId) }
    }

    private func readyService(fixture: @escaping () -> String) async throws -> VoiceControlService {
        guard let service = buildService(fixture: fixture) else {
            XCTFail("the assembly built no service, so this case proves nothing")
            throw XCTSkip("unreachable")
        }
        service.startIfAllowed()
        let listening = await waitUntil(timeout: 10) { service.isListening }
        XCTAssertTrue(listening, "premise: the gate must reach listening; state=\(service.gateState)")
        let routerReady = await waitUntil(timeout: 25) { service.intentRouterIsReadyForTesting }
        XCTAssertTrue(routerReady, "premise: the intent router must be ready, or nothing routes")
        return service
    }

    /// Speak a turn through the SERVICE'S OWN ENTRY POINT.
    ///
    /// This used to call `handleRoutingInput` directly, which is the DISPATCH function — it skips
    /// `enqueueRoutingInput` and therefore the serial chain and every admission-time step with it.
    /// The control then "passed" while the production route was never exercised, and the eager
    /// step's deletion survived: the interrupt it observed came from the direct-dispatch shortcut,
    /// not from the path a real capture takes. Entering through the installed `onRoutingInput`
    /// callback is the same seam `ColdAsrEligibilityProductionTests` uses, and it is the seam the
    /// engine actually calls.
    @discardableResult
    private func speak(_ service: VoiceControlService, _ transcript: String, _ utteranceId: String) -> Bool {
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let input = IntentRoutingInput.english(
            transcript: transcript,
            selection: .wakeWord,
            utteranceId: utteranceId
        )
        guard let routing = asr?.onRoutingInput else {
            XCTFail("the service must install onRoutingInput; without it no turn can be admitted")
            return false
        }
        return routing(input)
    }

    // MARK: - Baseline

    /// An ordinary turn reaches the wire exactly once. This makes the zeros below meaningful:
    /// without it, "zero authenticate frames" could be satisfied by a harness that never reached
    /// the service at all.
    func testAnOrdinaryTurnReachesTheWireExactlyOnce() async throws {
        let service = try await readyService(fixture: { self.doneFixture })
        speak(service, "play the next one", "u-baseline")
        let reached = await waitUntil(timeout: 15) { !self.authFrames(for: "u-baseline").isEmpty }
        XCTAssertTrue(reached, "premise: an ordinary turn must reach the wire; frames=\(allFrames())")
        XCTAssertEqual(authFrames(for: "u-baseline").count, 1, "exactly one auth frame for one turn")
        XCTAssertTrue(interruptFrames().isEmpty, "an ordinary turn interrupts nothing")
    }

    // MARK: - THE PREMISE spec required: a live barge-in is reachable at all

    /// TURN 2 CAN INTERRUPT A STILL-LIVE TURN 1 — asserted on the TRANSPORT's own boundaries.
    ///
    /// The serial chain makes this the whole question: a successor cannot run until its
    /// predecessor completes, so without the eager admission step no interrupt can ever be sent
    /// while the predecessor socket is open. Every claim below is read from the transport, not
    /// inferred from elapsed time:
    ///   - `receiveEntered` — the predecessor's receiver is live;
    ///   - `terminalWithheld` — its scripted terminal is PARKED, so the turn is genuinely in flight;
    ///   - `sentInterrupt` — the interrupt left on THAT socket.
    /// The bounded premise wait FAILS if the predecessor is not parked; it never waits out an
    /// acknowledgement timeout and calls the result live.
    func testBargeInReachesTheWireWhileThePredecessorIsStillLive() async throws {
        let service = try await readyService(fixture: { self.doneFixture })
        let sink = service.executorForTesting.cloudRouteSinkForTesting

        speak(service, "first question", "u-prior")
        // BOUNDED PREMISE WAIT: fail if turn 1 never parks. A timeout here is a premise failure,
        // not evidence of a live predecessor.
        let priorSockets = await waitUntil(timeout: 5) { self.recorder.all.first?.terminalWithheld == true }
        XCTAssertTrue(
            priorSockets,
            "premise: turn 1's receive must be parked with its terminal WITHHELD; "
            + "sockets=\(recorder.all.count) entered=\(recorder.all.first?.receiveEntered ?? false) "
            + "withheld=\(recorder.all.first?.terminalWithheld ?? false) frames=\(allFrames())"
        )
        guard let priorSocket = recorder.all.first else {
            XCTFail("no predecessor socket was built")
            return
        }
        XCTAssertTrue(priorSocket.receiveEntered, "premise: the predecessor receiver is consuming")
        XCTAssertFalse(
            terminals.contains("u-prior"),
            "premise: turn 1 must NOT have reached a terminal; terminals=\(terminals.all)"
        )

        speak(service, "play the next one", "u-barge")

        let interrupted = await waitUntil(timeout: 5) { priorSocket.sentInterrupt }
        XCTAssertTrue(
            interrupted,
            "the interrupt must leave on the PREDECESSOR socket while its terminal is withheld; "
            + "frames=\(priorSocket.sentTextFrames)"
        )
        XCTAssertTrue(
            (priorSocket.sentTextFrames.first { $0.contains("\"interrupt\"") } ?? "").contains("u-prior"),
            "the interrupt must name the live predecessor: \(priorSocket.sentTextFrames)"
        )
        // THE POINT, read from the transport: still withheld, so still in flight.
        XCTAssertTrue(
            priorSocket.terminalWithheld && !priorSocket.terminalReleased,
            "the interrupt must be sent BEFORE the predecessor's terminal is released"
        )

        firstTurnLatch.release()
        let released = await waitUntil(timeout: 5) { priorSocket.terminalReleased }
        XCTAssertTrue(released, "premise: the terminal must be released deliberately, not by expiry")
    }

    // MARK: - The bridge

    /// ACKNOWLEDGEMENT FIRST — the follow-up is submitted once, and only after the acknowledgement.
    ///
    /// The earlier version of this case returned as soon as the FIRST successor auth appeared. That
    /// snapshot cannot distinguish "exactly once" from "the first of two": A's recursive bridge and
    /// B's own queued link are both still in flight at that moment, and a second submission would
    /// land after the test had already finished looking. So this case now waits for BOTH links to
    /// reach their terminal, asserts how each ended, and only then counts outbound frames.
    func testFollowUpIsSubmittedOnceAfterTheAcknowledgement() async throws {
        let service = try await readyService(fixture: { self.doneFixture })
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let state = sink.interruptionStateForTesting

        speak(service, "first question", "u-prior")
        let priorLive = await waitUntil(timeout: 15) {
            await MainActor.run { sink.activeResultSocketForTesting?.requestId == "u-prior" }
        }
        XCTAssertTrue(priorLive, "premise: turn 1 must be in flight")

        speak(service, "play the next one", "u-barge")
        let interrupted = await waitUntil(timeout: 15) { !self.interruptFrames().isEmpty }
        XCTAssertTrue(interrupted, "premise: the barge-in must emit an interrupt; frames=\(allFrames())")
        let held = await waitUntil(timeout: 5) {
            await MainActor.run { state.heldFollowUpForTesting?.utteranceId == "u-barge" }
        }
        XCTAssertTrue(held, "premise: the follow-up must be retained before the acknowledgement")
        XCTAssertTrue(
            authFrames(for: "u-barge").isEmpty,
            "nothing may be submitted before the acknowledgement; frames=\(allFrames())"
        )

        // DELIVER TURN 1'S REAL TERMINAL — this is the acknowledgement.
        firstTurnLatch.release()

        // A's link settles FIRST, and it is what triggers the bridge. Awaiting it separately keeps
        // the two links' dispositions distinguishable in the failure message.
        let priorSettled = await waitUntil(timeout: 20) { self.terminals.contains("u-prior") }
        XCTAssertTrue(
            priorSettled,
            "A's queued link must reach a terminal after the acknowledgement; terminals=\(self.terminals.all)"
        )

        // THE BRIDGE, OBSERVED DIRECTLY. The reviewer's point stands: `onInputTerminal` fires in
        // the ENQUEUE task's defer, so a recursive `handleRoutingInput` from the bridge produces no
        // second terminal entry — a count of terminals cannot show whether the bridge ran. These
        // read the bridge's own take instead.
        XCTAssertTrue(
            bridgeTakes.contains("u-barge@origin2"),
            "the acknowledgement must release B TO THE SERVICE BRIDGE; measured takes="
            + "\(bridgeTakes.all)"
        )
        XCTAssertEqual(
            bridgeTakes.all.filter { $0.hasPrefix("u-barge@") }.count, 1,
            "exactly one bridge take for one acknowledgement — a second take would be a second "
            + "owner; measured=\(bridgeTakes.all)"
        )

        // B'S DISPATCHES, BOTH OF THEM. Two candidate owners exist: the bridge's recursive
        // dispatch and B's own queued link. Exactly one may reach the wire. This is measured from
        // the executor's own ownership decision, which is where "one submission" is actually
        // decided — the outbound count alone would not say WHICH dispatch won.
        let bridgeOwned = await waitUntil(timeout: 20) { self.dispatches.all.contains("u-barge:owner") }
        XCTAssertTrue(
            bridgeOwned,
            "one dispatch of B must own the submission; measured=\(self.dispatches.all)"
        )
        let duplicates = await waitUntil(timeout: 20) {
            self.dispatches.all.contains("u-barge:duplicate")
        }
        XCTAssertTrue(
            duplicates,
            "B's OTHER dispatch (its queued link) must be observed as a DUPLICATE rather than "
            + "vanish — it is the second owner the review named, and the executor's admission dedup "
            + "is what currently makes submission single; measured=\(self.dispatches.all)"
        )
        XCTAssertEqual(
            dispatches.all.filter { $0 == "u-barge:owner" }.count, 1,
            "exactly one owning dispatch; measured=\(dispatches.all)"
        )

        // THE OUTBOUND CLAIM, counted after both terminals and both dispatches.
        XCTAssertEqual(
            authFrames(for: "u-barge").count, 1,
            "the follow-up must be submitted EXACTLY once; frames=\(allFrames()) "
            + "dispatches=\(dispatches.all)"
        )
        XCTAssertEqual(
            interruptFrames().count, 1,
            "exactly one interrupt for one barge-in; frames=\(allFrames())"
        )
    }

    /// REFUSAL FIRST — a refused interruption never submits its retained utterance.
    ///
    /// Asserted at the state boundary the contract names, because driving the ordering through the
    /// full service is not deterministic with a shared fixture: the refusal terminal can arrive
    /// either before or after the successor's own dispatch, and the contract treats those cases
    /// differently (a `done` that arrives first IS settlement, and a LATE `invalid_request` cannot
    /// undo it). What is unconditional is the refusal rule itself: once a refusal is recorded, the
    /// retained utterance is DISCARDED and must never be submitted.
    func testRefusalDiscardsTheRetainedUtterance() async throws {
        let state = CloudInterruptionState()

        // A barge-in was emitted and its utterance retained.
        XCTAssertTrue(state.claimInterruptEmission(forRequestId: "u-prior"))
        XCTAssertTrue(
            state.hold(request: "play the next one", utteranceId: "u-barge", origin: nil,
                       forRequestId: "u-prior"),
            "premise: the interrupting utterance is retained while the interruption is unresolved"
        )
        XCTAssertFalse(state.isSuppressed("u-barge"), "premise: nothing is suppressed yet")

        // The server refuses.
        XCTAssertTrue(
            state.recordRefusal(
                forRequestId: "u-prior",
                retainingReport: CloudInterruptionState.PendingReport(
                    requestId: "u-prior", playbackPositionMs: nil, conversationId: "conv"
                )
            ),
            "the refusal must resolve the interruption"
        )

        XCTAssertTrue(
            state.isSuppressed("u-barge"),
            "a refusal must SUPPRESS the retained utterance so its queued turn cannot be submitted"
        )
        XCTAssertNil(
            state.heldFollowUpForTesting.map(\.utteranceId),
            "a refusal must also discard the held follow-up"
        )
        XCTAssertNil(
            state.recordTerminalAcknowledgement(forRequestId: "u-prior"),
            "a refusal is not settlement: a later terminal must not release the utterance"
        )
        XCTAssertTrue(
            state.hasPendingReport,
            "the refusal retains the interruption report for a later explicit turn"
        )
    }
}