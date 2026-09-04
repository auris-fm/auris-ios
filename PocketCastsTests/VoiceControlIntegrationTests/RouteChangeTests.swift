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
        // Grace period active → continuous
        let graceGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .appInForeground,
            micExposure: .exposed,
            gracePeriodActive: true
        )
        XCTAssertEqual(graceGate.state, .listening(mode: .continuous))

        // No grace period → wake word (appInForeground, exposed)
        let foregroundExposedGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .appInForeground,
            micExposure: .exposed,
            gracePeriodActive: false
        )
        XCTAssertEqual(foregroundExposedGate.state, .listening(mode: .wakeWord))

        // No grace period → wake word (playbackActive, exposed)
        let backgroundExposedGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .playbackActive,
            micExposure: .exposed,
            gracePeriodActive: false
        )
        XCTAssertEqual(backgroundExposedGate.state, .listening(mode: .wakeWord))

        // No grace period → wake word (playbackActive, isolated)
        let backgroundIsolatedGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .playbackActive,
            micExposure: .isolated,
            gracePeriodActive: false
        )
        XCTAssertEqual(backgroundIsolatedGate.state, .listening(mode: .wakeWord))
    }
}
