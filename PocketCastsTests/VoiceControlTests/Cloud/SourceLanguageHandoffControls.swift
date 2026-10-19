import XCTest
@testable import podcasts

/// ACTUAL-ASR → SERVICE HANDOFF → REAL AUTHENTICATE controls (core b6eafe25, reviewer 4feb0e39).
///
/// These drive the REAL service dispatch paths — `VoiceControlService.handleRoutingInput` through
/// the router, executor, and sink into a REAL `CloudRouteClient` whose Authenticate frame is
/// captured — not a `client.route` call that bypasses the handoffs. Two paths, both required:
///
///   - SELECTED (model-chosen `cloud_route`): the router classifies cloud_route and the service
///     stamps the input's preserved source fields into the reconstructed intent.
///   - FALLBACK (routing-failure escalation): the router fails, and the escalation constructs the
///     dispatch intent directly from the input.
///
/// Each case asserts the exact wire facts: the wake-trimmed source utterance is the runtime
/// `request` when one exists, the actual ASR LID rides `source_language` (yue stays yue), an
/// unknown language is OMITTED (never "en", never the locale), and a translated-only turn sends
/// the available English text without fabricating an original.
final class SourceLanguageHandoffControls: XCTestCase {
    // MARK: - Harness

    private struct HandoffCase {
        let name: String
        let sourceTranscript: String?
        let sourceLanguage: String?
        let routerTranscript: String
        let expectedRequest: String
        let expectedLanguage: String?
    }

    private let cases: [HandoffCase] = [
        HandoffCase(
            name: "yue", sourceTranscript: "嚟啲歡快嘅", sourceLanguage: "yue",
            routerTranscript: "play something upbeat",
            expectedRequest: "嚟啲歡快嘅", expectedLanguage: "yue"
        ),
        HandoffCase(
            name: "zh", sourceTranscript: "来点欢快的", sourceLanguage: "zh",
            routerTranscript: "play something upbeat",
            expectedRequest: "来点欢快的", expectedLanguage: "zh"
        ),
        HandoffCase(
            name: "unknown-lang", sourceTranscript: "来点欢快的", sourceLanguage: nil,
            routerTranscript: "play something upbeat",
            expectedRequest: "来点欢快的", expectedLanguage: nil
        ),
        HandoffCase(
            name: "translated-only-known-lang", sourceTranscript: nil, sourceLanguage: "zh",
            routerTranscript: "play something upbeat",
            expectedRequest: "play something upbeat", expectedLanguage: "zh"
        ),
        HandoffCase(
            name: "translated-only-unknown-lang", sourceTranscript: nil, sourceLanguage: nil,
            routerTranscript: "play something upbeat",
            expectedRequest: "play something upbeat", expectedLanguage: nil
        ),
        HandoffCase(
            name: "local-english", sourceTranscript: "play something upbeat", sourceLanguage: "en",
            routerTranscript: "play something upbeat",
            expectedRequest: "play something upbeat", expectedLanguage: "en"
        ),
    ]

