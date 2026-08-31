import XCTest
@testable import podcasts

final class ListeningModePolicyTests: XCTestCase {

    // MARK: - Helpers

    private func gateWith(
        context: GateContext,
        exposure: MicExposure,
        gracePeriod: Bool = false
    ) -> VoiceControlGate {
        let gracePeriodSignal = GracePeriodSignal()

        if gracePeriod { gracePeriodSignal.onCommandRecognized() }

        return VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: context,
            micExposure: exposure,
            gracePeriodSignal: gracePeriodSignal
        )
    }

    // MARK: - Rule 1: Grace period → continuous

    func test_gracePeriod_appInForeground_exposed_continuous() {
        let gate = gateWith(context: .appInForeground, exposure: .exposed, gracePeriod: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_gracePeriod_playbackActive_isolated_continuous() {
        let gate = gateWith(context: .playbackActive, exposure: .isolated, gracePeriod: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_gracePeriod_both_exposed_continuous() {
        let gate = gateWith(context: .both, exposure: .exposed, gracePeriod: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    // MARK: - Rule 2: Everything else → wake word

    func test_noGracePeriod_appInForeground_exposed_wakeWord() {
        let gate = gateWith(context: .appInForeground, exposure: .exposed, gracePeriod: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    func test_noGracePeriod_appInForeground_isolated_wakeWord() {
        let gate = gateWith(context: .appInForeground, exposure: .isolated, gracePeriod: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    func test_noGracePeriod_playbackActive_exposed_wakeWord() {
        let gate = gateWith(context: .playbackActive, exposure: .exposed, gracePeriod: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    func test_noGracePeriod_playbackActive_isolated_wakeWord() {
        let gate = gateWith(context: .playbackActive, exposure: .isolated, gracePeriod: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    func test_noGracePeriod_both_exposed_wakeWord() {
        let gate = gateWith(context: .both, exposure: .exposed, gracePeriod: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    func test_noGracePeriod_both_isolated_wakeWord() {
        let gate = gateWith(context: .both, exposure: .isolated, gracePeriod: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    // MARK: - Blocking conditions

    func test_noMic_off() {
        let gate = gateWith(context: .playbackActive, exposure: .noMic)
        XCTAssertEqual(gate.state, .off(reason: .noMicrophone))
    }

    func test_noContext_off() {
        let gate = gateWith(context: .none, exposure: .isolated)
        XCTAssertEqual(gate.state, .off(reason: .noContext))
    }
}
