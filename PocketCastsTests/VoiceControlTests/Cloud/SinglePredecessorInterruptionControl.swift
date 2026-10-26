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
        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .builtInSpeaker, uid: "spk")]
        session.inputs = [AudioPort(portType: .builtInMic, uid: "mic")]
        session.available = [AudioPort(portType: .builtInMic, uid: "mic")]
        session.availableAfterConfigure = [AudioPort(portType: .builtInMic, uid: "mic")]
        session.selectionTakesEffect = true

        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.setup = .allAllowed
        monitor.conflicts = .noneBlocked
        monitor.context = .playbackActive

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

        let listening = await waitUntil(timeout: 10) { service.isListening }
        XCTAssertTrue(listening, "premise: the gate must reach listening; state=\(service.gateState)")
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
        admit(service, "first question", "u-prior")
        let priorInFlight = await waitUntil(timeout: 15) {
            await MainActor.run { sink.activeResultSocketForTesting?.requestId == "u-prior" }
        }
        XCTAssertTrue(priorInFlight, "premise: A must be in flight; frames=\(allFrames())")
        XCTAssertEqual(authFrames(for: "u-prior").count, 1, "premise: exactly ONE predecessor round")

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
        admit(service, "play the next one", "u-barge")

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

        // THE ASSERTIONS: B submitted nothing, and claims no routing it did not do.
        XCTAssertEqual(
            authFrames(for: "u-barge").count, 0,
            "an UNDELIVERED interruption must never authenticate its follow-up; frames="
                + "\(authFrames(for: "u-barge"))"
        )
        XCTAssertFalse(
            dispatches.all.contains("u-barge:owner"),
            "the follow-up must not be dispatched when the interruption was undelivered; "
                + "dispatches=\(dispatches.all)"
        )
        XCTAssertFalse(
            terminals.outcomes(for: "u-barge").contains(.routed),
            "B must not report that it routed; it never reached dispatch. outcomes="
                + "\(terminals.outcomes(for: "u-barge"))"
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

        admit(service, "first question", "u-prior")
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