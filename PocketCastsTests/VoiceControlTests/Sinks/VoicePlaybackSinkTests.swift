import XCTest
@testable import podcasts

final class VoicePlaybackSinkTests: XCTestCase {

    func test_mockSink_pause_returnsSuccessEarcon() {
        let sink = MockPlaybackSink()
        let response = sink.pause()
        XCTAssertEqual(response, .earcon(.success))
    }

    func test_mockSink_resume_returnsSilent() {
        let sink = MockPlaybackSink()
        let response = sink.resume()
        XCTAssertEqual(response, .silent)
    }

    func test_mockSink_seekRelative_callsCorrectly() {
        let sink = MockPlaybackSink()
        let response = sink.seekRelative(deltaSeconds: 30)
        XCTAssertEqual(response, .silent)
        XCTAssertEqual(sink.lastSeekRelativeDelta, 30)
    }

    func test_mockSink_seekTo_callsCorrectly() {
        let sink = MockPlaybackSink()
        let response = sink.seekTo(positionSeconds: 120)
        XCTAssertEqual(response, .silent)
        XCTAssertEqual(sink.lastSeekToPosition, 120)
    }

    func test_mockSink_nextEpisode_returnsSpoken() {
        let sink = MockPlaybackSink()
        sink.nextEpisodeTitle = "The Daily"
        let response = sink.nextEpisode()
        XCTAssertEqual(response, .spoken("Playing The Daily"))
    }
}

private final class MockPlaybackSink: VoicePlaybackSink {
    var pauseCalled = false
    var lastSeekRelativeDelta: Int?
    var lastSeekToPosition: Int?
    var nextEpisodeTitle: String?

    func pause() -> VoiceResponse {
        pauseCalled = true
        return .earcon(.success)
    }

    func resume() -> VoiceResponse {
        .silent
    }

    func seekRelative(deltaSeconds: Int) -> VoiceResponse {
        lastSeekRelativeDelta = deltaSeconds
        return .silent
    }

    func seekTo(positionSeconds: Int) -> VoiceResponse {
        lastSeekToPosition = positionSeconds
        return .silent
    }

    func nextEpisode() -> VoiceResponse {
        if let title = nextEpisodeTitle {
            return .spoken("Playing \(title)")
        }
        return .earcon(.nextEpisode)
    }
}
