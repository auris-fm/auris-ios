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

    /// Drains main, where the service performs the socket work. The callbacks are invoked from the
    /// audio thread in production and hop to main, so asserting without this observes the state
    /// before the hop, not after it.
    private func drainMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
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
        await drainMain()
        admit("utterance-local", 0, firstTag)
        await drainMain()
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-local",
                       "admission must pin the connection to the utterance that owns it")

        // It is answered locally: nothing takes the connection, and it is not closed.
        XCTAssertTrue(sink.hasEarlyConnectionForTesting)

        // Second utterance: it must open its OWN connection, not be refused by the held one.
        let secondTag = open()
        XCTAssertNotNil(secondTag, "the next utterance must open a connection of its own")
        XCTAssertNotEqual(secondTag, firstTag, "it must not reuse the predecessor's connection")
        await drainMain()
        admit("utterance-next", 1, secondTag)
        await drainMain()
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
        await drainMain()
        admit("utterance-predecessor", 0, predecessorTag)
        await drainMain()

        // Before that drop runs, the successor opens and is admitted.
        let successorTag = open()
        await drainMain()
        admit("utterance-successor", 1, successorTag)
        await drainMain()
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

    /// A connection may only be consumed by the utterance it belongs to.
    ///
    /// Without the owner check the turn takes any held connection, so a predecessor's socket is
    /// used to send a successor's request — the same "one utterance using another's state" defect
    /// the tag was introduced to end, arriving from the other side.
    func test_aTurnDoesNotTakeAConnectionOwnedByAnotherUtterance() async throws {
        guard let service = makeService() else {
            return XCTFail("the assembly built no service, so the case proves nothing")
        }
        try await start(service)

        let engine = service.asrEngineForTesting
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let open = try XCTUnwrap(engine.onAddressedTrailingSilenceBegan)
        let admit = try XCTUnwrap(engine.onTurnAdmitted)

        // The predecessor opens and owns the connection.
        let predecessorTag = try XCTUnwrap(open())
        await drainMain()
        admit("utterance-predecessor", 0, predecessorTag)
        await drainMain()
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-predecessor")

        // A different utterance routes to the cloud. It must not take that connection.
        // The conversation bound refuses a turn whose origin is not live, which would refuse the
        // route before the take is ever reached — the case would then pass or fail for a reason of
        // its own making. Make the dispatched origin live.
        service.liveOriginManagerForTesting.registerLiveOrigin(1)
        let createdBefore = sink.clientCreationCountForTesting
        let result = await sink.routeToCloud(
            request: "play that",
            tier: .free,
            context: PlaybackContext(
                episodeId: "ep", podcastId: "pod",
                referencePositionMs: 1_000, clientPositionMs: 1_100,
                recentReferencePositions: [], previousReferencePositionMs: nil
            ),
            origin: 1,
            selection: nil,
            utteranceId: "utterance-other"
        )

        XCTAssertGreaterThan(sink.clientCreationCountForTesting, createdBefore,
                             "a turn must open its own connection, not send on one owned by another utterance "
                                 + "(result=\(String(describing: result)) owner=\(String(describing: sink.earlyConnectionOwnerForTesting)))")
        XCTAssertEqual(sink.earlyConnectionOwnerForTesting, "utterance-predecessor",
                       "the predecessor's connection must be left for its own turn")
    }

    /// The open is invoked from the audio processing thread in production, not from main.
    ///
    /// A control that calls it from `@MainActor` cannot fail on a main-actor assumption, which is
    /// exactly how `assumeIsolated` in this path went unnoticed. This case calls the installed
    /// callback from a background queue, as capture does.
    func test_openIsSafeToCallFromTheCaptureThread() async throws {
        guard let service = makeService() else {
            return XCTFail("the assembly built no service, so the case proves nothing")
        }
        try await start(service)

        let engine = service.asrEngineForTesting
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let open = try XCTUnwrap(engine.onAddressedTrailingSilenceBegan)

        // Off the main actor, on a labelled background queue: the trap an `assumeIsolated` would
        // hit here would fail this case rather than the whole suite.
        let tag: String? = await withCheckedContinuation { continuation in
            DispatchQueue(label: "fm.auris.audio.processing").async {
                continuation.resume(returning: open())
            }
        }

        XCTAssertNotNil(tag, "the open must produce a tag when called off main")
        await drainMain()
        XCTAssertTrue(sink.hasEarlyConnectionForTesting,
                      "the connection opened off main must reach the sink on main")
    }
}
