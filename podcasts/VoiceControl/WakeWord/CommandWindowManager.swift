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

    var isOpen: Bool { windowOpen }
}
