class VoiceControlGate {
    private let setup: GateSetup
    private let conflicts: GateConflicts
    private let context: GateContext
    private let micExposure: MicExposure

    init(setup: GateSetup, conflicts: GateConflicts, context: GateContext, micExposure: MicExposure) {
        self.setup = setup
        self.conflicts = conflicts
        self.context = context
        self.micExposure = micExposure
    }

    var state: GateState {
        guard setup.isReady else { return .off(reason: .setupNotReady) }
        guard conflicts.isClear else { return .off(reason: .conflictBlocking) }
        guard context != .none else { return .off(reason: .noContext) }
        guard micExposure != .noMic else { return .off(reason: .noMicrophone) }
        return .listening(mode: resolvedMode)
    }

    private var resolvedMode: ListeningMode {
        if case .appInForeground = context { return .continuous }
        if case .both = context { return .continuous }
        if case .isolated = micExposure { return .continuous }
        return .wakeWord
    }
}
