import Foundation

/// Minimal playback seam for `PlaybackManagerSink`.
///
/// Allows test injection of a mock playback manager without depending on
/// the concrete `PlaybackManager` class (which has a private init).
protocol PlaybackManagerProtocol {
    /// Whether playback is currently running. The cloud route's hold logic reads
    /// this to decide whether a turn may pause and later release playback (a
    /// pause the user made themselves must not be released).
    var isPlaying: Bool { get }
    func duration() -> TimeInterval
    func currentTime() -> TimeInterval
    func seekTo(time: TimeInterval)
    func pause()
    func play()
    func skipToNextUpNextEpisode() -> String?
    /// The skip WITH its actual decision: `outcome` is returned at the manager's own
    /// guard/action branches (played episode — shuffle-attributed — vs decline). The
    /// `presentationTitle` carries only the historical spoken candidate and proves nothing.
    func skipToNextUpNextEpisodeWithFact() -> (presentationTitle: String?, outcome: PlaybackManager.NextEpisodeSkipOutcome)
}

/// Default implementation of `VoicePlaybackSink` backed by `PlaybackManager`.
///
/// Per the intent-routing recovery contract (PR 59, cloud-seek-relative), this
/// sink owns the app's configurable seek interval and applies it in the
/// request's direction when the model produces a direction-only call.
class PlaybackManagerSink: VoicePlaybackSink {
    private let playbackManager: PlaybackManagerProtocol
    private let templates = SpokenTemplateResolver()

    init(playbackManager: PlaybackManagerProtocol) {
        self.playbackManager = playbackManager
    }

    var isPlaying: Bool { playbackManager.isPlaying }

    func pause() -> VoiceResponse {
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        playbackManager.pause()
        return .earcon(.success)
    }

    /// THE FACT CHANNEL (spec 32305c22 ruling): pause is an IDEMPOTENT success by the existing
    /// action contract — a prior paused state alone does not turn it into a refusal — so the
    /// fact is completed in both worlds, stated at the sink rather than inferred from the earcon.
    func pauseWithFact() -> (response: VoiceResponse, fact: SinkActionFact?) {
        let response = pause()
        return (response, SinkActionFact(state: "completed", reason: nil))
    }

    /// THE DISCRIMINATING SITE: the skip happens ONLY when the up-next queue is non-empty; with
    /// none, the sink speaks the same success-shaped template but NOTHING moved. The fact is
    /// emitted at that real decision: skip performed → completed; no object to act on →
    /// not_run/precondition_failed. The user-facing presentation is preserved unchanged.
    func nextEpisodeWithFact() -> (response: VoiceResponse, fact: SinkActionFact?) {
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        let result = playbackManager.skipToNextUpNextEpisodeWithFact()
        // The fact is the action's OWN decision from the manager's guard/action
        // branches — never the pre-read candidate title, which exists even when
        // the action declines (reviewer 50103ef9).
        let fact: SinkActionFact
        switch result.outcome {
        case .played: fact = SinkActionFact(state: "completed", reason: nil)
        case .declined: fact = SinkActionFact(state: "not_run", reason: "precondition_failed")
        }
        let response = VoiceResponse.spoken(templates.resolve("playback.next_episode", result.presentationTitle ?? "next episode"))
        return (response, fact)
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
            let interval = direction == .backward ? Settings.skipBackTime : Settings.skipForwardTime
            deltaMs = (direction == .backward ? -1 : 1) * interval * 1000
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
        // Resolve negative positions against episode duration.
        // Negative = offset from the episode end.
        let duration = playbackManager.duration()
        let position: TimeInterval
        if positionSeconds < 0 {
            let offsetFromEnd = Double(abs(positionSeconds))
            position = max(0.0, duration - offsetFromEnd)
        } else {
            position = Double(positionSeconds)
        }
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