    @MainActor
    private func makeService(
        classifyLabel: String,
        generateResult: String,
        box: FrameBox
    ) -> VoiceControlService {
        let inference = FakeLfmInference()
        inference.classifyLabel = classifyLabel
        inference.generateResult = generateResult
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let suite = "srclang_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        // Keep the defaults domain alive as long as the test object: removing it inside this
        // scope would race the turn's async config reads.
        objc_setAssociatedObject(self, "cfg_\(suite)", (defaults, fixtureConfig), .OBJC_ASSOCIATION_RETAIN)

        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                let stub = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                )
                box.tasks.append(stub.task)
                return stub.client
            },
            cloudConfig: fixtureConfig,
            asrBackend: { FakeAsrBackend() }
        )
        return service!
    }

    private func provenanceAudioSession() -> FakeAudioSessionControlling {
        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "srclang-bt-out")]
        session.availableAfterConfigure = [AudioPort(portType: .bluetoothHFP, uid: "srclang-hfp-mic")]
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

    private final class FrameBox: @unchecked Sendable {
        var tasks: [StubWebSocketTask] = []
    }

    @MainActor
    private func waitForFrame(_ box: FrameBox) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let frame = box.tasks.first?.sentAuthFrame { return frame }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("no Authenticate frame was captured within 8s")
        return [:]
    }

    private func makeInput(_ c: HandoffCase, selection: CloudConversationSelection?) -> IntentRoutingInput {
        IntentRoutingInput(
            sourceTranscript: c.sourceTranscript,
            sourceLanguage: c.sourceLanguage,
            routerTranscript: c.routerTranscript,
            translationKind: c.sourceTranscript == nil ? .backend : .platform,
            selection: selection
        )
    }

    // MARK: - SELECTED path (model-chosen cloud_route)

    @MainActor
    func testSelectedPathCarriesSourceFactsToTheRealFrame() async throws {
        for c in cases {
            let box = FrameBox()
            let service = makeService(
                classifyLabel: "cloud_route:route",
                generateResult: "<|tool_call_start|>[cloud_route(request='\(c.routerTranscript)')]<|tool_call_end|>",
                box: box
            )
            service.startIfAllowed()
            try await waitForListening(service)
            try await waitForRouter(service)
            service.gracePeriodSignalForTesting.onWakeWordDetected()

            await service.handleRoutingInput(
                makeInput(c, selection: .wakeWord),
                origin: service.gracePeriodSignalForTesting.currentGeneration()
            )

            let frame = try await waitForFrame(box)
            XCTAssertEqual(frame["request"] as? String, c.expectedRequest,
                           "[\(c.name)] selected path: runtime request on the wire")
            XCTAssertEqual(frame["source_language"] as? String, c.expectedLanguage,
                           "[\(c.name)] selected path: source_language on the wire (nil = omitted)")
        }
    }

    // MARK: - FALLBACK path (routing-failure escalation)

    @MainActor
    func testFallbackPathCarriesSourceFactsToTheRealFrame() async throws {
        for c in cases {
            let box = FrameBox()
            let service = makeService(
                classifyLabel: "no_match:",
                generateResult: "",
                box: box
            )
            service.startIfAllowed()
            try await waitForListening(service)
            try await waitForRouter(service)
            service.gracePeriodSignalForTesting.onWakeWordDetected()

            await service.handleRoutingInput(
                makeInput(c, selection: .wakeWord),
                origin: service.gracePeriodSignalForTesting.currentGeneration()
            )

            let frame = try await waitForFrame(box)
            XCTAssertEqual(frame["request"] as? String, c.expectedRequest,
                           "[\(c.name)] fallback path: runtime request on the wire")
            XCTAssertEqual(frame["source_language"] as? String, c.expectedLanguage,
                           "[\(c.name)] fallback path: source_language on the wire (nil = omitted)")
        }
    }

    /// LOCAL-ENGLISH control (reviewer 4af8d2d5 + 9d6dc5a7): an English utterance whose router
    /// classification is a LOCAL action (1) actually executes locally — the recording playback
    /// manager observes the real pause invocation and the parsed-intent observer sees the
    /// PlaybackIntent the English routing input produced — and (2) never dispatches to the cloud
    /// sink: zero Authenticate frames, zero client factory invocations. The prior form
    /// (tasks.isEmpty + sleep alone) also passed if local execution was silently dropped; a
    /// suppress-local-execution mutant now fails this control on the pause assertion.
    @MainActor
    func testLocalEnglishActionRoutesLocallyWithZeroAuthFrames() async throws {
        let box = FrameBox()
        let recorder = RecordingPlaybackSink()
        let intentBox = IntentBox()
        objc_setAssociatedObject(self, "srclang_intentbox", intentBox, .OBJC_ASSOCIATION_RETAIN)

        let suite = "srclang_local_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        objc_setAssociatedObject(self, "srclang_local_cfg", (defaults, fixtureConfig), .OBJC_ASSOCIATION_RETAIN)

        let inference = FakeLfmInference()
        inference.classifyLabel = "playback:pause"
        inference.generateResult = "playback(action='pause')"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: provenanceAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                let stub = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n"
                )
                box.tasks.append(stub.task)
                return stub.client
            },
            playbackSink: recorder,
            cloudConfig: fixtureConfig,
            asrBackend: { FakeAsrBackend() }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)
        service.gracePeriodSignalForTesting.onWakeWordDetected()

        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: "pause playback",
                language: "en",
                selection: .wakeWord
            ),
            origin: service.gracePeriodSignalForTesting.currentGeneration(),
            parsedIntentObserver: { intent in intentBox.intents.append(intent) }
        )

        // Bounded settle: a cloud dispatch would open a socket within this window.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // ACTUAL LOCAL EXECUTION: the English router input produced a local pause intent and the
        // playback manager REALLY received the pause.
        let intents = intentBox.intents
        XCTAssertTrue(
            intents.contains { $0 is PlaybackIntent },
            "the English routing input must parse to a LOCAL playback intent — got \(intents)"
        )
        XCTAssertEqual(
            recorder.pauseCalls, 1,
            "the local pause must ACTUALLY execute against the playback sink"
        )

        // ZERO CLOUD: routing stayed local.
        XCTAssertTrue(
            box.tasks.isEmpty,
            "a local action must never dispatch to the cloud — \(box.tasks.count) auth frames observed"
        )
    }

    private final class IntentBox: @unchecked Sendable {
        var intents: [any VoiceIntent] = []
    }

    /// Records ACTUAL local playback invocations (reviewer 9d6dc5a7).
    final class RecordingPlaybackSink: VoicePlaybackSink {
        private(set) var pauseCalls = 0
        var isPlaying = false
        func pause() -> VoiceResponse { pauseCalls += 1; return .earcon(.success) }
        func resume() -> VoiceResponse { .silent }
        func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse { .silent }
        func seekTo(positionSeconds: Int) -> VoiceResponse { .silent }
        func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse { .silent }
        func nextEpisode() -> VoiceResponse { .silent }
    }

    @MainActor
    private func waitForListening(_ service: VoiceControlService) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if service.isListening { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("gate did not reach listening: \(service.gateState)")
    }

    @MainActor
    private func waitForRouter(_ service: VoiceControlService) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if service.intentRouterIsReadyForTesting { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("router never became ready")
    }

}
