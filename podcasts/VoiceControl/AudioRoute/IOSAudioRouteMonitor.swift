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

/// A single audio port, reduced to the two things acquisition needs: what it is
/// (`portType`) and which physical device it is (`uid`). This keeps the route
/// monitor testable — `AVAudioSessionPortDescription` cannot be constructed in a
/// unit test, but this value can.
struct AudioPort: Equatable {
    let portType: AVAudioSession.Port
    let uid: String
}

/// Outcome of a route-acquisition attempt. `.acquired` is the only value that
/// may lead to capture; every other case leaves the route `Exposed`/`NoMic`.
enum RouteAcquisitionResult: Equatable {
    /// `currentRoute.inputs` now confirms an external microphone.
    case acquired
    /// There is no external output that could carry an external microphone.
    case notApplicable
    /// The input-capable session exposed no external candidate.
    case noCandidate
    /// Only the built-in microphone can be selected — never fall back to it.
    case builtInOnly
    /// A candidate was selected but `currentRoute.inputs` did not confirm it.
    case selectionFailed
    /// Configuring/activating/selecting threw.
    case sessionUnavailable
    /// The enclosing task was cancelled; acquisition opened nothing or closed
    /// whatever it opened.
    case cancelled

    /// Runtime reason appended to a non-acquisition log. `nil` when there is
    /// nothing to log (`.acquired`, `.notApplicable` and `.cancelled`).
    var failureReason: String? {
        switch self {
        case .acquired, .notApplicable, .cancelled:
            return nil
        case .noCandidate:
            return "route_acquisition_no_candidate"
        case .builtInOnly:
            return "route_acquisition_built_in_only"
        case .selectionFailed:
            return "route_acquisition_not_confirmed"
        case .sessionUnavailable:
            return "route_acquisition_session_unavailable"
        }
    }
}

/// Minimal boundary over `AVAudioSession` for acquisition and route reading.
/// Discovery (`availableInputs`) and confirmation (`currentInputs`) are exposed
/// separately on purpose: availability is never selection.
protocol AudioSessionControlling: AnyObject {
    /// Whether the shared app session is currently active. Acquisition only
    /// deactivates a session it activated itself, so this preserves playback.
    var isActive: Bool { get }
    /// Ports the session is currently using (`currentRoute.outputs`).
    var currentOutputs: [AudioPort] { get }
    /// Ports the session is currently using (`currentRoute.inputs`).
    var currentInputs: [AudioPort] { get }
    /// Ports that *can* be selected (`availableInputs`). Empty for a playback
    /// session — consulting it before configuring proves nothing.
    var availableInputs: [AudioPort] { get }

    func configureInputCapableSession() throws
    func setSessionActive(_ active: Bool) throws
    func selectPreferredInput(uid: String) throws
}

/// Live `AVAudioSession` adapter. The acquisition sequence follows Apple QA1799:
/// configure `.playAndRecord` + `.allowBluetooth`, activate when the route only
/// settles on an active session, then select with `setPreferredInput(_:)`.
final class RealAudioSession: AudioSessionControlling {
    private var session: AVAudioSession { AVAudioSession.sharedInstance() }

    /// `AVAudioSession` exposes no public `isActive`, so track the last state we
    /// set. An already-`.playAndRecord` category also counts as active: it means
    /// the shared session is already configured for capture by voice control or
    /// playback, and acquisition must not deactivate it.
    private var sessionIsActive = false
    var isActive: Bool { sessionIsActive || session.category == .playAndRecord }

    var currentOutputs: [AudioPort] {
        session.currentRoute.outputs.map { AudioPort(portType: $0.portType, uid: $0.uid) }
    }

    var currentInputs: [AudioPort] {
        session.currentRoute.inputs.map { AudioPort(portType: $0.portType, uid: $0.uid) }
    }

    var availableInputs: [AudioPort] {
        (session.availableInputs ?? []).map { AudioPort(portType: $0.portType, uid: $0.uid) }
    }

    func configureInputCapableSession() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
        )
    }

    func setSessionActive(_ active: Bool) throws {
        if active {
            try session.setActive(true)
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        sessionIsActive = active
    }

    func selectPreferredInput(uid: String) throws {
        guard let port = (session.availableInputs ?? []).first(where: { $0.uid == uid }) else {
            throw AudioSessionError.inputNotFound
        }
        try session.setPreferredInput(port)
    }
}

enum AudioSessionError: Error {
    case inputNotFound
}

class IOSAudioRouteMonitor: ObservableObject {
    @Published var currentRoute: AudioRoute = .unknown
    @Published var micExposure: MicExposure = .noMic

    private let gracePeriodSignal: GracePeriodSignal
    private let audioSession: AudioSessionControlling
    private var cancellables = Set<AnyCancellable>()

