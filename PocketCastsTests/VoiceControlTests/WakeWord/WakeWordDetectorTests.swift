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

    // MARK: - Command window lifecycle

    func test_commandWindow_opensOnWakeWord() {
        let manager = CommandWindowManager()
        XCTAssertFalse(manager.isOpen)
        manager.onWakeWordDetected()
        XCTAssertTrue(manager.isOpen)
    }

    func test_commandWindow_staysOpenBeforeTimeout() {
        let manager = CommandWindowManager()
        manager.onWakeWordDetected()
        // tick immediately — window should still be open (30s timeout not expired)
        manager.tick()
        XCTAssertTrue(manager.isOpen)
    }

    func test_speechActivity_keepsWindowOpen() {
        let manager = CommandWindowManager()
        manager.onWakeWordDetected()
        manager.onSpeechActivity()
        manager.tick()
        XCTAssertTrue(manager.isOpen)
    }

    // MARK: - Break methods

    func test_onAudioRouteChanged_closesWindow() {
        let manager = CommandWindowManager()
        manager.onWakeWordDetected()
        XCTAssertTrue(manager.isOpen)
        manager.onAudioRouteChanged()
        XCTAssertFalse(manager.isOpen)
    }

    func test_onAppBackgrounded_closesWindow() {
        let manager = CommandWindowManager()
        manager.onWakeWordDetected()
        XCTAssertTrue(manager.isOpen)
        manager.onAppBackgrounded()
        XCTAssertFalse(manager.isOpen)
    }

    func test_breakMethod_onClosedWindow_noops() {
        let manager = CommandWindowManager()
        XCTAssertFalse(manager.isOpen)
        // Should not crash or change state
        manager.onAudioRouteChanged()
        manager.onAppBackgrounded()
        XCTAssertFalse(manager.isOpen)
    }

    // MARK: - State change callback

    func test_onWindowStateChange_calledForOpenAndClose() {
        let manager = CommandWindowManager()
        var states: [Bool] = []
        manager.onWindowStateChange = { states.append($0) }

        manager.onWakeWordDetected()
        XCTAssertEqual(states, [true])

        manager.onAudioRouteChanged()
        XCTAssertEqual(states, [true, false])
    }
}
