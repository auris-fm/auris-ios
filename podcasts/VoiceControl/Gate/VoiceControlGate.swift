class VoiceControlGate {
    private let setup: GateSetup
    private let conflicts: GateConflicts
    private let context: GateContext
    private let micExposure: MicExposure
    /// Snapshot from the Combine pipeline — never re-read a live signal here.
    /// Re-reading raced with log-before-assign in `GracePeriodSignal` and inverted
    /// wakeWord ↔ continuous in production logs.
    private let gracePeriodActive: Bool

    init(
        setup: GateSetup,
        conflicts: GateConflicts,
        context: GateContext,
        micExposure: MicExposure,
        gracePeriodActive: Bool
    ) {
        self.setup = setup
        self.conflicts = conflicts
        self.context = context
        self.micExposure = micExposure
        self.gracePeriodActive = gracePeriodActive
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
            gracePeriodActive: gracePeriodActive,
            offReason: state.offReason
        )
    }

    private var resolvedMode: ListeningMode {
        // Rule 1: Grace period overrides everything → continuous
        if gracePeriodActive { return .continuous }

        // Rule 2: Everything else → wake word
        return .wakeWord
    }
}
