class VoiceControlGate {
    private let setup: GateSetup
    private let conflicts: GateConflicts
    private let context: GateContext
    private let micExposure: MicExposure
    /// Snapshot from the Combine pipeline — never re-read a live signal here.
    /// Re-reading raced with log-before-assign in `GracePeriodSignal` and inverted
    /// wakeWord ↔ continuous in production logs.
    private let gracePeriodActive: Bool
    /// DEBUG-SIMULATOR-ONLY DIAGNOSTIC (owner approval, #core:25b91a1b `77121fd4`).
    ///
    /// The simulator exposes no external input route, so `micExposure` is permanently `.exposed`
    /// there and the gate can never reach `.listening` — which means the end-to-end capture path
    /// cannot be exercised on a simulator at all. This flag admits the built-in microphone for
    /// THAT case only. It is a capture-ELIGIBILITY exception and nothing else: permission, user
    /// enablement, readiness, context, conflicts, wake/echo filtering and capture ownership are
    /// all still enforced above and unchanged. `MicExposureClassifier` keeps reporting the true
    /// `.exposed` classification — the exception lives here, at the decision, so logs and the
    /// posture stay honest about what the route actually is.
    ///
    /// Always `false` on device and in Release; see `DiagnosticMicOverride`.
    private let admitsBuiltInMicForSimulatorDiagnostic: Bool
    /// Whether an external microphone is actually available to capture from. The diagnostic
    /// exception must never override a real candidate.
    private let hasExternalMicrophoneCandidate: Bool

    init(
        setup: GateSetup,
        conflicts: GateConflicts,
        context: GateContext,
        micExposure: MicExposure,
        gracePeriodActive: Bool,
        admitsBuiltInMicForSimulatorDiagnostic: Bool = false,
        hasExternalMicrophoneCandidate: Bool = true
    ) {
        self.setup = setup
        self.conflicts = conflicts
        self.context = context
        self.micExposure = micExposure
        self.gracePeriodActive = gracePeriodActive
        self.admitsBuiltInMicForSimulatorDiagnostic = admitsBuiltInMicForSimulatorDiagnostic
        self.hasExternalMicrophoneCandidate = hasExternalMicrophoneCandidate
    }

    var state: GateState {
        guard setup.isReady else { return .off(reason: .setupNotReady) }
        guard conflicts.isClear else { return .off(reason: .conflictBlocking) }
        guard context != .none else { return .off(reason: .noContext) }
        // Capture requires an external (headset/earbud/Bluetooth) microphone:
        // only `.isolated` permits it. `.noMic` and `.exposed` both block, with
        // distinct reasons so settings and logs can tell them apart.
        switch micExposure {
        case .isolated:
            break
        case .exposed:
            // The ONE exception, and only when the diagnostic admits it. Everything the gate has
            // already checked (readiness, conflicts, context) still applies.
            guard admitsBuiltInMicForSimulatorDiagnostic else {
                return .off(reason: .exposedMicrophone)
            }
            // The exception exists for the case the simulator CANNOT solve — no external route at
            // all. If an external microphone IS present, requirement is unchanged even under the
            // diagnostic: admitting the built-in mic then would let a simulator session capture
            // from the wrong device and mask a real routing defect. So the exception applies only
            // when no external candidate exists.
            guard !hasExternalMicrophoneCandidate else {
                return .off(reason: .exposedMicrophone)
            }
        case .noMic:
            return .off(reason: .noMicrophone)
        }
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
