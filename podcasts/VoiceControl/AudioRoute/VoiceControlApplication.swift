import UIKit

/// Custom UIApplication that reports every touch event to TouchEventMonitor
/// so that AttendedSignal can reset its 30 s inactivity timer on user interaction.
class VoiceControlApplication: UIApplication {
    override func sendEvent(_ event: UIEvent) {
        super.sendEvent(event)
        if event.type == .touches {
            TouchEventMonitor.shared.reportTouch()
        }
    }
}
