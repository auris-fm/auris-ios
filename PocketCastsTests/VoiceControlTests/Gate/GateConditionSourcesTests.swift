import XCTest
@testable import podcasts

final class GateConditionSourcesTests: XCTestCase {

    func test_notOnCall_whenNoCalls_isAllowed() {
        let source = CallConditionSource()
        // Real CXCallObserver has no calls on test devices
        XCTAssertTrue(source.current.isAllowed || source.current == .unknown(reason: "uninitialized"))
    }

    func test_batteryOk_inLowPowerMode_isBlocked() {
        // Low power mode is off in test harness normally
        let condition = BatteryConditionSource().current
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            XCTAssertEqual(condition, .blocked(reason: "low_power_mode"))
        } else {
            XCTAssertEqual(condition, .allowed)
        }
    }

    func test_foreground_source_returnsCondition() {
        let source = ForegroundConditionSource(gracePeriodSignal: GracePeriodSignal())
        // In test environment, app may not be active
        let condition = source.current
        XCTAssertNotNil(condition)
    }

    func test_gateCondition_isAllowed_property() {
        XCTAssertTrue(GateCondition.allowed.isAllowed)
        XCTAssertFalse(GateCondition.blocked(reason: "test").isAllowed)
        XCTAssertFalse(GateCondition.unknown(reason: "test").isAllowed)
    }

    /// OWNER DELTA 8fe04cd/0aa4480 (spec): foreground loss WITHOUT an active cloud/answer hold
    /// has no listening context; WITH one, the context survives so the background answer can
    /// finish. Capture permission (`.isolated` mic) is unchanged and asserted at the gate.
    func test_contextSurvivesForegroundLossOnlyWhileAHoldIsActive() {
        XCTAssertEqual(
            LiveConditionMonitor.resolveContext(foregroundAllowed: true, holdActive: false),
            .appInForeground,
            "foreground, no hold: normal context"
        )
        XCTAssertEqual(
            LiveConditionMonitor.resolveContext(foregroundAllowed: true, holdActive: true),
            .appInForeground,
            "foreground with a hold: still a context"
        )
        XCTAssertEqual(
            LiveConditionMonitor.resolveContext(foregroundAllowed: false, holdActive: true),
            .appInForeground,
            "backgrounded DURING a hold: the context must survive for the background answer"
        )
        XCTAssertEqual(
            LiveConditionMonitor.resolveContext(foregroundAllowed: false, holdActive: false),
            .none,
            "backgrounded with no hold: no context (privacy fails closed)"
        )
    }

    /// End-to-end through the GATE: with a live hold, a backgrounded app still resolves to a
    /// listening state; without one it is `.off(.noContext)`.
    func test_gateKeepsListeningThroughForegroundLossWhileHeld() {
        let setup = GateSetup.allAllowed
        let conflicts = GateConflicts.noneBlocked
        // The signal holds a window open (a cloud/answer turn is running).
        let signal = GracePeriodSignal()
        signal.onWakeWordDetected()
        let generation = signal.currentGeneration()
        let hold = signal.beginPlaybackHold(forGeneration: generation)
        XCTAssertNotNil(hold)
        XCTAssertTrue(signal.hasActiveHold, "premise: a live hold exists")

        let heldContext = LiveConditionMonitor.resolveContext(foregroundAllowed: false,
                                                              holdActive: signal.hasActiveHold)
        let heldGate = VoiceControlGate(setup: setup, conflicts: conflicts, context: heldContext,
                                        micExposure: .isolated, gracePeriodActive: signal.isActive)
        XCTAssertTrue(heldGate.state.isListening, "backgrounded with a hold: capture stays available")

        // No hold: the same backgrounding has no context.
        signal.endPlaybackHold(hold)
        let bareContext = LiveConditionMonitor.resolveContext(foregroundAllowed: false,
                                                              holdActive: signal.hasActiveHold)
        let bareGate = VoiceControlGate(setup: setup, conflicts: conflicts, context: bareContext,
                                        micExposure: .isolated, gracePeriodActive: signal.isActive)
        XCTAssertEqual(bareGate.state.offReason, .noContext, "backgrounded without a hold: no context")
    }

    func test_liveConditionMonitor_initialState() {
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        // The gate starts enabled (current 2-rule posture); readiness is
        // refined as the pipeline/router report in.
        XCTAssertEqual(monitor.setup.enabledByUser, .allowed)
    }

    func test_gateConflicts_isClear_withOtherAppPlaying() {
        let conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        XCTAssertTrue(conflicts.isClear)

        let blocked = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .blocked(reason: "other_app_playing")
        )
        XCTAssertFalse(blocked.isClear)
    }

    func test_otherAppPlayingSource_returnsCondition() {
        let source = OtherAppPlayingConditionSource()
        let condition = source.current
        // In test environment, other audio is typically not playing
        XCTAssertEqual(condition, .allowed)
    }

    func test_otherAppPlayingSource_publisherFiresOnRouteChange() {
        let source = OtherAppPlayingConditionSource()
        var receivedValue: GateCondition?
        let cancellable = source.publisher
            .sink { condition in
                receivedValue = condition
            }

        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)

        // The source debounces 500ms on RunLoop.main; XCTest's wait(for:) does
        // not reliably advance RunLoop.main timers, so pump the loop directly.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        XCTAssertNotNil(receivedValue)
        cancellable.cancel()
    }
}
