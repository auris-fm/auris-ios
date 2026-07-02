import Foundation
import PocketCastsDataModel

class PlaybackQuerySink: VoicePlaybackQuerySink {
    private let playbackManager: PlaybackManager

    init(playbackManager: PlaybackManager) { self.playbackManager = playbackManager }

    func whatsPlaying() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() else {
            return .spoken("Nothing is playing")
        }
        return .spoken("Playing \(episode.displayableTitle())")
    }

    func position() -> VoiceResponse {
        let time = playbackManager.currentTime()
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return .spoken("\(minutes) minutes \(seconds) seconds")
    }

    func timeRemaining() -> VoiceResponse {
        let remaining = playbackManager.duration() - playbackManager.currentTime()
        let minutes = Int(remaining) / 60
        return .spoken("\(minutes) minutes remaining")
    }

    func episodeDuration() -> VoiceResponse {
        let duration = playbackManager.duration()
        let minutes = Int(duration) / 60
        return .spoken("\(minutes) minutes total")
    }

    func publishDate() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() as? Episode,
              let date = episode.publishedDate else {
            return .spoken("Unknown publish date")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return .spoken("Published \(formatter.string(from: date))")
    }

    func episodeDescription() -> VoiceResponse {
        return .spoken("Episode description unavailable")
    }

    func downloadStatus() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() else {
            return .spoken("Nothing playing")
        }
        let downloaded = episode.downloaded(pathFinder: DownloadManager.shared)
        return .spoken(downloaded ? "Downloaded" : "Streaming")
    }

    func episodeTitle() -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() else {
            return .spoken("Nothing playing")
        }
        return .spoken(episode.displayableTitle())
    }
}
