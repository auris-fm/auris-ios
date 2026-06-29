import Foundation

class PlaybackManagerSink: VoicePlaybackSink {
    private let playbackManager: PlaybackManager

    init(playbackManager: PlaybackManager) { self.playbackManager = playbackManager }

    func pause() -> VoiceResponse {
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        playbackManager.pause()
        return .earcon(.success)
    }

    func resume() -> VoiceResponse {
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        playbackManager.play()
        return .silent
    }

    func seekRelative(deltaSeconds: Int) -> VoiceResponse {
        let deltaMs = deltaSeconds * 1000
        let currentPos = Int(playbackManager.currentTime() * 1000)
        let duration = Int(playbackManager.duration() * 1000)
        let clamped = max(0, min(duration, currentPos + deltaMs))
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        playbackManager.seekTo(time: TimeInterval(clamped) / 1000.0)
        return .silent
    }

    func seekTo(positionSeconds: Int) -> VoiceResponse {
        let position = TimeInterval(positionSeconds)
        let duration = playbackManager.duration()
        let clamped = max(0.0, min(duration, position))
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        playbackManager.seekTo(time: clamped)
        return .silent
    }

    func nextEpisode() -> VoiceResponse {
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        let title = playbackManager.skipToNextUpNextEpisode()
        return .spoken("Playing \(title ?? "next episode")")
    }
}
