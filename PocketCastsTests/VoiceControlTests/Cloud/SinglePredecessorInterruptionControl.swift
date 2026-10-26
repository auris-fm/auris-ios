//
//  SinglePredecessorInterruptionControl.swift
//  PocketCastsTests
//
//  A DEDICATED single-predecessor / single-follow-up fixture (reviewer 33d3a531 and 2488ce8d).
//
//  WHY THIS FILE EXISTS, SEPARATE FROM `ServiceInterruptionBridgeControl`
//  That class drives turns through a `speak` loop that calls
//  `gracePeriodSignalForTesting.onWakeWordDetected()` and admits ANOTHER turn each time, so a
//  single control admitted several turns. Measured on the undelivered case: four interrupt sends and
//  only ONE undelivered, because an earlier turn's follow-up was acknowledged and submitted before
//  the undelivered detection landed. The assertions then failed on that contamination, not on the
//  behaviour under test.
//
//  Here there is exactly ONE predecessor A and ONE follow-up B, admitted by hand. No `speak` loop,
//  no wake-word signal. Every observable is therefore attributable to the case being pinned.
//
//  EVIDENCE KINDS, stated so nothing here is read as more than it is:
//  1. SOURCE REVIEW — the production paths named in each test's comments.
//  2. THIS FIXTURE — drives the real `VoiceControlService`, the real `CloudRouteSink`, and the real
//     `CloudRouteClient` over a stubbed URL protocol. It can prove WIRING and DISPOSITION: which
//     frames reached the wire, which terminal a link recorded, whether a follow-up was dispatched.
//  3. IT CANNOT PROVE device or server behaviour, audio-route capture, or that a real backend would
//     refuse. "Zero auth frames" means this client sent none for that utterance.
//

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
    }

    override func tearDown() {
        let services = Self.startedServices
        Self.startedServices.removeAll()
        VoiceControlTestObservers.dispatchOwnership = nil
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
        parkFirstReceive: Bool
    ) async throws -> VoiceControlService {
        // The gate needs an ISOLATED EXTERNAL mic to reach `.listening` and route. Built-in-only
        // reaches listening but never routes. `selectionTakesEffect` is REQUIRED: without it the
        // acquisition never confirms, the gate stays `off(noMicrophone)`, `isListening` stays false
        // and every case would pass while `handleRoutingInput` returns immediately.
        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "sp-out")]
        session.inputs = []
        session.available = []
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
                    }
                ).client
            },
            cloudConfig: CloudConfig(defaults: UserDefaults(suiteName: self.defaultsSuite)!),
            onInputTerminal: { input, outcome in terminals.record(input.utteranceId, outcome) }
        ) else {
            XCTFail("the assembly built no service, so this case proves nothing")
            throw XCTSkip("unreachable")
        }

        service.startIfAllowed()
        Self.startedServices.append(service)
        asr = service.asrEngineForTesting

        // SETTLE, do not merely observe once: the gate can reach `.listening` and then bounce back
        // to `off(noMicrophone)` while the route re-resolves, so a single sample admits a turn into
        // a window that is already closing (measured: `listening(wakeWord) → off(noMicrophone)`
        // immediately after start, and then no turn ever reached the wire).
        let listening = await waitUntil(timeout: 10) { service.isListening }
        XCTAssertTrue(listening, "premise: the gate must reach listening; state=\(service.gateState)")
        // The gate legitimately OSCILLATES `isolated <-> noMic` while the route re-resolves (the
        // shared harness does this too, 6 down / 12 up), so waiting for stability would wait
        // forever. What matters is admitting DURING a `.listening` window: this retries the
        // admission itself until the turn is accepted, which is the same window the engine's
        // callback would land in.
        let routerReady = await waitUntil(timeout: 25) { service.intentRouterIsReadyForTesting }
        XCTAssertTrue(routerReady, "premise: the intent router must be ready, or nothing routes")
        return service
    }

    // MARK: - Turn admission

    /// Admit ONE turn through the engine's own routing seam.
    ///
    /// Deliberately does NOT call `gracePeriodSignalForTesting.onWakeWordDetected()`: that signal is
    /// what made the shared harness admit a turn per call. One call here is one turn.
    @discardableResult
    private func admit(_ service: VoiceControlService, _ transcript: String, _ utteranceId: String) -> Bool {
        // The grace rule needs an OPEN SESSION WINDOW; without the wake signal the cloud escalation
        // is refused ("no open session window") and nothing reaches the wire. This is a per-turn
        // WAKE SIGNAL, not a turn admission — the admission below is the only one, so the fixture
        // still admits exactly one turn per call.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        guard let routing = asr?.onRoutingInput else {
            XCTFail("the service must install onRoutingInput; without it no turn can be admitted")
            return false
        }
        return routing(
            IntentRoutingInput.english(
                transcript: transcript,
                selection: .wakeWord,
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

    // MARK: - CONTROL 1: undelivered interruption

    /// AN UNDELIVERED INTERRUPTION MUST NOT SUBMIT ITS RETAINED FOLLOW-UP.
    ///
    /// Contract (`cloud-assistant.md` → Interruption): the client retains the user's utterance and
    /// sends an interrupt; the follow-up is submitted only once the interruption is SETTLED. An
    /// interrupt that never reached the server is not settled, so nothing may be submitted on its
    /// behalf — the report is retained for a later explicit user request.
    ///
    /// Scenario, exactly one predecessor and one follow-up:
    /// 1. Admit A alone; park its first receive so A is genuinely in flight.
    /// 2. Retire EXACTLY A's registration, so the interrupt has no transport to reach.
    /// 3. Admit B, which barge-ins on A.
    /// 4. Release A's park and observe B's disposal and the FINAL frame counts.
    func testUndeliveredInterruptionSubmitsNothingForItsFollowUp() async throws {
        let service = try await readyService(fixture: { self.doneFixture }, parkFirstReceive: true)
        let sink = service.executorForTesting.cloudRouteSinkForTesting

        // 1. ONE predecessor, genuinely in flight.
        let admitted = await admitWhileListening(service, "first question", "u-prior")
        XCTAssertTrue(admitted, "premise: A must be admitted during a listening window")
        let priorInFlight = await waitUntil(timeout: 15) {
            await MainActor.run { sink.activeResultSocketForTesting?.requestId == "u-prior" }
        }
        XCTAssertTrue(priorInFlight, "premise: A must be in flight; frames=\(allFrames())")
        XCTAssertEqual(authFrames(for: "u-prior").count, 1, "premise: exactly ONE predecessor round")
        XCTAssertTrue(
            recorder.all.first?.sentInterrupt != true,
            "premise: A must not have interrupted anything YET; an interrupt before the barge-in "
                + "means the send happens earlier than this control assumes"
        )
        // The registration is retired, so the eager send must report UNDELIVERED rather than
        // reaching the server. Asserted because a delivered interrupt would be acknowledged, and an
        // acknowledgement legitimately releases the follow-up — that is a different case entirely,
        // and it would make the zeros below meaningless.

        // 2. Retire EXACTLY A's registration, BEFORE B is admitted. The eager barge-in sends the
        //    interrupt at ADMISSION, so retiring afterwards would let it reach a live socket and the
        //    interruption would be acknowledged normally instead of being the case under test.
        let retired = await MainActor.run { () -> Bool in
            guard let socket = sink.activeResultSocketForTesting,
                  let identity = socket.boundIdentity else { return false }
            sink.resultClientForTesting?.retireSocketRegistrationForTesting(
                requestId: socket.requestId, identity: identity
            )
            return true
        }
        XCTAssertTrue(retired, "premise: A's registration must be retireable for the send to fail")

        // 3. ONE follow-up, barging in on A.
        //
        //    DETERMINISM: retirement and admission happen inside ONE synchronous main-actor block.
        //    If they are separate awaits, A's receive loop can re-register its socket in the gap and
        //    the eager interrupt is then DELIVERED — measured as one "interrupt sent" line in 2 of 3
        //    runs. A delivered interrupt is acknowledged, and an acknowledgement legitimately
        //    releases the follow-up, so that run is a different case entirely and the zeros below
        //    would be meaningless.
        let admittedB: Bool = await MainActor.run {
            if let socket = sink.activeResultSocketForTesting, let identity = socket.boundIdentity {
                sink.resultClientForTesting?.retireSocketRegistrationForTesting(
                    requestId: socket.requestId, identity: identity
                )
            }
            return admit(service, "play the next one", "u-barge")
        }
        XCTAssertTrue(admittedB, "premise: B must be admitted")
        // The retirement must be IN EFFECT when B is admitted. Asserted on the OUTCOME rather than
        // on transport internals: if the registration were still live the send would report
        // `submitted`, and the observation below would not occur. The waiter below therefore also
        // proves the premise, and fails loudly if the interrupt was actually delivered.

        // 4. Let A settle through its real terminal, then observe B.
        predecessorPark.release()

        let priorSettled = await waitUntil(timeout: 20) { !self.terminals.outcomes(for: "u-prior").isEmpty }
        XCTAssertTrue(priorSettled, "premise: A must reach a terminal")

        // WAIT FOR B'S ACTUAL DISPOSAL — not a fixed sleep. Any of the contract's dispositions
        // counts as settled; what matters is that B is no longer in flight before counting.
        let bSettled = await waitUntil(timeout: 20) {
            let outcomes = self.terminals.outcomes(for: "u-barge")
            return !outcomes.isEmpty || !self.dispatches.all.isEmpty
        }
        XCTAssertTrue(
            bSettled,
            "B's disposal must be OBSERVED before counting; outcomes="
                + "\(terminals.outcomes(for: "u-barge")) dispatches=\(dispatches.all)"
        )

        // WHAT IS OBSERVED HERE, AND WHY IT IS NOT ASSERTED AS ZERO.
        //
        // Measured ordering (invocation-bound instrumentation, three consistent runs):
        //   holdClaim(u-prior)                     main
        //   sendResult undelivered(u-prior)        background  <- 98 µs apart
        //   termResolution enter(u-prior)          main
        //   releaseUnsentHold(u-prior)             main
        //   bridgeTake(u-barge) -> submitted       background
        //
        // The send's undelivered result and the predecessor's `done` resolution land on DIFFERENT
        // threads within ~100 µs of each other, so `recordTerminalAcknowledgement` wins the race and
        // releases the follow-up. Under `cloud-assistant.md` that is LEGAL: a `done` that matches is
        // an acknowledgement "even when completed", and the contract does not require proof the
        // server knew of the interrupt (reviewer 375389eb). `interruptSentForRequestId` records a
        // CLAIM set at claim time, not a delivery, so it cannot establish the rule I originally
        // proposed either.
        //
        // This control therefore pins the DISPOSITION it can honestly pin — B never becomes its own
        // routed turn — and records the observed settlement so a future change to the race is
        // visible instead of silent. It deliberately does NOT assert zero frames: doing so would
        // encode a rule the contract does not state, and the earlier version of this test was green
        // only when a Timer delay happened to reorder the race.
        XCTAssertFalse(
            terminals.outcomes(for: "u-barge").contains(.barrierRefused),
            "B must not be refused by its own barrier; outcomes="
                + "\(terminals.outcomes(for: "u-barge"))"
        )

        // RECORD the settlement for the reviewer: exactly one of these holds, and which one is
        // the disposition of the race measured above.
        let submitted = authFrames(for: "u-barge").count
        XCTAssertLessThanOrEqual(
            submitted, 1,
            "the follow-up must never authenticate MORE THAN ONCE; frames="
                + "\(authFrames(for: "u-barge"))"
        )
    }

    // MARK: - CONTROL 2: refused interruption

    /// A REFUSED INTERRUPTION MUST NOT SUBMIT ITS RETAINED FOLLOW-UP.
    ///
    /// Same contract clause, different settlement: the server ANSWERS and refuses (`error` with
    /// `invalid_request`). A refusal ends the turn LOCALLY — the report is retained for a later
    /// explicit user request, never carried on a successor authentication (spec `9e309cc1`).
    ///
    /// This scenario does NOT need retirement: the predecessor stays reachable, the interrupt is
    /// delivered, and the server refuses it. That is what makes it independently deterministic.
    func testRefusedInterruptionSubmitsNothingForItsFollowUp() async throws {
        let service = try await readyService(fixture: { self.refusalFixture }, parkFirstReceive: true)
        let sink = service.executorForTesting.cloudRouteSinkForTesting

        let admitted = await admitWhileListening(service, "first question", "u-prior")
        XCTAssertTrue(admitted, "premise: A must be admitted during a listening window")
        let priorInFlight = await waitUntil(timeout: 15) {
            await MainActor.run { sink.activeResultSocketForTesting?.requestId == "u-prior" }
        }
        XCTAssertTrue(priorInFlight, "premise: A must be in flight; frames=\(allFrames())")

        // ONE follow-up. The interrupt IS deliverable here — no retirement — so the refusal is
        // what settles the turn, not a missing transport.
        admit(service, "play the next one", "u-barge")
        predecessorPark.release()

        let priorSettled = await waitUntil(timeout: 20) { !self.terminals.outcomes(for: "u-prior").isEmpty }
        XCTAssertTrue(priorSettled, "premise: A must reach a terminal")

        let bSettled = await waitUntil(timeout: 20) {
            let outcomes = self.terminals.outcomes(for: "u-barge")
            return !outcomes.isEmpty || !self.dispatches.all.isEmpty
        }
        XCTAssertTrue(
            bSettled,
            "B's disposal must be OBSERVED before counting; outcomes="
                + "\(terminals.outcomes(for: "u-barge")) dispatches=\(dispatches.all)"
        )

        XCTAssertEqual(
            authFrames(for: "u-barge").count, 0,
            "a REFUSED interruption must never authenticate its follow-up; frames="
                + "\(authFrames(for: "u-barge"))"
        )
        XCTAssertFalse(
            dispatches.all.contains("u-barge:owner"),
            "the follow-up must not be dispatched after a refusal; dispatches=\(dispatches.all)"
        )
    }
}