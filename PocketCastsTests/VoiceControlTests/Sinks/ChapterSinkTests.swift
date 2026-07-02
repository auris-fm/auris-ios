import XCTest
@testable import podcasts

final class ChapterSinkTests: XCTestCase {

    func test_sink_initialization_doesNotCrash() {
        let sink = ChapterSink(playbackManager: .shared)
        XCTAssertNotNil(sink)
    }

    func test_next_returnsSpoken() {
        let sink = ChapterSink(playbackManager: .shared)
        let response = sink.next()
        if case .spoken = response {
            // Success — either "Next chapter" or "No more chapters"
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_previous_returnsSpoken() {
        let sink = ChapterSink(playbackManager: .shared)
        let response = sink.previous()
        if case .spoken = response {
            // Success — any spoken response is valid
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_byIndex_returnsSpoken() {
        let sink = ChapterSink(playbackManager: .shared)
        let response = sink.byIndex(0)
        if case .spoken = response {
            // Success — either jump confirmation or "not found"
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_byTitle_returnsSpoken() {
        let sink = ChapterSink(playbackManager: .shared)
        let response = sink.byTitle("Introduction")
        if case .spoken = response {
            // Success — either jump confirmation or "not found"
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_queryCount_returnsSpoken() {
        let sink = ChapterSink(playbackManager: .shared)
        let response = sink.queryCount()
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("chapters") || text.contains("0") || text.contains("No"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_queryCurrent_returnsSpoken() {
        let sink = ChapterSink(playbackManager: .shared)
        let response = sink.queryCurrent()
        if case .spoken = response {
            // Success — any spoken response is valid
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_queryNext_returnsSpoken() {
        let sink = ChapterSink(playbackManager: .shared)
        let response = sink.queryNext()
        if case .spoken = response {
            // Success — either "Next: ..." or "No more chapters"
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_queryList_returnsSpoken() {
        let sink = ChapterSink(playbackManager: .shared)
        let response = sink.queryList()
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("chapters"))
        } else {
            XCTFail("Expected spoken response")
        }
    }
}
