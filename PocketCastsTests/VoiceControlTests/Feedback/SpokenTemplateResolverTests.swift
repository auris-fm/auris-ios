import XCTest
@testable import podcasts

final class SpokenTemplateResolverTests: XCTestCase {

    private let resolver = SpokenTemplateResolver()

    func test_resolve_effectsSetSpeed() {
        let result = resolver.resolve("effects.set_speed", 1.5)
        // Template: "%gx speed" → "1.5x speed"
        XCTAssertTrue(result.contains("1.5"))
        XCTAssertTrue(result.contains("speed"))
    }

    func test_resolve_sleepSet() {
        let result = resolver.resolve("sleep.set", 30)
        XCTAssertTrue(result.contains("30"))
        XCTAssertTrue(result.contains("Sleep timer"))
    }

    func test_resolve_playbackPlaying() {
        let result = resolver.resolve("playback.playing", "Test Episode")
        XCTAssertTrue(result.contains("Test Episode"))
    }

    func test_resolve_positionCurrent() {
        let result = resolver.resolve("position.current", 2, 30)
        XCTAssertTrue(result.contains("2"))
        XCTAssertTrue(result.contains("30"))
    }

    func test_resolve_chapterJumpedToIndex() {
        let result = resolver.resolve("chapter.jumped_to_index", 3)
        XCTAssertTrue(result.contains("3"))
    }

    func test_resolve_missingKey_returnsEmpty() {
        let result = resolver.resolve("nonexistent.key")
        XCTAssertEqual(result, "")
    }

    func test_resolve_noArgKey() {
        let result = resolver.resolve("chapter.next")
        XCTAssertFalse(result.isEmpty)
    }

    func test_resolve_volumeCurrent() {
        let result = resolver.resolve("volume.current", 75)
        XCTAssertTrue(result.contains("75"))
    }

    func test_resolve_queueContents() {
        let result = resolver.resolve("queue.contents", 5, "Ep1, Ep2, Ep3")
        XCTAssertTrue(result.contains("5"))
        XCTAssertTrue(result.contains("Ep1"))
    }

    func test_resolve_bookmarkList() {
        let result = resolver.resolve("bookmark.list", 3, "B1, B2, B3")
        XCTAssertTrue(result.contains("3"))
        XCTAssertTrue(result.contains("B1"))
    }

    func test_resolve_generalDownloaded() {
        let result = resolver.resolve("general.downloaded")
        XCTAssertFalse(result.isEmpty)
    }

    func test_resolve_datePublished() {
        let result = resolver.resolve("date.published", "Jul 2, 2026")
        XCTAssertTrue(result.contains("Jul 2, 2026"))
    }
}
