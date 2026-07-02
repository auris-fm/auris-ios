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

    func test_setSpeed_clampsToMaximum() {
        let sink = EffectsManagerSink(playbackManager: .shared)
        let response = sink.setSpeed(5.0)
        if case .spoken(let text) = response {
            XCTAssertTrue(text.contains("3.0"))
        } else {
            XCTFail("Expected spoken response")
        }
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
