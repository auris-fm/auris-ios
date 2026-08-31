import XCTest
@testable import podcasts

final class WakeWordDetectorTests: XCTestCase {

    func test_detector_missingModels_returnsErrorNotNotDetected() {
        let detector = WakeWordDetector(
            melModel: URL(fileURLWithPath: "/nonexistent/mel.onnx"),
            embedModel: URL(fileURLWithPath: "/nonexistent/embed.onnx"),
            classifierModel: URL(fileURLWithPath: "/nonexistent/auris.onnx"),
            threshold: 0.8
        )
        let result = detector.detect(samples: [Float](repeating: 0, count: 32000), sampleRate: 16000)
        guard case .error(let code) = result else {
            return XCTFail("Expected .error, got \(result)")
        }
        XCTAssertFalse(code.isEmpty)
        detector.release()
    }

    func test_detector_emptySamples_returnsError() {
        let detector = WakeWordDetector(
            melModel: URL(fileURLWithPath: "/nonexistent/mel.onnx"),
            embedModel: URL(fileURLWithPath: "/nonexistent/embed.onnx"),
            classifierModel: URL(fileURLWithPath: "/nonexistent/auris.onnx"),
            threshold: 0.8
        )
        let result = detector.detect(samples: [], sampleRate: 16000)
        guard case .error = result else {
            return XCTFail("Expected .error, got \(result)")
        }
        detector.release()
    }

    func test_error_carriesNoDetectionDecision() {
        let result = WakeWordResult.error(code: "init_failed")
        switch result {
        case .detected, .notDetected:
            XCTFail("error must not be a detection decision")
        case .error(let code):
            XCTAssertEqual(code, "init_failed")
        }
    }

    func test_detected_carriesConfidence() {
        XCTAssertEqual(WakeWordResult.detected(confidence: 0.9), .detected(confidence: 0.9))
    }
}
