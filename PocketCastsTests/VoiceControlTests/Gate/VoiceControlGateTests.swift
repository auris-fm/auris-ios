import XCTest
@testable import podcasts

final class VoiceControlGateTests: XCTestCase {

    // MARK: - Helpers

    private func makeGate(
        setup: GateSetup = .allAllowed,
        conflicts: GateConflicts = .noneBlocked,
        context: GateContext = .playbackActive,
        micExposure: MicExposure = .isolated,
        gracePeriod: Bool = false
    ) -> VoiceControlGate {
        let gracePeriodSignal = GracePeriodSignal()

        if gracePeriod { gracePeriodSignal.onCommandRecognized() }

        return VoiceControlGate(
            setup: setup,
            conflicts: conflicts,
            context: context,
            micExposure: micExposure,
            gracePeriodSignal: gracePeriodSignal
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

    // MARK: - Rule 1: Grace period → continuous

    func test_gracePeriodActive_continuous() {
        let gate = makeGate(context: .appInForeground, micExposure: .exposed, gracePeriod: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    // MARK: - Rule 2: Everything else → wake word

    func test_noGracePeriod_appInForeground_wakeWord() {
        let gate = makeGate(context: .appInForeground, micExposure: .exposed, gracePeriod: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    func test_noGracePeriod_playbackActive_wakeWord() {
        let gate = makeGate(context: .playbackActive, micExposure: .isolated, gracePeriod: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    func test_noGracePeriod_bothContext_wakeWord() {
        let gate = makeGate(context: .both, micExposure: .exposed, gracePeriod: false)
        XCTAssertEqual(gate.state, .listening(mode: .wakeWord))
    }

    // MARK: - Both context

    func test_both_context_gracePeriod_continuous() {
        let gate = makeGate(context: .both, micExposure: .exposed, gracePeriod: true)
        XCTAssertEqual(gate.state, .listening(mode: .continuous))
    }

    // MARK: - GatePosture

    func test_posture_blockedByCall_showsConflictBlocking() {
        let conflicts = GateConflicts(
            notOnCall: .blocked(reason: "inCall"),
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        let gate = makeGate(conflicts: conflicts)
        let posture = gate.posture
        XCTAssertFalse(posture.allowed)
        XCTAssertEqual(posture.offReason, .conflictBlocking)
        XCTAssertFalse(posture.conflicts.notOnCall.isAllowed)
    }

    func test_posture_gracePeriodActive_showsContinuous() {
        let gate = makeGate(context: .appInForeground, micExposure: .exposed, gracePeriod: true)
        let posture = gate.posture
        XCTAssertTrue(posture.allowed)
        XCTAssertEqual(posture.listeningMode, .continuous)
        XCTAssertTrue(posture.gracePeriodActive)
        XCTAssertEqual(posture.context, .appInForeground)
        XCTAssertEqual(posture.micExposure, .exposed)
    }
}
