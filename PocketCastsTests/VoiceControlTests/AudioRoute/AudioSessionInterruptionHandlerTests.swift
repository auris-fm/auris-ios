import XCTest
import AVFoundation
@testable import podcasts

@MainActor
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

    /// The system posts interruption notifications on an arbitrary thread. Everything
    /// the handler does in response — the `@Published` write and both callbacks — is
    /// main-actor work, so a background post must still deliver on main.
    ///
    /// Red against the unhopped handler: the callback runs on the posting thread.
    func test_beganNotificationPostedOffMain_deliversOnMain() {
        let handler = AudioSessionInterruptionHandler()
        let delivered = expectation(description: "onInterruptionBegan delivered")
        let observed = ThreadFlag()
        let posted = expectation(description: "posted from a background thread")

        handler.onInterruptionBegan = {
            observed.record(Thread.isMainThread)
            delivered.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // The notification publisher is synchronous, so this post is handled on
            // this very thread unless the handler hops to main itself.
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: nil,
                userInfo: [
                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
                ]
            )
            posted.fulfill()
        }

        wait(for: [posted, delivered], timeout: 5.0)
        XCTAssertTrue(observed.value,
                      "interruption handling must be delivered on the main thread, "
                      + "not on whatever thread posted the notification")
        XCTAssertTrue(handler.isInterrupted)
    }

    /// Same requirement for the ended path, which also reactivates the audio session.
    func test_endedNotificationPostedOffMain_deliversOnMain() {
        let handler = AudioSessionInterruptionHandler()
        handler.isInterrupted = true
        let delivered = expectation(description: "onInterruptionEnded delivered")
        let observed = ThreadFlag()
        let posted = expectation(description: "posted from a background thread")

        handler.onInterruptionEnded = {
            observed.record(Thread.isMainThread)
            delivered.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: nil,
                userInfo: [
                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                    AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
                ]
            )
            posted.fulfill()
        }

        wait(for: [posted, delivered], timeout: 5.0)
        XCTAssertTrue(observed.value,
                      "interruption handling must be delivered on the main thread")
    }
}

/// Records a boolean from whichever thread fulfils the expectation, so the
/// assertion can be made on the test's thread after the wait.
private final class ThreadFlag {
    private let lock = NSLock()
    private var stored = false

    func record(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
