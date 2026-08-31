import Foundation
import Combine
import PocketCastsUtils

/// 30s conversation grace period after a wake-word detection or command recognition.
/// Keeps continuous listening alive so the user can issue follow-up commands
/// without re-triggering the wake word.
class GracePeriodSignal: ObservableObject {
    @Published var isActive = false
    private let timeout: TimeInterval = 30.0
    private var timer: Timer?

    func onCommandRecognized() {
        startOrReset(trigger: "command recognized")
    }

    func onWakeWordDetected() {
        startOrReset(trigger: "wake word detected")
    }

    /// Audio route change (e.g. unplugging headphones) breaks the grace period
    /// to avoid exposing the user's voice when they may not expect it.
    func onAudioRouteChanged() {
        deactivate(trigger: "route changed")
    }

    /// App backgrounding breaks the grace period — privacy fails closed.
    func onAppBackgrounded() {
        deactivate(trigger: "backgrounded")
    }

    private func startOrReset(trigger: String) {
        if !isActive {
            FileLog.shared.addMessage("[VoiceControl/Signal] GracePeriod: true (\(trigger))")
        }
        isActive = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.isActive = false
        }
    }

    private func deactivate(trigger: String) {
        if isActive {
            FileLog.shared.addMessage("[VoiceControl/Signal] GracePeriod: false (\(trigger))")
        }
        timer?.invalidate()
        isActive = false
    }
}
