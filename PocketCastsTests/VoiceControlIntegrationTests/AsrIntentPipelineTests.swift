import XCTest
@testable import podcasts

final class AsrIntentPipelineTests: XCTestCase {

    /// The backend reports a failure for a model path that is not there, so a
    /// caller can never mistake "not loaded" for "ready" (see
    /// `WhisperCppBackendTests.test_ensureReady_missingModelPathFails`). The
    /// environment supplies the rest of the pipeline below.
    func test_backendInitialization_reportsFailureForMissingModel() async {
        // See `WhisperCppBackendTests`: an unwritable parent keeps the model
        // download from running at all, so the contract is asserted offline.
        let backend = WhisperCppBackend(modelPath: "/dev/null/auris-missing-\(UUID().uuidString)/model.bin")
        let result = await backend.ensureReady()
        switch result {
        case .success:
            XCTFail("a missing model path must not report success")
        case .failure:
            break
        }
    }

    func test_transcribe_emptySamples() async {
        let backend = WhisperCppBackend(modelPath: "/tmp/test")
        let result = await backend.transcribe(samples: [], sampleRateHz: 16000)
        XCTAssertTrue(result.text.isEmpty)
    }

    func test_asrEngine_initialization() {
        let stubDetector = StubWakeWordDetector()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: WhisperCppBackend(modelPath: "/tmp/test"),
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
