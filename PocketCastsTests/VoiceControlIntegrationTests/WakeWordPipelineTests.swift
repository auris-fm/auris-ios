import XCTest
@testable import podcasts

final class WakeWordPipelineTests: XCTestCase {

    func test_detector_initializesWithoutModels() {
        let detector = WakeWordDetector(
            melModel: URL(fileURLWithPath: "/test/mel.onnx"),
            embedModel: URL(fileURLWithPath: "/test/embed.onnx"),
            classifierModel: URL(fileURLWithPath: "/test/auris.onnx"),
            threshold: 0.5
        )
        // Detector should handle missing model gracefully
        let score = detector.detect(samples: Array(repeating: 0, count: 32000), sampleRate: 16000)
        XCTAssertLessThanOrEqual(score, 0.0)
        detector.release()
    }

    func test_commandWindow_lifecycle() {
        let manager = CommandWindowManager()
        XCTAssertFalse(manager.isOpen)
        manager.onWakeWordDetected()
        XCTAssertTrue(manager.isOpen)
    }
}