    init(
        gracePeriodSignal: GracePeriodSignal = GracePeriodSignal(),
        audioSession: AudioSessionControlling = RealAudioSession()
    ) {
        self.gracePeriodSignal = gracePeriodSignal
        self.audioSession = audioSession
        refreshRoute()
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
                self.refreshRoute()
                self.gracePeriodSignal.onAudioRouteChanged()
            }
            .store(in: &cancellables)
    }

    /// Re-read the live route and recompute exposure. Classification uses only
    /// `currentRoute.inputs`: `availableInputs` lists what *could* be selected and
    /// must never be treated as the selected microphone.
    func refreshRoute() {
        let output = classifyOutput(audioSession.currentOutputs.first)
        let input = audioSession.currentInputs.first.flatMap { classifyInput($0.portType) }
        let previousExposure = micExposure
        currentRoute = AudioRoute(output: output, input: input)
        micExposure = MicExposureClassifier.classify(currentRoute)
        if micExposure != previousExposure {
            FileLog.shared.addMessage("[VoicePipeline] MicExposure: \(previousExposure) → \(micExposure) (output: \(output), input: \(input.map { "\($0)" } ?? "nil"))")
        }
    }

    /// Attempt to acquire an external microphone without listening.
    ///
    /// Configures (and, when the route only settles on an active session,
    /// activates) `.playAndRecord` + `.allowBluetooth`, discovers a candidate via
    /// `availableInputs`, selects it with `setPreferredInput(_:)`, and reports
    /// `.acquired` only when `currentRoute.inputs` confirms an external mic.
    /// Never falls back to the built-in microphone.
    @MainActor
    func acquireExternalInput() async -> RouteAcquisitionResult {
        // A task cancelled before it starts must not touch the audio session at
        // all — otherwise a blocked/`Off` posture would still open an input route.
        guard !Task.isCancelled else { return .cancelled }

        // Only an external output can carry an external microphone. A built-in
        // speaker/earpiece route has nothing to acquire, so do not touch the session.
        guard hasExternalOutputHint(currentRoute.output) else { return .notApplicable }
        if micExposure == .isolated { return .acquired }

        // Record explicitly whether acquisition itself activated the session.
        // The app shares one `AVAudioSession` with playback, so deactivating a
        // session that was already active would stop the app's own audio.
        let wasActiveBefore = audioSession.isActive
        var activatedByAcquisition = false

        do {
            try audioSession.configureInputCapableSession()
        } catch {
            FileLog.shared.addMessage("[VoicePipeline] acquisition: configure failed — \(error)")
            closeSession(activatedByAcquisition: activatedByAcquisition)
            refreshRoute()
            return .sessionUnavailable
        }

        // Some routes only populate inputs/availableInputs once the session is
        // active. Configure first; activate only if discovery still sees nothing.
        // Whether this actually transitioned the session is what
        // `activatedByAcquisition` records, so a session playback already holds
        // open is never deactivated by a later failed acquisition.
        if audioSession.currentInputs.isEmpty, audioSession.availableInputs.isEmpty {
            do {
                try audioSession.setSessionActive(true)
                activatedByAcquisition = !wasActiveBefore
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] acquisition: activate failed — \(error)")
                closeSession(activatedByAcquisition: activatedByAcquisition)
                refreshRoute()
                return .sessionUnavailable
            }
        }

        if let cancelled = cancellationResult(activatedByAcquisition: activatedByAcquisition) {
            return cancelled
        }

        refreshRoute()
        if micExposure == .isolated { return .acquired }

        let candidates = audioSession.availableInputs.filter { isExternalInput($0.portType) }
        guard let candidate = candidates.first else {
            closeSession(activatedByAcquisition: activatedByAcquisition)
            refreshRoute()
            let builtInAvailable = audioSession.availableInputs.contains { $0.portType == .builtInMic }
                || audioSession.currentInputs.contains { $0.portType == .builtInMic }
            return builtInAvailable ? .builtInOnly : .noCandidate
        }

        do {
            try audioSession.selectPreferredInput(uid: candidate.uid)
        } catch {
            FileLog.shared.addMessage("[VoicePipeline] acquisition: select failed — \(error)")
            closeSession(activatedByAcquisition: activatedByAcquisition)
            refreshRoute()
            return .selectionFailed
        }

        refreshRoute()
        if micExposure == .isolated { return .acquired }

        // Availability is not selection: the candidate was listed and selected
        // but the live route still reports the built-in mic.
        closeSession(activatedByAcquisition: activatedByAcquisition)
        refreshRoute()
        return .selectionFailed
    }

    /// If the enclosing task was cancelled while acquisition ran, close whatever
    /// acquisition opened so a blocked/`Off` posture retains no input route.
    private func cancellationResult(activatedByAcquisition: Bool) -> RouteAcquisitionResult? {
        guard Task.isCancelled else { return nil }
        closeSession(activatedByAcquisition: activatedByAcquisition)
        refreshRoute()
        return .cancelled
    }

    /// Deactivate only a session acquisition itself activated, so the app's own
    /// playback is never stopped. Best-effort — the session may already be inactive.
    private func closeSession(activatedByAcquisition: Bool) {
        guard activatedByAcquisition else { return }
        try? audioSession.setSessionActive(false)
    }

    private func hasExternalOutputHint(_ output: AudioRouteOutput) -> Bool {
        switch output {
        case .headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .airPlay:
            return true
        case .builtInSpeaker, .unknown:
            return false
        }
    }

    private func isExternalInput(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .headsetMic, .bluetoothHFP, .bluetoothLE:
            return true
        default:
            return false
        }
    }

    private func classifyOutput(_ port: AudioPort?) -> AudioRouteOutput {
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

    private func classifyInput(_ portType: AVAudioSession.Port) -> AudioRouteInput? {
        switch portType {
        case .headsetMic: return .headsetMic
        case .bluetoothHFP: return .bluetoothHFP
        case .bluetoothLE: return .bluetoothLE
        case .builtInMic: return .builtInMic
        default: return nil
        }
    }
}
