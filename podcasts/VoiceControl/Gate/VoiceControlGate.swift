class VoiceControlGate {
    private let setup: GateSetup
    private let conflicts: GateConflicts
    private let context: GateContext
    private let micExposure: MicExposure
    private let gracePeriodSignal: GracePeriodSignal

    init(setup: GateSetup, conflicts: GateConflicts, context: GateContext,
         micExposure: MicExposure, gracePeriodSignal: GracePeriodSignal) {
        self.setup = setup
        self.conflicts = conflicts
        self.context = context
        self.micExposure = micExposure
        self.gracePeriodSignal = gracePeriodSignal
    }

    var state: GateState {
        guard setup.isReady else { return .off(reason: .setupNotReady) }
        guard conflicts.isClear else { return .off(reason: .conflictBlocking) }
        guard context != .none else { return .off(reason: .noContext) }
        guard micExposure != .noMic else { return .off(reason: .noMicrophone) }
        return .listening(mode: resolvedMode)
    }

    var posture: GatePosture {
        GatePosture(
            allowed: state.isListening,
            listeningMode: state.listeningMode,
            setup: setup,
            conflicts: conflicts,
            context: context,
            micExposure: micExposure,
            gracePeriodActive: gracePeriodSignal.isActive,
            offReason: state.offReason
        )
    }

    private var resolvedMode: ListeningMode {
        // Rule 1: Grace period overrides everything → continuous
        if gracePeriodSignal.isActive { return .continuous }

        // Rule 2: Everything else → wake word
        return .wakeWord
    }
}
