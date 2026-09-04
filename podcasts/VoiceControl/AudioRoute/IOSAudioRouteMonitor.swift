import AVFoundation
import Combine
import PocketCastsUtils

enum AudioRouteOutput {
    case headphones, bluetoothHFP, bluetoothA2DP, bluetoothLE, builtInSpeaker, airPlay, unknown
}

enum AudioRouteInput {
    case headsetMic, bluetoothHFP, bluetoothLE, builtInMic
}

struct AudioRoute: Equatable {
    let output: AudioRouteOutput
    let input: AudioRouteInput?

    static let unknown = AudioRoute(output: .unknown, input: nil)
}

enum MicExposureClassifier {
    static func classify(_ route: AudioRoute) -> MicExposure {
        guard let input = route.input else { return .noMic }
        switch input {
        case .headsetMic, .bluetoothHFP, .bluetoothLE:
            return .isolated
        case .builtInMic:
            return .exposed
        }
    }
}

class IOSAudioRouteMonitor: ObservableObject {
    @Published var currentRoute: AudioRoute = .unknown
    @Published var micExposure: MicExposure = .noMic

    private let gracePeriodSignal: GracePeriodSignal
    private var cancellables = Set<AnyCancellable>()

    init(gracePeriodSignal: GracePeriodSignal = GracePeriodSignal()) {
        self.gracePeriodSignal = gracePeriodSignal
        updateRoute(AVAudioSession.sharedInstance().currentRoute)
        NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                guard let self,
                      let info = notification.userInfo,
                      let reason = info[AVAudioSessionRouteChangeReasonKey] as? UInt
                else { return }
                let validReasons: Set<UInt> = [
                    AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                ]
                guard validReasons.contains(reason) else { return }
                self.updateRoute(AVAudioSession.sharedInstance().currentRoute)
                self.gracePeriodSignal.onAudioRouteChanged()
            }
            .store(in: &cancellables)
    }

    private func updateRoute(_ avRoute: AVAudioSessionRouteDescription) {
        let output = classifyOutput(avRoute.outputs.first)
        // On devices with a built-in mic (all iPhones/iPads), currentRoute.inputs
        // may be empty before the audio session is configured for recording.
        // Fall back to availableInputs so the gate doesn't deadlock itself
        // (gate blocks → no recording session → inputs stay empty).
        let inputPort = avRoute.inputs.first
            ?? AVAudioSession.sharedInstance().availableInputs?.first
        let input = inputPort.flatMap { classifyInput($0) }
        let previousExposure = micExposure
        currentRoute = AudioRoute(output: output, input: input)
        micExposure = MicExposureClassifier.classify(currentRoute)
        if micExposure != previousExposure {
            FileLog.shared.addMessage("[VoicePipeline] MicExposure: \(previousExposure) → \(micExposure) (output: \(output), input: \(input.map { "\($0)" } ?? "nil"))")
        }
    }

    private func classifyOutput(_ port: AVAudioSessionPortDescription?) -> AudioRouteOutput {
        guard let port else { return .builtInSpeaker }
        switch port.portType {
        case .headphones: return .headphones
        case .bluetoothHFP: return .bluetoothHFP
        case .bluetoothA2DP: return .bluetoothA2DP
        case .bluetoothLE: return .bluetoothLE
        case .builtInSpeaker: return .builtInSpeaker
        case .airPlay: return .airPlay
        default: return .builtInSpeaker
        }
    }

    private func classifyInput(_ port: AVAudioSessionPortDescription) -> AudioRouteInput? {
        switch port.portType {
        case .headsetMic: return .headsetMic
        case .bluetoothHFP: return .bluetoothHFP
        case .bluetoothLE: return .bluetoothLE
        case .builtInMic: return .builtInMic
        default: return nil
        }
    }
}
