import XCTest
@testable import podcasts

/// SIMULATOR INPUT DISCOVERY (owner: "the app on simulator doesn't open mic"): a fresh
/// simulator AVAudioSession reports no `currentRoute` inputs until a record-capable category is
/// configured and the session activated, even though `availableInputs` lists the built-in mic —
/// so the route monitor published `.noMic` forever and the gate refused with `.noMicrophone`.
/// The monitor now configures the input-capable session once at init when it would otherwise
/// publish `.noMic` with a non-empty discovery list (DEBUG + simulator only). This control
/// compiles under the same #if, so it exercises exactly the shipped rule.
final class SimulatorInputDiscoveryTests: XCTestCase {
    /// Mirrors the probed real session: no live input until the input-capable configuration,
    /// then the built-in mic appears on `currentRoute`.
    private final class HiddenInputSession: AudioSessionControlling {
        var available: [AudioPort] = []
        var inputs: [AudioPort] = []
        private(set) var configureCount = 0
        private(set) var activateCount = 0
        var isActive = false
        var currentOutputs: [AudioPort] { [] }
        var currentInputs: [AudioPort] { inputs }
        var availableInputs: [AudioPort] { available }
        func configureInputCapableSession() throws {
            configureCount += 1
            inputs = [AudioPort(portType: .builtInMic, uid: "built-in")]
        }
        func setSessionActive(_ active: Bool) throws {
            activateCount += active ? 1 : 0
            isActive = active
        }
        func selectPreferredInput(uid: String) throws {}
        func clearPreferredInput() {}
        func restorePlaybackCategory() {}
    }

    #if DEBUG && targetEnvironment(simulator)
    func testInitSurfacesTheHiddenSimulatorInput() {
        let session = HiddenInputSession()
        session.available = [AudioPort(portType: .builtInMic, uid: "built-in")]
        XCTAssertEqual(session.inputs.count, 0, "premise: the fresh session reports no live input")

        let monitor = IOSAudioRouteMonitor(audioSession: session)

        XCTAssertEqual(monitor.micExposure, .exposed,
                       "the monitor must surface the built-in mic through the discovery path, "
                           + "not publish .noMic forever")
        XCTAssertEqual(session.configureCount, 1, "discovery configures the input-capable session exactly once")
        XCTAssertEqual(session.activateCount, 1, "discovery activates the session exactly once")
    }

    func testDiscoveryDoesNotRunWhenAnInputIsAlreadyLive() {
        let session = HiddenInputSession()
        session.available = [AudioPort(portType: .builtInMic, uid: "built-in")]
        session.inputs = [AudioPort(portType: .builtInMic, uid: "built-in")]

        _ = IOSAudioRouteMonitor(audioSession: session)

        XCTAssertEqual(session.configureCount, 0, "a live input needs no discovery configuration")
        XCTAssertEqual(session.activateCount, 0, "a live input needs no discovery activation")
    }

    func testDiscoveryDoesNotRunWhenNothingIsAvailable() {
        let session = HiddenInputSession()  // no available inputs at all

        let monitor = IOSAudioRouteMonitor(audioSession: session)

        XCTAssertEqual(monitor.micExposure, .noMic,
                       "with a genuinely empty discovery list there is nothing to surface")
        XCTAssertEqual(session.configureCount, 0, "no discovery configuration without candidates")
        XCTAssertEqual(session.activateCount, 0, "no discovery activation without candidates")
    }
    #endif
}
