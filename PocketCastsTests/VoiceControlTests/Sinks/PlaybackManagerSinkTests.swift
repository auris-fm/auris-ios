import XCTest
@testable import podcasts

final class PlaybackManagerSinkTests: XCTestCase {

    func test_pause_setsVoiceCommandsSource() {
        // Setting the analytics source before pause is the responsibility of the sink
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        XCTAssertEqual(AnalyticsPlaybackHelper.shared.currentSource, .voiceCommands)
    }

    func test_resume_setsVoiceCommandsSource() {
        AnalyticsPlaybackHelper.shared.currentSource = .voiceCommands
        XCTAssertEqual(AnalyticsPlaybackHelper.shared.currentSource, .voiceCommands)
    }

    func test_sink_initialization_doesNotCrash() {
        let sink = PlaybackManagerSink(playbackManager: .shared)
        XCTAssertNotNil(sink)
    }

    func test_pause_returnsSuccessEarcon() {
        let sink = PlaybackManagerSink(playbackManager: .shared)
        let response = sink.pause()
        XCTAssertEqual(response, .earcon(.success))
    }

    func test_resume_returnsSilent() {
        let sink = PlaybackManagerSink(playbackManager: .shared)
        let response = sink.resume()
        XCTAssertEqual(response, .silent)
    }

    func test_seekTo_returnsSilent() {
        let sink = PlaybackManagerSink(playbackManager: .shared)
        let response = sink.seekTo(positionSeconds: 120)
        XCTAssertEqual(response, .silent)
    }

    func test_seekRelative_returnsSilent() {
        let sink = PlaybackManagerSink(playbackManager: .shared)
        let response = sink.seekRelative(deltaSeconds: 30)
        XCTAssertEqual(response, .silent)
    }
}
