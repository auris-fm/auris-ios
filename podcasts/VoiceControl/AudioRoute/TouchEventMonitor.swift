import UIKit
import Combine

/// Monitors touch events across the app to feed the AttendedSignal.
/// A custom UIApplication subclass (VoiceControlApplication) posts touch
/// events here, and VoiceControlService subscribes to forward them to
/// AttendedSignal.onUserInteraction().
class TouchEventMonitor {
    static let shared = TouchEventMonitor()
    let touchEvent = PassthroughSubject<Void, Never>()

    func reportTouch() {
        touchEvent.send()
    }
}
