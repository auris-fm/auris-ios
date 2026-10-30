import Foundation

/// DEBUG-SIMULATOR-ONLY BUILT-IN-MIC DIAGNOSTIC (owner approval, #core:25b91a1b `77121fd4`).
///
/// WHY THIS EXISTS: the simulator has no external input route, so `MicExposureClassifier` reports
/// `.exposed` for the built-in microphone and `VoiceControlGate` can never reach `.listening`
/// there. The entire end-to-end capture path — acquisition, sample delivery, echo reference,
/// wake-word filtering — is therefore unexercised on a simulator.
///
/// WHAT IT DOES NOT DO: it does not change the classification, weaken permission or user
/// enablement, skip readiness/conflict/context checks, or alter capture ownership. It admits the
/// built-in microphone to the gate on a Debug simulator build, and nothing else.
///
/// DEVICE AND RELEASE ARE UNCHANGED. All three conditions below must hold; a Release build
/// compiles the constant to `false`, so the exception cannot be reached in a shipping binary even
/// if the process were misconfigured.
enum DiagnosticMicOverride {
    /// The override is active for this process.
    ///
    /// Both conditions are COMPILE-TIME constants, which is deliberate: there is no runtime flag,
    /// defaults key or constructor argument that can switch this on in a shipping binary, so the
    /// exception cannot be enabled by configuration drift or a stray debug menu.
    static var isActive: Bool {
        enabledByBuild && isSimulator
    }

    /// `#if DEBUG` — compiled out of Release entirely.
    static var enabledByBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The simulated device, not the host Mac (`TARGET_OS_SIMULATOR`, never `TARGET_OS_MAC`).
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The log label required when the diagnostic path is admitted, so a simulator session is
    /// never mistaken for a real external-microphone exposure.
    static let logLabel = "DIAGNOSTIC-BUILTIN-MIC (Debug simulator only)"
}
