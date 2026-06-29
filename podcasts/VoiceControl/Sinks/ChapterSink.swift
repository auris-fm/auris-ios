import Foundation

class ChapterSink: VoiceChapterSink {
    private let playbackManager: PlaybackManager

    init(playbackManager: PlaybackManager) { self.playbackManager = playbackManager }

    func next() -> VoiceResponse {
        playbackManager.skipToNextChapter(startPlaybackAfterSkip: true)
        return .spoken("Next chapter")
    }

    func previous() -> VoiceResponse {
        playbackManager.skipToPreviousChapter(startPlaybackAfterSkip: true)
        return .spoken("Previous chapter")
    }

    func byIndex(_ index: Int) -> VoiceResponse {
        guard let chapter = playbackManager.chapterAt(index: index) else {
            return .spoken("Chapter not found")
        }
        playbackManager.skipToChapter(chapter, startPlaybackAfterSkip: true)
        return .spoken("Jumped to chapter \(index + 1)")
    }

    func byTitle(_ title: String) -> VoiceResponse {
        let chapterCount = playbackManager.chapterCount(onlyPlayable: true)
        for i in 0..<chapterCount {
            if let chapter = playbackManager.playableChapterAt(index: i),
               chapter.title.localizedCaseInsensitiveContains(title) {
                playbackManager.skipToChapter(chapter, startPlaybackAfterSkip: true)
                return .spoken("Jumped to \(chapter.title)")
            }
        }
        return .spoken("Chapter not found")
    }

    func openLink(index: Int?, query: String?) -> VoiceResponse {
        // Chapter links are URL-based; delegate to system URL opening
        if let idx = index, let chapter = playbackManager.chapterAt(index: idx), let urlStr = chapter.url, let url = URL(string: urlStr) {
            UIApplication.shared.open(url)
            return .earcon(.success)
        }
        return .spoken("No link available")
    }

    func queryList() -> VoiceResponse {
        let count = playbackManager.chapterCount()
        var items: [String] = []
        for i in 0..<min(count, 10) {
            if let ch = playbackManager.chapterAt(index: i) {
                items.append(ch.title)
            }
        }
        let list = items.joined(separator: ", ")
        return .spoken("\(count) chapters: \(list)")
    }

    func queryCurrent() -> VoiceResponse {
        let chapters = playbackManager.currentChapters()
        if let visible = chapters.visibleChapter {
            return .spoken("Chapter \(chapters.index): \(visible.title)")
        }
        return .spoken("No active chapter")
    }

    func queryCount() -> VoiceResponse {
        let count = playbackManager.chapterCount()
        return .spoken("\(count) chapters")
    }

    func queryNext() -> VoiceResponse {
        let chapters = playbackManager.currentChapters()
        let nextIndex = chapters.index + 1
        if let next = playbackManager.chapterAt(index: nextIndex) {
            return .spoken("Next: \(next.title)")
        }
        return .spoken("No more chapters")
    }
}
