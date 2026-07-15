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
        if !isActive {
            FileLog.shared.addMessage("[VoiceControl/Signal] GracePeriod: true (command recognized)")
        }
        isActive = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.isActive = false
        }
    }

    func onWakeWordDetected() {
        if !isActive {
            FileLog.shared.addMessage("[VoiceControl/Signal] GracePeriod: true (wake word detected)")
        }
        isActive = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.isActive = false
        }
    }

    /// Audio route change (e.g. unplugging headphones) breaks the grace period
    /// to avoid exposing the user's voice when they may not expect it.
    func onAudioRouteChanged() {
        if isActive {
            FileLog.shared.addMessage("[VoiceControl/Signal] GracePeriod: false (route changed)")
        }
        timer?.invalidate()
        isActive = false
    }

    /// App backgrounding breaks the grace period — privacy fails closed.
    func onAppBackgrounded() {
        if isActive {
            FileLog.shared.addMessage("[VoiceControl/Signal] GracePeriod: false (backgrounded)")
        }
        timer?.invalidate()
        isActive = false
    }
}
