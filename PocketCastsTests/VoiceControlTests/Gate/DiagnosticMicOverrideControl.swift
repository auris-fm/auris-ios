@testable import podcasts
import XCTest

/// Controls for the Debug-simulator-only built-in-mic diagnostic (owner approval, #core:25b91a1b).
///
/// The owner's requirement was not "the flag exists" but that the exception is NARROW and that the
/// real classification survives. These controls test exactly that, and they are written so each one
/// has a mutant that would survive if the guard were removed.
/// MEASURED LIMIT OF THE DIAGNOSTIC (recorded here so it cannot be mistaken for working).
///
/// The override completes only HALF of the owner's requirement. With a built-in-only route the
/// gate now reaches `.listening` — verified by `testDiagnosticAdmitsBuiltInMicWhenNoExternalExists`
/// and by a real service run that logged `MicExposure: noMic -> exposed` then
/// `Gate: -> listening`. But `IOSAudioRouteMonitor.acquireExternalInput` still returns
/// `.notApplicable` when no external OUTPUT could carry an external microphone, and
/// `VoiceControlService` treats `.notApplicable` as a silent no-op — so capture never starts and
/// no samples are received.
///
/// A test asserting sample delivery was written and REMOVED: it hangs the suite (the run times out
/// and reports 0 tests executed) rather than failing. Making the diagnostic actually deliver
/// samples requires widening acquisition for the simulator case — a separate, deliberate change,
/// not something to smuggle in under a gate-permission approval.
final class DiagnosticMicOverrideControl: XCTestCase {
    /// Bounded poll, so a premise that never becomes true FAILS instead of hanging the suite.
    private func awaitTrue(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func gate(
        exposure: MicExposure,
        admits: Bool,
        externalCandidate: Bool,
        conflicts: GateConflicts = .noneBlocked,
        context: GateContext = .playbackActive
    ) -> VoiceControlGate {
        VoiceControlGate(
            setup: .allAllowed,
            conflicts: conflicts,
            context: context,
            micExposure: exposure,
            gracePeriodActive: false,
            admitsBuiltInMicForSimulatorDiagnostic: admits,
            hasExternalMicrophoneCandidate: externalCandidate
        )
    }

    /// THE EXCEPTION DOES NOT WEAKEN THE CLASSIFICATION: `.exposed` stays `.exposed`, and without
    /// the diagnostic it must still block. Mutant: making the `.exposed` case fall through
    /// unconditionally fails this.
    func testExposedStillBlocksWithoutTheDiagnostic() {
        let g = gate(exposure: .exposed, admits: false, externalCandidate: false)
        XCTAssertEqual(g.state.offReason, .exposedMicrophone)
        XCTAssertEqual(g.posture.micExposure, .exposed, "the classification itself must be unchanged")
    }

    /// A REAL EXTERNAL MICROPHONE STILL KEEPS THE REQUIREMENT, even with the diagnostic active.
    /// This is the guard that stops the override masking a routing defect: if a headset IS
    /// available the app must not quietly capture from the built-in microphone instead.
    func testDiagnosticDoesNotOverrideAnAvailableExternalMicrophone() {
        let g = gate(exposure: .exposed, admits: true, externalCandidate: true)
        XCTAssertEqual(
            g.state.offReason, .exposedMicrophone,
            "an available external mic must keep the original requirement"
        )
    }

    /// AND IT DOES ADMIT the built-in microphone when nothing external exists — the one case it
    /// exists for. Mutant: removing the exception leaves the simulator unable to listen at all.
    func testDiagnosticAdmitsBuiltInMicWhenNoExternalExists() {
        let g = gate(exposure: .exposed, admits: true, externalCandidate: false)
        XCTAssertTrue(g.state.isListening, "the diagnostic must admit this one case")
    }

    /// THE PRECEDENCE IS UNCHANGED: the exception sits AFTER readiness, conflicts and context, so it
    /// cannot resurrect a gate that those already refused.
    func testDiagnosticDoesNotBypassConflicts() {
        let g = gate(
            exposure: .exposed,
            admits: true,
            externalCandidate: false,
            conflicts: GateConflicts(
                notOnCall: .blocked(reason: "on a call"),
                notCasting: .allowed,
                batteryOk: .allowed,
                otherAppPlaying: .allowed
            )
        )
        XCTAssertEqual(g.state.offReason, .conflictBlocking, "conflicts are checked FIRST")
    }

    /// `noMic` IS NOT `exposed`: there is no microphone at all, and the diagnostic must not invent
    /// one. Mutant: widening the guard to admit `.noMic` fails this.
    func testDiagnosticDoesNotAdmitAUserWithNoMicrophone() {
        let g = gate(exposure: .noMic, admits: true, externalCandidate: false)
        XCTAssertEqual(g.state.offReason, .noMicrophone)
    }

    /// THE SHIPPING GUARANTEE: the override cannot be active in a Release build.
    func testOverrideIsCompiledOutOfRelease() {
        #if DEBUG
        XCTAssertTrue(
            DiagnosticMicOverride.enabledByBuild,
            "in Debug the build-side constant is on (the simulator check is the other half)"
        )
        #else
        XCTAssertFalse(DiagnosticMicOverride.enabledByBuild, "Release must not carry the override")
        XCTAssertFalse(DiagnosticMicOverride.isActive)
        #endif
    }
}
