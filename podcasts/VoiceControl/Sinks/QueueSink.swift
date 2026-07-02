import Foundation
import PocketCastsDataModel

class QueueSink: VoiceQueueSink {
    private let playbackManager: PlaybackManager
    private let dataManager: DataManager
    private let templates = SpokenTemplateResolver()

    init(playbackManager: PlaybackManager, dataManager: DataManager = .sharedManager) {
        self.playbackManager = playbackManager
        self.dataManager = dataManager
    }

    func addTop(episode: String) -> VoiceResponse {
        guard let episode = dataManager.findBaseEpisode(uuid: episode) else {
            return .spoken(templates.resolve("queue.episode_not_found"))
        }
        playbackManager.addToUpNext(episode: episode, ignoringQueueLimit: false, toTop: true, userInitiated: false)
        return .earcon(.success)
    }

    func addBottom(episode: String) -> VoiceResponse {
        guard let episode = dataManager.findBaseEpisode(uuid: episode) else {
            return .spoken(templates.resolve("queue.episode_not_found"))
        }
        playbackManager.addToUpNext(episode: episode, ignoringQueueLimit: false, toTop: false, userInitiated: false)
        return .earcon(.success)
    }

    func remove(episode: String) -> VoiceResponse {
        let episode = dataManager.findBaseEpisode(uuid: episode)
        playbackManager.removeIfPlayingOrQueued(episode: episode, fireNotification: true)
        return .earcon(.success)
    }

    func moveToTop(episode: String) -> VoiceResponse {
        let episodes = dataManager.allUpNextEpisodes()
        guard let index = episodes.firstIndex(where: { $0.uuid == episode }) else {
            return .spoken(templates.resolve("queue.episode_not_in_queue"))
        }
        dataManager.movePlaylistEpisode(from: index, to: 0)
        return .earcon(.success)
    }

    func moveToBottom(episode: String) -> VoiceResponse {
        let episodes = dataManager.allUpNextEpisodes()
        guard let index = episodes.firstIndex(where: { $0.uuid == episode }) else {
            return .spoken(templates.resolve("queue.episode_not_in_queue"))
        }
        dataManager.movePlaylistEpisode(from: index, to: episodes.count - 1)
        return .earcon(.success)
    }

    func clear() -> VoiceResponse {
        dataManager.deleteAllUpNextEpisodes()
        return .earcon(.success)
    }

    func removeByPodcast(podcast: String) -> VoiceResponse {
        let episodes = dataManager.allUpNextEpisodes()
        let toRemove = episodes.filter { $0.parentIdentifier() == podcast }
        for episode in toRemove {
            dataManager.saveUpNextRemove(episodeUuid: episode.uuid)
        }
        return .earcon(.success)
    }

    func sort(sortOrder: SortOrder) -> VoiceResponse {
        // Sort is not directly supported; re-queue in reverse order for oldestFirst
        let episodes = dataManager.allUpNextEpisodes()
        dataManager.deleteAllUpNextEpisodes()
        let sorted = sortOrder == .oldestFirst ? episodes.reversed() : episodes
        for episode in sorted {
            dataManager.saveUpNextAddToBottom(episodeUuid: episode.uuid)
        }
        return .earcon(.success)
    }

    func queryContents() -> VoiceResponse {
        let episodes = dataManager.allUpNextEpisodes()
        let titles = episodes.prefix(5).map { $0.displayableTitle() }.joined(separator: ", ")
        return .spoken(templates.resolve("queue.contents", episodes.count, titles))
    }

    func queryNext() -> VoiceResponse {
        if let next = dataManager.allUpNextEpisodes().first {
            return .spoken(templates.resolve("queue.next", next.displayableTitle()))
        }
        return .spoken(templates.resolve("queue.empty"))
    }

    func queryLength() -> VoiceResponse {
        let episodes = dataManager.allUpNextEpisodes()
        let total = episodes.reduce(0.0) { $0 + $1.duration }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        if hours > 0 {
            return .spoken(templates.resolve("queue.remaining_hours", hours, minutes))
        }
        return .spoken(templates.resolve("queue.remaining_minutes", minutes))
    }

    func queryIsQueued(episode: String) -> VoiceResponse {
        let isInQueue = playbackManager.inUpNext(episode: dataManager.findBaseEpisode(uuid: episode))
        return .spoken(templates.resolve(isInQueue ? "queue.yes" : "queue.no"))
    }
}
