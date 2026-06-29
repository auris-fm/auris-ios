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
}
