import XCTest
@testable import podcasts

final class VoiceControlGateTests: XCTestCase {

    func test_allSetupReady_allConflictsClear_contextActive_returnsListening() {
        let gate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .playbackActive,
            micExposure: .isolated
        )
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_modelsNotReady_blocksListening() {
        let setup = GateSetup(
            enabledByUser: .allowed,
            deviceSupported: .allowed,
            modelsReady: .blocked(reason: "downloading")
        )
        let gate = VoiceControlGate(
            setup: setup,
            conflicts: .noneBlocked,
            context: .playbackActive,
            micExposure: .isolated
        )
        XCTAssertEqual(gate.state, .off(reason: .setupNotReady))
    }

    func test_callInProgress_blocksListening() {
        let conflicts = GateConflicts(
            notOnCall: .blocked(reason: "inCall"),
            notCasting: .allowed,
            batteryOk: .allowed
        )
        let gate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: conflicts,
            context: .playbackActive,
            micExposure: .isolated
        )
        XCTAssertEqual(gate.state, .off(reason: .conflictBlocking))
    }

    func test_noContext_blocksListening() {
        let gate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .none,
            micExposure: .isolated
        )
        XCTAssertEqual(gate.state, .off(reason: .noContext))
    }

    func test_noMic_blocksListening() {
        let gate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .playbackActive,
            micExposure: .noMic
        )
        XCTAssertEqual(gate.state, .off(reason: .noMicrophone))
    }

    func test_foreground_alwaysContinuous() {
        let gate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .appInForeground,
            micExposure: .exposed
        )
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_backgroundPlayback_isolated_continuous() {
        let gate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .playbackActive,
            micExposure: .isolated
        )
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_backgroundPlayback_exposed_wakeWord() {
        let gate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .playbackActive,
            micExposure: .exposed
        )
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    func test_both_context_continuous() {
        let gate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .both,
            micExposure: .exposed
        )
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }
}
