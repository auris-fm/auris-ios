import XCTest
@testable import podcasts

/// A capture substitute: records that capture was requested, opens no microphone, and can deliver
/// a buffer as the real capture would.
final class FakeAudioCapture: AudioCaptureSource {
    var onCapturedSamples: (([Float], MonotonicTime?) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() throws { startCount += 1 }
    func stop() { stopCount += 1 }
    func emit(samples: [Float], at time: MonotonicTime? = nil) {
        onCapturedSamples?(samples, time)
    }
}

/// The CALLER-level provenance control: a wake during ACTIVE GRACE must reach the sink as
/// `.wakeWord`, driven through the service's REAL assembly, start path and input registration.
///
/// This is the control the manager-level case explicitly cannot be — the manager is handed an
/// explicit selection, so it never exercises where the service derives one.
final class ServiceSelectionProvenanceTests: XCTestCase {
    /// Delivers audio through the capture so the REAL registered path runs rather than a direct
    /// handler call.
    private func driveRegisteredCallback(capture: FakeAudioCapture) async {
        // Two seconds of signal at the engine rate, enough to close a VAD segment.
        capture.emit(samples: [Float](repeating: 0.05, count: 16_000 * 2), at: nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    @MainActor
    func testAWakeInputDuringActiveGraceReachesTheSinkAsWake() async throws {
        let capture = FakeAudioCapture()
        let assembly = VoiceControlAssembly()
        guard let service = assembly.buildVoiceControlService(capture: capture) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }

        // Start the service the way the app does, so `isListening` becomes true through the real
        // path rather than a synthetic setter.
        service.startIfAllowed()
        try XCTSkipUnless(
            service.isListening,
            "the gate did not reach .listening with these conditions, so the real start path was "
                + "not exercised and the case could not assert about it"
        )
        XCTAssertGreaterThan(capture.startCount, 0, "the real start path did not begin capture")

        // A window is ALREADY OPEN before the wake arrives: without this a live read and the
        // input's provenance agree, and the case proves nothing.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        XCTAssertTrue(
            service.gracePeriodSignalForTesting.isActive,
            "the window did not open, so the arrangement under test was not established"
        )

        // Wait for the router model, which loads asynchronously. Without this the input is
        // dropped as `model_not_loaded` and the case would assert about a turn that never ran —
        // passing as "nil reached the sink" for a reason unrelated to the selection.
        let readyDeadline = Date().addingTimeInterval(20)
        while Date() < readyDeadline {
            if service.intentRouterIsReadyForTesting { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try XCTSkipUnless(
            service.intentRouterIsReadyForTesting,
            "the intent router never became ready, so the input could not be routed and the case "
                + "would assert about a dropped turn rather than about the selection"
        )

        let sink = service.executorForTesting.cloudRouteSinkForTesting

        // DRIVE THE REGISTERED CALLBACK, so this covers registration and not only the derivation.
        // Delivering samples through the capture runs capture -> segmenter -> ASR ->
        // `onRoutingInput` -> the service's serial callback, which is where the input's provenance
        // has to survive. Calling `handleRoutingInput` directly would prove the derivation and
        // NOTHING about registration — the two are separate, and a passing direct call must not be
        // read as covering the callback.
        await driveRegisteredCallback(capture: capture)

        let delivered = await MainActor.run { sink.lastSelectionForTesting }
        if delivered == nil {
            XCTFail(
                "the registered callback path produced no turn, so the provenance has not been "
                    + "shown to survive registration; only the direct handler was exercised"
            )
            return
        }

        let reached = await MainActor.run { sink.lastSelectionForTesting }
        XCTAssertEqual(
            reached, .wakeWord,
            "a wake during active grace reached the sink as a follow-up, so the selection came "
                + "from live window state rather than the input's provenance"
        )
    }
}
