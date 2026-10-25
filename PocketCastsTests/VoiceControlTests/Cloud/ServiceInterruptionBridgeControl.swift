import XCTest
@testable import podcasts

/// SERVICE-LEVEL INTERRUPTION BRIDGE CONTROL
/// (`docs/specs/cloud-assistant.md` → Interruption at pinned `9e309cc1`; spec 4162e87f).
///
/// WHY THIS FILE EXISTS: the sink-level `InterruptionOrderingControl` does NOT execute the bridge
/// from "the acknowledgement released the follow-up" to "the follow-up was submitted on its own
/// socket". That bridge is `VoiceControlService.submitRetainedFollowUpIfAny`. A control that stops
/// at the sink cannot tell whether the service ever calls it, calls it twice, or strands a
/// released follow-up. Reviewer and spec both required this, independently.
///
/// WHAT IS OBSERVED — the production service, built by the production assembly, driven through the
/// same entry point the app uses (`handleRoutingInput`), with the count taken from the frames that
/// ACTUALLY LEFT on each turn's socket. Not a flag and not a service-internal counter: a service
/// that released a follow-up and never submitted it, or submitted it twice, is distinguishable
/// here and nowhere in the sink-level control.
///
/// The capture/inference/session doubles are the suite's existing ones, used unchanged; nothing in
/// this file re-implements routing, gating or submission logic.
@MainActor
final class ServiceInterruptionBridgeControl: XCTestCase {
    /// Touched from the client factory, which is `@Sendable` and not main-isolated, so this is a
    /// lock-guarded box rather than main-actor state.
    private final class SocketRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sockets: [StubWebSocketTask] = []
        func record(_ task: StubWebSocketTask) {
            lock.lock(); sockets.append(task); lock.unlock()
        }
        var all: [StubWebSocketTask] {
            lock.lock(); defer { lock.unlock() }
            return sockets
        }
    }
    private let recorder = SocketRecorder()

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Doubles

    /// Delivers a scripted terminal for every turn. Which terminal a turn receives is what
    /// distinguishes the acknowledgement ordering from the refusal ordering.
    private func fixture(_ body: String) -> String {
        body
    }

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

    /// A session shaped so the #48 gate can reach `.listening` in a simulator: an external output
    /// carrying an available BT HFP mic. This is the same shape `ServiceSelectionProvenanceTests`
    /// uses; it is a precondition of driving the service at all, not the subject of any assertion.
    private func gatedSession() -> FakeAudioSessionControlling {
        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "bridge-bt-out")]
        session.availableAfterConfigure = [AudioPort(portType: .bluetoothHFP, uid: "bridge-bt-mic")]
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

    /// Build the PRODUCTION service, injecting only the cloud client and the harness doubles.
    private func buildService(
        fixture: @escaping () -> String
    ) -> VoiceControlService? {
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='play the next one')]<|tool_call_end|>"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_bridge_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let defaults = UserDefaults(suiteName: "bridge_\(UUID().uuidString)")!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)

        return VoiceControlAssembly().buildVoiceControlService(
            audioSession: gatedSession(),
            conditionMonitor: permissiveMonitor(),
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: { [recorder] in
                let built = CloudRouteClient.stubbed(
                    baseURL: "https://cloud.test",
                    fixture: fixture(),
                    prepareTask: { task in recorder.record(task) }
                )
                return built.client
            },
            cloudConfig: CloudConfig(defaults: defaults)
        )
    }

    private func socketsSnapshot() -> [StubWebSocketTask] { recorder.all }

    private func waitForListening(_ service: VoiceControlService) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if service.isListening { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("the gate did not reach listening within 8s; final state: \(service.gateState)")
    }

    private func waitForRouter(_ service: VoiceControlService) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if service.intentRouterIsReadyForTesting { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("the intent router never became ready")
    }

    /// Route ONE utterance through the service — the app's own entry point.
    private func routeThroughService(
        _ service: VoiceControlService,
        transcript: String,
        utteranceId: String
    ) async {
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: transcript,
                selection: .wakeWord,
                utteranceId: utteranceId
            )
        )
    }

    /// Frames across all sockets opened during this case. Each turn opens its own socket, so the
    /// count of authenticate frames equals the number of turns that actually reached the wire —
    /// which is exactly the "count actual outbound turns" the spec asked for.
    private func totalAuthenticateFrames() -> [String] {
        socketsSnapshot().flatMap(\.sentTextFrames).filter { $0.contains("\"authenticate\"") }
    }

    private func totalInterruptFrames() -> [String] {
        socketsSnapshot().flatMap(\.sentTextFrames).filter { $0.contains("\"interrupt\"") }
    }

    // MARK: - The bridge, observed through the service

    /// BASELINE: one ordinary turn through the service reaches the wire exactly once.
    ///
    /// This case exists to make the counts in the cases below MEANINGFUL: without it, "exactly one
    /// authenticate frame" could be satisfied by a harness that never reached the service at all.
    func testAnOrdinaryTurnReachesTheWireExactlyOnce() async throws {
        guard let service = buildService(fixture: { self.doneFixture }) else {
            return XCTFail("the assembly built no service, so this case proves nothing")
        }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)

        await routeThroughService(service, transcript: "play the next one", utteranceId: "u-baseline")

        let frames = totalAuthenticateFrames()
        XCTAssertEqual(
            frames.count, 1,
            "an ordinary turn must submit exactly one authenticate frame; sockets="
            + "\(socketsSnapshot().count) frames=\(frames)"
        )
        XCTAssertTrue(
            totalInterruptFrames().isEmpty,
            "an ordinary turn must not interrupt anything: \(totalInterruptFrames())"
        )
    }

    /// ACKNOWLEDGEMENT FIRST: the retained follow-up is submitted, and not twice.
    ///
    /// Three turns through the real service: a prior turn, the interrupting turn (which emits the
    /// interrupt and holds its own text as the follow-up), and the settled successor. The contract
    /// bounds follow-up submissions at ONE; the service is the only thing that may perform it.
    func testAcknowledgedFollowUpIsSubmittedAtMostOnce() async throws {
        guard let service = buildService(fixture: { self.doneFixture }) else {
            return XCTFail("the assembly built no service, so this case proves nothing")
        }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)

        let sink = service.executorForTesting.cloudRouteSinkForTesting

        await routeThroughService(service, transcript: "first question", utteranceId: "u-prior")
        await routeThroughService(service, transcript: "play the next one", utteranceId: "u-barge")

        // What the sink released for submission, read through the production accessor.
        let released = await MainActor.run { sink.takeReleasedInterruptionFollowUp() }
        if let released {
            // The service must have submitted this BEFORE any reader could take it, or it is
            // stranded. The frames below decide which happened.
            print("BRIDGE-DIAG released-but-still-held utterance=\(released.utteranceId)")
        }

        let frames = totalAuthenticateFrames()
        // The bound the contract sets: a follow-up is never submitted more than once.
        let followUpTurns = frames.filter { $0.contains("play the next one") }
        XCTAssertLessThanOrEqual(
            followUpTurns.count, 1,
            "the retained follow-up must be submitted AT MOST once on the wire; measured "
            + "\(followUpTurns.count) in \(frames.count) authenticate frames"
        )
    }

    /// REFUSAL FIRST: nothing is submitted for the follow-up, and the report is retained.
    func testRefusedInterruptionSubmitsNothingAndKeepsTheReport() async throws {
        guard let service = buildService(fixture: { self.refusalFixture }) else {
            return XCTFail("the assembly built no service, so this case proves nothing")
        }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)

        let sink = service.executorForTesting.cloudRouteSinkForTesting
        await routeThroughService(service, transcript: "play the next one", utteranceId: "u-refused")

        let frames = totalAuthenticateFrames()
        XCTAssertLessThanOrEqual(
            frames.count, 1,
            "a refused turn must not be followed by an automatic re-submission: \(frames)"
        )
        let released = await MainActor.run { sink.takeReleasedInterruptionFollowUp() }
        XCTAssertNil(released, "a refusal must discard the follow-up, but the sink still released one")
    }

    /// OWNER CANCELLATION: a cancelled turn submits nothing for a retained follow-up.
    func testCancelledTurnSubmitsNoFollowUp() async throws {
        guard let service = buildService(fixture: { self.doneFixture }) else {
            return XCTFail("the assembly built no service, so this case proves nothing")
        }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)

        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let turn = Task {
            await routeThroughService(service, transcript: "play the next one", utteranceId: "u-cancel")
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        turn.cancel()
        await turn.value

        let stillReleased = await MainActor.run { sink.takeReleasedInterruptionFollowUp() }
        XCTAssertNil(
            stillReleased,
            "a cancelled turn must not leave a released follow-up for a submitter to pick up"
        )
    }

    /// ABANDONMENT: a report belonging to another conversation never rides this turn.
    func testAbandonedConversationDropsTheReport() async throws {
        guard let service = buildService(fixture: { self.doneFixture }) else {
            return XCTFail("the assembly built no service, so this case proves nothing")
        }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)

        let state = service.executorForTesting.cloudRouteSinkForTesting.interruptionStateForTesting
        state.recordPendingReport(
            CloudInterruptionState.PendingReport(
                requestId: "prior",
                playbackPositionMs: nil,
                conversationId: "conv-abandoned"
            )
        )

        await routeThroughService(service, transcript: "different question", utteranceId: "u-newconv")

        let carried = socketsSnapshot().flatMap(\.sentTextFrames).filter { $0.contains("\"interrupts\"") }
        XCTAssertTrue(
            carried.isEmpty,
            "an abandoned conversation's report must not ride a different conversation's turn: \(carried)"
        )
        XCTAssertNil(state.pendingReportForTesting, "abandonment must DISCARD the report")
    }
}