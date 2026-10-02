import Foundation

/// Default implementation of `VoicePlaybackSink` backed by `PlaybackManager`.
///
/// Per the intent-routing recovery contract (PR 59, cloud-seek-relative), this
/// sink owns the app's configurable seek interval and applies it in the
/// request's direction when the model produces a direction-only call.
class PlaybackManagerSink: VoicePlaybackSink {
    private let playbackManager: PlaybackManager
    private let templates = SpokenTemplateResolver()

    init(playbackManager: PlaybackManager) {
        self.playbackManager = playbackManager
    }

    var isPlaying: Bool { playbackManager.isPlaying }

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

    /// Seek relative to the current position.
    ///
    /// When `deltaSeconds` is nil the request stated no amount — the sink
    /// applies its own configurable interval in `direction`. When `deltaSeconds`
    /// is non-null it is used directly and `direction` is informational only
    /// (the sign of the delta decides).
    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse {
        let deltaMs: Int
        if let deltaSeconds {
            deltaMs = deltaSeconds * 1000
        } else {
            // Direction-only call — apply the app's default interval in the
            // request's direction. The sink owns this interval; the mapper
            // must never manufacture a delta for a direction-only call.
            deltaMs = (direction == .backward ? -1 : 1) * 30_000 // 30s default
        }

        let currentPos = Int(playbackManager.currentTime() * 1000)
        let duration = Int(playbackManager.duration() * 1000)
        let clamped = max(0, min(duration, currentPos + deltaMs))
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        playbackManager.seekTo(time: TimeInterval(clamped) / 1000.0)
        return .silent
    }

    /// Seek to an absolute position.
    ///
    /// When `positionSeconds` is negative it is an offset back from the episode
    /// end. The sink resolves that offset against the episode duration and
    /// bounds the result — never before the start and never past the end.
    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse {
        let position: TimeInterval
        if positionSeconds < 0 {
            // Negative: offset back from the episode end.
            let offsetFromEnd = Double(abs(positionSeconds))
            let durationSec = Double(episodeDurationSeconds)
            position = max(0, durationSec - offsetFromEnd)
        } else {
            position = Double(positionSeconds)
        }
        let duration = playbackManager.duration()
        let clamped = max(0.0, min(duration, position))
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        playbackManager.seekTo(time: clamped)
        return .silent
    }

    func seekTo(positionSeconds: Int) -> VoiceResponse {
        // Non-negative path: delegate to the duration-aware variant.
        // Episode duration is not available at this level; callers should use
        // the overload that accepts it for negative positions.
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
        return .spoken(templates.resolve("playback.next_episode", title ?? "next episode"))
    }
}
