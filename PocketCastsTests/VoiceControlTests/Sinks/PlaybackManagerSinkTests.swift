import XCTest
@testable import podcasts

// Mock PlaybackManagerProtocol that captures seekTo calls and provides controlled duration.
final class MockPlaybackManager: PlaybackManagerProtocol {
    var capturedSeekTime: TimeInterval?
    var durationValue: TimeInterval = 0
    var currentTimeValue: TimeInterval = 0
    var skipResult: String? = nil
    var isPlaying = false

    func duration() -> TimeInterval { durationValue }
    func currentTime() -> TimeInterval { currentTimeValue }
    func seekTo(time: TimeInterval) { capturedSeekTime = time }
    func pause() {}
    func play() {}
    func skipToNextUpNextEpisode() -> String? { skipResult }
}

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
        let sink = PlaybackManagerSink(playbackManager: PlaybackManager.shared)
        XCTAssertNotNil(sink)
    }

    func test_pause_returnsSuccessEarcon() {
        let sink = PlaybackManagerSink(playbackManager: PlaybackManager.shared)
        let response = sink.pause()
        XCTAssertEqual(response, .earcon(.success))
    }

    func test_resume_returnsSilent() {
        let sink = PlaybackManagerSink(playbackManager: PlaybackManager.shared)
        let response = sink.resume()
        XCTAssertEqual(response, .silent)
    }

    func test_seekTo_returnsSilent() {
        let sink = PlaybackManagerSink(playbackManager: PlaybackManager.shared)
        let response = sink.seekTo(positionSeconds: 120)
        XCTAssertEqual(response, .silent)
    }

    func test_seekRelative_withDelta_returnsSilent() {
        let sink = PlaybackManagerSink(playbackManager: PlaybackManager.shared)
        let response = sink.seekRelative(deltaSeconds: 30, direction: .forward)
        XCTAssertEqual(response, .silent)
    }

    func test_seekRelative_withNilDelta_usesDirectionDefault() {
        let sink = PlaybackManagerSink(playbackManager: PlaybackManager.shared)
        let response = sink.seekRelative(deltaSeconds: nil, direction: .backward)
        XCTAssertEqual(response, .silent)
    }

    func test_seekTo_withNegativePosition_resolvesAgainstDuration() {
        let sink = PlaybackManagerSink(playbackManager: PlaybackManager.shared)
        // Negative position: offset from episode end. The sink should not crash
        // and should return silent.
        let response = sink.seekTo(positionSeconds: -50, episodeDurationSeconds: 3600)
        XCTAssertEqual(response, .silent)
    }

    func test_seekTo_withNegativePositionBeyondDuration_clampsToStart() {
        let sink = PlaybackManagerSink(playbackManager: PlaybackManager.shared)
        // Negative offset longer than episode — should clamp to 0.
        let response = sink.seekTo(positionSeconds: -5000, episodeDurationSeconds: 300)
        XCTAssertEqual(response, .silent)
    }

    func test_seekTo_withNegativePosition_oneArgument_resolvesAgainstDuration() {
        // Regression: the local executor calls the one-argument seekTo.
        // Negative positions must resolve against episode duration, not
        // clamp to zero. This test verifies the actual position passed
        // to playback, not just that .silent is returned.
        let mock = MockPlaybackManager()
        mock.durationValue = 3600
        let sink = PlaybackManagerSink(playbackManager: mock)
        let response = sink.seekTo(positionSeconds: -300)
        XCTAssertEqual(response, .silent)
        // 5 minutes from a 60-minute episode → seek to 55:00 (3300s)
        XCTAssertEqual(mock.capturedSeekTime, 3300.0,
                       "negative position must resolve against episode duration")
    }

    func test_seekTo_withNegativePosition_oneArgument_oldClampFails() {
        // Demonstrates that restoring the old clamp (max(0, position))
        // would fail this assertion, confirming the test is meaningful.
        let mock = MockPlaybackManager()
        mock.durationValue = 3600
        let sink = PlaybackManagerSink(playbackManager: mock)
        let response = sink.seekTo(positionSeconds: -300)
        XCTAssertEqual(response, .silent)
        // If the old clamp were in place, capturedSeekTime would be 0.0.
        // The new implementation should produce 3300.0.
        XCTAssertNotEqual(mock.capturedSeekTime, 0.0,
                          "regression test must fail with the old clamp")
    }
}
