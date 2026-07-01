import XCTest
@testable import podcasts

final class ListeningModePolicyTests: XCTestCase {

    // MARK: - Helpers

    private func gateWith(
        context: GateContext,
        exposure: MicExposure,
        attended: Bool = false,
        gracePeriod: Bool = false,
        playbackRecent: Bool = false
    ) -> VoiceControlGate {
        let attendedSignal = AttendedSignal()
        let gracePeriodSignal = GracePeriodSignal()
        let playbackRecencySignal = PlaybackRecencySignal()

        if attended { attendedSignal.onUserInteraction() }
        if gracePeriod { gracePeriodSignal.onCommandRecognized() }
        if playbackRecent { playbackRecencySignal.update(isPlaying: true) }

        return VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: context,
            micExposure: exposure,
            attendedSignal: attendedSignal,
            gracePeriodSignal: gracePeriodSignal,
            playbackRecencySignal: playbackRecencySignal
        )
    }

    // MARK: - Grace period (Priority 1)

    func test_gracePeriod_overridesEverything() {
        let gate = gateWith(context: .appInForeground, exposure: .exposed, gracePeriod: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    // MARK: - Foreground + attended/unattended

    func test_foreground_attended_continuous() {
        let gate = gateWith(context: .appInForeground, exposure: .exposed, attended: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_foreground_unattended_wakeWord() {
        let gate = gateWith(context: .appInForeground, exposure: .isolated, attended: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    // MARK: - Background + playback recency

    func test_backgroundPlayback_isolated_recent_continuous() {
        let gate = gateWith(context: .playbackActive, exposure: .isolated, playbackRecent: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_backgroundPlayback_isolated_notRecent_wakeWord() {
        let gate = gateWith(context: .playbackActive, exposure: .isolated, playbackRecent: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    func test_backgroundPlayback_exposed_wakeWord() {
        let gate = gateWith(context: .playbackActive, exposure: .exposed)
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

    // MARK: - Both context

    func test_both_context_attended_continuous() {
        let gate = gateWith(context: .both, exposure: .exposed, attended: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_both_context_unattended_wakeWord() {
        let gate = gateWith(context: .both, exposure: .isolated, attended: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }
}
