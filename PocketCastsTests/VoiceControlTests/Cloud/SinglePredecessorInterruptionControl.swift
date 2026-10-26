// Single-predecessor/single-follow-up controls for interruption settlement.
// Drives the real service, sink and client over a fake audio route and stubbed transport.
// Request-bound barriers establish terminal order; counts and outcomes are specific to A/B.
// This verifies client wiring and disposal, not microphone recognition or live server behavior.

import XCTest
@testable import podcasts

@MainActor
final class SinglePredecessorInterruptionControl: XCTestCase {

    // MARK: - Fixture state

    /// Records each socket the client opened, and the index it was created at, so a single
    /// control can park EXACTLY the first receive and let every later one run normally.
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
    private var defaultsSuite: String!

    /// Parks A's FIRST receive so A is genuinely in flight when the barge-in is attempted.
    private var predecessorPark = HoldLatch()

    /// Every service this class started, stopped in teardown. The `AVAudioSession` is one
    /// process-wide object, so a leaked service keeps reacting to later route notifications.
    private static var startedServices: [VoiceControlService] = []

    /// Terminals, recorded from the assembly's `@Sendable` hook.
    private final class TerminalRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(id: String, outcome: VoiceControlService.InputTerminalOutcome)] = []
        func record(_ id: String, _ outcome: VoiceControlService.InputTerminalOutcome) {
            lock.lock(); entries.append((id, outcome)); lock.unlock()
        }
        func outcomes(for id: String) -> [VoiceControlService.InputTerminalOutcome] {
            lock.lock(); defer { lock.unlock() }
            return entries.filter { $0.id == id }.map(\.outcome)
        }
    }
    private let terminals = TerminalRecorder()

    /// Dispatch ownership, reported by the executor as "<utterance>:owner" / "<utterance>:duplicate".
    private final class DispatchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private let dispatches = DispatchRecorder()
    private let bridgeTakes = DispatchRecorder()
    private let queuedClassifications = DispatchRecorder()


    private var asr: VoiceAsrEngine?

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        // RESET FIRST: `CloudRouteTestURLProtocol` is process-global, so a previous case's stubbed
        // fixture otherwise leaks into this one (measured: the refusal case's `invalid_request`
        // arriving during the undelivered case, which produced a spurious "interrupt sent").
        CloudRouteTestURLProtocol.reset()
        predecessorPark = HoldLatch()
        defaultsSuite = "single_pred_\(UUID().uuidString)"
        UserDefaults(suiteName: defaultsSuite)!
            .set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        VoiceControlTestObservers.dispatchOwnership = { [dispatches] value in dispatches.record(value) }
        VoiceControlTestObservers.followUpTaken = { [bridgeTakes] value in bridgeTakes.record(value) }
    }

    override func tearDown() {
        let services = Self.startedServices
        Self.startedServices.removeAll()
        VoiceControlTestObservers.dispatchOwnership = nil
        VoiceControlTestObservers.followUpTaken = nil
        // UNCONDITIONAL RELEASE, before stopping: a case that fails mid-way must never leave a
        // receive parked and wedge the next case.
        predecessorPark.release()
        for service in services { joinAcquisitionCleanup(service) }
        // SETTLE THE PROCESS-GLOBAL TRANSPORT before the next case starts. A stopped service can
        // still have a receive loop unwinding, and `CloudRouteTestURLProtocol` is process-global, so
        // the previous case's stubbed error was observed INSIDE the next case (measured:
        // `interruption refused for turn u-prior (code=invalid_request)` logged between the two
        // tests, which is the refusal fixture leaking into the undelivered case).
        let settled = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { settled.signal() }
        _ = settled.wait(timeout: .now() + 2)
        CloudRouteTestURLProtocol.reset()
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    /// Capture the task BEFORE `stop()` nils it, then join its bounded completion.
    private func joinAcquisitionCleanup(_ service: VoiceControlService) {
        let captured = service.captureAcquisitionTaskForTesting()
        var stopped = false
        var completed = true
        var done = false
        Task { @MainActor in
            service.stop()
            stopped = true
            if let captured {
                completed = await VoiceControlService.awaitCompletion(of: captured, timeout: 10)
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(15)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(done, "teardown could not complete stop/join within its bound")
        _ = stopped
        if captured != nil {
            XCTAssertTrue(completed, "the in-flight acquisition task did not complete — not joined")
        }
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

    /// Build a real service whose client is stubbed.
    ///
    /// `parkFirstReceive` parks ONLY the first receive, so A is genuinely in flight; every later
    /// receive runs normally, letting A settle through its REAL terminal rather than a
    /// cancellation. Otherwise the service never reaches the state the barge-in needs.
    private func readyService(
        fixture: @escaping () -> String,
        parkFirstReceive: Bool,
        closeWithoutTerminal: Bool = false
    ) async throws -> VoiceControlService {
        // Start with a confirmed external microphone so route discovery cannot retire the window.
        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "sp-out")]
        session.inputs = [AudioPort(portType: .bluetoothHFP, uid: "sp-mic")]
        session.available = session.inputs
        session.availableAfterConfigure = [AudioPort(portType: .bluetoothHFP, uid: "sp-mic")]
        session.selectionTakesEffect = true

        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.conflicts = GateConflicts(
            notOnCall: .allowed, notCasting: .allowed,
            batteryOk: .allowed, otherAppPlaying: .allowed
        )

        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='play the next one')]<|tool_call_end|>"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_singlepred_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)

        let recorder = self.recorder
        let terminals = self.terminals
        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: session,
            conditionMonitor: monitor,
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: { [predecessorPark] in
                CloudRouteClient.stubbed(
                    baseURL: "https://cloud.test",
                    fixture: fixture(),
                    prepareTask: { task in
                        let index = recorder.record(task)
                        if parkFirstReceive, index == 1 {
                            task.holdFirstReceiveUntilReleased(predecessorPark)
                        }
                        if closeWithoutTerminal, index == 1 {
                            // The client closes its stream without yielding a synthetic error.
                            // An ordinary EOF becomes connection_lost and exercises refusal instead.
                            task.receiveError = CancellationError()
                        }
                    }
                ).client
            },
            cloudConfig: CloudConfig(defaults: UserDefaults(suiteName: self.defaultsSuite)!),
            onInputTerminal: { input, outcome in terminals.record(input.utteranceId, outcome) },
            parsedIntentObserverFactory: { [queuedClassifications] input in
                queuedClassifications.record(input.utteranceId ?? "-")
                return nil
            }
        ) else {
            XCTFail("the assembly built no service, so this case proves nothing")
            throw XCTSkip("unreachable")
        }

        service.startIfAllowed()
        Self.startedServices.append(service)
        asr = service.asrEngineForTesting

        let listening = await waitUntil(timeout: 10) { service.isListening }
        XCTAssertTrue(listening, "premise: the gate must reach listening; state=\(service.gateState)")
        let routerReady = await waitUntil(timeout: 25) { service.intentRouterIsReadyForTesting }
        XCTAssertTrue(routerReady, "premise: the intent router must be ready, or nothing routes")
        return service
    }

    // MARK: - Turn admission

    /// Admit ONE turn through the engine's own routing seam.
    ///
    /// Admits one input with its wake or follow-up selection.
    @discardableResult
    private func admit(_ service: VoiceControlService, _ transcript: String, _ utteranceId: String) -> Bool {
        // A wakes a window; B continues it without replacing its conversation identity.
        let selection: CloudConversationSelection = utteranceId == "u-prior" ? .wakeWord : .followUp
        if selection == .wakeWord {
            service.gracePeriodSignalForTesting.onWakeWordDetected()
        } else {
            service.gracePeriodSignalForTesting.onCommandRecognized()
        }
        guard let routing = asr?.onRoutingInput else {
            XCTFail("the service must install onRoutingInput; without it no turn can be admitted")
            return false
        }
        return routing(
            IntentRoutingInput.english(
                transcript: transcript,
                selection: selection,
                utteranceId: utteranceId
            )
        )
    }

    /// Admit ONE turn, retrying until it lands inside a `.listening` window.
    ///
    /// The gate oscillates, and `enqueueRoutingInput` refuses any callback that arrives while it is
    /// `off`. Retrying the ADMISSION is the honest model of what the engine does — its callback
    /// lands whenever it lands — and it still admits exactly one turn.
    private func admitWhileListening(
        _ service: VoiceControlService,
        _ transcript: String,
        _ utteranceId: String
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if service.isListening, admit(service, transcript, utteranceId) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    // MARK: - Observation

    private func allFrames() -> [String] { recorder.all.flatMap(\.sentTextFrames) }
    private func authFrames(for utteranceId: String) -> [String] {
        allFrames().filter {
            $0.contains("\"authenticate\"") && $0.contains("\"request_id\":\"\(utteranceId)\"")
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    func testStoppedCaptureIsDroppedRatherThanLabelledSuppressed() async throws {
        let service = try await readyService(fixture: { self.doneFixture }, parkFirstReceive: false)
        service.stop()
        let outcome = await service.handleRoutingInput(.english(transcript: "next", utteranceId: "stopped"))
        XCTAssertEqual(outcome, .dropped)
        XCTAssertEqual(authFrames(for: "stopped").count, 0)
    }

    private func retirePredecessor(_ sink: CloudRouteSink) throws {
        let socket = try XCTUnwrap(sink.activeResultSocketForTesting)
        let identity = try XCTUnwrap(socket.boundIdentity)
        sink.resultClientForTesting?.retireSocketRegistrationForTesting(
            requestId: socket.requestId, identity: identity
        )
    }

    func testFailureFinalizedBeforeDoneDiscardsB() async throws {
        let service = try await readyService(fixture: { self.doneFixture }, parkFirstReceive: true)
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let failureFinished = DiagnosticMicOverrideControl.FlagBox()
        sink.afterUnsentHoldReleaseForTesting = { requestId in
            if requestId == "u-prior" { failureFinished.set() }
        }
        let admittedA = await admitWhileListening(service, "first question", "u-prior")
        XCTAssertTrue(admittedA)
        let active = await waitUntil(timeout: 15) { sink.activeResultSocketForTesting?.requestId == "u-prior" && self.recorder.all.first?.terminalWithheld == true }
        XCTAssertTrue(active)
        try retirePredecessor(sink)
        let admittedB = admit(service, "play the next one", "u-barge")
        XCTAssertTrue(admittedB)
        let discarded = await waitUntil(timeout: 15) { failureFinished.isSet }
        XCTAssertTrue(discarded, "failure transition must finish before A’s done")
        XCTAssertTrue(sink.isSuppressedForTesting("u-barge"))
        XCTAssertNil(sink.interruptionStateForTesting.heldFollowUpForTesting)
        predecessorPark.release()
        let settled = await waitUntil(timeout: 20) {
            !self.terminals.outcomes(for: "u-prior").isEmpty
                && !self.terminals.outcomes(for: "u-barge").isEmpty
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(authFrames(for: "u-barge").count, 0)
        XCTAssertFalse(dispatches.all.contains("u-barge:owner"))
        XCTAssertNil(sink.pendingFollowUpSubmission)
        XCTAssertEqual(terminals.outcomes(for: "u-barge"), [.handedOffToFollowUpSubmission])
        XCTAssertFalse(queuedClassifications.all.contains("u-barge"), "B's queued link must never classify")
        XCTAssertFalse(dispatches.all.contains("u-barge:duplicate"), "B must have only the bridge dispatch")
    }

    func testDoneBeforeFailureCleanupSubmitsBExactlyOnce() async throws {
        let service = try await readyService(fixture: { self.doneFixture }, parkFirstReceive: true)
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let failurePark = HoldLatch()
        defer { failurePark.release() }
        let entered = DiagnosticMicOverrideControl.FlagBox()
        sink.beforeUnsentHoldReleaseForTesting = { requestId in
            guard requestId == "u-prior" else { return }
            entered.set()
            await failurePark.waitUntilReleased()
        }
        let admittedA = await admitWhileListening(service, "first question", "u-prior")
        XCTAssertTrue(admittedA)
        let active = await waitUntil(timeout: 15) { sink.activeResultSocketForTesting?.requestId == "u-prior" && self.recorder.all.first?.terminalWithheld == true }
        XCTAssertTrue(active)
        try retirePredecessor(sink)
        let admittedB = admit(service, "play the next one", "u-barge")
        XCTAssertTrue(admittedB)
        let failedSend = await waitUntil(timeout: 15) { entered.isSet }
        XCTAssertTrue(failedSend)
        XCTAssertEqual(sink.interruptionStateForTesting.heldFollowUpForTesting?.utteranceId, "u-barge")
        predecessorPark.release()
        let acknowledged = await waitUntil(timeout: 20) {
            sink.interruptionStateForTesting.resolvedForTesting.contains("u-prior")
        }
        XCTAssertTrue(acknowledged, "matching done must resolve before failed-send cleanup")
        failurePark.release()
        let settled = await waitUntil(timeout: 20) {
            !self.terminals.outcomes(for: "u-prior").isEmpty
                && !self.terminals.outcomes(for: "u-barge").isEmpty
                && self.authFrames(for: "u-barge").count == 1
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(authFrames(for: "u-barge").count, 1)
        XCTAssertEqual(dispatches.all.filter { $0 == "u-barge:owner" }.count, 1)
        XCTAssertEqual(bridgeTakes.all.filter { $0.hasPrefix("u-barge@") }.count, 1)
        XCTAssertEqual(terminals.outcomes(for: "u-barge"), [.handedOffToFollowUpSubmission])
        XCTAssertFalse(queuedClassifications.all.contains("u-barge"), "B's queued link must never classify")
        XCTAssertFalse(dispatches.all.contains("u-barge:duplicate"), "B must have only the bridge dispatch")
        let authData = try XCTUnwrap(authFrames(for: "u-barge").first?.data(using: .utf8))
        let auth = try XCTUnwrap(JSONSerialization.jsonObject(with: authData) as? [String: Any])
        let report = try XCTUnwrap(auth["interrupts"] as? [String: Any])
        XCTAssertEqual(report["request_id"] as? String, "u-prior")
        XCTAssertEqual(auth["conversation_mode"] as? String, "resume")
    }

    func testTruncatedPredecessorDiscardsHeldBAndAllowsAnotherInterruption() async throws {
        try await checkUnsettledPredecessor(cancel: false)
    }

    func testCancelledPredecessorDiscardsHeldBAndAllowsAnotherInterruption() async throws {
        try await checkUnsettledPredecessor(cancel: true)
    }

    private func checkUnsettledPredecessor(cancel: Bool) async throws {
        let service = try await readyService(
            fixture: { "" }, parkFirstReceive: true, closeWithoutTerminal: true
        )
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let admittedA = await admitWhileListening(service, "first question", "u-prior")
        XCTAssertTrue(admittedA)
        let parked = await waitUntil(timeout: 15) { self.recorder.all.first?.terminalWithheld == true }
        XCTAssertTrue(parked)
        let predecessorTask = try XCTUnwrap(service.captureRoutingTaskForTesting())
        let admittedB = admit(service, "play the next one", "u-barge")
        XCTAssertTrue(admittedB)
        let held = await waitUntil(timeout: 15) {
            sink.interruptionStateForTesting.heldFollowUpForTesting?.utteranceId == "u-barge"
        }
        XCTAssertTrue(held)
        if cancel {
            predecessorTask.cancel()
            XCTAssertTrue(predecessorTask.isCancelled)
        } else {
            XCTAssertFalse(predecessorTask.isCancelled, "stream truncation must not cancel the owner")
        }
        predecessorPark.release()
        let finished = await waitUntil(timeout: 20) {
            !self.terminals.outcomes(for: "u-prior").isEmpty
                && !self.terminals.outcomes(for: "u-barge").isEmpty
        }
        XCTAssertTrue(finished)
        XCTAssertTrue(sink.isSuppressedForTesting("u-barge"))
        XCTAssertNil(sink.interruptionStateForTesting.heldFollowUpForTesting)
        XCTAssertEqual(sink.interruptionStateForTesting.pendingReportForTesting?.requestId, "u-prior")
        XCTAssertEqual(authFrames(for: "u-barge").count, 0)
        XCTAssertTrue(sink.interruptionStateForTesting.claimInterruptEmission(forRequestId: "later"))
    }

    // MARK: - CONTROL: refused interruption

    /// A REFUSED INTERRUPTION MUST NOT SUBMIT ITS RETAINED FOLLOW-UP.
    ///
    /// Deterministic premise chain (reviewer `453fbb5f`): B ADMITTED, A parked and in flight, exactly
    /// ONE interrupt emitted for A, B's follow-up HELD — and only then is A's error served. The
    /// zero-auth assertion is therefore not satisfiable by a harness that never created an
    /// interruption, and no unrelated dispatch can satisfy completion.
    ///
    /// NO input barrier is used, and that is deliberate: a follow-up RETAINED FOR AN INTERRUPTION
    /// never reaches `testInputBarrier` (the service's ownership transfer returns at 597-599, the
    /// barrier is awaited at 615), so parking B there is impossible by construction. Attempting it
    /// produced controls whose mutants all survived — the barrier, not the state machine, was what
    /// suppressed the submission. The barrier was removed rather than papered over.
    func testRefusedInterruptionSubmitsNothingForItsFollowUp() async throws {
        let service = try await readyService(fixture: { self.refusalFixture }, parkFirstReceive: true)
        let sink = service.executorForTesting.cloudRouteSinkForTesting

        // 1. A admitted and IN FLIGHT (parked at its receive, so it cannot complete early).
        let admittedA = await admitWhileListening(service, "first question", "u-prior")
        XCTAssertTrue(admittedA, "premise: A must be admitted")
        let priorInFlight = await waitUntil(timeout: 15) {
            await MainActor.run { sink.activeResultSocketForTesting?.requestId == "u-prior" && self.recorder.all.first?.terminalWithheld == true }
        }
        XCTAssertTrue(priorInFlight, "premise: A must be in flight; frames=\(allFrames())")
        XCTAssertTrue(
            self.recorder.all.first?.sentInterrupt != true,
            "premise: A must not have interrupted anything before B"
        )

        XCTAssertTrue(recorder.all.first?.terminalWithheld == true, "A must be parked at receive")
        XCTAssertEqual(authFrames(for: "u-prior").count, 1)

        // 2. B ADMITTED — asserted, not ignored.
        let admittedB = await MainActor.run { admit(service, "play the next one", "u-barge") }
        XCTAssertTrue(admittedB, "premise: B must be admitted, or there is no follow-up to refuse")

        // 3. EXACTLY ONE interrupt reaches A. This is the interruption under test.
        let interruptEmitted = await waitUntil(timeout: 15) {
            self.recorder.all.contains { $0.sentInterrupt }
        }
        XCTAssertTrue(interruptEmitted, "premise: one interrupt must reach A; frames=\(allFrames())")

        // 4. B is RETAINED. Asserted through the state machine, so a harness that silently dropped
        //    B cannot pass this control.
        let bHeld = await MainActor.run { sink.interruptionStateForTesting.heldFollowUpForTesting?.utteranceId == "u-barge" }
        XCTAssertTrue(bHeld, "premise: B must be HELD, not already submitted")
        let submittedWhileHeld = authFrames(for: "u-barge").count
        XCTAssertEqual(submittedWhileHeld, 0, "premise: B is not submitted while held")

        // 5. ONLY NOW release A, so its error (the refusal) is served.
        predecessorPark.release()

        // 6. Await A's terminal AND B's own disposition — never an unrelated dispatch.
        let priorSettled = await waitUntil(timeout: 20) {
            !self.terminals.outcomes(for: "u-prior").isEmpty
        }
        XCTAssertTrue(priorSettled, "premise: A must reach a terminal")
        let bDisposed = await waitUntil(timeout: 20) {
            let outcomes = self.terminals.outcomes(for: "u-barge")
            // `.handedOffToFollowUpSubmission` is B's NORMAL retirement into the follow-up
            // submitter, which is not a submission; the zero-auth count below is what asserts that.
            return outcomes.contains(.dropped)
                || outcomes.contains(.barrierCancelled)
                || outcomes.contains(.handedOffToFollowUpSubmission)
                || !self.authFrames(for: "u-barge").isEmpty
        }
        XCTAssertTrue(
            bDisposed,
            "B's OWN disposition must be observed; outcomes=\(terminals.outcomes(for: "u-barge"))"
        )

        XCTAssertEqual(allFrames().filter { $0.contains("\"interrupt\"") }.count, 1)
        XCTAssertEqual(sink.interruptionStateForTesting.pendingReportForTesting?.requestId, "u-prior")
        XCTAssertNil(sink.interruptionStateForTesting.heldFollowUpForTesting)

        XCTAssertEqual(terminals.outcomes(for: "u-barge"), [.handedOffToFollowUpSubmission])
        XCTAssertFalse(queuedClassifications.all.contains("u-barge"), "B's queued link must never classify")
        XCTAssertFalse(dispatches.all.contains("u-barge:duplicate"), "B must have only the bridge dispatch")

        // 7. THE ASSERTION.
        XCTAssertEqual(
            authFrames(for: "u-barge").count, 0,
            "a REFUSED interruption must never authenticate its follow-up; frames="
                + "\(authFrames(for: "u-barge"))"
        )
        XCTAssertFalse(
            dispatches.all.contains("u-barge:owner"),
            "B must not be dispatched after a refusal; dispatches=\(dispatches.all)"
        )
    }
}
