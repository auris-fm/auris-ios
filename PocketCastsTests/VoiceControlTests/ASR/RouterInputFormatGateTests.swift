import XCTest
@testable import podcasts

/// The `dual_v1` gate is production fail-closed; only the debug benchmark
/// harness may open it (Item 21 reviewed/debug harness path, @spec ruling
/// #reviews:d18481a8). These tests pin both sides of that gate.
final class RouterInputFormatGateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RouterInputFormat.benchmarkGateOpen = false
    }

    override func tearDown() {
        RouterInputFormat.benchmarkGateOpen = false
        super.tearDown()
    }

    func test_dualV1IsFailClosedByDefault() {
        XCTAssertFalse(RouterInputFormat.dualV1.isReadyForInference)
        XCTAssertFalse(RouterInputFormat.parse("dual_v1").isReadyForInference)
    }

    func test_englishV1StaysReadyRegardlessOfGate() {
        RouterInputFormat.benchmarkGateOpen = true
        XCTAssertTrue(RouterInputFormat.englishV1.isReadyForInference)
    }

    func test_gateOpenAllowsDualV1Only() {
        RouterInputFormat.benchmarkGateOpen = true
        XCTAssertTrue(RouterInputFormat.dualV1.isReadyForInference)
        XCTAssertFalse(RouterInputFormat.sourceV1.isReadyForInference)
        XCTAssertFalse(RouterInputFormat.unknown("dual_v2").isReadyForInference)
    }

    func test_gateCloseRestoresFailClosed() {
        RouterInputFormat.benchmarkGateOpen = true
        RouterInputFormat.benchmarkGateOpen = false
        XCTAssertFalse(RouterInputFormat.dualV1.isReadyForInference)
    }
}
