import XCTest
@testable import podcasts

final class EffectsManagerSinkTests: XCTestCase {

    func test_sink_initialization_doesNotCrash() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        XCTAssertNotNil(sink)
    }

    func test_setSpeed_returnsSpoken() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        let response = sink.setSpeed(1.5)
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("1.5"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    func test_setSpeed_clampsToMinimum() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        let response = sink.setSpeed(0.1)
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("0.5"))
        } else {
            XCTFail("Expected spoken response")
        }
    }

    /// The clamp is the contract; the spoken wording is a template and its
    /// formatting is the template's business. Asserting `text.contains("3.0")`
    /// made this test depend on how the number is rendered (locale, trailing
    /// zero), which is not what "clamps to maximum" means.
    func test_setSpeed_clampsToMaximum() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        let response = sink.setSpeed(5.0)

        guard case .spoken(let text) = response else {
            return XCTFail("Expected a spoken response, got \(response)")
        }
        XCTAssertFalse(text.isEmpty, "a spoken response must say something")
        XCTAssertEqual(PlaybackManager.shared.effects().playbackSpeed, 3.0,
                       "a speed above the maximum is clamped to it")
    }

    func test_setTrimMode_returnsEarcon() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        let response = sink.setTrimMode(.medium)
        XCTAssertEqual(response, .earcon(.success))
    }

    func test_setVolumeBoost_returnsEarcon() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        let response = sink.setVolumeBoost(enabled: true)
        XCTAssertEqual(response, .earcon(.success))
    }

    func test_queryEffects_returnsSpoken() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        let response = sink.queryEffects()
        if case .spoken = response {
            // Success — any spoken response is valid
        } else {
            XCTFail("Expected spoken response")
        }
    }
}
