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
    /// This is separate from the registered-callback case on purpose: converting that case to the
    /// registered path REMOVED the only coverage this repair had, which is worse than the
    /// misleading pass the conversion was meant to avoid. Coverage has to be added to, not moved.
    ///
    /// It asserts the repair directly — the input's own provenance is honoured when the caller
    /// passes no parameter — so reverting `selection ?? input.selection` fails it.
    @MainActor
    func testTheInputProvenanceIsHonouredWhenTheParameterIsAbsent() async throws {
        let capture = FakeAudioCapture()
        let assembly = VoiceControlAssembly()
        guard let service = assembly.buildVoiceControlService(capture: capture) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try XCTSkipUnless(
            service.isListening,
            "the gate did not reach .listening, so the handler would return at its own guard"
        )

        let readyDeadline = Date().addingTimeInterval(20)
        while Date() < readyDeadline {
            if service.intentRouterIsReadyForTesting { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try XCTSkipUnless(service.intentRouterIsReadyForTesting, "the router never became ready")

        service.gracePeriodSignalForTesting.onWakeWordDetected()
        XCTAssertTrue(service.gracePeriodSignalForTesting.isActive, "the window did not open")

        let sink = service.executorForTesting.cloudRouteSinkForTesting
        // The PARAMETER is deliberately omitted: that is the caller shape the repair exists for.
        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: "what did the host mean by that remark",
                selection: .wakeWord
            )
        )

        let reached = await MainActor.run { sink.lastSelectionForTesting }
        XCTAssertEqual(
            reached, .wakeWord,
            "the input's own provenance was discarded when no parameter was passed, so the turn "
                + "fell through to the sink's live-state provider"
        )
    }

    /// Delivers audio through the capture so the REAL registered path runs rather than a direct
    /// handler call.
    private func driveRegisteredCallback(capture: FakeAudioCapture) async {
        // A VAD-closing envelope: ENERGY ABOVE THRESHOLD for long enough to confirm speech, then
        // a real SILENCE tail. A constant tone never closes a segment — the segmenter only emits
        // once silence has persisted past `silenceTimeoutMs` — so emitting one would leave the
        // case asserting about a turn that could not exist.
        //
        // The assembly's segmenter uses threshold 0.020, so the speech frames sit well above it,
        // and the silence tail is genuinely silent rather than merely quieter.
        // ONE FRAME PER CALL, because `minSpeechFrames` counts CALLS, not samples. The segmenter
        // confirms speech only after 5 consecutive above-threshold frames, so a single large
        // buffer is one frame and can never trigger — which is why the previous fixture produced
        // no turn regardless of the envelope. The capture delivers buffer-sized chunks, so this
        // matches what the real one does.
        let frameSize = 1_600                                            // 100 ms at 16 kHz
        for _ in 0..<20 {                                                // 2s of speech: > 5 frames
            capture.emit(samples: [Float](repeating: 0.05, count: frameSize), at: nil)
        }
        // The silence window is WALL-CLOCK (`Date()`), not sample count, so the quiet frames have
        // to be spread across real time. Delivering them back-to-back elapses microseconds and the
        // 500 ms condition never becomes true — which is why the segment never emitted.
        for _ in 0..<8 {                                                 // 800 ms of real silence
            capture.emit(samples: [Float](repeating: 0.0, count: frameSize), at: nil)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
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

        // The escalation runs on the service's SERIAL task, which is still awaiting routing when
        // the emits return. Polling for the turn rather than checking once is what makes this a
        // measurement of the path instead of a race with it.
        var delivered: CloudConversationSelection?
        let turnDeadline = Date().addingTimeInterval(10)
        while Date() < turnDeadline {
            delivered = await MainActor.run { sink.lastSelectionForTesting }
            if delivered != nil { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
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
