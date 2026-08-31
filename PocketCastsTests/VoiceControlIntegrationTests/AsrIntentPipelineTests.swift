import XCTest
@testable import podcasts

final class AsrIntentPipelineTests: XCTestCase {

    func test_backendInitialization() async {
        let backend = WhisperCppBackend(modelPath: "/tmp/test")
        let result = await backend.ensureReady()
        if case .success = result {
            // Expected stub behavior
        } else {
            XCTFail("Expected success from stub")
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
        let output = "<start_function_call>call:playback{action:pause}<end_function_call>"
        let toolCall = FunctionGemmaParser.parse(output)
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
