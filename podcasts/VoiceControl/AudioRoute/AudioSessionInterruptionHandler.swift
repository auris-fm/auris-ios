import AVFoundation
import Combine
import PocketCastsUtils

class AudioSessionInterruptionHandler: ObservableObject {
    @Published var isInterrupted = false

    private var cancellables = Set<AnyCancellable>()

    /// Called when interruption begins — stop capture, discard segment.
    ///
    /// Main-actor-typed on purpose: the system posts interruption notifications on
    /// an arbitrary thread, so the guarantee has to come from the type. Anyone
    /// assigning or invoking this from off-main is a compile error rather than a
    /// race. The one call site below hops.
    @MainActor var onInterruptionBegan: (@MainActor () -> Void)?

    /// Called when interruption ends with shouldResume — reactivate session, recompute mode.
    ///
    /// Main-actor for the same reason as `onInterruptionBegan`: it reactivates the
    /// audio session and recomputes the mode, both main-actor work, and it is
    /// invoked from the same arbitrarily-threaded notification.
    @MainActor var onInterruptionEnded: (@MainActor () -> Void)?

    init() {
        NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification)
            // Hop at the SOURCE, where the system notification arrives, so the
            // `isInterrupted` writes and both callbacks run together on main and in
            // emission order. Hopping only the callbacks would leave the published
            // state being written on the posting thread.
            .receive(on: DispatchQueue.main)
            .sink { @MainActor [weak self] notification in
                guard let self,
                      let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let interruptionType = AVAudioSession.InterruptionType(rawValue: type)
                else { return }

                switch interruptionType {
                case .began:
                    FileLog.shared.addMessage("[VoicePipeline] Began — stopping capture, discarding segment")
                    self.isInterrupted = true
                    // The notification handler runs on the posting thread; the callback
                    // and the `@Published` write above are main-actor work.
                    self.onInterruptionBegan?()

                case .ended:
                    // The interruption has ended regardless of the resume option;
                    // only the reactivation callback is gated on shouldResume.
                    self.isInterrupted = false
                    let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    FileLog.shared.addMessage("[VoicePipeline] Ended (shouldResume: \(shouldResume))")
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
