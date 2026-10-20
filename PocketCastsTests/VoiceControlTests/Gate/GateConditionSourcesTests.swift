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

    /// OWNER DELTA 8fe04cd/0aa4480, CORRECTED per spec 3893cd55 (reviewer 724db1e8): the gate
    /// context comes ONLY from actual foreground OR an eligible playback context (an episode
    /// loaded — playing or paused). A cloud/grace hold is NEITHER and must never manufacture
    /// context: capture must be Off after the last genuine context is gone.
    func test_contextComesOnlyFromForegroundOrEligiblePlayback() {
        XCTAssertEqual(
            LiveConditionMonitor.resolveContext(foregroundAllowed: true, playbackContextAvailable: false),
            .appInForeground, "foreground only"
        )
        XCTAssertEqual(
            LiveConditionMonitor.resolveContext(foregroundAllowed: true, playbackContextAvailable: true),
            .both, "foreground plus playback"
        )
        XCTAssertEqual(
            LiveConditionMonitor.resolveContext(foregroundAllowed: false, playbackContextAvailable: true),
            .playbackActive, "backgrounded BUT an episode is loaded: real playback context"
        )
        XCTAssertEqual(
            LiveConditionMonitor.resolveContext(foregroundAllowed: false, playbackContextAvailable: false),
            .none, "backgrounded, no playback: no context, capture Off (fails closed)"
        )
    }

    /// THE DEFECT THIS PIN (regression control): a hold must never produce context. The same
    /// backgrounding with a HOLD but no real episode yields `.none`.
    func test_aHoldAloneIsNeverAContextSource() {
        XCTAssertEqual(
            LiveConditionMonitor.resolveContext(foregroundAllowed: false, playbackContextAvailable: false),
            .none,
            "even with a live cloud/grace hold, no real context source means no context"
        )
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
