import XCTest
@testable import podcasts

final class RouterReadinessTests: XCTestCase {

    func test_updateModelsReady_blocked_blocksSetup() {
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.updateModelsReady(.blocked(reason: "router_not_ready"))
        XCTAssertEqual(monitor.setup.modelsReady, .blocked(reason: "router_not_ready"))
        XCTAssertFalse(monitor.setup.modelsReady.isAllowed)
    }

    func test_updateModelsReady_allowed_unblocksSetup() {
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.updateModelsReady(.blocked(reason: "router_not_ready"))
        monitor.updateModelsReady(.allowed)
        XCTAssertTrue(monitor.setup.modelsReady.isAllowed)
    }
}
