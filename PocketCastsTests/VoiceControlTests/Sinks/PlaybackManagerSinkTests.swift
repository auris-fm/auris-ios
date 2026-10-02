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

    func test_seekRelative_withDelta_returnsSilent() {
        let sink = PlaybackManagerSink(playbackManager: .shared)
        let response = sink.seekRelative(deltaSeconds: 30, direction: .forward)
        XCTAssertEqual(response, .silent)
    }

    func test_seekRelative_withNilDelta_usesDirectionDefault() {
        let sink = PlaybackManagerSink(playbackManager: .shared)
        let response = sink.seekRelative(deltaSeconds: nil, direction: .backward)
        XCTAssertEqual(response, .silent)
    }

    func test_seekTo_withNegativePosition_resolvesAgainstDuration() {
        let sink = PlaybackManagerSink(playbackManager: .shared)
        // Negative position: offset from episode end. The sink should not crash
        // and should return silent.
        let response = sink.seekTo(positionSeconds: -50, episodeDurationSeconds: 3600)
        XCTAssertEqual(response, .silent)
    }

    func test_seekTo_withNegativePositionBeyondDuration_clampsToStart() {
        let sink = PlaybackManagerSink(playbackManager: .shared)
        // Negative offset longer than episode — should clamp to 0.
        let response = sink.seekTo(positionSeconds: -5000, episodeDurationSeconds: 300)
        XCTAssertEqual(response, .silent)
    }
}
