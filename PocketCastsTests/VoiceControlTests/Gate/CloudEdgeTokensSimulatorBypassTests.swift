import XCTest
import PocketCastsUtils

/// Simulator-gated debug bypass:
/// on Debug simulator builds the cloud edge-token switch defaults ON so the
/// cloud assistant is testable in the simulator; every other build keeps the
/// default-off gate. The #if mirrors the production rule so the control holds
/// in every configuration.
final class CloudEdgeTokensSimulatorBypassTests: XCTestCase {
    func testDefaultMatchesSimulatorDebugBypassRule() {
        #if DEBUG && targetEnvironment(simulator)
        XCTAssertTrue(FeatureFlag.cloudEdgeTokens.default, "Debug simulator build must bypass the cloudEdgeTokens default-off gate")
        #else
        XCTAssertFalse(FeatureFlag.cloudEdgeTokens.default, "Non-simulator builds keep the default-off gate")
        #endif
    }
}
