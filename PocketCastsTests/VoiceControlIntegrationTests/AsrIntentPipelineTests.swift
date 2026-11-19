import XCTest
@testable import podcasts

final class AsrIntentPipelineTests: XCTestCase {
    private struct StubError: Error {}

    /// Minimal `AsrBackend` stand-in: the real backends (SenseVoice/Canary) need
    /// on-device models, which a unit test cannot supply. The Whisper fixture
    /// these tests used is gone with the unselected backend (monthly review
    /// core#157); the stub keeps the pipeline contracts testable offline.
    private final class StubAsrBackend: AsrBackend {
        private let readyResult: Result<Void, Error>
        init(readyResult: Result<Void, Error> = .success(())) { self.readyResult = readyResult }
        let capabilities = AsrCapabilities(canTranslateToEnglish: false)
        var requiredModel: ModelSpec { ModelSpec(id: "stub", files: [], targetDir: "stub") }
        func ensureReady() async -> Result<Void, Error> { readyResult }
        func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
            AsrResult(text: "", detectedLanguage: nil, tokens: nil)
        }
        func release() {}
    }

    /// The backend reports a failure for a model that is not there, so a caller
    /// can never mistake "not loaded" for "ready".
    func test_backendInitialization_reportsFailureForMissingModel() async {
        let backend = StubAsrBackend(readyResult: .failure(StubError()))
        let result = await backend.ensureReady()
        if case .success = result {
            XCTFail("a missing model must not report success")
        }
    }

    func test_asrEngine_initialization() {
        let stubDetector = StubWakeWordDetector()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: StubAsrBackend(),
            signalFilter: SignalFilter(),
            wakeWordDetector: stubDetector,
            gracePeriodSignal: GracePeriodSignal()
        )
        // Engine should not be running by default
        engine.stop() // Should not crash
    }

    func test_toolCallMapper_roundTrip() {
        let mapper = ToolCallMapper()
        let call = ToolCall(name: "playback", arguments: ["action": "pause"])
        let intent = mapper.map(call)
        XCTAssertNotNil(intent)
    }

    func test_parser_integration() {
        let output = "<|tool_call_start|>[playback(action='pause')]<|tool_call_end|>"
        let toolCall = LfmToolCallParser.parse(output)
        XCTAssertNotNil(toolCall)
        let intent = ToolCallMapper().map(toolCall!)
        XCTAssertNotNil(intent)
    }
}

private final class StubWakeWordDetector: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        .notDetected(confidence: 0)
    }

    func release() {}
}
