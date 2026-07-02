class VoiceControlGate {
    private let setup: GateSetup
    private let conflicts: GateConflicts
    private let context: GateContext
    private let micExposure: MicExposure
    private let attendedSignal: AttendedSignal
    private let gracePeriodSignal: GracePeriodSignal
    private let playbackRecencySignal: PlaybackRecencySignal

    init(setup: GateSetup, conflicts: GateConflicts, context: GateContext,
         micExposure: MicExposure, attendedSignal: AttendedSignal,
         gracePeriodSignal: GracePeriodSignal, playbackRecencySignal: PlaybackRecencySignal) {
        self.setup = setup
        self.conflicts = conflicts
        self.context = context
        self.micExposure = micExposure
        self.attendedSignal = attendedSignal
        self.gracePeriodSignal = gracePeriodSignal
        self.playbackRecencySignal = playbackRecencySignal
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
            attended: attendedSignal.isAttended,
            gracePeriodActive: gracePeriodSignal.isActive,
            playbackRecent: playbackRecencySignal.isRecent,
            offReason: state.offReason
        )
    }

    private var resolvedMode: ListeningMode {
        // Priority 1: Grace period overrides everything
        if gracePeriodSignal.isActive { return .continuous }

        let isForeground = context == .appInForeground || context == .both

        // Priority 2: Foreground + attended
        if isForeground, attendedSignal.isAttended { return .continuous }

        // Priority 3: Foreground + unattended
        if isForeground, !attendedSignal.isAttended { return .wakeWord }

        // Priority 4: Background + Isolated + playback recent
        if context == .playbackActive, micExposure == .isolated, playbackRecencySignal.isRecent {
            return .continuous
        }

        // Priority 5: Background + Isolated + playback inactive >30s
        if context == .playbackActive, micExposure == .isolated, !playbackRecencySignal.isRecent {
            return .wakeWord
        }

        // Priority 6: Background + Exposed
        if context == .playbackActive, micExposure == .exposed { return .wakeWord }

        return .wakeWord // fail-safe default
    }
}
