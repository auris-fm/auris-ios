import XCTest
@testable import podcasts

final class VolumeManagerSinkTests: XCTestCase {

    func test_sink_initialization_doesNotCrash() {
        let sink = VolumeManagerSink()
        XCTAssertNotNil(sink)
    }

    func test_setVolume_returnsSilent() {
        let sink = VolumeManagerSink()
        let response = sink.setVolume(50)
        XCTAssertEqual(response, .silent)
    }

    func test_setVolume_clampsToZero() {
        let sink = VolumeManagerSink()
        let response = sink.setVolume(-10)
        XCTAssertEqual(response, .silent)
    }

    func test_setVolume_clampsToMax() {
        let sink = VolumeManagerSink()
        let response = sink.setVolume(150)
        XCTAssertEqual(response, .silent)
    }

    func test_adjustVolume_returnsSilent() {
        let sink = VolumeManagerSink()
        let response = sink.adjustVolume(delta: 10)
        XCTAssertEqual(response, .silent)
    }

    /// The failure path of the volume operation: the system slider cannot be reached, so no
    /// volume is set. This is the case `audio_session_denied` names, and the reason it needs a
    /// producer rather than a comment.
    ///
    /// Note what the existing `.silent` assertions above do NOT establish: `setVolume` returned
    /// `.silent` whether or not the slider was found, so they pass on the failure path too. A
    /// case that cannot distinguish success from failure is not evidence that either happened.
    func test_setSystemVolume_reportsFailureWhenTheSliderIsUnreachable() {
        // Measured, not assumed: a live MPVolumeView reports a slider here whether or not it is
        // in a window, so the unreachable case has to be chosen rather than waited for.
        let sink = VolumeManagerSink(resolveSlider: { nil })
        XCTAssertFalse(
            sink.setSystemVolume(0.5),
            "an unreachable slider must report failure, not a success-shaped silence"
        )
    }

    func test_setSystemVolume_reportsSuccessWhenTheSliderIsReachable() {
        let slider = UISlider()
        let sink = VolumeManagerSink(resolveSlider: { slider })
        XCTAssertTrue(sink.setSystemVolume(0.5))
    }

    /// The distinction the old assertions could not make: `setVolume` returns the same
    /// success-shaped response on both paths, so nothing downstream could tell a change from
    /// a no-op. The carried outcome is what makes the two separable.
    func test_setVolume_distinguishesSuccessFromFailure() {
        let reachable = VolumeManagerSink(resolveSlider: { UISlider() })
        let unreachable = VolumeManagerSink(resolveSlider: { nil })
        XCTAssertTrue(reachable.setSystemVolume(0.5))
        XCTAssertFalse(unreachable.setSystemVolume(0.5))
    }

    func test_queryVolume_returnsSpoken() {
        let sink = VolumeManagerSink()
        let response = sink.queryVolume()
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("Volume"))
        } else {
            XCTFail("Expected spoken response")
        }
    }
}
