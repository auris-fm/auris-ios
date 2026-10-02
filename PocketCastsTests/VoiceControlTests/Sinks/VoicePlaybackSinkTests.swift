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

    func test_mockSink_seekRelative_withDelta_callsCorrectly() {
        let sink = MockPlaybackSink()
        let response = sink.seekRelative(deltaSeconds: 30, direction: .forward)
        XCTAssertEqual(response, .silent)
        XCTAssertEqual(sink.lastSeekRelativeDelta, 30)
    }

    func test_mockSink_seekRelative_withNilDelta_callsCorrectly() {
        let sink = MockPlaybackSink()
        let response = sink.seekRelative(deltaSeconds: nil, direction: .backward)
        XCTAssertEqual(response, .silent)
        XCTAssertNil(sink.lastSeekRelativeDelta)
        XCTAssertEqual(sink.lastSeekRelativeDirection, .backward)
    }

    func test_mockSink_seekRelative_withNegativeDelta() {
        let sink = MockPlaybackSink()
        let response = sink.seekRelative(deltaSeconds: -15, direction: .forward)
        XCTAssertEqual(response, .silent)
        XCTAssertEqual(sink.lastSeekRelativeDelta, -15)
    }

    func test_mockSink_seekTo_callsCorrectly() {
        let sink = MockPlaybackSink()
        let response = sink.seekTo(positionSeconds: 120)
        XCTAssertEqual(response, .silent)
        XCTAssertEqual(sink.lastSeekToPosition, 120)
    }

    func test_mockSink_seekTo_withDuration_callsCorrectly() {
        let sink = MockPlaybackSink()
        let response = sink.seekTo(positionSeconds: 120, episodeDurationSeconds: 600)
        XCTAssertEqual(response, .silent)
        XCTAssertEqual(sink.lastSeekToPosition, 120)
        XCTAssertEqual(sink.lastEpisodeDuration, 600)
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
    var lastSeekRelativeDirection: SeekDirection = .forward
    var lastSeekToPosition: Int?
    var lastEpisodeDuration: Int?
    var nextEpisodeTitle: String?

    func pause() -> VoiceResponse {
        pauseCalled = true
        return .earcon(.success)
    }

    func resume() -> VoiceResponse {
        .silent
    }

    func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse {
        lastSeekRelativeDelta = deltaSeconds
        lastSeekRelativeDirection = direction
        return .silent
    }

    func seekTo(positionSeconds: Int) -> VoiceResponse {
        lastSeekToPosition = positionSeconds
        return .silent
    }

    func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse {
        lastSeekToPosition = positionSeconds
        lastEpisodeDuration = episodeDurationSeconds
        return .silent
    }

    func nextEpisode() -> VoiceResponse {
        if let title = nextEpisodeTitle {
            return .spoken("Playing \(title)")
        }
        return .earcon(.nextEpisode)
    }
}
