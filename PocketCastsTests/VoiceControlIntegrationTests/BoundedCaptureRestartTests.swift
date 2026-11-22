import AVFoundation
import XCTest
@testable import podcasts

/// The bounded automatic capture restart loop (core spec "Automatic capture
/// restarts", plan voice-control-core Step 7): a capture that dies on its own
/// gets one automatic restart through the same start path. If that restarted
/// capture dies again within 60 s, automatic restarts are withheld — logged
/// once as `mic_restart_withheld {reason, ran_ms}` (pinned at the logger
/// level in `VoiceControlServiceLoggingTests`) — and only a new external
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
    ) -> VoiceControlService {
        VoiceControlAssembly().buildVoiceControlService(
            audioSession: session,
            conditionMonitor: conditionMonitor,
            capture: SucceedingCapture()
        )!
    }

    /// Give the real engine + monitors time to observe a stopped capture; a
    /// restart that should not happen must be given the chance to (wrongly)
    /// happen.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The loop: capture dies on its own (<60 s) → one restart through the
    /// same start path → the restarted capture dies again <60 s → withheld.
    /// A non-device exposure flip after the withhold must not restart
    /// capture; a real device trigger re-arms and does.
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

        let service = makeService(session)
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
    }

    /// A stop caused by the user disabling voice control must never be
    /// mistaken for an autonomous death: re-enabling re-arms, and the next
    /// route-loss death is a fresh run whose death grants a restart, so
    /// capture comes back when the route returns.
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
        let service = makeService(session, conditionMonitor: monitor)
        service.startIfAllowed()
        await waitUntil(timeout: 5) { service.isListening }

        // The user disables voice control through the same published condition
        // the settings toggle drives — capture stops.
        monitor.setup = GateSetup(
            enabledByUser: GateCondition.blocked(reason: "user_disabled"),
            deviceSupported: .allowed,
            modelsReady: .allowed
        )
        await waitUntil(timeout: 5) { !service.isListening }

        // Re-enabling is a genuine trigger that re-arms; capture runs again.
        monitor.setup = GateSetup(
            enabledByUser: .allowed,
            deviceSupported: .allowed,
            modelsReady: .allowed
        )
        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "re-enabling voice control runs capture again")

        // The route-loss death is a fresh run (not a restart run), so it
        // grants a restart: when the route returns, capture runs again — a
        // withhold would leave it off.
        session.inputs = []
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { !service.isListening }
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "a death after a user disable/re-enable cycle grants a restart, never withholds")
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

        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: session,
            conditionMonitor: monitor,
            capture: FailingCaptureWithPlaybackTeardown(monitorSession: session)
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

extension BoundedCaptureRestartTests {

    /// An interruption's stop never counts against the restart budget, and it
    /// must not leak onto a later real death: after an interruption ends and
    /// capture resumes on a still-isolated route, that resumed run is a fresh
    /// run — its own autonomous death grants a restart, never a withhold.
    @MainActor
    func test_interruptionIsNotCounted_thenItsResumedRunGrantsARestart() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        session.available = [port(.bluetoothHFP, uid: "bt-mic")]

        let service = makeService(session)
        service.startIfAllowed()
        await waitUntil(timeout: 5) { service.isListening }

        // Interruption: capture stops, the route stays isolated.
        postInterruptionBegan()
        await waitUntil(timeout: 5) { !service.isListening }

        // The interruption ends with shouldResume: the gate recomputes and
        // capture resumes through the same start path.
        postInterruptionEnded(shouldResume: true)
        // A plain (non-device) route notification lets the gate recompute on
        // the real monitor path rather than relying on incidental side effects.
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "the post-interruption resume restarts capture")

        // That resumed run dies on its own: it was NOT a restart run, so its
        // death grants a restart instead of withholding.
        session.inputs = []
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { !service.isListening }

        // And the granted restart runs when the route returns.
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "the granted restart runs after the route returns")
    }

    private func postInterruptionBegan() {
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
    }

    private func postInterruptionEnded(shouldResume: Bool) {
        var userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
        ]
        if shouldResume {
            userInfo[AVAudioSessionInterruptionOptionKey] =
                AVAudioSession.InterruptionOptions.shouldResume.rawValue
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil, userInfo: userInfo
        )
    }
}

extension BoundedCaptureRestartTests {

    /// A stop caused by a conflict appearing (a call starting) is listening no
    /// longer being allowed, not an autonomous capture fault: it must not
    /// spend the restart budget. Its clearing is a trigger that re-arms, and
    /// a later genuine early death still grants a restart.
    @MainActor
    func test_conflictStop_doesNotSpendTheRestartBudget() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        session.available = [port(.bluetoothHFP, uid: "bt-mic")]
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())

        let service = makeService(session, conditionMonitor: monitor)
        service.startIfAllowed()
        await waitUntil(timeout: 5) { service.isListening }

        // A call starts and ends (exposure never changes — still isolated).
        monitor.conflicts = GateConflicts(
            notOnCall: GateCondition.blocked(reason: "inCall"),
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        await waitUntil(timeout: 5) { !service.isListening }
        monitor.conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "the blocker clearing resumes capture")

        // That resumed run dies on its own via an exposure loss: a fresh run,
        // so its death grants a restart — the route returning brings capture
        // back instead of leaving it withheld.
        session.inputs = []
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { !service.isListening }
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "a conflict stop never spends the budget")
    }
}

extension BoundedCaptureRestartTests {

    /// A headset disconnect that kills a RESTARTED run is the user's device
    /// changing, not a death of the capture itself: the device-change trigger
    /// fires in the SAME evaluation that observes the dead route (the monitor
    /// advances its epoch before publishing), so the budget is not spent and
    /// nothing withholds. The proof: after reconnecting and a plain route
    /// restoration, capture runs again — a withhold would leave it off.
    ///
    /// This goes through the real route monitor's notification path (posted
    /// `.oldDeviceUnavailable` / `.newDeviceAvailable`), never a hand-set
    /// epoch.
    @MainActor
    func test_headsetDisconnectDuringRestartRun_doesNotWithholdOrSpendTheBudget() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        session.available = [port(.bluetoothHFP, uid: "bt-mic")]

        let service = makeService(session)
        service.startIfAllowed()
        await waitUntil(timeout: 5) { service.isListening }

        // Fresh run dies autonomously → the granted restart runs.
        session.inputs = []
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { !service.isListening }
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { service.isListening }

        // The headset unplug kills the restarted capture. This is a physical
        // device change: the trigger re-arms in the same evaluation and the
        // budget is untouched.
        session.inputs = []
        session.available = []
        postRouteChange(reason: .oldDeviceUnavailable)
        await waitUntil(timeout: 5) { !service.isListening }

        // The headset comes back, then the route settles on it (non-device).
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        session.available = [port(.bluetoothHFP, uid: "bt-mic")]
        postRouteChange(reason: .newDeviceAvailable)
        await waitUntil(timeout: 5) { service.isListening }
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        postRouteChange(reason: .categoryChange)
        await settle()
        XCTAssertTrue(service.isListening, "the unplug re-armed restarts — capture runs on the restored route")

        // And a fresh early death still grants a restart: the unplug spent
        // nothing.
        session.inputs = []
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { !service.isListening }
        session.inputs = [port(.bluetoothHFP, uid: "bt-mic")]
        postRouteChange(reason: .categoryChange)
        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "the unplug spent no restart budget — a fresh death still grants a restart")
    }
}
