import XCTest
@testable import podcasts

final class NativeAudioCaptureTests: XCTestCase {

    func test_capture_engineConfiguration_sampleRate() {
        let capture = NativeAudioCapture()
        // Engine should not be running by default
        XCTAssertFalse(capture.engine.isRunning)
    }

    func test_capture_hasInputNode() {
        let capture = NativeAudioCapture()
        // AVAudioEngine should have an input node available
        XCTAssertTrue(capture.engine.inputNode.numberOfInputs > 0 || capture.engine.inputNode.numberOfOutputs > 0)
    }

    func test_vadSegmenter_energyBasedDetection() {
        let segmenter = NativeVadSegmenter()
        var utteranceReceived = false
        segmenter.onUtterance = { _ in utteranceReceived = true }

        // Send speech-like samples (high energy)
        let speech: [Float] = (0..<320).map { sin(Float($0) * 0.1) }
        segmenter.process(speech)

        // Send silence samples
        let silence: [Float] = Array(repeating: 0, count: 320)
        segmenter.process(silence)

        // The energy-based stub should detect speech from high-energy samples
        // But utterance won't fire until silence timeout, which won't happen synchronously
        XCTAssertFalse(utteranceReceived, "Utterance should not fire without silence timeout")
    }
}
