import Foundation
import PocketCastsDataModel

class PlaybackQuerySink: VoicePlaybackQuerySink {
    private let playbackManager: PlaybackManager
    private let templates = SpokenTemplateResolver()

    init(playbackManager: PlaybackManager) { self.playbackManager = playbackManager }

    func whatsPlaying() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() else {
            return .spoken(templates.resolve("playback.nothing_playing"))
        }
        return .spoken(templates.resolve("playback.playing", episode.displayableTitle()))
    }

    func position() -> VoiceResponse {
        let time = playbackManager.currentTime()
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return .spoken(templates.resolve("position.current", minutes, seconds))
    }

    func timeRemaining() -> VoiceResponse {
        let remaining = playbackManager.duration() - playbackManager.currentTime()
        let minutes = Int(remaining) / 60
        return .spoken(templates.resolve("position.remaining", minutes))
    }

    func episodeDuration() -> VoiceResponse {
        let duration = playbackManager.duration()
        let minutes = Int(duration) / 60
        return .spoken(templates.resolve("position.duration", minutes))
    }

    func publishDate() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() as? Episode,
              let date = episode.publishedDate else {
            return .spoken(templates.resolve("general.unknown_publish_date"))
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return .spoken(templates.resolve("date.published", formatter.string(from: date)))
    }

    func episodeDescription() -> VoiceResponse {
        return .spoken(templates.resolve("general.episode_description_unavailable"))
    }

    func downloadStatus() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() else {
            return .spoken(templates.resolve("playback.nothing_playing"))
        }
        let downloaded = episode.downloaded(pathFinder: DownloadManager.shared)
        return .spoken(templates.resolve(downloaded ? "general.downloaded" : "general.streaming"))
    }

    func episodeTitle() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() else {
            return .spoken(templates.resolve("playback.nothing_playing"))
        }
        return .spoken(episode.displayableTitle())
    }
}
