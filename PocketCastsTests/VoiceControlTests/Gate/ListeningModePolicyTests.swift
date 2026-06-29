import XCTest
@testable import podcasts

final class ListeningModePolicyTests: XCTestCase {

    func test_foreground_exposed_continuous() {
        let gate = gateWith(context: .appInForeground, exposure: .exposed)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_foreground_isolated_continuous() {
        let gate = gateWith(context: .appInForeground, exposure: .isolated)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_backgroundPlayback_isolated_continuous() {
        let gate = gateWith(context: .playbackActive, exposure: .isolated)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_backgroundPlayback_exposed_wakeWord() {
        let gate = gateWith(context: .playbackActive, exposure: .exposed)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    func test_noMic_off() {
        let gate = gateWith(context: .playbackActive, exposure: .noMic)
        XCTAssertEqual(gate.state, .off(reason: .noMicrophone))
    }

    func test_noContext_off() {
        let gate = gateWith(context: .none, exposure: .isolated)
        XCTAssertEqual(gate.state, .off(reason: .noContext))
    }

    func test_both_context_exposed_continuous() {
        let gate = gateWith(context: .both, exposure: .exposed)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    // MARK: - Helpers

    private func gateWith(context: GateContext, exposure: MicExposure) -> VoiceControlGate {
        VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: context,
            micExposure: exposure
        )
    }
}
