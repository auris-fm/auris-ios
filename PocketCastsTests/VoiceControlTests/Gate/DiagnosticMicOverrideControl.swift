@testable import podcasts
import XCTest

/// Controls for the Debug-simulator-only built-in-mic diagnostic (owner approval, #core:25b91a1b).
///
/// The owner's requirement was not "the flag exists" but that the exception is NARROW and that the
/// real classification survives. These controls test exactly that, and they are written so each one
/// has a mutant that would survive if the guard were removed.
/// SCOPE OF EVIDENCE — three distinct things, kept apart deliberately:
///
/// 1. SOURCE REVIEW: the exception is restricted by two compile-time constants (Debug +
///    simulator), the microphone classifier is untouched, and every other gate check still runs
///    ahead of it.
/// 2. FAKE-CAPTURE TEST EVIDENCE (the controls in this file): the gate admits a built-in-only
///    route, the session is configured input-capable, and injected samples reach the routing
///    callback. These prove the WIRING. They cannot prove the simulator device or the real wake
///    detector delivered anything — the samples are injected and wake detection is simulated.
/// 3. ACTUAL-APP EVIDENCE (observed on simulator 928D99F3 with this build, quoted verbatim):
///      MicExposure: noMic -> exposed (output: builtInSpeaker, input: builtInMic)
///      Gate: off(noMicrophone) -> listening(wakeWord)
///      Audio engine started (input: <AVAudioFormat: 1 ch, 48000 Hz, Float32> -> 16000.0Hz)
///      First buffer: 1600 samples, min=-0.007902 max=0.006273
///    "Audio engine started" alone is NOT sample evidence — it is emitted at startup. The
///    `First buffer` line is emitted from the native capture callback on a real received buffer,
///    with non-zero amplitude, at the pipeline's 16 kHz rate. That is the actual-signal line.
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

    /// Services started by the end-to-end control, stopped unconditionally in teardown. Stated
    /// explicitly here because a leaked service keeps its route monitor subscribed to the one
    /// process-wide `AVAudioSession` and perturbs later tests.
    private static var startedServices: [VoiceControlService] = []

    override func tearDown() {
        // A REAL JOIN, NOT A TIMER (reviewer e8327339). `stop()` alone can leave an acquisition
        // task in flight; those tasks touch the one process-wide `AVAudioSession`, so one still
        // running perturbs whatever control executes next — measured as an interruption case
        // failing only in the combined run. An earlier version waited on an ignored 0.5s timer,
        // which is a guess about duration; awaiting the task is the actual completion.
        let services = Self.startedServices
        Self.startedServices.removeAll()
        super.tearDown()
        for service in services {
            joinAcquisitionCleanup(service)
        }
    }

    /// Stop a service and JOIN its acquisition task. The join runs on the MAIN actor and is
    /// driven by draining the main run loop — never by blocking a thread, because the acquisition
    /// task is main-actor bound and a `DispatchSemaphore.wait` on main would deadlock against it
    /// (measured: a 32s suite instead of a few seconds).
    private func joinAcquisitionCleanup(_ service: VoiceControlService) {
        var done = false
        Task { @MainActor in
            service.stop()
            _ = await service.awaitAcquisitionCleanupForTesting()
            done = true
        }
        let deadline = Date().addingTimeInterval(10) // hang guard only; the join ends on completion
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// START A REAL SERVICE over a built-in-only session, so later route changes flow through the
    /// actual publisher chain. Shared by the connect/disconnect controls below.
    @MainActor
    private func startedServiceForLiveRoute(session: FakeAudioSessionControlling) -> VoiceControlService? {
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.setup = .allAllowed
        monitor.conflicts = .noneBlocked
        monitor.context = .playbackActive
        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: session,
            conditionMonitor: monitor,
            capture: FakeAudioCapture(),
            inference: FakeLfmInference(),
            asrBackend: { TranscribingAsrBackend(text: "play the latest episode") }
        ) else {
            XCTFail("no service built, so this control proves nothing")
            return nil
        }
        Self.startedServices.append(service)
        service.startIfAllowed()
        return service
    }

    /// THE EXCEPTION MUST TRACK THE *CURRENT* ROUTE (reviewer `20f3cb92`, blocking).
    ///
    /// Driven through a LIVE service, not by constructing two gates: two fresh gates re-evaluate
    /// from scratch and therefore pass even when the service captures availability once at wiring
    /// time. (Measured — that first version of these controls was vacuous and a mutant survived it.)
    ///
    /// CONNECT: the service starts on a built-in-only route, where the diagnostic admits the
    /// built-in microphone. An external input then appears. A service that read availability once
    /// keeps the exception enabled and ignores the real headset.
    @MainActor
    func testLiveServiceDropsTheExceptionWhenAnExternalMicrophoneAppears() async throws {
        XCTAssertTrue(DiagnosticMicOverride.isActive, "premise: Debug simulator build")

        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .builtInSpeaker, uid: "sim-speaker")]
        session.inputs = [AudioPort(portType: .builtInMic, uid: "sim-builtin-mic")]
        session.available = [AudioPort(portType: .builtInMic, uid: "sim-builtin-mic")]
        session.availableAfterConfigure = [AudioPort(portType: .builtInMic, uid: "sim-builtin-mic")]

        guard let service = startedServiceForLiveRoute(session: session) else { return }
        let listening = await awaitTrue(timeout: 10) { service.isListening }
        XCTAssertTrue(listening, "premise: diagnostic admits the built-in mic; state=\(service.gateState)")
        guard listening else { return }

        // CONNECT an external input and republish the route, as a real route change would.
        session.available = [
            AudioPort(portType: .builtInMic, uid: "sim-builtin-mic"),
            AudioPort(portType: .bluetoothHFP, uid: "late-bt-mic"),
        ]
        session.availableAfterConfigure = session.available
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "late-bt-out")]
        service.routeMonitorForTesting.refreshRoute()

        let dropped = await awaitTrue(timeout: 10) {
            service.gateState.offReason == .exposedMicrophone
        }
        XCTAssertTrue(
            dropped,
            "a live service must drop the built-in exception the moment an external microphone "
                + "appears; reading availability once at wiring leaves it enabled. "
                + "state=\(service.gateState)"
        )
    }

    /// DISCONNECT: the service starts WITH an external microphone, where the requirement correctly
    /// suppresses the exception; the external input then goes away. A service that read
    /// availability once keeps the exception suppressed for the rest of the process, so the
    /// simulator permanently loses the approved diagnostic after any external route.
    @MainActor
    func testLiveServiceEnablesTheExceptionWhenTheExternalMicrophoneGoesAway() async throws {
        XCTAssertTrue(DiagnosticMicOverride.isActive, "premise: Debug simulator build")

        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "bt-out")]
        session.inputs = [AudioPort(portType: .bluetoothHFP, uid: "bt-mic")]
        session.available = [AudioPort(portType: .bluetoothHFP, uid: "bt-mic")]
        session.availableAfterConfigure = [AudioPort(portType: .bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true

        guard let service = startedServiceForLiveRoute(session: session) else { return }
        // Premise: an external microphone IS in use. Note the gate legitimately reaches
        // `listening` here — an isolated external mic is allowed without any exception — so the
        // premise must be asserted on the EXPOSURE, not on listening. (`!isListening` was the
        // wrong premise and failed for that reason, not because the diagnostic misbehaved.)
        let isolated = await awaitTrue(timeout: 10) {
            service.gatePosture.micExposure == .isolated
        }
        XCTAssertTrue(
            isolated,
            "premise: the external microphone must be in use, so the built-in exception is not "
                + "the reason for listening; state=\(service.gateState) exposure=\(service.gatePosture.micExposure)"
        )

        // DISCONNECT: nothing external remains.
        session.outputs = [AudioPort(portType: .builtInSpeaker, uid: "sim-speaker")]
        session.inputs = [AudioPort(portType: .builtInMic, uid: "sim-builtin-mic")]
        session.available = [AudioPort(portType: .builtInMic, uid: "sim-builtin-mic")]
        session.availableAfterConfigure = session.available
        service.routeMonitorForTesting.refreshRoute()

        let enabled = await awaitTrue(timeout: 10) { service.isListening }
        XCTAssertTrue(
            enabled,
            "the approved diagnostic must become available again once the external microphone is "
                + "gone; a stale availability read suppresses it permanently. state=\(service.gateState)"
        )
    }

    /// END TO END: a built-in-microphone-only session must reach `.listening` AND start capture,
    /// then receive samples. This is the owner's actual requirement (approval `77121fd4`, spec
    /// restatement `db25f02b`), not merely a gate flag flipping.
    ///
    /// Every wait is bounded and reports failure; the service is stopped in `tearDown` whether
    /// this passes, fails or throws.
    @MainActor
    func testBuiltInMicOnlySessionReachesListeningAndDeliversSamples() async {
        let session = FakeAudioSessionControlling()
        // Exactly the simulator's situation: a built-in output that cannot carry an external
        // microphone, and only the built-in input.
        session.outputs = [AudioPort(portType: .builtInSpeaker, uid: "sim-speaker")]
        session.inputs = [AudioPort(portType: .builtInMic, uid: "sim-builtin-mic")]
        session.available = [AudioPort(portType: .builtInMic, uid: "sim-builtin-mic")]
        session.availableAfterConfigure = [AudioPort(portType: .builtInMic, uid: "sim-builtin-mic")]
        session.selectionTakesEffect = true

        XCTAssertTrue(
            DiagnosticMicOverride.isActive,
            "premise: this suite runs in a Debug simulator build, where the override exists"
        )

        let capture = FakeAudioCapture()
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.setup = .allAllowed
        monitor.conflicts = GateConflicts(
            notOnCall: .allowed, notCasting: .allowed, batteryOk: .allowed, otherAppPlaying: .allowed
        )
        monitor.context = .playbackActive

        // The assembly loads the wake-word ONNX models synchronously; without a seeded model
        // manager it blocks the test host until the watchdog kills the run. Same seeding the
        // production-path suites use.
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("diagmic_seed_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: session,
            conditionMonitor: monitor,
            capture: capture,
            inference: FakeLfmInference(),
            modelManager: modelManager,
            // A TRANSCRIBING backend, not the empty one: an empty transcript yields no utterance,
            // so nothing is ever enqueued and sample delivery would look broken when the audio
            // actually arrived.
            asrBackend: { TranscribingAsrBackend(text: "play the latest episode") }
        ) else {
            XCTFail("no service built, so this control proves nothing")
            return
        }
        Self.startedServices.append(service)

        service.startIfAllowed()

        let listening = await awaitTrue(timeout: 10) { service.isListening }
        XCTAssertTrue(listening, "gate must reach listening; state=\(service.gateState)")
        guard listening else { return }

        // THE DIAGNOSTIC PATH ITSELF, asserted on its own observable. Capture start does NOT
        // prove it: `VoiceAsrEngine.start()` begins capture unconditionally once the engine runs,
        // so a control that stopped here passed even with the acquisition path mutated out
        // (measured — the mutant survived). The gate reaching `.listening` proves the ADMISSION
        // change; this proves the SESSION change, i.e. that a built-in-only route was actually
        // opened input-capable rather than skipped as `.notApplicable`.
        let configured = await awaitTrue(timeout: 10) { session.configureCount > 0 }
        XCTAssertTrue(
            configured,
            "the diagnostic must make the session input-capable; without it the built-in route "
                + "is skipped and only the gate half of the change is exercised"
        )

        // The diagnostic's whole point: capture must actually START. A gate that reports
        // listening but never opens the input would pass a state-only assertion.
        let started = await awaitTrue(timeout: 10) { capture.startCount > 0 }
        XCTAssertTrue(
            started,
            "reaching listening must actually START capture — otherwise the diagnostic is half done"
        )
        guard started else { return }

        // And the started capture must reach the PIPELINE, not merely accept samples: the hook
        // fires when a routed input is enqueued from captured audio, so it is real evidence that
        // audio flowed, unlike asserting a call count on the fake. A non-silent tone is used so
        // the VAD cannot dismiss it as silence.
        var fired = false
        service.enqueueAfterCaptureForTesting = {
            if !fired { fired = true }
        }
        // The gate settles in `.wakeWord` mode, where the pipeline deliberately does NOT route
        // speech — it waits for the wake word. Nothing about mic plumbing changes that, so enter
        // continuous mode exactly as a real wake-word detection would. Without this the audio
        // flows through capture and is correctly ignored, which would look like "samples never
        // arrive" but would be the wake-word requirement working.
        service.gracePeriodSignalForTesting.onWakeWordDetected()

        // ONE FRAME PER CALL, and well above the segmenter threshold: `minSpeechFrames` counts
        // CALLS (5), not samples, so a single large buffer is one frame and speech is never
        // confirmed — a single burst silently produces no segment and this would look like
        // "samples never arrive".
        let frameSize = 1_600   // 100 ms at 16 kHz
        for _ in 0..<20 {       // 2s of speech
            capture.emit(samples: [Float](repeating: 0.05, count: frameSize), at: nil)
        }
        // The silence window is WALL-CLOCK (Date() vs 500 ms), so quiet frames must be spread
        // across real time; back-to-back they elapse microseconds and no segment closes.
        for _ in 0..<8 {
            capture.emit(samples: [Float](repeating: 0.0, count: frameSize), at: nil)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        let delivered = await awaitTrue(timeout: 10) { fired }
        XCTAssertTrue(
            delivered,
            "samples from the built-in microphone must reach the voice pipeline, not just start capture"
        )
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
