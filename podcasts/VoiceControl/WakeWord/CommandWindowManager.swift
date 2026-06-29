import Foundation

class CommandWindowManager {
    private let conversationTimeout: TimeInterval = 10.0
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

    var isOpen: Bool { windowOpen }
}
