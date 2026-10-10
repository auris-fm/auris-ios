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
}
