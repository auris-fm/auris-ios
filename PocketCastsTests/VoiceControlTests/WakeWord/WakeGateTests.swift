import XCTest
@testable import podcasts

final class WakeGateTests: XCTestCase {

    func test_error_discardsSegmentInBothModes() {
        XCTAssertEqual(
            WakeGate.decide(result: .error(code: "detect_failed"), listeningMode: .wakeWord, graceActive: false),
            .discardProcessing(errorCode: "detect_failed")
        )
        XCTAssertEqual(
            WakeGate.decide(result: .error(code: "detect_failed"), listeningMode: .continuous, graceActive: true),
            .discardProcessing(errorCode: "detect_failed")
        )
    }

    func test_notDetected_outsideGrace_dropsUtterance() {
        XCTAssertEqual(
            WakeGate.decide(result: .notDetected(confidence: 0.1), listeningMode: .wakeWord, graceActive: false),
            .dropUtterance
        )
    }

    func test_notDetected_duringGrace_forwardsFullSegment() {
        XCTAssertEqual(
            WakeGate.decide(result: .notDetected(confidence: 0.1), listeningMode: .continuous, graceActive: true),
            .forward(detected: false)
        )
        // Wake-word mode with an active grace period is equivalent.
        XCTAssertEqual(
            WakeGate.decide(result: .notDetected(confidence: 0.1), listeningMode: .wakeWord, graceActive: true),
            .forward(detected: false)
        )
    }

    func test_detected_forwardsInBothModes() {
        XCTAssertEqual(
            WakeGate.decide(result: .detected(confidence: 0.9), listeningMode: .wakeWord, graceActive: false),
            .forward(detected: true)
        )
        XCTAssertEqual(
            WakeGate.decide(result: .detected(confidence: 0.9), listeningMode: .continuous, graceActive: true),
            .forward(detected: true)
        )
    }
}
