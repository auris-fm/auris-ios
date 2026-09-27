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
    /// Escalation budget for the current window (shared client contract: at most
    /// one dispatch per grace window). Restored by anything that opens or resets
    /// the window — a wake or a recognised command — and never by the escalation
    /// attempt itself, so a run of routing failures inside one window dispatches
    /// once instead of once per failure.
    private var escalationClaimed = false

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

    /// Consumes the window's escalation budget. Returns `false` when the window
    /// is closed or already spent — the caller then keeps the turn local.
    func claimEscalationBudget() -> Bool {
        if Thread.isMainThread { return claimEscalationBudgetOnMain() }
        return DispatchQueue.main.sync { claimEscalationBudgetOnMain() }
    }

    /// Marks the current window's budget spent *without* extending the window.
    ///
    /// The fallback dispatch itself is a successful command, so the executor
    /// restarts the grace period when it returns — which would otherwise restore
    /// the budget and let a second unclear utterance in the same window dispatch
    /// again. The window is meant to continue; the escalation allowance is not.
    func markEscalationBudgetSpent() {
        if Thread.isMainThread { escalationClaimed = true; return }
        DispatchQueue.main.async { [weak self] in self?.escalationClaimed = true }
    }

    private func claimEscalationBudgetOnMain() -> Bool {
        guard isActive, !escalationClaimed else { return false }
        escalationClaimed = true
        return true
    }

    private func startOrResetOnMain(trigger: String) {
        // Publish first, then log. Logging while `isActive` still held the old
        // value let Combine condition refreshes resolve the wrong listening mode.
        let becameActive = !isActive
        isActive = true
        escalationClaimed = false
        if becameActive {
            FileLog.shared.addMessage("[VoicePipeline] GracePeriod: true (\(trigger))")
        }
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
            let wasActive = self.isActive
            self.timer?.invalidate()
            self.timer = nil
            self.isActive = false
            if wasActive {
                FileLog.shared.addMessage("[VoicePipeline] GracePeriod: false (\(trigger))")
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}
