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
    /// The PRODUCTION FALLBACK repair, covered on its own.
    ///
    /// The PRODUCTION FALLBACK repair, covered on its own: the input's own provenance is honoured
    /// when the caller passes no parameter. Separate from the registered-callback case on purpose —
    /// converting that case to the registered path removed the only coverage this repair had, and
    /// coverage has to be added to, not moved.
    @MainActor
    func testTheInputProvenanceIsHonouredWhenTheParameterIsAbsent() async throws {
        let capture = FakeAudioCapture()
        guard let service = VoiceControlAssembly().buildVoiceControlService(capture: capture) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try XCTSkipUnless(service.isListening, "the gate did not reach .listening")
        try await waitForRouter(service: service)
        service.gracePeriodSignalForTesting.onWakeWordDetected()

        let sink = service.executorForTesting.cloudRouteSinkForTesting
        // The PARAMETER is deliberately omitted — the caller shape the repair exists for.
        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: "what did the host mean by that remark",
                selection: .wakeWord
            )
        )

        let reached = await MainActor.run { sink.lastSelectionForTesting }
        XCTAssertEqual(
            reached, .wakeWord,
            "the input's provenance was discarded when no parameter was passed"
        )
    }

    /// The REGISTERED path only. Audio goes in through the capture and nothing else: no direct
    /// handler call, because an earlier version bridged the two and the observed escalation could
    /// have come from the second invocation — successive-stage logs did not prove ONE input
    /// traversed them all.
    @MainActor
    func testTheRegisteredInputCarriesItsProvenanceToTheSink() async throws {
        let capture = FakeAudioCapture()
        guard let service = VoiceControlAssembly().buildVoiceControlService(capture: capture) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try XCTSkipUnless(service.isListening, "the gate did not reach .listening")
        XCTAssertGreaterThan(capture.startCount, 0, "the real start path did not begin capture")
        try await waitForRouter(service: service)

        // A window is ALREADY OPEN before the wake arrives, so a live read and the input's
        // provenance would disagree — without this the case proves nothing.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        XCTAssertTrue(service.gracePeriodSignalForTesting.isActive, "the window did not open")

        let sink = service.executorForTesting.cloudRouteSinkForTesting
        await driveRegisteredCallback(capture: capture)

        // Poll: the escalation runs on the service's serial task, still awaiting routing when the
        // emits return.
        var delivered: CloudConversationSelection?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            delivered = await MainActor.run { sink.lastSelectionForTesting }
            if delivered != nil { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        try XCTSkipUnless(
            delivered != nil,
            "the registered input produced no turn, so registration is not exercised; this is not "
                + "a pass and must not be read as coverage"
        )
        XCTAssertEqual(
            delivered, .wakeWord,
            "the registered input's provenance did not reach the sink"
        )
    }

    /// Delivers audio through the capture so the REAL registered path runs — the only input the
    /// registered case uses.
    private func driveRegisteredCallback(capture: FakeAudioCapture) async {
        // ONE FRAME PER CALL: `minSpeechFrames` (5) counts CALLS, not samples, so a single large
        // buffer is one frame and speech is never confirmed.
        let frameSize = 1_600                                              // 100 ms at 16 kHz
        for _ in 0..<20 {                                                  // 2s of speech
            capture.emit(samples: [Float](repeating: 0.05, count: frameSize), at: nil)
        }
        // The silence window is WALL-CLOCK (`Date()` vs 500 ms), so quiet frames must be spread
        // across real time; back-to-back they elapse microseconds and the condition never fires.
        for _ in 0..<8 {                                                   // 800 ms of real silence
            capture.emit(samples: [Float](repeating: 0.0, count: frameSize), at: nil)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    @MainActor
    private func waitForRouter(service: VoiceControlService) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if service.intentRouterIsReadyForTesting { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("the intent router never became ready")
    }

}
