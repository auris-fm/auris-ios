import AVFoundation
import XCTest
@testable import podcasts

/// An ended interruption carries `AVAudioSessionInterruptionOptionKey` whenever
/// the system posts it, but the notification is a plain `NotificationCenter`
/// message: anything else in the process can post one without that key, and the
/// playback handler must survive it. Missing options mean "no flags", which is
/// the same thing the handler already assumes when the value is zero — so an
/// absent key ends the interruption without resuming, never crashes the app.
final class InterruptionOptionKeyTests: XCTestCase {

    /// Posts an ended interruption with no option key at all and asserts the
    /// handler both survives it and does not resume playback.
    ///
    /// The manager is driven through the real notification it observes, so this
    /// exercises the same path a system (or in-process) post takes. Playback is
    /// not running here, so a resume would be wrong for two independent reasons;
    /// the assertion that matters is that handling completes at all.
    func test_endedInterruptionWithoutOptionKey_doesNotCrashAndDoesNotResume() {
        let manager = PlaybackManager.shared
        let wasPlayingBefore = manager.isPlaying

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            ]
        )

        // Reaching this line at all is the crash assertion: the handler runs
        // synchronously on the posting thread.
        XCTAssertFalse(manager.interruptionInProgress(),
                       "an ended interruption clears the in-progress flag even with no option key")
        XCTAssertEqual(manager.isPlaying, wasPlayingBefore,
                       "no option key means no shouldResume flag, so playback must not start")
    }

    /// The other side of the same rule: an explicit zero-valued option key is
    /// handled identically to an absent one. Pins that the default introduced for
    /// the missing key is the same value the handler already treated as "no
    /// resume", rather than a new behaviour.
    func test_endedInterruptionWithZeroOptions_behavesLikeAnAbsentKey() {
        let manager = PlaybackManager.shared
        let wasPlayingBefore = manager.isPlaying

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: 0
            ]
        )

        XCTAssertFalse(manager.interruptionInProgress())
        XCTAssertEqual(manager.isPlaying, wasPlayingBefore)
    }
}
