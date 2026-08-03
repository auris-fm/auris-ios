import XCTest
@testable import podcasts

final class WakeWordPipelineTests: XCTestCase {

    func test_detector_missingModels_failsClosed() {
        let detector = WakeWordDetector(
            melModel: URL(fileURLWithPath: "/test/mel.onnx"),
            embedModel: URL(fileURLWithPath: "/test/embed.onnx"),
            classifierModel: URL(fileURLWithPath: "/test/auris.onnx"),
            threshold: 0.8
        )
        // Detector must report an error, never a zero-confidence notDetected.
        let result = detector.detect(samples: Array(repeating: 0, count: 32000), sampleRate: 16000)
        if case .error(let code) = result {
            XCTAssertFalse(code.isEmpty)
        } else {
            XCTFail("Expected .error for missing models, got \(result)")
        }
        detector.release()
    }

    func test_gracePeriod_opensOnWakeWord() {
        let signal = GracePeriodSignal()
        XCTAssertFalse(signal.isActive)
        signal.onWakeWordDetected()
        XCTAssertTrue(signal.isActive)
    }
}
