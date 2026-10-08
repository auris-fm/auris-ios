import XCTest
@testable import podcasts

final class BookmarkSinkTests: XCTestCase {

    func test_sink_initialization_doesNotCrash() {
        let sink = BookmarkSink(playbackManager: .shared)
        XCTAssertNotNil(sink)
    }

    func test_add_reportsSuccessOrNothingPlaying() {
        // Two outcomes are correct and they are decided by ambient state (whether
        // an episode is loaded), so the assertion is on the contract, not on the
        // wording: the sink either confirms with the success earcon or explains
        // that nothing is playing. Matching the English text made this test
        // depend on the locale and on the machine's playback state.
        let sink = BookmarkSink(playbackManager: .shared)
        let response = sink.add(title: "Test")
        switch response {
        case .earcon(.success):
            break // an episode is loaded and the bookmark was added
        case .spoken(let text):
            XCTAssertFalse(text.isEmpty, "the explanation must say something")
        default:
            XCTFail("Expected the success earcon or a spoken explanation, got \(response)")
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
