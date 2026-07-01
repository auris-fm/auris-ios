import Foundation
import Combine

// MARK: - Attended Signal

/// Tracks whether the user has interacted with the app within the last 30s.
/// Foreground + attended → continuous listening (lowest friction).
class AttendedSignal: ObservableObject {
    @Published var isAttended = false
    private let timeout: TimeInterval = 30.0
    private var timer: Timer?

    func onUserInteraction() {
        isAttended = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.isAttended = false
        }
    }
}

// MARK: - Grace Period Signal

/// 30s conversation grace period after a command is recognized.
/// Keeps continuous listening alive so the user can issue follow-up commands
/// without re-triggering wake word.
class GracePeriodSignal: ObservableObject {
    @Published var isActive = false
    private let timeout: TimeInterval = 30.0
    private var timer: Timer?

    func onCommandRecognized() {
        isActive = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.isActive = false
        }
    }

    /// Audio route change (e.g. unplugging headphones) breaks the grace period
    /// to avoid exposing the user's voice when they may not expect it.
    func onAudioRouteChanged() {
        timer?.invalidate()
        isActive = false
    }

    /// App backgrounding breaks the grace period — privacy fails closed.
    func onAppBackgrounded() {
        timer?.invalidate()
        isActive = false
    }
}

// MARK: - Playback Recency Signal

/// Tracks whether audio playback was active within the last 30s.
/// Used to decide between continuous and wake-word mode when the app is
/// in the background with an isolated (headset) microphone.
class PlaybackRecencySignal: ObservableObject {
    @Published var isRecent = false
    private let timeout: TimeInterval = 30.0
    private var lastPlayingTime: Date?
    private var timer: Timer?

    func update(isPlaying: Bool) {
        if isPlaying {
            isRecent = true
            lastPlayingTime = Date()
            timer?.invalidate()
        } else {
            lastPlayingTime = Date()
            scheduleExpiry()
        }
    }

    private func scheduleExpiry() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.isRecent = false
        }
    }
}
