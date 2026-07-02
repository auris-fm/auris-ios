import Foundation

class BookmarkSink: VoiceBookmarkSink {
    private let playbackManager: PlaybackManager
    private let templates = SpokenTemplateResolver()

    init(playbackManager: PlaybackManager) { self.playbackManager = playbackManager }

    func add(title: String?) -> VoiceResponse {
        guard let episode = playbackManager.currentEpisode() else {
            return .spoken(templates.resolve("playback.nothing_playing"))
        }
        playbackManager.bookmarkManager.add(
            to: episode,
            at: playbackManager.currentTime(),
            title: title ?? L10n.bookmarkDefaultTitle
        )
        return .earcon(.success)
    }

    func rename(ref: String, title: String) -> VoiceResponse {
        guard let bookmark = playbackManager.bookmarkManager.bookmark(for: ref) else {
            return .spoken(templates.resolve("bookmark.not_found"))
        }
        Task {
            await playbackManager.bookmarkManager.update(title: title, for: bookmark)
        }
        return .earcon(.success)
    }

    func play(ref: String) -> VoiceResponse {
        guard let bookmark = playbackManager.bookmarkManager.bookmark(for: ref) else {
            return .spoken(templates.resolve("bookmark.not_found"))
        }
        playbackManager.playBookmark(bookmark, source: .voiceCommands)
        return .earcon(.success)
    }

    func delete(ref: String) -> VoiceResponse {
        guard let bookmark = playbackManager.bookmarkManager.bookmark(for: ref) else {
            return .spoken(templates.resolve("bookmark.not_found"))
        }
        Task {
            await playbackManager.bookmarkManager.remove([bookmark])
        }
        return .earcon(.success)
    }

    func deleteAll() -> VoiceResponse {
        let all = playbackManager.bookmarkManager.allBookmarks()
        Task {
            await playbackManager.bookmarkManager.remove(all)
        }
        return .spoken(templates.resolve("bookmark.all_deleted"))
    }

    func queryList() -> VoiceResponse {
        let bookmarks = playbackManager.bookmarkManager.allBookmarks()
        let titles = bookmarks.prefix(5).map { $0.title }.joined(separator: ", ")
        return .spoken(templates.resolve("bookmark.list", bookmarks.count, titles))
    }

    func queryCount() -> VoiceResponse {
        let count = playbackManager.bookmarkManager.allBookmarks().count
        return .spoken(templates.resolve("bookmark.count", count))
    }

    func queryNearby() -> VoiceResponse {
        let currentTime = playbackManager.currentTime()
        let nearby = playbackManager.bookmarkManager.allBookmarks()
            .filter { abs($0.time - currentTime) < 60 }
        if nearby.isEmpty {
            return .spoken(templates.resolve("bookmark.no_nearby"))
        }
        return .spoken(templates.resolve("bookmark.nearby", nearby.count))
    }
}
