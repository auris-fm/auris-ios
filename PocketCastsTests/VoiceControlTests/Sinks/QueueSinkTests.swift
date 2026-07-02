import XCTest
@testable import podcasts

final class QueueSinkTests: XCTestCase {

    func test_sink_initialization_doesNotCrash() {
        let sink = QueueSink(playbackManager: .shared)
        XCTAssertNotNil(sink)
    }

    func test_addTop_nonexistent_returnsSpoken() {
        let sink = QueueSink(playbackManager: .shared)
        let response = sink.addTop(episode: "nonexistent-uuid")
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("not found"))
        } else {
            XCTFail("Expected spoken response for nonexistent episode")
        }
    }

    func test_addBottom_nonexistent_returnsSpoken() {
        let sink = QueueSink(playbackManager: .shared)
        let response = sink.addBottom(episode: "nonexistent-uuid")
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("not found"))
        } else {
            XCTFail("Expected spoken response for nonexistent episode")
        }
    }

    func test_clear_returnsEarcon() {
        let sink = QueueSink(playbackManager: .shared)
        let response = sink.clear()
        XCTAssertEqual(response, .earcon(.success))
    }

    func test_queryContents_returnsSpoken() {
        let sink = QueueSink(playbackManager: .shared)
        let response = sink.queryContents()
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("episodes") || text.contains("queue") || text.contains("0") || text.contains("No"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_queryNext_returnsSpoken() {
        let sink = QueueSink(playbackManager: .shared)
        let response = sink.queryNext()
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("Next") || text.contains("empty") || text.contains("Queue"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_queryLength_returnsSpoken() {
        let sink = QueueSink(playbackManager: .shared)
        let response = sink.queryLength()
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("minutes") || text.contains("hours") || text.contains("remaining"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_queryIsQueued_nonexistent_returnsSpoken() {
        let sink = QueueSink(playbackManager: .shared)
        let response = sink.queryIsQueued(episode: "nonexistent-uuid")
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("Yes") || text.contains("No"))
        } else {
            XCTFail("Expected spoken response")
        }
    }
}
