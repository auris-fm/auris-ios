import XCTest
import AVFoundation
@testable import podcasts

/// The route subscription must outlive the assembly that built it.
///
/// `AppDelegate` constructs the service through a temporary `VoiceControlAssembly()`, keeps
/// the service and discards the assembly. The service is what the app goes on to use, so any
/// behaviour that lives on a monitor reachable only through the assembly would stop working
/// at the moment the assembly is released — with no failure anywhere, because nothing
/// observes route changes in order to notice.
///
/// The cases here build through the assembly the way `AppDelegate` does, release it, and then
/// deliver a real route-change notification. They assert the effect on the engine's own
/// classification rather than on a helper called directly, because calling the helper would
/// pass whether or not any subscription exists.
final class RouteSubscriptionLifetimeTests: XCTestCase {

    /// The positive control: with the assembly alive, a route change reaches the grace signal.
    ///
    /// Without this, a failing lifetime case below could not be attributed to the release —
    /// it would be equally consistent with route changes never being observed at all.
    func test_routeChange_deactivatesGrace_whileTheAssemblyIsAlive() throws {
        let signal = GracePeriodSignal()
        let monitor = IOSAudioRouteMonitor(gracePeriodSignal: signal)

        signal.onWakeWordDetected()
        XCTAssertTrue(signal.isActive, "the grace window did not arm, so the case proves nothing")

        postRouteChange()

        XCTAssertFalse(
            signal.isActive,
            "a route change did not reach the grace signal even with the monitor retained"
        )
        _ = monitor
    }

    /// The regression: release the assembly, keep the service, and deliver a route change.
    ///
    /// This is the shape `AppDelegate` uses. If the subscription is owned by something the
    /// assembly holds, it dies here and the grace window stays armed across a route change —
    /// a privacy-relevant failure that fails closed-silently in the opposite direction from
    /// what the design intends.
    func test_routeChange_deactivatesGrace_afterTheAssemblyIsReleased() throws {
        let service: VoiceControlService?
        do {
            // Scoped so the assembly is released at the end of the block, as in the app.
            let assembly = VoiceControlAssembly()
            service = assembly.buildVoiceControlService()
            XCTAssertNotNil(service, "the assembly built no service, so the case proves nothing")
        } catch {
            throw error
        }

        guard let service else { return }

        // Reach the same grace signal the service uses, through the service rather than
        // through the assembly — the assembly is gone by now.
        let signal = service.gracePeriodSignalForTesting
        signal.onWakeWordDetected()
        XCTAssertTrue(signal.isActive, "the grace window did not arm, so the case proves nothing")

        postRouteChange()

        XCTAssertFalse(
            signal.isActive,
            """
            after the assembly was released, a route change no longer reached the grace \\
            signal: the subscription's lifetime is tied to the assembly rather than to the \\
            service the app keeps.
            """
        )
    }

    private func postRouteChange() {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]
        )
    }

    /// The echo-filter route must keep following the observed output route after the
    /// assembly that built the service has been released.
    ///
    /// `VoiceControlAssembly` subscribes to `routeMonitor.$currentRoute` and pushes the
    /// classification into the engine, storing the cancellable in the *assembly's* own set.
    /// `AppDelegate` builds through a temporary assembly and keeps only the service, so that
    /// subscription is torn down as soon as the builder goes out of scope and
    /// `setEchoFilterRoute` is never called again.
    ///
    /// The engine then keeps whatever route it was constructed with, so a route change on
    /// the real device — plugging in headphones, connecting to a car — leaves the filter
    /// correlating against the window of the route it is no longer on.
    ///
    /// This is the subscription the reported defect concerns, and it is not the one the
    /// grace-signal case above exercises: that one is owned by the monitor itself and
    /// survives on its own account.
    func test_echoFilterRouteFollowsTheOutputRoute_afterTheAssemblyIsReleased() throws {
        let service: VoiceControlService?
        do {
            let assembly = VoiceControlAssembly()
            service = assembly.buildVoiceControlService()
            XCTAssertNotNil(service, "the assembly built no service, so the case proves nothing")
        }

        guard let service else { return }

        let engine = service.asrEngineForTesting
        let monitor = service.routeMonitorForTesting

        // Move the observed route to the built-in speaker and let Combine deliver.
        monitor.currentRoute = AudioRoute(output: .builtInSpeaker, input: .builtInMic)
        let delivered = expectation(description: "the engine was told about the new route")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { delivered.fulfill() }
        wait(for: [delivered], timeout: 2)

        XCTAssertEqual(
            engine.echoFilterRoute, .builtInSpeaker,
            """
            after the assembly was released, the engine's echo-filter route no longer \
            follows the observed output route: the subscription that drives it was owned by \
            the builder rather than by the service the app keeps.
            """
        )
    }
}
