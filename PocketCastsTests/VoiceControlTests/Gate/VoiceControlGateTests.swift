import XCTest
@testable import podcasts

final class VoiceControlGateTests: XCTestCase {

    // MARK: - Helpers

    private func makeGate(
        setup: GateSetup = .allAllowed,
        conflicts: GateConflicts = .noneBlocked,
        context: GateContext = .playbackActive,
        micExposure: MicExposure = .isolated,
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
            setup: setup,
            conflicts: conflicts,
            context: context,
            micExposure: micExposure,
            attendedSignal: attendedSignal,
            gracePeriodSignal: gracePeriodSignal,
            playbackRecencySignal: playbackRecencySignal
        )
    }

    // MARK: - Blocking conditions

    func test_allSetupReady_allConflictsClear_contextActive_returnsListening() {
        let gate = makeGate()
        if case .listening = gate.state {} else { XCTFail("Expected listening, got \(gate.state)") }
    }

    func test_modelsNotReady_blocksListening() {
        let setup = GateSetup(
            enabledByUser: .allowed,
            deviceSupported: .allowed,
            modelsReady: .blocked(reason: "downloading")
        )
        let gate = makeGate(setup: setup)
        XCTAssertEqual(gate.state, .off(reason: .setupNotReady))
    }

    func test_callInProgress_blocksListening() {
        let conflicts = GateConflicts(
            notOnCall: .blocked(reason: "inCall"),
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        let gate = makeGate(conflicts: conflicts)
        XCTAssertEqual(gate.state, .off(reason: .conflictBlocking))
    }

    func test_otherAppPlaying_blocksListening() {
        let conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .blocked(reason: "other_app_playing")
        )
        let gate = makeGate(conflicts: conflicts)
        XCTAssertEqual(gate.state, .off(reason: .conflictBlocking))
    }

    func test_noContext_blocksListening() {
        let gate = makeGate(context: .none)
        XCTAssertEqual(gate.state, .off(reason: .noContext))
    }

    func test_noMic_blocksListening() {
        let gate = makeGate(micExposure: .noMic)
        XCTAssertEqual(gate.state, .off(reason: .noMicrophone))
    }

    // MARK: - Priority 1: Grace period

    func test_gracePeriodActive_overridesEverything_continuous() {
        // Even with exposed mic, no context, grace period wins
        let gate = makeGate(context: .appInForeground, micExposure: .exposed, gracePeriod: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    // MARK: - Priority 2: Foreground + attended

    func test_foregroundAttended_continuous() {
        let gate = makeGate(context: .appInForeground, micExposure: .exposed, attended: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    // MARK: - Priority 3: Foreground + unattended

    func test_foregroundUnattended_wakeWord() {
        let gate = makeGate(context: .appInForeground, micExposure: .exposed, attended: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    // MARK: - Priority 4: Background + Isolated + playback recent

    func test_backgroundPlayback_isolated_recent_continuous() {
        let gate = makeGate(context: .playbackActive, micExposure: .isolated, playbackRecent: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    // MARK: - Priority 5: Background + Isolated + playback inactive >30s

    func test_backgroundPlayback_isolated_notRecent_wakeWord() {
        let gate = makeGate(context: .playbackActive, micExposure: .isolated, playbackRecent: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    // MARK: - Priority 6: Background + Exposed

    func test_backgroundPlayback_exposed_wakeWord() {
        let gate = makeGate(context: .playbackActive, micExposure: .exposed)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    // MARK: - Both context

    func test_both_context_attended_continuous() {
        let gate = makeGate(context: .both, micExposure: .exposed, attended: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    func test_both_context_unattended_wakeWord() {
        let gate = makeGate(context: .both, micExposure: .exposed, attended: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    // MARK: - Fail-safe

    func test_fallback_wakeWord() {
        // No matching priority → wakeWord default
        let gate = makeGate(context: .playbackActive, micExposure: .isolated, playbackRecent: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }
}
