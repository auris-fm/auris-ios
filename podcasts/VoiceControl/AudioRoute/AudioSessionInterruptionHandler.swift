import AVFoundation
import Combine
import PocketCastsUtils

class AudioSessionInterruptionHandler: ObservableObject {
    @Published var isInterrupted = false

    private var cancellables = Set<AnyCancellable>()

    /// Called when interruption begins — stop capture, discard segment.
    var onInterruptionBegan: (() -> Void)?

    /// Called when interruption ends with shouldResume — reactivate session, recompute mode.
    var onInterruptionEnded: (() -> Void)?

    init() {
        NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let self,
                      let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let interruptionType = AVAudioSession.InterruptionType(rawValue: type)
                else { return }

                switch interruptionType {
                case .began:
                    FileLog.shared.addMessage("[VoiceControl/Interruption] Began — stopping capture, discarding segment")
                    self.isInterrupted = true
                    self.onInterruptionBegan?()

                case .ended:
                    guard let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    FileLog.shared.addMessage("[VoiceControl/Interruption] Ended (shouldResume: \(shouldResume))")
                    self.isInterrupted = false
                    if shouldResume {
                        self.onInterruptionEnded?()
                    }

                @unknown default:
                    break
                }
            }
            .store(in: &cancellables)
    }
}
