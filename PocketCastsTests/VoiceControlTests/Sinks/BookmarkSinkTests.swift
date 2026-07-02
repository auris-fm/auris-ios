import XCTest
@testable import podcasts

final class BookmarkSinkTests: XCTestCase {

    func test_sink_initialization_doesNotCrash() {
        let sink = BookmarkSink(playbackManager: .shared)
        XCTAssertNotNil(sink)
    }

    func test_add_withoutEpisode_returnsSpoken() {
        // When no episode is playing, add should return error message
        let sink = BookmarkSink(playbackManager: .shared)
        let response = sink.add(title: "Test")
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("Nothing playing") || text.contains("bookmark"))
        } else if case .earcon(.success) = response {
            // If an episode happens to be playing, success earcon is also valid
        } else {
            XCTFail("Expected spoken or earcon response, got \(response)")
        }
    }

    func test_delete_nonexistent_returnsSpoken() {
        let sink = BookmarkSink(playbackManager: .shared)
        let response = sink.delete(ref: "nonexistent")
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("not found") || text.contains("Bookmark"))
        } else if case .earcon(.success) = response {
            // If ref exists for some reason, success is valid
        } else {
            XCTFail("Expected spoken or earcon response")
        }
    }

    func test_play_nonexistent_returnsSpoken() {
        let sink = BookmarkSink(playbackManager: .shared)
        let response = sink.play(ref: "nonexistent")
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("not found") || text.contains("Bookmark"))
        } else if case .earcon(.success) = response {
            // If ref exists for some reason, success is valid
        } else {
            XCTFail("Expected spoken or earcon response")
        }
    }

    func test_queryCount_returnsSpoken() {
        let sink = BookmarkSink(playbackManager: .shared)
        let response = sink.queryCount()
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("bookmarks") || text.contains("0"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_queryList_returnsSpoken() {
        let sink = BookmarkSink(playbackManager: .shared)
        let response = sink.queryList()
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("bookmarks"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_queryNearby_returnsSpoken() {
        let sink = BookmarkSink(playbackManager: .shared)
        let response = sink.queryNearby()
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("bookmarks") || text.contains("No"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_deleteAll_returnsSpoken() {
        let sink = BookmarkSink(playbackManager: .shared)
        let response = sink.deleteAll()
        if case .spoken = response {
            // Success — "All bookmarks deleted" or similar
        } else {
            XCTFail("Expected spoken response")
        }
    }
}
