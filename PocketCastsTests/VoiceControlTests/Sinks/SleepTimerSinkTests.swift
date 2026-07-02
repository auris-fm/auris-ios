import XCTest
@testable import podcasts

final class SleepTimerSinkTests: XCTestCase {

    func test_sink_initialization_doesNotCrash() {
        let sink = SleepTimerSink(playbackManager: .shared)
        XCTAssertNotNil(sink)
    }

    func test_set_returnsSpoken() {
        let sink = SleepTimerSink(playbackManager: .shared)
        let response = sink.set(minutes: 30)
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("30"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_endOfEpisode_returnsEarcon() {
        let sink = SleepTimerSink(playbackManager: .shared)
        let response = sink.endOfEpisode()
        XCTAssertEqual(response, .earcon(.success))
    }

    func test_endOfChapter_returnsEarcon() {
        let sink = SleepTimerSink(playbackManager: .shared)
        let response = sink.endOfChapter()
        XCTAssertEqual(response, .earcon(.success))
    }

    func test_addTime_returnsSpoken() {
        let sink = SleepTimerSink(playbackManager: .shared)
        let response = sink.addTime(minutes: 5)
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("5"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_cancel_returnsEarcon() {
        let sink = SleepTimerSink(playbackManager: .shared)
        let response = sink.cancel()
        XCTAssertEqual(response, .earcon(.success))
    }

    func test_query_returnsSpoken() {
        let sink = SleepTimerSink(playbackManager: .shared)
        let response = sink.query()
        if case .spoken = response {
            // Success — any spoken response is valid
        } else {
            XCTFail("Expected spoken response")
        }
    }
}
