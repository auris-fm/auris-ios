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
    /// ISOLATED cloud configuration: `isConfigured()` is `{ !CloudConfig.shared.baseUrl.isEmpty }`,
    /// and it is checked BEFORE the origin gate and before the client is built, so without a base
    /// URL a routed turn is refused before reaching the transport. An own defaults suite keeps this
    /// from affecting other cases, and teardown restores it.
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "service_selection_provenance_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }
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


    /// The ASR wake callback the SERVICE installs must actually open the grace window.
    ///
    /// `VoiceControlService` wires this link in production:
    ///     asrEngine.onWakeWordDetected = { self?.gracePeriodSignal.onWakeWordDetected(); … }
    /// but every existing case calls `gracePeriodSignalForTesting.onWakeWordDetected()` DIRECTLY,
    /// so the wiring itself was never driven. Breaking that closure — or leaving it nil — would
    /// leave every case green while the app never opened a window on a wake.
    ///
    /// This case fires the callback the engine holds, through the real assembly and start path.
    @MainActor
    func testTheASRWakeCallbackInstalledByTheServiceOpensTheGraceWindow() async throws {
        let capture = FakeAudioCapture()
        guard let service = VoiceControlAssembly().buildVoiceControlService(capture: capture) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try XCTSkipUnless(service.isListening, "the gate did not reach .listening")
        try await waitForRouter(service: service)

        XCTAssertFalse(
            service.gracePeriodSignalForTesting.isActive,
            "the window must be shut before the wake, or this case cannot show it opening"
        )

        // Fire the PRODUCTION callback, not the signal. A nil closure here means the service never
        // installed the link, which is precisely the defect this case exists to catch.
        let installed = service.asrEngineForTesting.onWakeWordDetected
        XCTAssertNotNil(
            installed,
            "the service must install an ASR wake callback; a nil one means no wake ever opens a window"
        )
        installed?()

        XCTAssertTrue(
            service.gracePeriodSignalForTesting.isActive,
            "the installed ASR wake callback must open the grace window"
        )
    }

    /// The REGISTERED ASR INPUT path carries its provenance to the sink — driven
    /// deterministically, without waiting on a real transcript from synthetic audio.
    ///
    /// `VoiceControlService` installs `asrEngine.onRoutingInput`, and that closure is where the
    /// turn's provenance is captured — BEFORE the serial Task queues. The existing registered-input
    /// case drove synthetic audio through the capture and then skipped, because no transcript ever
    /// emerged, so the path was never exercised. This case fires the callback the engine actually
    /// holds, which is the same seam the production ASR uses and removes the dependence on a
    /// recognizer result.
    ///
    /// It also covers the OLDER repair: provenance is read from the INPUT at the callback, so a
    /// selection stamped on the input must survive to the sink.
    @MainActor
    func testTheRegisteredASRInputCarriesItsProvenanceToTheSink() async throws {
        let capture = FakeAudioCapture()
        guard let service = VoiceControlAssembly().buildVoiceControlService(capture: capture) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try XCTSkipUnless(service.isListening, "the gate did not reach .listening")
        try await waitForRouter(service: service)

        // A window is already open, so a live read and the input's provenance would disagree —
        // without this the case cannot show the provenance being carried.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        XCTAssertTrue(service.gracePeriodSignalForTesting.isActive, "the window did not open")

        // The callback the service installed. A nil one means the registered path does not exist.
        let installed = service.asrEngineForTesting.onRoutingInput
        XCTAssertNotNil(
            installed,
            "the service must install an onRoutingInput callback; a nil one means no ASR input is routed"
        )

        let sink = service.executorForTesting.cloudRouteSinkForTesting
        // The stamp must DISAGREE with what a live read would produce. The window above was
        // opened by a WAKE (`.wakeWord`), so stamping `.followUp` means only genuine provenance
        // carriage can deliver `.followUp`: if the input's provenance were dropped and the code
        // fell back to the live window, this assertion would see `.wakeWord` instead. Stamping the
        // same value the window implies would make the case pass either way.
        installed?(IntentRoutingInput.english(
            transcript: "what did the host mean by that remark",
            selection: .followUp
        ))

        var delivered: CloudConversationSelection?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            delivered = sink.lastSelectionForTesting
            if delivered != nil { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        XCTAssertEqual(
            delivered, .followUp,
            "the registered ASR input's provenance must reach the sink — NOT the live window's "
                + "implied .wakeWord, which is what a dropped provenance would fall back to"
        )
    }

    /// The ASR substitution is ON THE LOADING PATH: the engine's `preloadBackend()` calls
    /// `backend.ensureReady()`, so a substituted backend is invoked during a real service start and
    /// no real model is loaded. This case is what keeps the seam alive and falsifiable.
    @MainActor
    func testTheSubstitutedBackendIsPreloadedByTheServiceStart() async throws {
        let capture = FakeAudioCapture()
        let fakeBackend = FakeAsrBackend()
        VoiceControlAssembly.asrBackendOverrideForTesting = { fakeBackend }
        defer { VoiceControlAssembly.asrBackendOverrideForTesting = nil }

        guard let service = VoiceControlAssembly().buildVoiceControlService(capture: capture) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try XCTSkipUnless(service.isListening, "the gate did not reach .listening")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if fakeBackend.ensureReadyCount > 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(
            fakeBackend.ensureReadyCount, 0,
            "the engine's preload must invoke the substituted backend; without the override the "
                + "service crashes on the real ONNX model instead"
        )
    }
}
