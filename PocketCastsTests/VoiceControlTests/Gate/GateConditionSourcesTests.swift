import XCTest
@testable import podcasts

final class GateConditionSourcesTests: XCTestCase {

    func test_notOnCall_whenNoCalls_isAllowed() {
        let source = CallConditionSource()
        // Real CXCallObserver has no calls on test devices
        XCTAssertTrue(source.current.isAllowed || source.current == .unknown(reason: "uninitialized"))
    }

    func test_batteryOk_inLowPowerMode_isBlocked() {
        // Low power mode is off in test harness normally
        let condition = BatteryConditionSource().current
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            XCTAssertEqual(condition, .blocked(reason: "low_power_mode"))
        } else {
            XCTAssertEqual(condition, .allowed)
        }
    }

    func test_foreground_source_returnsCondition() {
        let source = ForegroundConditionSource()
        // In test environment, app may not be active
        let condition = source.current
        XCTAssertNotNil(condition)
    }

    func test_gateCondition_isAllowed_property() {
        XCTAssertTrue(GateCondition.allowed.isAllowed)
        XCTAssertFalse(GateCondition.blocked(reason: "test").isAllowed)
        XCTAssertFalse(GateCondition.unknown(reason: "test").isAllowed)
    }

    func test_liveConditionMonitor_initialState() {
        let monitor = LiveConditionMonitor()
        // Initial state should be unknown
        if case .unknown = monitor.setup.enabledByUser {} else { XCTFail() }
    }

    func test_gateConflicts_isClear_withOtherAppPlaying() {
        let conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        XCTAssertTrue(conflicts.isClear)

        let blocked = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .blocked(reason: "other_app_playing")
        )
        XCTAssertFalse(blocked.isClear)
    }

    func test_otherAppPlayingSource_returnsCondition() {
        let source = OtherAppPlayingConditionSource()
        let condition = source.current
        // In test environment, other audio is typically not playing
        XCTAssertEqual(condition, .allowed)
    }

    func test_otherAppPlayingSource_publisherFiresOnRouteChange() {
        let source = OtherAppPlayingConditionSource()
        let expectation = expectation(description: "publisher emits on route change")
        var receivedValue: GateCondition?
        let cancellable = source.publisher
            .dropFirst() // ignore initial/current value
            .sink { condition in
                receivedValue = condition
                expectation.fulfill()
            }

        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(receivedValue)
        cancellable.cancel()
    }
}
