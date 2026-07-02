import XCTest
import AVFoundation
@testable import podcasts

final class AudioSessionInterruptionHandlerTests: XCTestCase {

    func test_beganNotification_setsIsInterruptedAndCallsOnInterruptionBegan() {
        let handler = AudioSessionInterruptionHandler()
        let beganExpectation = expectation(description: "onInterruptionBegan called")

        handler.onInterruptionBegan = {
            beganExpectation.fulfill()
        }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )

        wait(for: [beganExpectation], timeout: 1.0)
        XCTAssertTrue(handler.isInterrupted)
    }

    func test_endedNotificationWithShouldResume_setsIsInterruptedFalseAndCallsOnInterruptionEnded() {
        let handler = AudioSessionInterruptionHandler()
        let endedExpectation = expectation(description: "onInterruptionEnded called")

        // First set isInterrupted to true as if began happened
        handler.isInterrupted = true

        handler.onInterruptionEnded = {
            endedExpectation.fulfill()
        }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )

        wait(for: [endedExpectation], timeout: 1.0)
        XCTAssertFalse(handler.isInterrupted)
    }

    func test_endedNotificationWithoutShouldResume_setsIsInterruptedFalseButDoesNotCallOnInterruptionEnded() {
        let handler = AudioSessionInterruptionHandler()
        let endedExpectation = expectation(description: "onInterruptionEnded NOT called")
        endedExpectation.isInverted = true

        handler.isInterrupted = true

        handler.onInterruptionEnded = {
            endedExpectation.fulfill()
        }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: 0
            ]
        )

        wait(for: [endedExpectation], timeout: 1.0)
        XCTAssertFalse(handler.isInterrupted)
    }
}
