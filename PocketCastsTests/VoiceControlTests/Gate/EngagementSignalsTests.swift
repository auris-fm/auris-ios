import XCTest
@testable import podcasts

final class EngagementSignalsTests: XCTestCase {

    // MARK: - AttendedSignal

    func test_attendedSignal_startsUnattended() {
        let signal = AttendedSignal()
        XCTAssertFalse(signal.isAttended)
    }

    func test_attendedSignal_userInteraction_setsAttended() {
        let signal = AttendedSignal()
        signal.onUserInteraction()
        XCTAssertTrue(signal.isAttended)
    }

    func test_attendedSignal_secondTouch_resetsTimer() {
        let signal = AttendedSignal()
        signal.onUserInteraction()
        signal.onUserInteraction() // should invalidate previous timer and start fresh
        XCTAssertTrue(signal.isAttended)
    }

    // MARK: - GracePeriodSignal

    func test_gracePeriodSignal_startsInactive() {
        let signal = GracePeriodSignal()
        XCTAssertFalse(signal.isActive)
    }

    func test_gracePeriodSignal_commandRecognized_setsActive() {
        let signal = GracePeriodSignal()
        signal.onCommandRecognized()
        XCTAssertTrue(signal.isActive)
    }

    func test_gracePeriodSignal_routeChange_breaksGracePeriod() {
        let signal = GracePeriodSignal()
        signal.onCommandRecognized()
        XCTAssertTrue(signal.isActive)
        signal.onAudioRouteChanged()
        XCTAssertFalse(signal.isActive)
    }

    func test_gracePeriodSignal_appBackgrounded_breaksGracePeriod() {
        let signal = GracePeriodSignal()
        signal.onCommandRecognized()
        XCTAssertTrue(signal.isActive)
        signal.onAppBackgrounded()
        XCTAssertFalse(signal.isActive)
    }

    func test_gracePeriodSignal_secondCommand_resetsTimer() {
        let signal = GracePeriodSignal()
        signal.onCommandRecognized()
        signal.onCommandRecognized()
        XCTAssertTrue(signal.isActive)
    }

    // MARK: - PlaybackRecencySignal

    func test_playbackRecencySignal_startsNotRecent() {
        let signal = PlaybackRecencySignal()
        XCTAssertFalse(signal.isRecent)
    }

    func test_playbackRecencySignal_playing_setsRecent() {
        let signal = PlaybackRecencySignal()
        signal.update(isPlaying: true)
        XCTAssertTrue(signal.isRecent)
    }

    func test_playbackRecencySignal_paused_keepsRecent() {
        let signal = PlaybackRecencySignal()
        signal.update(isPlaying: true)
        XCTAssertTrue(signal.isRecent)
        signal.update(isPlaying: false)
        // Still recent — timer hasn't expired yet
        XCTAssertTrue(signal.isRecent)
    }

    func test_playbackRecencySignal_resumeAfterPause_keepsRecent() {
        let signal = PlaybackRecencySignal()
        signal.update(isPlaying: true)
        signal.update(isPlaying: false) // pause
        signal.update(isPlaying: true)  // resume
        XCTAssertTrue(signal.isRecent)
    }
}
