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
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: WhisperCppBackend(modelPath: "/tmp/test"),
            signalFilter: SignalFilter()
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
