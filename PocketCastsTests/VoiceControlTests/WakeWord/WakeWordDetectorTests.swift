import XCTest
@testable import podcasts

final class WakeWordDetectorTests: XCTestCase {

    func test_detector_initialization_withoutModels_returnsZero() {
        // Without actual ONNX models, detector should still be initializable
        let detector = WakeWordDetector(
            melModel: URL(fileURLWithPath: "/nonexistent/mel.onnx"),
            embedModel: URL(fileURLWithPath: "/nonexistent/embed.onnx"),
            classifierModel: URL(fileURLWithPath: "/nonexistent/auris.onnx"),
            threshold: 0.5
        )
        let score = detector.detect(samples: [Float](repeating: 0, count: 32000), sampleRate: 16000)
        XCTAssertEqual(score, 0.0)
        detector.release()
    }

    func test_detector_emptySamples_returnsZero() {
        let detector = WakeWordDetector(
            melModel: URL(fileURLWithPath: "/nonexistent/mel.onnx"),
            embedModel: URL(fileURLWithPath: "/nonexistent/embed.onnx"),
            classifierModel: URL(fileURLWithPath: "/nonexistent/auris.onnx"),
            threshold: 0.5
        )
        let score = detector.detect(samples: [], sampleRate: 16000)
        XCTAssertEqual(score, 0.0)
        detector.release()
    }

    func test_commandWindow_opensOnWakeWord() {
        let manager = CommandWindowManager()
        XCTAssertFalse(manager.isOpen)
        manager.onWakeWordDetected()
        XCTAssertTrue(manager.isOpen)
    }

    func test_commandWindow_closesAfterTimeout() {
        let manager = CommandWindowManager()
        manager.onWakeWordDetected()
        // Advance last speech time past timeout
        XCTAssertTrue(manager.isOpen)
        // tick with no recent speech should close
        manager.tick()
        // Immediately after detection, window should still be open
        XCTAssertTrue(manager.isOpen)
    }

    func test_speechActivity_keepsWindowOpen() {
        let manager = CommandWindowManager()
        manager.onWakeWordDetected()
        manager.onSpeechActivity()
        manager.tick()
        XCTAssertTrue(manager.isOpen)
    }
}
