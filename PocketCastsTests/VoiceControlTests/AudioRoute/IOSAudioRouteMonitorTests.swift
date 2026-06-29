import XCTest
@testable import podcasts

final class IOSAudioRouteMonitorTests: XCTestCase {

    func test_headsetWithMic_isIsolated() {
        let route = AudioRoute(output: .headphones, input: .headsetMic)
        XCTAssertEqual(MicExposureClassifier.classify(route), .isolated)
    }

    func test_builtInSpeaker_isExposed() {
        let route = AudioRoute(output: .builtInSpeaker, input: .builtInMic)
        XCTAssertEqual(MicExposureClassifier.classify(route), .exposed)
    }

    func test_bluetoothHFP_isIsolated() {
        let route = AudioRoute(output: .bluetoothHFP, input: .bluetoothHFP)
        XCTAssertEqual(MicExposureClassifier.classify(route), .isolated)
    }

    func test_bluetoothLE_isIsolated() {
        let route = AudioRoute(output: .bluetoothLE, input: .bluetoothLE)
        XCTAssertEqual(MicExposureClassifier.classify(route), .isolated)
    }

    func test_bluetoothA2dp_noInput_isNoMic() {
        let route = AudioRoute(output: .bluetoothA2DP, input: nil)
        XCTAssertEqual(MicExposureClassifier.classify(route), .noMic)
    }

    func test_airPlay_noInput_isNoMic() {
        let route = AudioRoute(output: .airPlay, input: nil)
        XCTAssertEqual(MicExposureClassifier.classify(route), .noMic)
    }
}
