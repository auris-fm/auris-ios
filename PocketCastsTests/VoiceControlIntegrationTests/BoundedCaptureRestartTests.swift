import AVFoundation
import XCTest
@testable import podcasts

/// The bounded automatic capture restart loop (core spec "Automatic capture
/// restarts", plan voice-control-core Step 7): a capture that dies on its own
/// gets one automatic restart through the same start path. If that restarted
/// capture dies again within 60 s, automatic restarts are withheld — logged
/// once as `mic_restart_withheld {reason, ran_ms}` — and only a new external
/// trigger (the user's device set changed, a blocker cleared, voice control
/// re-enabled) re-arms them. A non-device exposure flip is the app's own
/// routing state and must never restart or re-arm capture.
///
/// Runs in these tests are always far under 60 s, so the "dies within 60 s"
/// half of the rule is exercised naturally; the 60 s-healthy boundary is
/// pinned in `CaptureRestartPolicyTests`.
final class BoundedCaptureRestartTests: XCTestCase {

    private func port(_ type: AVAudioSession.Port, uid: String) -> AudioPort {
        AudioPort(portType: type, uid: uid)
    }

    private func makeService(
        _ session: FakeAudioSessionControlling,
        conditionMonitor: LiveConditionMonitor? = nil
    ) -> (VoiceControlService, RecordingMicLifecycleSink) {
        let sink = RecordingMicLifecycleSink()
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: session,
            conditionMonitor: conditionMonitor,
            capture: SucceedingCapture(),
            lifecycleLogSink: sink
        )!
        return (service, sink)
    }

    /// Give the real engine + monitors time to observe a stopped capture; a
    /// restart that should not happen must be given the chance to (wrongly)
    /// happen.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The loop: capture dies on its own (<60 s) → one restart through the
    /// same start path → the restarted capture dies again <60 s → withheld,
    /// logged once. A non-device exposure flip after the withhold must not
    /// restart capture; a real device trigger re-arms and does.
    ///
    /// Deaths here are deliberately NON-device route changes (category
    /// change): a connect/disconnect is itself a trigger that re-arms, so a
    /// route-loss-by-disconnect can never demonstrate the withhold.
    @MainActor
    func test_autonomousDeath_grantsOneRestart_thenSecondDeathIsWithheldUntilADeviceTrigger() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        session.available = [port(.bluetoothHFP, uid: "bt-mic")]

        let (service, sink) = makeService(session)
        service.startIfAllowed()

        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "the first capture runs")

        // Death 1: the route moves away without any physical device change
        // (autonomous end). Grants the one automatic restart.
        session.inputs = []
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { !service.isListening }

        // The route comes back the same non-device way: the gate restarts
        // capture through the same start path — the granted restart.
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "the automatic restart runs through the same start path")

        // Death 2: the restarted capture dies again, still <60 s → withheld.
        session.inputs = []
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { !service.isListening }

        XCTAssertEqual(
            sink.records.filter { $0.event == "mic_restart_withheld" }.count,
            1,
            "the withhold is logged exactly once, with the end reason and ran_ms"
        )
        let withheld = sink.records.first { $0.event == "mic_restart_withheld" }
        XCTAssertEqual(withheld?.level, .error)
        XCTAssertFalse(withheld?.reasons.isEmpty ?? true, "the withhold carries why the restart ended")

        // Another non-device exposure flip must NOT restart capture while
        // withheld: no trigger, no restart, no route acquisition.
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        postRouteChange(reason: .categoryChange)
        await settle()
        XCTAssertFalse(service.isListening,
                       "withheld restarts ignore non-device exposure flips — no trigger, no restart")

        // A real device trigger re-arms; capture may start again.
        postRouteChange(reason: .newDeviceAvailable)
        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "the device trigger re-armed automatic restarts")

        // Still exactly one withhold: the re-arm is not itself a withhold event.
        XCTAssertEqual(sink.records.filter { $0.event == "mic_restart_withheld" }.count, 1)
    }

    /// A route change that stops capture must never be mistaken for a
    /// user-requested stop: only voice control being disabled exempts a stop
    /// from the restart budget.
    @MainActor
    func test_userDisable_thenDeathWithinBudget_doesNotWithhold() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]

        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        // Built with the user's explicit off, the way a restored settings
        // choice arrives.
        let (service, sink) = makeService(session, conditionMonitor: monitor)
        service.startIfAllowed()
        await waitUntil(timeout: 5) { service.isListening }

        // The user disables voice control through the same published condition
        // the settings toggle drives — capture stops. Re-enabling is a genuine
        // trigger that re-arms; the following route-loss death is a fresh run
        // (not a restart run), so it grants a restart, never withholds.
        let enabled = monitor.setup.enabledByUser.isAllowed
        monitor.setup = GateSetup(
            enabledByUser: enabled ? GateCondition.blocked(reason: "user_disabled") : .allowed,
            deviceSupported: .allowed,
            modelsReady: .allowed
        )
        await waitUntil(timeout: 5) { !service.isListening }

        postRouteChange(reason: .oldDeviceUnavailable)
        await settle()
        XCTAssertFalse(
            sink.records.contains { $0.event == "mic_restart_withheld" },
            "a stop after a user disable and re-enable is not a withhold"
        )
    }

    private func postRouteChange(reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
        )
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

extension BoundedCaptureRestartTests {

    /// A blocker clearing is a trigger: it must re-arm a failed capture start
    /// (clear the capture-start-failed suppression) even with no physical
    /// device change. Before the widening, only a physical reconnect cleared
    /// the suppression, so a user whose blocker cleared (voice control
    /// re-enabled here) never got capture back.
    @MainActor
    func test_blockerClearing_rearmFailedCaptureStart_withoutDeviceChange() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        // The candidate is present but not yet acquired: the route is Exposed,
        // so capture needs the acquisition attempt this test is about.
        session.inputs = []
        session.available = [port(.bluetoothHFP, uid: "bt-mic")]
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.conflicts = GateConflicts(
            notOnCall: GateCondition.blocked(reason: "inCall"),
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )

        let sink = RecordingMicLifecycleSink()
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: session,
            conditionMonitor: monitor,
            capture: FailingCaptureWithPlaybackTeardown(monitorSession: session),
            lifecycleLogSink: sink
        )!
        service.startIfAllowed()

        // The call ends (blocker clears) while the route stays put: one
        // acquisition attempt follows. It fails to start, and the release
        // hides availableInputs — the suppression then holds.
        monitor.conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        await waitUntil(timeout: 5) { session.configureCount >= 1 }
        XCTAssertGreaterThanOrEqual(session.configureCount, 1, "the blocker clearing granted one acquisition attempt")
        await waitUntil(timeout: 5) { !service.isListening }
        XCTAssertTrue(service.isListening == false, "the failing capture never listens")

        // The user re-enables voice control — a blocked→allowed transition, no
        // device change. The failed-start suppression must clear so capture
        // tries again. The failed attempt's teardown hid availableInputs; the
        // headset is still physically connected, so the candidate is there.
        monitor.setup = GateSetup(
            enabledByUser: GateCondition.blocked(reason: "user_disabled"),
            deviceSupported: .allowed,
            modelsReady: .allowed
        )
        await settle()
        session.available = [port(.bluetoothHFP, uid: "bt-mic")]
        monitor.setup = GateSetup(
            enabledByUser: .allowed,
            deviceSupported: .allowed,
            modelsReady: .allowed
        )
        await waitUntil(timeout: 5) { session.configureCount >= 2 }
        XCTAssertEqual(session.configureCount, 2,
                       "the blocker clearing re-arms the failed start — no device change needed")
    }
}
