import Foundation
import Combine
import PocketCastsUtils

/// 30s conversation grace period after a wake-word detection or command recognition.
/// Keeps continuous listening alive so the user can issue follow-up commands
/// without re-triggering the wake word.
class GracePeriodSignal: ObservableObject {
    @Published private(set) var isActive = false
    private let timeout: TimeInterval
    private var timer: Timer?

    init(timeout: TimeInterval = 30.0) {
        self.timeout = timeout
    }

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
        // Wake/ASR callbacks arrive off the main thread. `Timer.scheduledTimer`
        // binds to the *current* run loop — on a cooperative QoS queue that loop
        // never spins, so the grace period never expires and listening stays
        // continuous. Mirror Android (`Dispatchers.Main` + delay).
        if Thread.isMainThread {
            startOrResetOnMain(trigger: trigger)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.startOrResetOnMain(trigger: trigger)
            }
        }
    }

    private func startOrResetOnMain(trigger: String) {
        if !isActive {
            FileLog.shared.addMessage("[VoicePipeline] GracePeriod: true (\(trigger))")
        }
        isActive = true
        timer?.invalidate()
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            self?.deactivate(trigger: "timeout")
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func deactivate(trigger: String) {
        let apply = { [weak self] in
            guard let self else { return }
            if self.isActive {
                FileLog.shared.addMessage("[VoicePipeline] GracePeriod: false (\(trigger))")
            }
            self.timer?.invalidate()
            self.timer = nil
            self.isActive = false
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}
