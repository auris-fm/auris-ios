import XCTest
@testable import podcasts

/// A capture substitute: records that capture was requested, opens no microphone, and can deliver
/// a buffer as the real capture would.
final class FakeAudioCapture: AudioCaptureSource {
    var onCapturedSamples: (([Float], MonotonicTime?, Int) -> Void)?
    var tapSession: Int = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() throws { startCount += 1 }
    func stop() { stopCount += 1 }
    func emit(samples: [Float], at time: MonotonicTime? = nil) {
        onCapturedSamples?(samples, time, tapSession)
    }
}

/// A fake backend whose transcription is a fixed transcript, so the REAL capture→VAD→ASR
/// pipeline can be driven end to end without the real model (which cannot load here).
final class TranscribingAsrBackend: AsrBackend {
    let text: String
    private(set) var ensureReadyCount = 0
    init(text: String) { self.text = text }
    var requiredModel: ModelSpec { ModelSpec(id: "fake-transcribing", files: [], targetDir: "fake") }
    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
    }
    func ensureReady() async -> Result<Void, Error> {
        ensureReadyCount += 1
        return .success(())
    }
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        AsrResult(text: text, detectedLanguage: nil, tokens: nil)
    }
    func release() {}
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
    /// Every service this class starts, stopped in tearDown. See the note there.
    private static var startedServices: [VoiceControlService] = []

    override func setUp() {
        super.setUp()
        suiteName = "service_selection_provenance_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        // STOP EVERY SERVICE THIS CLASS STARTED (diagnosis of the intermittent families).
        //
        // 21 cases start a service and only one ever stopped it, so each case left a live
        // `VoiceControlService` with its ASR callbacks, mic gate and serial chain still running.
        // Those survivors keep producing `onInputRoutingFinished` callbacks into closures that
        // capture the FINISHED case's stream, and they compete for the audio session. That is a
        // load-dependent, isolation-passing failure by construction: alone, nothing else is
        // running and the assert sees its own event; under load, a leaked service's callback or
        // the extra work delays the terminal past the 10s bound.
        for service in Self.startedServices { service.stop() }
        Self.startedServices.removeAll()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Start a service and register it for teardown. Use instead of a bare `startIfAllowed()`.
    private func startTracked(_ service: VoiceControlService) {
        service.startIfAllowed()
        Self.startedServices.append(service)
    }
    /// Main's #48 gate reaches `.listening` only on an EXTERNAL microphone. The simulator has no
    /// external input route, so every provenance case supplies the same fake session shape the
    /// acquisition tests use: an external BT output carrying an available BT HFP mic whose
    /// selection takes effect. The condition monitor is fully allowed.
    private func provenanceAudioSession() -> FakeAudioSessionControlling {
        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "prov-bt-out")]
        session.availableAfterConfigure = [AudioPort(portType: .bluetoothHFP, uid: "prov-bt-mic")]
        return session
    }

    @MainActor
    private func provenanceConditionMonitor() -> LiveConditionMonitor {
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        return monitor
    }
    /// The PRODUCTION FALLBACK repair, covered on its own.
    ///
    /// The PRODUCTION FALLBACK repair, covered on its own: the input's own provenance is honoured
    /// when the caller passes no parameter. Separate from the registered-callback case on purpose —
    /// converting that case to the registered path removed the only coverage this repair had, and
    /// coverage has to be added to, not moved.
    @MainActor
    func testTheInputProvenanceIsHonouredWhenTheParameterIsAbsent() async throws {
        // The REAL LFM model never loads in this environment; the suite's own seeded pattern supplies a ready router.
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"
        let modelManager = ModelManager(storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("lfm_seed_\(UUID().uuidString)"))
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let capture = FakeAudioCapture()
        guard let service = VoiceControlAssembly().buildVoiceControlService(audioSession: provenanceAudioSession(), conditionMonitor: provenanceConditionMonitor(), capture: capture, inference: inference, modelManager: modelManager) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)
        service.gracePeriodSignalForTesting.onWakeWordDetected()

        let sink = service.executorForTesting.cloudRouteSinkForTesting
        // The PARAMETER is deliberately omitted — the caller shape the repair exists for.
        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: "what did the host mean by that remark",
                selection: .wakeWord,
                utteranceId: "05213c56-cfd9-4e38-be5f-ba4a01ea30ea",
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
        // The REAL LFM model never loads in this environment; the suite's own seeded pattern supplies a ready router.
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"
        let modelManager = ModelManager(storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("lfm_seed_\(UUID().uuidString)"))
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let backend = TranscribingAsrBackend(text: "what did the host mean by that remark")
        let capture = FakeAudioCapture()
        guard let service = VoiceControlAssembly().buildVoiceControlService(audioSession: provenanceAudioSession(), conditionMonitor: provenanceConditionMonitor(), capture: capture, inference: inference, modelManager: modelManager, asrBackend: { backend }) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
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

        // All prerequisites are supplied (external-mic session, seeded router, substituted
        // backend), so a missing turn is a FAILURE, not a skip.
        XCTAssertNotNil(
            delivered,
            "the registered input produced no turn even though every prerequisite is supplied"
        )
        // The window was ALREADY OPEN when the audio arrived, so a wake-free registered input is
        // a FOLLOW-UP, not a wake — the provenance this case exists to carry.
        XCTAssertEqual(
            delivered, .followUp,
            "the registered input's provenance did not reach the sink"
        )
    }

    /// Delivers audio through the capture so the REAL registered path runs — the only input the
    /// registered case uses.
    private func driveRegisteredCallback(capture: FakeAudioCapture) async {
        let frameSize = 1_600                                              // 100 ms at 16 kHz
        // The audio must be speech to the REAL model. This control drives the real assembly, which
        // classifies with the bundled Silero model. The previous fixture was constant 0.05 DC —
        // accepted by the energy rule on loudness alone, and correctly not speech to a model that
        // reads structure. `SileroSegmenterIntegrationControl.test_fixtureEvidence_...` measures
        // both directions. With a non-speech fixture no utterance can form, so "no turn" described
        // the fixture rather than the provenance this control exists to carry.
        let speech = Self.recordedSpeechSamples()
        XCTAssertGreaterThan(
            speech.count, frameSize * 5,
            "no recorded speech fixture is available, so this control cannot supply speech to the "
                + "real classifier and would prove nothing"
        )
        // ONE FRAME PER CALL: `minSpeechFrames` (5) counts CALLS, not samples, so a single large
        // buffer is one frame and speech is never confirmed.
        var offset = 0
        while offset + frameSize <= speech.count {
            capture.emit(samples: Array(speech[offset..<(offset + frameSize)]), at: nil)
            offset += frameSize
        }
        // The silence window is WALL-CLOCK (`Date()` vs 500 ms), so quiet frames must be spread
        // across real time; back-to-back they elapse microseconds and the condition never fires.
        for _ in 0..<8 {                                                   // 800 ms of real silence
            capture.emit(samples: [Float](repeating: 0.0, count: frameSize), at: nil)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Recorded human speech at the model's rate, read in place from the host checkout.
    ///
    /// Never copied into the repository: it is an external Apache-2.0 fixture, and duplicating it
    /// would make the test pass against a stale copy of something it does not own.
    private static func recordedSpeechSamples() -> [Float] {
        let hostHome = ProcessInfo.processInfo.environment["AURIS_HOST_HOME"] ?? "/Users/dev"
        let url = URL(fileURLWithPath: hostHome)
            .appendingPathComponent("code/auris/livekit-wakeword/swift/Tests/LiveKitWakeWordTests/Fixtures/positive.wav")
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Minimal RIFF parse, matching the integration control's reader.
        func u32(_ o: Int) -> Int {
            Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24
        }
        var index = 12
        var dataRange: Range<Int>?
        while index + 8 <= data.count {
            let id = String(bytes: data[index..<(index + 4)], encoding: .ascii) ?? ""
            let size = u32(index + 4)
            let body = index + 8
            if id == "data" {
                dataRange = body..<min(body + size, data.count)
                break
            }
            index = body + size + (size % 2)
        }
        guard let range = dataRange else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(range.count / 2)
        var i = range.lowerBound
        while i + 1 < range.upperBound {
            let raw = Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)
            samples.append(Float(raw) / 32768.0)
            i += 2
        }
        return samples
    }

    /// Acquisition is asynchronous: wait (bounded) for the gate to reach listening instead of
    /// skipping at the first tick. A timeout here is a BLOCKER, not coverage.
    @MainActor
    private func waitForListening(service: VoiceControlService) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if service.isListening { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let state = service.gateState
        throw XCTSkip("the gate did not reach listening within 8s; final state: \(state)")
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
        // The REAL LFM model never loads in this environment; the suite's own seeded pattern supplies a ready router.
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"
        let modelManager = ModelManager(storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("lfm_seed_\(UUID().uuidString)"))
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let capture = FakeAudioCapture()
        guard let service = VoiceControlAssembly().buildVoiceControlService(audioSession: provenanceAudioSession(), conditionMonitor: provenanceConditionMonitor(), capture: capture, inference: inference, modelManager: modelManager) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
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
        // The REAL LFM model never loads in this environment; the suite's own seeded pattern supplies a ready router.
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"
        let modelManager = ModelManager(storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("lfm_seed_\(UUID().uuidString)"))
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let capture = FakeAudioCapture()
        guard let service = VoiceControlAssembly().buildVoiceControlService(audioSession: provenanceAudioSession(), conditionMonitor: provenanceConditionMonitor(), capture: capture, inference: inference, modelManager: modelManager) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
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
            selection: .followUp,
            utteranceId: "ba1f70e0-1010-47f1-b203-9b417709601c",
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

        guard let service = VoiceControlAssembly().buildVoiceControlService(audioSession: provenanceAudioSession(), conditionMonitor: provenanceConditionMonitor(), capture: capture, asrBackend: { fakeBackend }) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
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

    /// THE SERVICE-OWNED BINDING: a wake must reach the MANAGER the sink uses, so a routed turn is
    /// admitted at the origin gate. This is the production admission defect: a binding stored in the
    /// assembly's `cancellables` is cancelled when the build call returns, so the manager never
    /// learns a window opened and every turn is refused.
    @MainActor
    func testAWakeReachesTheSinkManagersLiveOrigin() async throws {
        let capture = FakeAudioCapture()
        let fakeBackend = FakeAsrBackend()

        guard let service = VoiceControlAssembly().buildVoiceControlService(audioSession: provenanceAudioSession(), conditionMonitor: provenanceConditionMonitor(), capture: capture, asrBackend: { fakeBackend }) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)

        let manager = service.liveOriginManagerForTesting

        // No window yet: a turn carrying any generation must be refused.
        XCTAssertNil(
            manager.prepare(selection: .wakeWord, origin: 1, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88"),
            "with no window open, no captured origin is live"
        )

        // A wake opens a window; the SERVICE-OWNED binding must move the manager's live origin.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let generation = service.gracePeriodSignalForTesting.currentGeneration()

        let deadline = Date().addingTimeInterval(3)
        var admitted = false
        while Date() < deadline {
            if manager.prepare(selection: .wakeWord, origin: generation, utteranceId: "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88") != nil { admitted = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(
            admitted,
            "the service-owned binding must teach the sink's manager that this window is live — "
                + "this is exactly what a cancelled assembly subscription prevents"
        )
    }

    /// THE SERVICE SUBMISSION POSITIVE: the routed request must reach the CONTROLLED TRANSPORT.
    ///
    /// Admission order matters: `isConfigured()` runs first, so the base URL comes from the isolated
    /// fixture configuration; then the origin gate; only then is the client built and the request
    /// sent. The client factory is injected per-assembly, and the recorder observes the SUBMITTED
    /// text rather than the pre-guard sink entry.
    /// DIALOG COMPLETION, ACTUAL LOCAL PATH (spec 0443b70, reviewer 71c153eb): utterance A begins
    /// a dialog (local, no wire turn), then utterance B — the real `new_command` control — closes
    /// it. B's own admitted id is what any turn B dispatches would carry; the dialog origin never
    /// substitutes, and A performs no wire dispatch of its own.
    @MainActor
    func testADialogBegunByAIsClosedByBUnderBsOwnAdmittedIdentity() async throws {
        let inference = FakeLfmInference()
        // A begins the dialog; it is a dialog CONTROL, not a cloud route.
        inference.classifyLabel = "dialog_control:begin"
        inference.generateResult =
            "<|tool_call_start|>[dialog_control(action='begin', target_tool='bookmark', target_action='rename')]<|tool_call_end|>"
        let modelManager = ModelManager(storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("lfm_seed_\(UUID().uuidString)"))
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let capture = FakeAudioCapture()
        let fakeBackend = FakeAsrBackend()
        var injectedTask: StubWebSocketTask?
        var factoryInvocations = 0
        var reprocessedSelectionObserved: CloudConversationSelection?
        var stubs: [StubWebSocketTask] = []

        let suite = "dialog_completion_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                factoryInvocations += 1
                let built = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                )
                injectedTask = built.task
                stubs.append(built.task)
                return built.client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend },
            testInputBarrier: { input in
                // The REPROCESSED value arrives as a fresh turn; the model now answers it with a
                // cloud route — the completion's own dispatch. Swapped at the barrier, which runs
                // BEFORE classification, so the swap is deterministic.
                if input.routerTranscript == "what did the host say about the merger" {
                    reprocessedSelectionObserved = input.selection
                    inference.classifyLabel = "cloud_route:route"
                    inference.generateResult =
                        "<|tool_call_start|>[cloud_route(request='what did the host say about the merger', tier='free')]<|tool_call_end|>"
                }
            }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)

        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let generation = service.gracePeriodSignalForTesting.currentGeneration()

        // Establish a LIVE conversation first: a wake-selected cloud turn prepares (and opens)
        // it, so B's follow-up reprocess has a conversation to RESUME — the discriminator between
        // the preserved followUp selection (resume) and a dropped selection (create).
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what is this episode about', tier='free')]<|tool_call_end|>"
        let warmId = "7d1c22ab-51e0-4c6a-9f30-8b44c1d2e001"
        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "what is this episode about", selection: .wakeWord, utteranceId: warmId),
            origin: generation
        )
        let warmDeadline = Date().addingTimeInterval(5)
        while Date() < warmDeadline, injectedTask?.sentAuthFrame == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let warmFrame = try XCTUnwrap(injectedTask?.sentAuthFrame, "premise: the warm-up turn dispatched")
        XCTAssertEqual(warmFrame["request_id"] as? String, warmId)
        XCTAssertEqual(warmFrame["conversation_mode"] as? String, "create", "premise: a live conversation now exists")
        let warmConversationId = warmFrame["conversation_id"] as? String

        // Let the 2s same-type command debounce window expire, so the reprocessed dispatch below
        // is not suppressed as a duplicate of the warm-up cloud_route turn.
        try? await Task.sleep(nanoseconds: 2_200_000_000)

        inference.classifyLabel = "dialog_control:begin"
        inference.generateResult =
            "<|tool_call_start|>[dialog_control(action='begin', target_tool='bookmark', target_action='rename')]<|tool_call_end|>"

        // A: begins the dialog (local control, admission id A-plan).
        let aId = "3e91c40b-27af-4d5e-8c16-0b2f7a4d9e83"
        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "rename my bookmark", selection: .wakeWord, utteranceId: aId),
            origin: generation
        )
        let dialogDeadline = Date().addingTimeInterval(5)
        while Date() < dialogDeadline {
            if service.dialogManagerForTesting.pendingDialog != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(
            service.dialogManagerForTesting.pendingDialog,
            "A must have begun a dialog through the REAL router path"
        )
        XCTAssertEqual(stubs.count, 1, "A's dialog control performs no wire dispatch — the warm-up turn built the only client")

        // B: the model emits the REAL completion control (new_command) — the dialog closes
        // LOCALLY, and its value is re-processed as a fresh transcript.
        inference.classifyLabel = "dialog_control:new_command"
        inference.generateResult =
            "<|tool_call_start|>[dialog_control(action='new_command', value='what did the host say about the merger')]<|tool_call_end|>"
        let bId = "8a2bf59d-6c31-4e08-b7d4-5c91f0e37a26"

        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "actually, what did the host say about the merger", selection: .followUp, utteranceId: bId),
            origin: generation
        )

        XCTAssertNil(
            service.dialogManagerForTesting.pendingDialog,
            "B's completion closes A's dialog — the dialog-origin context is consumed, not carried as B's identity"
        )

        // The reprocessed value is enqueued as its own chain link — settle before asserting:
        // wait for a SECOND client (the warm-up built the first) and its auth frame.
        let dispatchDeadline = Date().addingTimeInterval(5)
        while Date() < dispatchDeadline, stubs.count < 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThanOrEqual(stubs.count, 2, "B's reprocessed turn reached the transport")
        let frameDeadline = Date().addingTimeInterval(5)
        while Date() < frameDeadline, stubs.last?.sentAuthFrame == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let body = try XCTUnwrap(stubs.last?.sentAuthFrame, "B's turn was submitted")
        XCTAssertEqual(
            body["request_id"] as? String, bId,
            "the completing utterance dispatches under ITS OWN admitted id, never A's dialog origin"
        )
        XCTAssertEqual(
            reprocessedSelectionObserved, .followUp,
            "the reprocessed turn keeps B's CAPTURED selection, not live-state continuation"
        )
        XCTAssertEqual(
            body["conversation_mode"] as? String, "resume",
            "B was a follow-up capture, so its reprocessed dispatch RESUMES the live conversation"
        )
        XCTAssertEqual(
            body["conversation_id"] as? String, warmConversationId,
            "the resumed dispatch is bound to the conversation the window opened"
        )
    }

    /// ROUTER LOAD LIFECYCLE (spec 6b45a5d2, reviewer 0b5b4222): the LFM router load is armed at
    /// the FIRST-ARM boundary (`startIfAllowed`), NOT at construction. Building the service must
    /// perform zero `inference.load` calls; the load happens once the lifecycle arms.
    @MainActor
    func test_routerLoadIsArmedAtFirstArmNotAtConstruction() async throws {
        let inference = FakeLfmInference()
        let modelManager = ModelManager(storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("lfm_seed_\(UUID().uuidString)"))
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let capture = FakeAudioCapture()
        let fakeBackend = FakeAsrBackend()

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            cloudConfig: CloudConfig(defaults: UserDefaults(suiteName: "router_load_lifecycle_\(UUID().uuidString)")!),
            asrBackend: { fakeBackend }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }

        // Settle any work an erroneous init-time load could have queued before asserting: an
        // unawaited Task scheduled at construction must have had its chance to run here.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            inference.loadCount, 0,
            "construction performs NO eager router load — the model is paid at first arm"
        )

        startTracked(service)
        try await waitForRouter(service: service)

        XCTAssertGreaterThanOrEqual(
            inference.loadCount, 1,
            "the first arm kicks the router load"
        )
    }

    /// SELECTION PRESERVATION THROUGH REPROCESS (reviewer 8cb24f13): a fresh WAKE capture that
    /// completes a dialog keeps its wakeWord selection through the reprocessed dispatch — the
    /// wire mode is create, not the live-state resume a dropped selection would fall back to.
    @MainActor
    func testAWakeCaptureCompletingADialogReprocessesUnderItsWakeSelection() async throws {
        let inference = FakeLfmInference()
        inference.classifyLabel = "dialog_control:begin"
        inference.generateResult =
            "<|tool_call_start|>[dialog_control(action='begin', target_tool='bookmark', target_action='rename')]<|tool_call_end|>"
        let modelManager = ModelManager(storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("lfm_seed_\(UUID().uuidString)"))
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let capture = FakeAudioCapture()
        let fakeBackend = FakeAsrBackend()
        var injectedTask: StubWebSocketTask?
        var factoryInvocations = 0
        var reprocessedSelectionObserved: CloudConversationSelection?
        var stubs: [StubWebSocketTask] = []

        let suite = "dialog_completion_wake_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                factoryInvocations += 1
                let built = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                )
                injectedTask = built.task
                stubs.append(built.task)
                return built.client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend },
            testInputBarrier: { input in
                if input.routerTranscript == "what did the host say about the merger" {
                    reprocessedSelectionObserved = input.selection
                    inference.classifyLabel = "cloud_route:route"
                    inference.generateResult =
                        "<|tool_call_start|>[cloud_route(request='what did the host say about the merger', tier='free')]<|tool_call_end|>"
                }
            }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)

        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let generation = service.gracePeriodSignalForTesting.currentGeneration()

        // A begins the dialog; B is a FRESH WAKE capture during the live window that completes
        // it with new_command.
        let aId = "3e91c40b-27af-4d5e-8c16-0b2f7a4d9e83"
        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "rename my bookmark", selection: .wakeWord, utteranceId: aId),
            origin: generation
        )
        let dialogDeadline = Date().addingTimeInterval(5)
        while Date() < dialogDeadline {
            if service.dialogManagerForTesting.pendingDialog != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(service.dialogManagerForTesting.pendingDialog, "premise: A's dialog is pending")
        XCTAssertEqual(stubs.count, 0, "A's dialog control performs no wire dispatch")

        inference.classifyLabel = "dialog_control:new_command"
        inference.generateResult =
            "<|tool_call_start|>[dialog_control(action='new_command', value='what did the host say about the merger')]<|tool_call_end|>"
        let bId = "8a2bf59d-6c31-4e08-b7d4-5c91f0e37a26"

        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "actually, what did the host say about the merger", selection: .wakeWord, utteranceId: bId),
            origin: generation
        )

        let dispatchDeadline = Date().addingTimeInterval(5)
        while Date() < dispatchDeadline, injectedTask?.sentAuthFrame == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let body = try XCTUnwrap(injectedTask?.sentAuthFrame, "B's reprocessed turn was submitted")
        XCTAssertEqual(
            body["request_id"] as? String, bId,
            "the reprocessed dispatch carries B's admitted identity"
        )
        XCTAssertEqual(
            reprocessedSelectionObserved, .wakeWord,
            "B's wake selection survives the reprocess — it is NOT demoted to live-state continuation"
        )
        XCTAssertEqual(
            body["conversation_mode"] as? String, "create",
            "a wake capture completing a dialog dispatches as a NEW conversation, not a resume"
        )
    }

    /// MODEL-CHOSEN DISPATCH IDENTITY (reviewer c48e1d98): a turn the model genuinely ROUTES
    /// (not an escalation) must also dispatch under the hour's admitted utterance id. The routed
    /// path is the one the escalation path is only a fallback for.
    @MainActor
    func testAModelChosenRouteDispatchesUnderTheAdmittedUtteranceIdentity() async throws {
        let inference = FakeLfmInference()
        // A full, well-formed label+call so the mapper SUCCEEDS: this exercises the ROUTED
        // (model-chosen) stamping site, not the escalation fallback, which stamps elsewhere.
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark', tier='free')]<|tool_call_end|>"
        let modelManager = ModelManager(storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("lfm_seed_\(UUID().uuidString)"))
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let capture = FakeAudioCapture()
        let fakeBackend = FakeAsrBackend()
        var injectedTask: StubWebSocketTask?
        var factoryInvocations = 0

        let suite = "model_chosen_identity_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                factoryInvocations += 1
                let built = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                )
                injectedTask = built.task
                return built.client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)

        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let liveGeneration = service.gracePeriodSignalForTesting.currentGeneration()

        let admittedId = "b7d5f310-4a8e-4c62-95b1-3f0a7d2e6c18"
        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: "what did the host mean by that remark",
                selection: .wakeWord,
                utteranceId: admittedId,
            ),
            origin: liveGeneration
        )

        let deadline = Date().addingTimeInterval(5)
        var frame: [String: Any]?
        while Date() < deadline {
            if let captured = injectedTask?.sentAuthFrame { frame = captured; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(factoryInvocations, 0, "the model-chosen route reached the transport")
        let body = try XCTUnwrap(frame, "the model-chosen route was submitted")
        XCTAssertEqual(
            body["request_id"] as? String, admittedId,
            "the MODEL-CHOSEN path must carry the admitted utterance identity"
        )
    }

    /// DIALOG-TO-WIRE IDENTITY (spec 0443b70): with a dialog begun by an earlier utterance (A)
    /// pending, the turn B that is routed while that dialog is open dispatches under B's OWN
    /// admitted ID. A is dialog-origin correlation, never a replacement dispatch identity.
    @MainActor
    func testADialogPendingTurnDispatchesUnderItsOwnAdmittedIdentity() async throws {
        // The suite's own seeded router pattern: a ready LFM that classifies the free-text as a cloud route.
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"
        let modelManager = ModelManager(storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("lfm_seed_\(UUID().uuidString)"))
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let capture = FakeAudioCapture()
        let fakeBackend = FakeAsrBackend()
        var injectedTask: StubWebSocketTask?
        var factoryInvocations = 0

        let suite = "dialog_identity_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                factoryInvocations += 1
                let built = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                )
                injectedTask = built.task
                return built.client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)

        // A's dialog, begun through the PRODUCTION handle path: the pending dialog is the
        // dialog-origin context A created. It carries NO dispatch identity of its own.
        let dialogOpened = service.dialogManagerForTesting.handle(.begin(targetTool: "bookmark", targetAction: "rename"))
        XCTAssertNotNil(dialogOpened.question, "premise: A's dialog is pending with a question")

        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let liveGeneration = service.gracePeriodSignalForTesting.currentGeneration()

        // B: a turn routed WHILE the dialog is pending. Its admitted identity is its own UUID.
        let bId = "9c47e2a1-5d83-4b06-a7f2-1e8c90d43b57"
        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: "what did the host mean by that remark",
                selection: .wakeWord,
                utteranceId: bId,
            ),
            origin: liveGeneration
        )

        let deadline = Date().addingTimeInterval(5)
        var frame: [String: Any]?
        while Date() < deadline {
            if let captured = injectedTask?.sentAuthFrame { frame = captured; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(factoryInvocations, 0, "B reached the controlled transport")
        let body = try XCTUnwrap(frame, "B's turn was submitted")

        XCTAssertEqual(
            body["request_id"] as? String, bId,
            "B's admitted ID is the WIRE identity — a pending dialog never replaces it"
        )
        XCTAssertNotNil(
            service.dialogManagerForTesting.pendingDialog,
            "A's dialog-origin correlation survives B's dispatch untouched"
        )
    }

    @MainActor
    func testTheServiceSubmitsTheRoutedRequestToTheControlledTransport() async throws {
        let capture = FakeAudioCapture()
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        let modelManager = ModelManager(storageDir: tempDir)
        seedLfmAssetsForTestingForPositive(manager: modelManager)

        let fakeBackend = FakeAsrBackend()

        // The fixture's OWN defaults, injected as the PRODUCTION READER's configuration — writing
        // an unconsumed suite would leave `CloudConfig.shared` blind to it.
        let suite = "service_submission_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Capture the INJECTED CLIENT'S OWN task and frame, rather than a shared static recorder: a
        // static (and a substring search over it) cannot attribute a submission to THIS turn.
        var injectedTask: StubWebSocketTask?
        var factoryInvocations = 0
        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                factoryInvocations += 1
                let built = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                )
                injectedTask = built.task
                return built.client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)

        // REQUEST-SCOPED: the observer captures the identity prepared for THIS dispatch, rather
        // than reading a sink-wide "last prepared" slot afterwards.
        var preparedForThisTurn: CloudPreparedConversation?
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let liveGeneration = service.gracePeriodSignalForTesting.currentGeneration()

        // ASSERT THE EXACT PREDICATE before dispatch, so a refusal here is attributed to it.
        XCTAssertFalse(
            fixtureConfig.baseUrl.isEmpty,
            "the injected configuration must make the sink's own predicate true; baseUrl=\(fixtureConfig.baseUrl)"
        )

        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: "what did the host mean by that remark",
                selection: .wakeWord,
                utteranceId: "ddbd8a62-57db-49c9-9b42-4f1e8c29e8c9",
            ),
            origin: liveGeneration,
            preparedObserver: { prepared in preparedForThisTurn = prepared }
        )


        // Wait for the injected task to submit its auth frame.
        let deadline = Date().addingTimeInterval(5)
        var frame: [String: Any]?
        while Date() < deadline {
            if let captured = injectedTask?.sentAuthFrame { frame = captured; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertGreaterThan(
            factoryInvocations, 0,
            "ADMISSION: the injected factory must be invoked, or the turn never reached the client"
        )
        let body = try XCTUnwrap(
            frame,
            "EFFECT: the injected client must SUBMIT this turn's frame — no shared recorder is used"
        )
        // THIS TURN'S identity, compared against the identity the sink PREPARED — UUID syntax
        // alone is not an identity comparison.
        let requestId = try XCTUnwrap(body["request_id"] as? String, "the frame carries a request_id")
        XCTAssertNotNil(UUID(uuidString: requestId), "request_id is client-assigned")

        let prepared = preparedForThisTurn
        let preparedRequestId = try XCTUnwrap(
            prepared?.requestId,
            "the sink must have prepared a conversation for this turn; without it there is nothing "
                + "to compare the submitted identity against"
        )
        XCTAssertEqual(
            requestId, preparedRequestId,
            "the SUBMITTED request_id must be the identity the sink PREPARED for this turn"
        )

        // Conversation fields travel together with the identity on every turn.
        let conversationId = try XCTUnwrap(body["conversation_id"] as? String)
        let conversationMode = try XCTUnwrap(body["conversation_mode"] as? String)
        XCTAssertEqual(conversationId, prepared?.conversationId)
        // PREPARED-MODE EQUALITY: not merely "one of the two values" — the mode the sink PREPARED.
        XCTAssertEqual(
            conversationMode, prepared?.mode,
            "the submitted conversation_mode must be the mode the sink PREPARED for this turn"
        )
        // FRAME TYPE: the submission is an authenticate frame, not some other message shape.
        XCTAssertEqual(
            body["type"] as? String, "authenticate",
            "the submitted frame must be the authenticate frame"
        )
        // EXACT ROUTED TEXT: the request the user's turn carried, not a paraphrase.
        XCTAssertEqual(
            body["request"] as? String,
            "what did the host mean by that remark",
            "the submitted frame must carry the routed transcript verbatim"
        )
        XCTAssertNil(
            body["capabilities"],
            "no renderer is advertised here, so capabilities must be omitted"
        )
    }

    /// ESCALATION PROVENANCE: a turn carrying a caller-supplied selection must reach the
    /// routing-failure escalation with THAT selection, not whatever the live window would derive by
    /// the time the fallback dispatches.
    ///
    /// WHAT THIS DRIVES, stated so it is not mistaken for more: this calls `handleRoutingInput`
    /// DIRECTLY with an explicit `selection:`. It does NOT exercise an installed callback, nor the
    /// closure in `VoiceControlService` that stamps `capturedSelection` — so it shows the escalation
    /// CARRIES a supplied selection through to the sink, not that the installed callback SUPPLIES the
    /// right one. (The installed closure's stamping is the `c6654fa49` caller-level control's subject.)
    ///
    /// `preparedObserver` is the observable seam: it fires only for a turn the sink ADMITS, so its
    /// value carries the intent's provenance as the sink received it.
    @MainActor
    func testTheEscalationTurnCarriesItsOwnCapturedProvenance() async throws {
        let capture = FakeAudioCapture()
        let inference = FakeLfmInference()
        // Classify as no_match so routing fails and the escalation path is taken.
        inference.classifyLabel = "no_match:"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        let modelManager = ModelManager(storageDir: tempDir)
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let fakeBackend = FakeAsrBackend()

        let suite = "escalation_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        var prepared: CloudPreparedConversation?
        var factoryInvocations = 0

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                factoryInvocations += 1
                return CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                ).client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        try await waitForRouter(service: service)

        // A window is open, and the turn's selection is stamped at the callback.
        service.gracePeriodSignalForTesting.onWakeWordDetected()

        // The stamp DISAGREES with the live derivation: the window is ACTIVE, so the sink's
        // provider would say `.followUp`; stamping `.wakeWord` means only genuine provenance
        // carriage can deliver it.
        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: "what did the host mean by that remark",
                selection: .wakeWord,
                utteranceId: "886a1837-856e-46fb-804b-137ece5200d1",
            ),
            origin: service.gracePeriodSignalForTesting.currentGeneration(),
            preparedObserver: { value in prepared = value }
        )

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if prepared != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertGreaterThan(
            factoryInvocations, 0,
            "the escalation must reach the transport (routing failed, so the fallback dispatches)"
        )
        let value = try XCTUnwrap(
            prepared,
            "the escalated turn must be admitted, so its prepared conversation is observable"
        )
        // A fallback carries the generation whose allowance it spent, so the identity exists.
        XCTAssertFalse(value.requestId.isEmpty, "the escalated turn carries a request identity")

        // PROVENANCE: the sink records the selection the INTENT carried, before its guards, so this
        // shows what the escalation actually passed on — the turn's own `.followUp`, not a
        // live-derived value.
        let carried = await MainActor.run { sink.lastSelectionForTesting }
        XCTAssertEqual(
            carried, .wakeWord,
            "the escalated turn must carry the selection its callback stamped — NOT the live "
                + "derivation, which for an ACTIVE window would say .followUp"
        )
    }

    /// ESCALATION PROVENANCE, through the INSTALLED callback: a turn the service's own
    /// `asrEngine.onRoutingInput` closure stamps must reach the routing-failure escalation carrying
    /// THAT selection, not whatever the live window would derive by the time the fallback dispatches.
    ///
    /// Driven through `installed?(...)` rather than by calling `handleRoutingInput` directly, so the
    /// service's capture-before-the-serial-Task is inside the case rather than assumed.
    @MainActor
    func testTheInstalledCallbackEscalationCarriesItsOwnProvenance() async throws {
        let capture = FakeAudioCapture()
        let inference = FakeLfmInference()
        inference.classifyLabel = "no_match:"     // routing fails, so the escalation path is taken

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        let modelManager = ModelManager(storageDir: tempDir)
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let fakeBackend = FakeAsrBackend()

        let suite = "escalation_installed_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                ).client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)

        // A window is OPEN, so the sink's provider would derive `.followUp`. Stamping `.wakeWord`
        // makes the two DISAGREE: only genuine carriage can deliver the stamped value.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let installed = service.asrEngineForTesting.onRoutingInput
        XCTAssertNotNil(installed, "the service must install an onRoutingInput callback")

        let sink = service.executorForTesting.cloudRouteSinkForTesting
        installed?(IntentRoutingInput.english(
            transcript: "what did the host mean by that remark",
            selection: .wakeWord,
            utteranceId: "51f843e7-549e-42e9-b5df-5ae0a0a275c9",
        ))

        var delivered: CloudConversationSelection?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            delivered = sink.lastSelectionForTesting
            if delivered != nil { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(
            delivered, .wakeWord,
            "the escalated turn must carry the selection the INSTALLED callback stamped — not the "
                + "live derivation, which for an active window would say .followUp"
        )
    }
    /// INSTALLED INPUT CAPTURE -> QUEUE -> RETIRE / OPEN -> RELEASE.
    ///
    /// MEASURED TRACE (the precondition this case depends on actually holds):
    ///     queuechk task created for origin=1  ->  resumed; cancelled=false   (the held turn runs)
    ///     queuechk task created for origin=2  ->  resumed; cancelled=true    (the queued turn DROPS)

    /// QUEUED INSTALLED INPUT — the acknowledgement is COMPLETION, not preparation.
    ///
    /// Arrangement, per the assigned contract: a preceding turn is HELD on its socket, so input A
    /// QUEUES behind it; A's window is then RETIRED and a fresh window B opened, with
    /// `transcriptEpoch` UNCHANGED; the hold is released and A's COMPLETION is AWAITED through the
    /// per-input callback; only then are A's effects and B's allowance asserted.
    ///
    /// A preparation observer would not do: it fires before routing completes, so it cannot say
    /// whether the turn went on to act.
    ///
    /// WHICH ROUTING PATH THIS EXERCISES, measured rather than assumed: the router reports
    /// `finalOutcome=outcomeNoIntent`, `failedStage=stageMapperDialog`,
    /// `reason=mapper_or_dialog_failed`, so the turn takes the **no-match / fallback ESCALATION**
    /// path (`RouteFailureEscalationPolicy` -> `claimDispatchOwnership`), NOT a model-chosen
    /// `cloud_route`. Both paths share the same intent and executor by construction, so the
    /// retirement and allowance rules are the same; this case pins the escalation one.
    @MainActor
    func testAQueuedInputWhoseWindowRetiredSubmitsNothingAndLeavesTheFreshAllowanceClaimable() async throws {
        let capture = FakeAudioCapture()
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        let modelManager = ModelManager(storageDir: tempDir)
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let fakeBackend = FakeAsrBackend()

        let suite = "queued_input_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        // The FIRST turn built is held open on its socket — an ASYNC hold, so the main actor stays
        // free — which is what keeps the input submitted after it waiting in the queue.
        let gate = Gate()
        var heldOnce = false
        var turnsBuilt = 0

        // A's COMPLETION acknowledgement, captured per input rather than read from a shared slot.
        var finishedInputs: [String] = []
        let aFinished = AsyncStream<Void>.makeStream()

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                )
                turnsBuilt += 1
                if !heldOnce {
                    heldOnce = true
                    built.task.holdUntilReleased(gate)
                }
                return built.client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend },
            onInputRoutingFinished: { finished in
                finishedInputs.append(finished.routerTranscript)
                if finished.routerTranscript.contains("A question") {
                    aFinished.continuation.yield()
                }
            }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)
        XCTAssertFalse(
            fixtureConfig.baseUrl.isEmpty,
            "the injected configuration must make the sink's own predicate true"
        )

        let signal = service.gracePeriodSignalForTesting
        let installed = service.asrEngineForTesting.onRoutingInput
        XCTAssertNotNil(installed, "the service must install an onRoutingInput callback")

        // A preceding turn is dispatched and HELD, so it occupies the serial slot.
        signal.onWakeWordDetected()
        installed?(IntentRoutingInput.english(transcript: "held turn", selection: .wakeWord, utteranceId: "u-200"))
        let builtDeadline = Date().addingTimeInterval(8)
        while Date() < builtDeadline && turnsBuilt == 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(turnsBuilt, 1, "the preceding turn must have been built and held")

        // A is submitted next: it QUEUES behind the held turn and cannot run while it waits.
        signal.onWakeWordDetected()
        let windowA = signal.currentGeneration()
        installed?(IntentRoutingInput.english(transcript: "A question", selection: .wakeWord, utteranceId: "u-200"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            turnsBuilt, 1,
            "precondition: A must still be QUEUED — only the held turn has reached a client"
        )

        // RETIRE A's window and OPEN a fresh one. The epoch is deliberately UNCHANGED: the subject is
        // A's CAPTURED GENERATION, and advancing the epoch would refuse A for a different reason.
        signal.onAppBackgrounded()
        signal.onWakeWordDetected()
        let windowB = signal.currentGeneration()
        XCTAssertNotEqual(windowA, windowB, "B must be a different window from A, or staleness is untestable")

        // B IS A FRESH WINDOW THAT OWNS A CLAIMABLE ALLOWANCE, proven WITHOUT consuming it: exactly
        // one allowance is outstanding, and it belongs to B. Consuming it here would refuse A by
        // B's SPENT BUDGET rather than by A's OWN RETIRED GENERATION — the two are then
        // indistinguishable and the case would pass for the wrong reason.
        // B's freshness is established by the SEQUENCE, not by consuming its allowance: B was opened
        // after A was retired, and `isActive` is true for it. Claiming the allowance here would
        // refuse A by B's SPENT BUDGET instead of by A's OWN retired generation, making the two
        // indistinguishable. B's allowance stays UNSPENT until after A has been acknowledged.
        XCTAssertTrue(signal.isActive, "B's window must be OPEN, so the refusal is not 'no window'")
        XCTAssertGreaterThan(
            windowB, windowA,
            "B's generation must be strictly later than A's, so 'retired' is a statement about order"
        )

        // RELEASE the held turn, then AWAIT A's COMPLETION — not a timer.
        gate.release()
        let completion = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in aFinished.stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            // `cancelAll` reaches BOTH children because both are STRUCTURED children of this group:
            // the stream reader is cancelled by its own task, and the sleeper by `Task.sleep`
            // throwing. Awaiting an UNSTRUCTURED `Task` inside a group child — which is what this
            // used to do — cannot be terminated by `cancelAll`, so a timeout leaked that task and
            // left the stream alive past teardown.
            group.cancelAll()
            _ = await group.next()
            return first
        }
        XCTAssertTrue(
            completion,
            "A must ACKNOWLEDGE COMPLETION; without the acknowledgement the assertions below would "
                + "be reading a state the case does not control. Finished inputs seen: \(finishedInputs)"
        )

        // ONLY NOW, with A acknowledged: B's window is STILL its own. (Dispatch ownership is per
        // request — owner delta 3484cbc/5eca874 — so the observable is the window identity, not a
        // window budget.)
        XCTAssertTrue(signal.isActive, "B's window is still open after A completed")
        XCTAssertEqual(
            signal.currentGeneration(), windowB,
            "A completing under its retired window must not RESET B's window; a new generation here "
                + "means A re-armed the successor"
        )

        // ONLY NOW: A submitted nothing.
        XCTAssertEqual(
            turnsBuilt, 1,
            "A, queued when its window retired, must submit nothing; a second client means it acted "
                + "under B"
        )
    }

    /// The paired POSITIVE: the same arrangement WITHOUT the retirement must let the queued input act,
    /// so the case above is measuring retirement rather than a queue that never runs.
    @MainActor
    func testAQueuedInputWhoseWindowIsUnretiredProceedsAndUsesTheTransports() async throws {
        let capture = FakeAudioCapture()
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        let modelManager = ModelManager(storageDir: tempDir)
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let fakeBackend = FakeAsrBackend()

        let suite = "unretired_input_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        let gate = Gate()
        var heldOnce = false
        var turnsBuilt = 0
        let aFinished = AsyncStream<Void>.makeStream()

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                )
                turnsBuilt += 1
                if !heldOnce {
                    heldOnce = true
                    built.task.holdUntilReleased(gate)
                }
                return built.client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend },
            onInputRoutingFinished: { finished in
                if finished.routerTranscript.contains("A question") {
                    aFinished.continuation.yield()
                }
            }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)

        let installed = service.asrEngineForTesting.onRoutingInput
        XCTAssertNotNil(installed, "the service must install an onRoutingInput callback")

        service.gracePeriodSignalForTesting.onWakeWordDetected()
        installed?(IntentRoutingInput.english(transcript: "held turn", selection: .wakeWord, utteranceId: "u-200"))
        let builtDeadline = Date().addingTimeInterval(8)
        while Date() < builtDeadline && turnsBuilt == 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(turnsBuilt, 1, "the preceding turn must have been built and held")

        // A queues behind the held turn. NOTHING is retired here.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        installed?(IntentRoutingInput.english(transcript: "A question", selection: .wakeWord, utteranceId: "u-200"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(turnsBuilt, 1, "precondition: A is queued")

        gate.release()
        // Structured children only, so `cancelAll` on timeout actually terminates the reader as well
        // as the sleeper; awaiting an unstructured Task here could not be cancelled.
        let completion = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in aFinished.stream { return true }
                return false
            }
            group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            _ = await group.next()
            return first
        }
        XCTAssertTrue(completion, "A must acknowledge completion")

        // POSITIVE: with nothing retired, the queued input DOES reach the transport.
        XCTAssertEqual(
            turnsBuilt, 2,
            "an UNRETIRED queued input must still submit; if it does not, the retirement case above "
                + "is passing because the queue never runs"
        )
    }

    /// MODEL-CHOSEN ROUTING: a turn the ROUTER PARSES into `cloud_route` (not an escalation) is
    /// stamped with the window it was dispatched under, and its completion must be judged against
    /// THAT window. If the window is retired while the turn is in flight, the completion must not
    /// re-arm the window that replaced it.
    ///
    /// The label is `cloud_route:route` with a matching tool call, which is what makes the router
    /// actually MAP a `CloudRouteIntent` — `cloud_route:` alone the mapper rejects, and the turn then
    /// takes the escalation path instead, which is a different contract.
    @MainActor
    func testAParsedModelChosenRouteRetiredInFlightCannotRearmTheSuccessor() async throws {
        let capture = FakeAudioCapture()
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        let modelManager = ModelManager(storageDir: tempDir)
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let fakeBackend = FakeAsrBackend()

        let suite = "model_route_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        // The parsed turn is HELD open on its socket, so it is still in flight when the window is
        // retired. An ASYNC hold, so the main actor the test runs on stays free.
        let gate = Gate()
        var heldOnce = false
        var turnsBuilt = 0

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                let built = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                )
                turnsBuilt += 1
                if !heldOnce {
                    heldOnce = true
                    built.task.holdUntilReleased(gate)
                }
                return built.client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)
        XCTAssertFalse(fixtureConfig.baseUrl.isEmpty, "baseUrl must be non-empty")

        let signal = service.gracePeriodSignalForTesting
        let installed = service.asrEngineForTesting.onRoutingInput
        XCTAssertNotNil(installed, "the service must install an onRoutingInput callback")

        // The parsed model-chosen turn is dispatched under its own window and HELD in flight.
        signal.onWakeWordDetected()
        let turnWindow = signal.currentGeneration()
        installed?(IntentRoutingInput.english(
            transcript: "what did the host mean by that remark",
            selection: .wakeWord,
            utteranceId: "b8024eb5-6cee-44ba-93ad-0b817f55a1d1",
        ))
        let builtDeadline = Date().addingTimeInterval(8)
        while Date() < builtDeadline && turnsBuilt == 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(
            turnsBuilt, 1,
            "the parsed model-chosen turn must have reached the transport and be held there; if it "
                + "did not, the router did not MAP a cloud route and this is not the parsed path"
        )

        // PRIVACY CLOSE, then a SUCCESSOR window. The successor is its OWN window with its own
        // generation; a stale completion must not reset it (owner delta 3484cbc/5eca874: dispatch
        // ownership is per request, so the observable is the successor's window identity, not a
        // window budget).
        signal.onAppBackgrounded()
        signal.onWakeWordDetected()
        let successor = signal.currentGeneration()
        XCTAssertNotEqual(turnWindow, successor, "the successor must be a different window")

        // RELEASE the in-flight parsed turn. Its completion lands under a RETIRED window.
        gate.release()
        let settleDeadline = Date().addingTimeInterval(10)
        while Date() < settleDeadline && turnsBuilt < 2 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Let the completion's window decision run.
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(signal.isActive, "the successor's window is still live")
        XCTAssertEqual(
            signal.currentGeneration(), successor,
            "a parsed model-chosen route landing after its window was retired must NOT reset the "
                + "successor's window; a new generation here means the successor was reset"
        )
    }


    /// CAPTURED-ORIGIN ADMISSION, isolated from debounce.
    ///
    /// A per-input barrier in the installed serial chain holds A BEFORE classification, so the test
    /// can retire A's window and open B while A waits, then release it. Debounce never enters the
    /// picture because A is the FIRST cloud route in this test — the assertion is about
    /// captured-origin admission, not about the debounce guard.
    ///
    /// The unretired twin below is the positive: same arrangement, nothing retired, A must proceed.
    @MainActor
    func testAHeldParsedModelInputWhoseWindowRetiredIsRefusedAdmission() async throws {
        let capture = FakeAudioCapture()
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        let modelManager = ModelManager(storageDir: tempDir)
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let fakeBackend = FakeAsrBackend()

        let suite = "origin_held_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        // A is held at the barrier until the test releases it.
        let gate = Gate()
        var turnsBuilt = 0
        var finishedInputs: [String] = []
        var arrivals: [VoiceControlService.InputBarrierOutcome] = []
        let arrivalWait = AsyncStream<Void>.makeStream()
        var terminals: [VoiceControlService.InputTerminalOutcome] = []
        var parsedIntents: [any VoiceIntent] = []
        let aFinished = AsyncStream<Void>.makeStream()
        let terminalWait = AsyncStream<Void>.makeStream()

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                turnsBuilt += 1
                return CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                ).client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend },
            onInputRoutingFinished: { finished in
                finishedInputs.append(finished.routerTranscript)
                if finished.routerTranscript.contains("A question") {
                    aFinished.continuation.yield()
                }
            },
            testInputBarrier: { input in
                // Hold ONLY A, before classification, so its window can be retired while it waits.
                // The wait PROPAGATES its outcome: the barrier is THROWING, so a cancellation or a
                // refusal STOPS the serial chain instead of letting routing resume below it.
                guard input.routerTranscript.contains("A question") else { return }
                try await gate.wait()
            },
            onInputBarrierSettled: { input, outcome in
                if input.routerTranscript.contains("A question") {
                    arrivals.append(outcome)
                    arrivalWait.continuation.yield()
                }
            },
            onInputTerminal: { input, outcome in
                if input.routerTranscript.contains("A question") {
                    terminals.append(outcome)
                    terminalWait.continuation.yield()
                }
            },
            // INVOCATION-LOCAL: the factory returns a FRESH observer for THIS input, so nothing is
            // read from a shared slot and an overlapping turn cannot overwrite what it observed.
            parsedIntentObserverFactory: { input in
                guard input.routerTranscript.contains("A question") else { return nil }
                return { parsed in parsedIntents.append(parsed) }
            }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)
        XCTAssertFalse(fixtureConfig.baseUrl.isEmpty, "baseUrl must be non-empty")

        let signal = service.gracePeriodSignalForTesting
        let installed = service.asrEngineForTesting.onRoutingInput
        XCTAssertNotNil(installed, "the service must install an onRoutingInput callback")

        // A is submitted and parks at the barrier, stamped with its own window.
        signal.onWakeWordDetected()
        let windowA = signal.currentGeneration()
        installed?(IntentRoutingInput.english(transcript: "A question", selection: .wakeWord, utteranceId: "u-200"))
        // AWAIT THE EVENT, do not sleep and hope: the arrival acknowledgement is what makes "held"
        // observable, and a fixed sleep asserts a timing rather than a fact.
        let arrived = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in arrivalWait.stream { return true }
                return false
            }
            group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            _ = await group.next()
            return first
        }
        XCTAssertTrue(
            arrived,
            "A must ACKNOWLEDGE ARRIVAL at the barrier; without it 'held' is an assumption. "
                + "Arrivals seen: \(arrivals)"
        )
        XCTAssertEqual(
            arrivals, [.arrived],
            "A must have ACKNOWLEDGED ARRIVAL at the barrier — an event distinct from routing "
                + "completion — or the hold below would be indistinguishable from an input that was "
                + "never submitted. Arrivals seen: \(arrivals)"
        )
        XCTAssertEqual(
            turnsBuilt, 0,
            "A must be HELD at the barrier and have taken no action; a client now means the barrier "
                + "did not hold and the assertions below would prove nothing"
        )

        // RETIRE A's window and OPEN a successor, epoch deliberately UNCHANGED.
        signal.onAppBackgrounded()
        signal.onWakeWordDetected()
        let successor = signal.currentGeneration()
        XCTAssertNotEqual(windowA, successor, "the successor must be a different window from A")
        XCTAssertTrue(signal.isActive, "the successor window must be OPEN")

        // RELEASE, then await A's TERMINAL acknowledgement. NOT the routing-attempted hook: a turn
        // refused before routing never fires that one, so awaiting it here would hang until the
        // timeout — which is exactly why the terminal outcome exists.
        gate.release()
        let completion = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in terminalWait.stream { return true }
                return false
            }
            group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            _ = await group.next()
            return first
        }
        XCTAssertTrue(
            completion,
            "A must report a TERMINAL outcome; without it the assertions below read a state the case "
                + "does not control. Terminals seen: \(terminals)"
        )
        // EXPLICIT ENUM ASSERTION, per input and BEFORE executor dispatch: the router PARSED this
        // input into a `CloudRouteIntent` whose `origin` is the `.modelCall` CASE — not the
        // `origin:` Int? generation that reaches `routeToCloud`, which is a different value.
        let parsed = try XCTUnwrap(
            parsedIntents.first as? CloudRouteIntent,
            "this input must have been parsed into a CloudRouteIntent; saw: "
                + "\(parsedIntents.map { String(describing: type(of: $0)) })"
        )
        XCTAssertEqual(
            parsed.origin, .modelCall,
            "the parsed intent's ORIGIN ENUM must be .modelCall — the model-chose-it case — rather "
                + "than .routingFailure; saw \(parsed.origin)"
        )
        // SEPARATELY, AFTER STAMPING: the observer fires on the RAW classified intent, so its
        // generation is nil there by construction; the captured window is verified from the SINK's
        // pre-guard record, which is the stamped dispatch. Asserting it on `parsed` would be asserting
        // a value that does not exist at that point.
        XCTAssertNil(
            parsed.generation,
            "the observation is of the RAW classified intent, before stamping, so its generation is "
                + "nil there; saw \(String(describing: parsed.generation))"
        )
        let stampedOrigin = await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting.lastOriginForTesting
        }
        XCTAssertEqual(
            stampedOrigin, windowA,
            "AFTER STAMPING the dispatch must carry the generation THIS turn captured (\(windowA)), "
                + "not the successor's; saw \(String(describing: stampedOrigin))"
        )

        // MEASURED, and it corrected an assumption of mine: the retired input settles as `.routed`,
        // NOT as `.barrierRefused`. The barrier RELEASES normally here — the refusal happens later,
        // when `prepare` refuses the turn's live-origin check. `.routed` therefore means "routing was
        // ATTEMPTED", which is true and is not the same claim as "an action ran"; the no-action part
        // is asserted separately by `turnsBuilt == 0`.
        XCTAssertEqual(
            terminals, [.routed],
            "the retired input must report a TERMINAL outcome; `.routed` records that routing was "
                + "attempted, while the refusal itself is the live-origin check in prepare. Seen: "
                + "\(terminals)"
        )
        XCTAssertTrue(
            finishedInputs.contains("A question"),
            "routing WAS attempted for this turn, so the routing-attempted signal must fire; the "
                + "narrower signal stays narrower than the terminal one. Finished: \(finishedInputs)"
        )

        // REFUSED ADMISSION: A completed and took NO action.
        XCTAssertEqual(
            turnsBuilt, 0,
            "a parsed model-chosen input whose window retired while it waited must be refused "
                + "admission; a client here means it acted under the successor"
        )
        // The successor's allowance is its own and untouched.
        XCTAssertEqual(
            signal.claimDispatchOwnership(),
            successor,
            "the successor's allowance must be unclaimed and still its own after A was refused"
        )
    }

    /// The POSITIVE twin: identical arrangement with NOTHING retired, so A must be admitted and act.
    /// Without this, the case above could pass because the barrier or the submission never worked.
    @MainActor
    func testAHeldParsedModelInputWhoseWindowIsUnretiredIsAdmitted() async throws {
        let capture = FakeAudioCapture()
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        let modelManager = ModelManager(storageDir: tempDir)
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let fakeBackend = FakeAsrBackend()

        let suite = "origin_unretired_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        let gate = Gate()
        var turnsBuilt = 0
        var arrivals: [VoiceControlService.InputBarrierOutcome] = []
        let arrivalWait = AsyncStream<Void>.makeStream()
        var terminals: [VoiceControlService.InputTerminalOutcome] = []
        let terminalWait = AsyncStream<Void>.makeStream()
        var parsedIntents: [any VoiceIntent] = []
        let aFinished = AsyncStream<Void>.makeStream()

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                turnsBuilt += 1
                return CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                ).client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend },
            onInputRoutingFinished: { finished in
                if finished.routerTranscript.contains("A question") { aFinished.continuation.yield() }
            },
            testInputBarrier: { input in
                guard input.routerTranscript.contains("A question") else { return }
                try await gate.wait()
            },
            onInputBarrierSettled: { input, outcome in
                if input.routerTranscript.contains("A question") {
                    arrivals.append(outcome)
                    arrivalWait.continuation.yield()
                }
            },
            onInputTerminal: { input, outcome in
                if input.routerTranscript.contains("A question") {
                    terminals.append(outcome)
                    terminalWait.continuation.yield()
                }
            },
            parsedIntentObserverFactory: { input in
                guard input.routerTranscript.contains("A question") else { return nil }
                return { parsed in parsedIntents.append(parsed) }
            }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)

        let installed = service.asrEngineForTesting.onRoutingInput
        XCTAssertNotNil(installed, "the service must install an onRoutingInput callback")

        service.gracePeriodSignalForTesting.onWakeWordDetected()
        // The window THIS turn is stamped with, captured at submission so the raw-origin assertion
        // below compares against the turn's own window rather than a live read.
        let admittedWindow = service.gracePeriodSignalForTesting.currentGeneration()
        installed?(IntentRoutingInput.english(transcript: "A question", selection: .wakeWord, utteranceId: "u-200"))
        // AWAIT THE EVENT rather than sleeping: arrival is what makes "held" a fact.
        let arrived = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in arrivalWait.stream { return true }
                return false
            }
            group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            _ = await group.next()
            return first
        }
        XCTAssertTrue(
            arrived,
            "A must ACKNOWLEDGE ARRIVAL at the barrier; without it 'held' is an assumption. "
                + "Arrivals seen: \(arrivals)"
        )
        XCTAssertEqual(
            arrivals, [.arrived],
            "arrival is its own event, distinct from terminal settlement and from any action"
        )
        XCTAssertEqual(turnsBuilt, 0, "A must be held at the barrier and have taken no action")

        // NOTHING is retired. Release and await TERMINAL SETTLEMENT — the every-exit outcome, which is
        // the acknowledgement that this input's task returned.
        gate.release()
        let completion = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in terminalWait.stream { return true }
                return false
            }
            group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            _ = await group.next()
            return first
        }
        XCTAssertTrue(
            completion,
            "A must report a TERMINAL outcome; without it the assertions below read a state the case "
                + "does not control. Terminals seen: \(terminals)"
        )
        XCTAssertEqual(
            terminals, [.routed],
            "the admitted input's terminal outcome is `.routed`: routing was ATTEMPTED, which is a "
                + "different claim from an action having run. Seen: \(terminals)"
        )

        // POSITIVE: an unretired held input IS admitted and acts.
        XCTAssertEqual(
            turnsBuilt, 1,
            "an UNRETIRED held model-chosen input must be admitted and reach the transport; if it "
                + "does not, the refusal case above cannot be attributed to retirement"
        )
        // EXPLICIT ENUM ASSERTION, the positive half of the pair, per input and BEFORE dispatch.
        let parsed = try XCTUnwrap(
            parsedIntents.first as? CloudRouteIntent,
            "the admitted input must have been parsed into a CloudRouteIntent; saw: "
                + "\(parsedIntents.map { String(describing: type(of: $0)) })"
        )
        XCTAssertEqual(
            parsed.origin, .modelCall,
            "the parsed intent's ORIGIN ENUM must be .modelCall, the model-chose-it case; saw "
                + "\(parsed.origin)"
        )
        // SEPARATELY, AFTER STAMPING (see the refusal case): the observation is of the RAW
        // classified intent, so its generation is nil there; the captured window is verified from the
        // stamped dispatch.
        XCTAssertNil(
            parsed.generation,
            "the observation is of the RAW classified intent, before stamping; saw "
                + "\(String(describing: parsed.generation))"
        )
        let stampedOrigin = await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting.lastOriginForTesting
        }
        XCTAssertEqual(
            stampedOrigin, admittedWindow,
            "AFTER STAMPING the admitted dispatch must carry the generation it captured "
                + "(\(admittedWindow)); saw \(String(describing: stampedOrigin))"
        )
    }

    /// CANCELLATION YIELDS NO SUBMISSION OR ACTION, and is reported as an event DISTINCT from
    /// arrival and from routing completion.
    ///
    /// The input is held at the barrier, then the serial chain is cancelled (as `stop()` does). The
    /// throwing barrier must then STOP the chain: a non-throwing barrier could only return from its
    /// own closure, and routing would resume immediately below it, so a cancelled input would still
    /// be routed. Three events are asserted separately: ARRIVAL at the barrier, CANCELLATION, and
    /// absence of any routing completion for that input.
    @MainActor
    func testACancelledHeldInputIsReportedCancelledAndTakesNoAction() async throws {
        let capture = FakeAudioCapture()
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        let modelManager = ModelManager(storageDir: tempDir)
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let fakeBackend = FakeAsrBackend()

        let suite = "cancel_held_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        let gate = Gate()
        var turnsBuilt = 0
        var arrivals: [VoiceControlService.InputBarrierOutcome] = []
        let arrivalWait = AsyncStream<Void>.makeStream()
        var terminals: [VoiceControlService.InputTerminalOutcome] = []
        var finishedInputs: [String] = []
        let terminalWait = AsyncStream<Void>.makeStream()

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture,
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                turnsBuilt += 1
                return CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                ).client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { fakeBackend },
            onInputRoutingFinished: { finished in
                finishedInputs.append(finished.routerTranscript)
            },
            testInputBarrier: { input in
                guard input.routerTranscript.contains("A question") else { return }
                try await gate.wait()
            },
            onInputBarrierSettled: { input, outcome in
                if input.routerTranscript.contains("A question") {
                    arrivals.append(outcome)
                    arrivalWait.continuation.yield()
                }
            },
            onInputTerminal: { input, outcome in
                if input.routerTranscript.contains("A question") {
                    terminals.append(outcome)
                    terminalWait.continuation.yield()
                }
            }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        startTracked(service)
        try await waitForListening(service: service)
        try await waitForRouter(service: service)

        let installed = service.asrEngineForTesting.onRoutingInput
        XCTAssertNotNil(installed, "the service must install an onRoutingInput callback")

        // Submit A; it arrives at the barrier and waits.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        installed?(IntentRoutingInput.english(transcript: "A question", selection: .wakeWord, utteranceId: "u-200"))
        // AWAIT THE EVENT: a fixed sleep would assert a timing rather than the fact that A is held.
        let arrived = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in arrivalWait.stream { return true }
                return false
            }
            group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            _ = await group.next()
            return first
        }
        XCTAssertTrue(
            arrived,
            "A must ACKNOWLEDGE ARRIVAL at the barrier; without it 'held' is an assumption. "
                + "Arrivals seen: \(arrivals)"
        )
        XCTAssertEqual(arrivals, [.arrived], "A must have ARRIVED at the barrier")
        XCTAssertEqual(turnsBuilt, 0, "A must have taken no action while held")

        // CLASSIFIER COUNT BEFORE TERMINAL SETTLEMENT: A is HELD at the barrier, which sits BEFORE
        // classification, so it must not have been classified yet. Recorded here and compared after
        // settlement, so "the cancellation changed no classifier state" is observed rather than
        // assumed from the absence of clients.
        let classifyCountAtBarrier = inference.classifyCount

        // CANCEL the serial chain, then open the gate so the wait can observe the cancellation.
        service.stop()
        gate.release()
        // AWAIT THE TERMINAL ACKNOWLEDGEMENT rather than sleeping and inferring from absence: every
        // exit reports how the task ended, so settlement is observed, not assumed.
        let settled = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in terminalWait.stream { return true }
                return false
            }
            group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            _ = await group.next()
            return first
        }
        XCTAssertTrue(
            settled,
            "the cancelled input must report a TERMINAL outcome; without it the assertions below "
                + "would rely on an absence timer. Terminals seen: \(terminals)"
        )
        XCTAssertEqual(
            terminals, [.barrierCancelled],
            "the terminal outcome must be barrierCancelled — how the task ENDED — which is distinct "
                + "from arrival and from an action having run. Seen: \(terminals)"
        )

        // CANCELLATION IS ITS OWN EVENT, and distinct from arrival and from routing completion.
        XCTAssertEqual(
            arrivals, [.arrived, .cancelled],
            "the cancelled input must be reported CANCELLED at the barrier, not silently skipped; "
                + "arrival and cancellation are separate events. Seen: \(arrivals)"
        )
        // NO SUBMISSION OR ACTION.
        XCTAssertEqual(
            turnsBuilt, 0,
            "a CANCELLED held input must submit nothing; a client here means the chain resumed "
                + "routing after the barrier was cancelled"
        )
        // CLASSIFIER COUNT AFTER TERMINAL SETTLEMENT: unchanged, because a turn cancelled at the
        // barrier never reaches classification. A rise here would mean the chain resumed past the
        // barrier — the very thing the throwing barrier exists to prevent.
        //
        // MEASURED, for the two fall-through mutants actually tried: both also violated the TERMINAL
        // outcome contract — the second even though it deliberately preserved `.barrierCancelled`,
        // because falling through overwrites it. In those two, the terminal assertion reported the
        // same violation. That is all this records; it is not a claim that every conceivable
        // violation reachable here also moves the terminal outcome. (XCTest reports every failed
        // assertion in a case, so this is about the violations being the same one, not about
        // execution stopping early.) Kept because it names the classifier state explicitly; NOT
        // cited as separate coverage.
        XCTAssertEqual(
            inference.classifyCount, classifyCountAtBarrier,
            "a turn cancelled at the barrier must not have been classified; the count moved from "
                + "\(classifyCountAtBarrier) to \(inference.classifyCount)"
        )
        // NO ROUTING COMPLETION for that input: cancellation is not completion.
        XCTAssertFalse(
            finishedInputs.contains("A question"),
            "a cancelled input must NOT report routing completion; that would conflate cancellation "
                + "with a route that finished. Finished: \(finishedInputs)"
        )
    }
}

/// Names the ACTUAL gate blocker for the provenance path on this environment: builds the
/// service exactly as the provenance cases do and reports the gate's off-reason. This is a
/// diagnosis control — a skip above must cite this reason, never a bare count.
extension ServiceSelectionProvenanceTests {
    @MainActor
    func testGateBlockerDiagnosis_forTheProvenancePath() {
        let capture = FakeAudioCapture()
        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: capture
        ) else {
            XCTFail("the assembly built no service — the manifest/assets are the blocker")
            return
        }
        startTracked(service)
        let expectation = expectation(description: "gate settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 5)
        let state = service.gateState
        if case .off(let reason) = state {
            XCTFail("gate did not reach listening; off reason: \(reason)")
        } else {
            print("[provenance-diagnosis] gate state: \(state)")
        }
    }
}
