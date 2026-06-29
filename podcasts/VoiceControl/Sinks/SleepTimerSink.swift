import Foundation

class SleepTimerSink: VoiceSleepSink {
    private let playbackManager: PlaybackManager

    init(playbackManager: PlaybackManager) { self.playbackManager = playbackManager }

    func set(minutes: Int) -> VoiceResponse {
        let interval = TimeInterval(minutes * 60)
        playbackManager.setSleepTimerInterval(interval)
        return .spoken("Sleep timer set for \(minutes) minutes")
    }

    func endOfEpisode() -> VoiceResponse {
        playbackManager.numberOfEpisodesToSleepAfter = 1
        return .earcon(.success)
    }

    func endOfChapter() -> VoiceResponse {
        // Sleep after 1 episode is the closest available mechanism
        playbackManager.numberOfEpisodesToSleepAfter = 1
        return .earcon(.success)
    }

    func addTime(minutes: Int) -> VoiceResponse {
        let added = TimeInterval(minutes * 60)
        playbackManager.sleepTimeRemaining += added
        NotificationCenter.postOnMainThread(notification: Constants.Notifications.sleepTimerChanged)
        return .spoken("Added \(minutes) minutes")
    }

    func cancel() -> VoiceResponse {
        playbackManager.cancelSleepTimer(userInitiated: false)
        return .earcon(.success)
    }

    func query() -> VoiceResponse {
        if playbackManager.sleepTimerActive() {
            let remaining = Int(playbackManager.sleepTimeRemaining / 60)
            if remaining > 0 {
                return .spoken("\(remaining) minutes remaining")
            }
            return .spoken("Sleep after episode")
        }
        return .spoken("Sleep timer is not active")
    }
}
