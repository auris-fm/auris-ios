import XCTest
import AVFoundation

@testable import podcasts

/// The early-connection lifecycle driven through the SERVICE's own installed callbacks.
///
/// A control that calls the sink directly passes even when the production wiring never reaches it
/// — it proves the sink works, not that the feature works. These cases fire the callbacks the
/// assembly installs on the engine, so a mistake in the wiring fails here.
///
/// The defects under test are invisible within one turn: a held connection is skipped, not failed,
/// so every turn still answers. Only an utterance that follows another can show it.
@MainActor
final class EarlyConnectionWiringControl: XCTestCase {

    private func port(_ type: AVAudioSession.Port, uid: String) -> AudioPort {
        AudioPort(portType: type, uid: uid)
    }

    private func makeService() -> VoiceControlService? {
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("early_conn_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        return VoiceControlAssembly().buildVoiceControlService(
            audioSession: session,
            conditionMonitor: monitor,
            capture: SucceedingCapture(),
            inference: FakeLfmInference(),
            modelManager: modelManager,
            asrBackend: { SuspendedAsrBackend(text: "hello") }
        )
    }

    private func start(_ service: VoiceControlService) async throws {
        service.startIfAllowed()
        let deadline = Date().addingTimeInterval(5)
        while !service.isListening, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(service.isListening, "the service never started listening")
    }

    /// The service must actually install the open. If it does not, nothing opens a connection in
    /// production however correct the sink is.
    func test_serviceInstallsTheEarlyOpen() async throws {
        guard let service = makeService() else {
            return XCTFail("the assembly built no service, so the case proves nothing")
        }
        try await start(service)

        let engine = service.asrEngineForTesting
        XCTAssertNotNil(engine.onAddressedTrailingSilenceBegan,
                        "the service must install the early open, or no connection opens in production")
        XCTAssertNotNil(engine.onTurnAdmitted, "the service must install admission")
        XCTAssertNotNil(engine.onTurnReleased, "the service must install the drop")
    }

    /// Case 1: a locally answered command never consumes its connection, and the next utterance
    /// must still open its own rather than be turned away by the held one.
    ///
    /// Driven through the installed open and admission callbacks, exactly as the engine calls them.
    func test_localCommandThenNextUtteranceOpensThroughTheServiceWiring() async throws {
        guard let service = makeService() else {
            return XCTFail("the assembly built no service, so the case proves nothing")
        }
        try await start(service)

        let engine = service.asrEngineForTesting
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let open = try XCTUnwrap(engine.onAddressedTrailingSilenceBegan)
        let admit = try XCTUnwrap(engine.onTurnAdmitted)

        // First utterance: the engine opens at its trailing silence and the turn is admitted.
        let firstTag = open()
        XCTAssertNotNil(firstTag, "the first utterance must open a connection")
        admit("utterance-local", 0, firstTag)
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-local",
                       "admission must pin the connection to the utterance that owns it")

        // It is answered locally: nothing takes the connection, and it is not closed.
        XCTAssertTrue(sink.hasEarlyConnectionForTesting)

        // Second utterance: it must open its OWN connection, not be refused by the held one.
        let secondTag = open()
        XCTAssertNotNil(secondTag, "the next utterance must open a connection of its own")
        XCTAssertNotEqual(secondTag, firstTag, "it must not reuse the predecessor's connection")
        admit("utterance-next", 1, secondTag)
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-next")
    }

    /// Case 2: a predecessor's drop that arrives after a successor has opened must not close the
    /// successor's connection. Closing it would leave that turn waiting on a handshake cancelled
    /// underneath it.
    func test_delayedPredecessorDropDoesNotCloseTheSuccessorsConnection() async throws {
        guard let service = makeService() else {
            return XCTFail("the assembly built no service, so the case proves nothing")
        }
        try await start(service)

        let engine = service.asrEngineForTesting
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let open = try XCTUnwrap(engine.onAddressedTrailingSilenceBegan)
        let admit = try XCTUnwrap(engine.onTurnAdmitted)
        let drop = try XCTUnwrap(engine.onTurnReleased)

        // The predecessor opens and is admitted, then its turn dies and schedules its drop.
        let predecessorTag = open()
        admit("utterance-predecessor", 0, predecessorTag)

        // Before that drop runs, the successor opens and is admitted.
        let successorTag = open()
        admit("utterance-successor", 1, successorTag)
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-successor")

        // Now the predecessor's drop lands.
        drop("utterance-predecessor", predecessorTag)
        // The service hops to main to act on it; let that hop run.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(sink.hasEarlyConnectionForTesting,
                      "a predecessor's delayed drop must not close the successor's connection")
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-successor",
                       "the successor must still own its connection after the late drop")
    }
}