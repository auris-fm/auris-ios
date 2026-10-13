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

        guard let service = VoiceControlAssembly().buildVoiceControlService(capture: capture, asrBackend: { fakeBackend }) else {
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

    /// THE SERVICE-OWNED BINDING: a wake must reach the MANAGER the sink uses, so a routed turn is
    /// admitted at the origin gate. This is the production admission defect: a binding stored in the
    /// assembly's `cancellables` is cancelled when the build call returns, so the manager never
    /// learns a window opened and every turn is refused.
    @MainActor
    func testAWakeReachesTheSinkManagersLiveOrigin() async throws {
        let capture = FakeAudioCapture()
        let fakeBackend = FakeAsrBackend()

        guard let service = VoiceControlAssembly().buildVoiceControlService(capture: capture, asrBackend: { fakeBackend }) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try XCTSkipUnless(service.isListening, "the gate did not reach .listening")

        let manager = service.liveOriginManagerForTesting

        // No window yet: a turn carrying any generation must be refused.
        XCTAssertNil(
            manager.prepare(selection: .wakeWord, origin: 1),
            "with no window open, no captured origin is live"
        )

        // A wake opens a window; the SERVICE-OWNED binding must move the manager's live origin.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let generation = service.gracePeriodSignalForTesting.currentGeneration()

        let deadline = Date().addingTimeInterval(3)
        var admitted = false
        while Date() < deadline {
            if manager.prepare(selection: .wakeWord, origin: generation) != nil { admitted = true; break }
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
        service.startIfAllowed()
        try XCTSkipUnless(service.isListening, "the gate did not reach .listening")
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
                selection: .wakeWord
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
        service.startIfAllowed()
        try XCTSkipUnless(service.isListening, "the gate did not reach .listening")
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
                selection: .wakeWord
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
        service.startIfAllowed()
        try XCTSkipUnless(service.isListening, "the gate did not reach .listening")
        try await waitForRouter(service: service)

        // A window is OPEN, so the sink's provider would derive `.followUp`. Stamping `.wakeWord`
        // makes the two DISAGREE: only genuine carriage can deliver the stamped value.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let installed = service.asrEngineForTesting.onRoutingInput
        XCTAssertNotNil(installed, "the service must install an onRoutingInput callback")

        let sink = service.executorForTesting.cloudRouteSinkForTesting
        installed?(IntentRoutingInput.english(
            transcript: "what did the host mean by that remark",
            selection: .wakeWord
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
    /// So the second turn IS genuinely queued behind the first, and IS dropped once capture stops.
    ///
    /// The service's own `asrEngine.onRoutingInput` closure CAPTURES a turn's provenance at the
    /// callback and only then QUEUES behind earlier work. Here a FIRST turn is held open on the
    /// socket, so a SECOND input queues behind it. While the second is still queued its window is
    /// RETIRED and a new one opened and spent. Releasing the held turn must then let the queued turn
    /// be DROPPED by its staleness guard: it must not act under the window that replaced it, and the
    /// new window's spent budget must survive.
    @MainActor
    func testAQueuedTurnIsDroppedWhenItsWindowRetiresBeforeItRuns() async throws {
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

        let suite = "queued_drop_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        // The FIRST turn to build a client is held open on its socket, so it keeps the serial slot
        // and everything submitted after it queues. The hold is ASYNC (`holdUntilReleased` makes the
        // fixture's receive() await), so it never blocks the main actor the test runs on.
        let gate = Gate()
        var heldOnce = false
        var turnsBuilt = 0
        guard let service = VoiceControlAssembly().buildVoiceControlService(
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
        service.startIfAllowed()
        try XCTSkipUnless(service.isListening, "the gate did not reach .listening")
        try await waitForRouter(service: service)

        let signal = service.gracePeriodSignalForTesting
        let installed = service.asrEngineForTesting.onRoutingInput
        XCTAssertNotNil(installed, "the service must install an onRoutingInput callback")

        // FIRST input: its turn is held open, so it occupies the serial slot.
        signal.onWakeWordDetected()
        let heldWindow = signal.currentGeneration()
        installed?(IntentRoutingInput.english(transcript: "held turn", selection: .wakeWord))

        let firstBuilt = Date().addingTimeInterval(5)
        while Date() < firstBuilt && turnsBuilt == 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(turnsBuilt, 1, "the first turn must have been built and held")

        // SECOND input: it QUEUES behind the held turn and cannot run yet.
        signal.onWakeWordDetected()
        let queuedWindow = signal.currentGeneration()
        XCTAssertNotEqual(heldWindow, queuedWindow, "the second input must stamp a different window")
        installed?(IntentRoutingInput.english(transcript: "queued turn", selection: .followUp))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            turnsBuilt, 1,
            "precondition: the second turn must STILL BE QUEUED — only the held one reached a client"
        )

        // STOP capture: this bumps `transcriptEpoch` and cancels the serial chain — the only thing
        // in the source that advances the epoch. Restarting then opens a fresh window.
        service.stop()
        service.startIfAllowed()
        try await waitForRouter(service: service)
        signal.onAppBackgrounded()
        signal.onWakeWordDetected()
        let newWindow = signal.currentGeneration()
        XCTAssertNotEqual(queuedWindow, newWindow, "the replacement window must differ from the queued one")
        XCTAssertNotNil(signal.claimEscalationBudget(), "the replacement window's budget is spent here")

        // RELEASE the held turn. The queued turn then gets its turn to run — and must be DROPPED,
        // because the window it was stamped under has ended.
        gate.release()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if turnsBuilt > 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // "Dropped" is observed as: it never built a client, i.e. never dispatched under the new
        // window. The drop is guarded by THREE REDUNDANT terms in the source — `Task.isCancelled`
        // (stop() cancels the serial task), `isListening`, and `transcriptEpoch` — and measured, the
        // term that actually fires here is CANCELLATION (traced: the queued task resumes with
        // cancelled=true). A mutation of any ONE term therefore survives, because another catches it:
        // that is redundancy, not a coverage gap. The case asserts the OBSERVABLE DROP, not one term.
        XCTAssertEqual(
            turnsBuilt, 1,
            "a turn still QUEUED when its window retired must be dropped, not dispatched under the "
                + "window that replaced it"
        )
        XCTAssertNil(
            signal.claimEscalationBudget(),
            "the replacement window's spent budget must be unchanged; a value here means the queued "
                + "turn ran and reset it"
        )
    }
}
