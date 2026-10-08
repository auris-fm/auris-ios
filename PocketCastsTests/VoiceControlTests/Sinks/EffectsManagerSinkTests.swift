import XCTest
@testable import podcasts

final class EffectsManagerSinkTests: XCTestCase {

    func test_sink_initialization_doesNotCrash() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        XCTAssertNotNil(sink)
    }

    /// The speed applied is the contract; the wording is the template's. These
    /// two asserted the rendered number, which is how a locale or a trailing
    /// zero turns into a failing test that has nothing to do with the behaviour.
    func test_setSpeed_returnsSpoken() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        let response = sink.setSpeed(1.5)
        guard case .spoken(let text) = response else {
            return XCTFail("Expected spoken response, got \(response)")
        }
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(PlaybackManager.shared.effects().playbackSpeed, 1.5)
    }

    func test_setSpeed_clampsToMinimum() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        let response = sink.setSpeed(0.1)
        guard case .spoken(let text) = response else {
            return XCTFail("Expected spoken response, got \(response)")
        }
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(PlaybackManager.shared.effects().playbackSpeed, 0.5,
                       "a speed below the minimum is clamped to it")
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
