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
