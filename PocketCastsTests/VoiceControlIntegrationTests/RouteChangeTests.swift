import XCTest
@testable import podcasts

final class RouteChangeTests: XCTestCase {

    func test_micExposureClassifier_isolatedCases() {
        let testCases: [(AudioRouteInput, MicExposure)] = [
            (.headsetMic, .isolated),
            (.bluetoothHFP, .isolated),
            (.bluetoothLE, .isolated),
        ]
        for (input, expected) in testCases {
            let route = AudioRoute(output: .headphones, input: input)
            XCTAssertEqual(MicExposureClassifier.classify(route), expected, "Input \(input) should be \(expected)")
        }
    }

    func test_micExposureClassifier_builtInMic_isExposed() {
        let route = AudioRoute(output: .builtInSpeaker, input: .builtInMic)
        XCTAssertEqual(MicExposureClassifier.classify(route), .exposed)
    }

    func test_micExposureClassifier_noInput_isNoMic() {
        let route = AudioRoute(output: .bluetoothA2DP, input: nil)
        XCTAssertEqual(MicExposureClassifier.classify(route), .noMic)
    }

    func test_gate_modeResolution_matrix() {
        let attendedSignal = AttendedSignal()
        let gracePeriodSignal = GracePeriodSignal()
        let playbackRecencySignal = PlaybackRecencySignal()
        let recentPlaybackSignal = PlaybackRecencySignal()
        recentPlaybackSignal.update(isPlaying: true)

        // Foreground + attended = continuous
        attendedSignal.onUserInteraction()
        let foregroundAttendedGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .appInForeground,
            micExposure: .exposed,
            attendedSignal: attendedSignal,
            gracePeriodSignal: gracePeriodSignal,
            playbackRecencySignal: playbackRecencySignal
        )
        XCTAssertEqual(foregroundAttendedGate.state, .listening(mode: .continuous))

        // Background + exposed = wakeWord
        let backgroundExposedGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .playbackActive,
            micExposure: .exposed,
            attendedSignal: AttendedSignal(),
            gracePeriodSignal: GracePeriodSignal(),
            playbackRecencySignal: PlaybackRecencySignal()
        )
        XCTAssertEqual(backgroundExposedGate.state, .listening(mode: .wakeWord))

        // Background + isolated + playback recent = continuous
        let backgroundIsolatedGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .playbackActive,
            micExposure: .isolated,
            attendedSignal: AttendedSignal(),
            gracePeriodSignal: GracePeriodSignal(),
            playbackRecencySignal: recentPlaybackSignal
        )
        XCTAssertEqual(backgroundIsolatedGate.state, .listening(mode: .continuous))
    }
}
