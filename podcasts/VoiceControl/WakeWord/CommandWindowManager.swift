import Foundation

class CommandWindowManager {
    private let conversationTimeout: TimeInterval = 30.0
    private var windowOpen = false
    private var lastSpeechTime: Date?
    var onWindowStateChange: ((Bool) -> Void)?

    func onWakeWordDetected() {
        windowOpen = true
        lastSpeechTime = Date()
        onWindowStateChange?(true)
    }

    func onSpeechActivity() {
        guard windowOpen else { return }
        lastSpeechTime = Date()
    }

    func tick() {
        guard windowOpen, let last = lastSpeechTime else { return }
        if Date().timeIntervalSince(last) > conversationTimeout {
            windowOpen = false
            onWindowStateChange?(false)
        }
    }

    /// Immediately close the command window on audio route change
    /// to avoid exposing the user's voice after unplugging headphones.
    func onAudioRouteChanged() {
        guard windowOpen else { return }
        windowOpen = false
        onWindowStateChange?(false)
    }

    /// Immediately close the command window when the app backgrounds.
    /// Privacy fails closed.
    func onAppBackgrounded() {
        guard windowOpen else { return }
        windowOpen = false
        onWindowStateChange?(false)
    }

    /// Reset state for a new listening session.
    func reset() {
        windowOpen = false
        lastSpeechTime = nil
    }

    /// Close the command window (no state change callback).
    func close() {
        windowOpen = false
        lastSpeechTime = nil
    }

    var isOpen: Bool { windowOpen }

    /// Alias for isOpen — used by ASR engine.
    var isActive: Bool { windowOpen }
}
