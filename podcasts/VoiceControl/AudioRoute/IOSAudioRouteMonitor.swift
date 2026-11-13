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

/// Physical route identity for acquisition dedup. Two different devices can
/// present the same port *types* (e.g. two Bluetooth headsets, both
/// `.bluetoothA2DP` output / `.bluetoothHFP` input), so the port UIDs are part
/// of the key: a failed acquisition on one device must not suppress an attempt
/// for another.
struct AudioRouteIdentity: Equatable {
    let output: AudioRouteOutput
    let outputUID: String?
    let input: AudioRouteInput?
    let inputUID: String?
}

/// The service's acquisition dedup key: a route identity plus the epoch of the
/// physical-device change it was observed on. See `IOSAudioRouteMonitor.acquisitionKey`.
///
/// The epoch is what makes a *physical route-change notification* grant one attempt
/// even when the route identity is unchanged. It is deliberately per-notification:
/// each received physical notification advances it, so each is entitled to one
/// attempt on its own. Distinct notifications are NOT inferred to be one physical
/// event (spec 5d418579) — that is not required, and the counter cannot establish it.
struct AcquisitionRouteKey: Equatable {
    let route: AudioRouteIdentity
    let deviceChangeEpoch: UInt
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
    /// Release any preferred input (`setPreferredInput(nil)`) so an external
    /// input route is not retained after a failed/cancelled acquisition.
    func clearPreferredInput()
    /// Restore the playback-friendly category after acquisition configured an input-capable one.
    /// An acquisition that never became capture must not leave the shared session in
    /// `.playAndRecord`: playback then routes through `.defaultToSpeaker`, and `PlaybackManager`
    /// skips the category restore for `.playAndRecord`, so nothing recovers it.
    func restorePlaybackCategory()
}

/// Live `AVAudioSession` adapter. The acquisition sequence follows Apple QA1799:
/// configure `.playAndRecord` + `.allowBluetooth`, activate when the route only
/// settles on an active session, then select with `setPreferredInput(_:)`.
final class RealAudioSession: AudioSessionControlling {
    private var session: AVAudioSession { AVAudioSession.sharedInstance() }

    /// `AVAudioSession` exposes no public active-state query, so track the last
    /// state acquisition itself set. This is deliberately *not* inferred from
    /// the category: `category == .playAndRecord` says nothing about whether the
    /// session is active, and treating it as active hid live `.playback`
    /// sessions (which then got deactivated on a failed acquisition). Whether
    /// playback is using the shared session is supplied by the caller instead.
    private var sessionIsActive = false
    var isActive: Bool { sessionIsActive }

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

    func clearPreferredInput() {
        try? session.setPreferredInput(nil)
    }

    func restorePlaybackCategory() {
        // Match `PlaybackManager.setAudioSessionProperties`, which selects `.spokenAudio`: restoring
        // `.default` here would silently change the mode of a live playback session until playback
        // activates again.
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
    }
}

enum AudioSessionError: Error {
    case inputNotFound
}

class IOSAudioRouteMonitor: ObservableObject {
    @Published var currentRoute: AudioRoute = .unknown
    @Published var micExposure: MicExposure = .noMic
    /// Whether ANY external microphone is available to capture from right now.
    ///
    /// The Debug-simulator diagnostic exception must apply ONLY when this is false. Reading it
    /// from the session keeps the exception pinned to "the simulator genuinely has no external
    /// route" rather than "the gate happens to be off".
    /// Whether an external microphone is or COULD BE available.
    ///
    /// Deliberately conservative in the direction that preserves the requirement: it is true if an
    /// external input is listed OR the current output is itself an external route that could carry
    /// one. The narrower `availableInputs`-only check was not sufficient — a session reports no
    /// available inputs until it is configured input-capable, so the gate could evaluate while the
    /// real answer was still "external mic possible" and the diagnostic would wrongly admit the
    /// built-in microphone. Erring toward "external possible" can only keep the requirement, never
    /// relax it.
    var hasExternalMicrophoneCandidate: Bool {
        if audioSession.availableInputs.contains(where: { isExternalInput($0.portType) }) {
            return true
        }
        return hasExternalOutputHint(currentRoute.output)
    }

    private let gracePeriodSignal: GracePeriodSignal
    private let audioSession: AudioSessionControlling
    private var cancellables = Set<AnyCancellable>()

    /// How long `acquireExternalInput` waits for the live route to confirm a
    /// selected external input. `setPreferredInput` commonly settles on a later
    /// `routeChangeNotification`, so an immediate read can still report the
    /// built-in mic; the bounded wait re-reads the route until the deadline.
    var confirmationTimeout: Duration = .milliseconds(500)

    /// Whether the last successful acquisition activated the shared session.
    /// The service releases an acquired route that never led to capture; this
    /// records what that release is allowed to undo (never a session playback
    /// already owns).
    private var lastAcquisitionActivatedSession = false
    /// Whether the last successful acquisition selected a preferred input.
    private var lastAcquisitionSelectedInput = false
    /// Counts physical audio-device changes — a device connected or disconnected, as reported by
    /// the route-change notification. Selection changes do not advance it. It is the only reliable
    /// evidence that an external device is genuinely gone: `availableInputs` is empty whenever the
    /// session is not input-capable, including the `.playback` restore after a failed capture, so a
    /// missing candidate UID alone is not proof of removal.
    private(set) var physicalDeviceChangeEpoch: UInt = 0
    /// UID of the external input the last acquisition selected. Retained across
    /// the preferred-input release so a failed capture start can be keyed to the
    /// physical device rather than the transient live route (which reverts to the
    /// built-in mic on release).
    private(set) var lastAcquisitionTargetUID: String?

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
                let isPhysicalDeviceChange = validReasons.contains(reason)
                // Re-read the route for EVERY reason: an `.override`, `.categoryChange` or
                // `.routeConfigurationChange` can move the input away from the headset, and a stale
                // `.isolated` would leave capture running on the built-in microphone. Only a
                // physical connect/disconnect advances the epoch and breaks grace.
                self.refreshRoute()
                if isPhysicalDeviceChange {
                    self.physicalDeviceChangeEpoch &+= 1
                    self.gracePeriodSignal.onAudioRouteChanged()
                }
            }
            .store(in: &cancellables)
    }

    /// Current route keyed by physical port UID as well as port type, for the
    /// service's one-attempt-per-route acquisition dedup.
    var currentRouteIdentity: AudioRouteIdentity {
        AudioRouteIdentity(
            output: currentRoute.output,
            outputUID: audioSession.currentOutputs.first?.uid,
            input: currentRoute.input,
            inputUID: audioSession.currentInputs.first?.uid
        )
    }

    /// The acquisition dedup key: the live route identity **paired with the
    /// physical-device-change epoch**.
    ///
    /// The identity alone cannot express the retry contract. After a headset
    /// disconnect and reconnect the session is in `.playback`, so it selects no
    /// input: the identity is type-level (`input: nil`) and *identical* to the
    /// failed attempt that preceded the disconnect — yet the device is genuinely
    /// re-presented and the contract grants one fresh attempt (spec 5d418579).
    /// The epoch distinguishes the two: it advances once per received physical
    /// route-change notification, so a later notification produces a key that
    /// differs from the failed attempt's key even with an unchanged identity.
    ///
    /// Note the actual publication ordering — the epoch is incremented by the
    /// monitor's route-change handler, not atomically with `refreshRoute()`. The
    /// handler calls `refreshRoute()` first (which publishes `micExposure` →
    /// one gate evaluation carrying the OLD epoch) and only then increments the
    /// epoch and breaks grace (whose `isActive` publication → a second gate
    /// evaluation carrying the NEW epoch). So a single physical notification can
    /// reach `considerAcquisition` twice; the first sees the old key and is
    /// deduped, and the second sees the new epoch and is the attempt the contract
    /// grants. This key is read at each evaluation, so it is correct in both.
    var acquisitionKey: AcquisitionRouteKey {
        AcquisitionRouteKey(route: currentRouteIdentity, deviceChangeEpoch: physicalDeviceChangeEpoch)
    }

    /// The live external input candidate (from `availableInputs`) — the physical
    /// device a route acquisition would select. Stable across the preferred-input
    /// release, unlike `currentRouteIdentity`, so it can key the "capture start
    /// failed" suppression.
    var currentExternalInputUID: String? {
        audioSession.availableInputs.first { isExternalInput($0.portType) }?.uid
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
    func acquireExternalInput(isPlaybackActive: @escaping () -> Bool = { false }) async -> RouteAcquisitionResult {
        // A task cancelled before it starts must not touch the audio session at
        // all — otherwise a blocked/`Off` posture would still open an input route.
        guard !Task.isCancelled else { return .cancelled }
        // Each attempt starts fresh: do not let a previous attempt's device key
        // leak into the "capture start failed" fallback if this one does not
        // select an input.
        lastAcquisitionTargetUID = nil

        // Only an external output can carry an external microphone. A built-in
        // speaker/earpiece route has nothing to acquire, so do not touch the session.
        guard hasExternalOutputHint(currentRoute.output) else {
            // DIAGNOSTIC (Debug simulator only): there is no external route here, so the normal
            // path can never open an input and the whole capture path goes unexercised on a
            // simulator. Open the session input-capable so the BUILT-IN microphone can deliver
            // samples. The real classification is untouched — `micExposure` still reads
            // `.exposed`; only the acquisition decision differs, and only under the compile-time
            // constants in `DiagnosticMicOverride`.
            // `.noMic` TOO: a fresh simulator session reports NO input port at all until the
            // session is configured input-capable, so requiring `.exposed` here made the
            // diagnostic unreachable in the actual app (measured: the live simulator logs
            // `off(noMicrophone)`, never `exposed`). `.isolated` is still refused — a real
            // external microphone must never be traded for the built-in one.
            guard DiagnosticMicOverride.isActive,
                  micExposure == .exposed || micExposure == .noMic
            else { return .notApplicable }
            return await acquireBuiltInInputForDiagnostic(isPlaybackActive: isPlaybackActive)
        }
        if micExposure == .isolated {
            return acquiredResult(activatedByAcquisition: false, hadSelectedInput: false, isPlaybackActive: isPlaybackActive)
        }

        // Record explicitly whether acquisition itself activated the session.
        // The app shares one `AVAudioSession` with playback, so deactivating a
        // session in use by playback would stop the app's own audio. Playback is
        // signalled by the caller because `AVAudioSession` cannot be queried for
        // its active state and the category is not an activity signal.
        let sessionAlreadyInUse = audioSession.isActive || isPlaybackActive()
        var activatedByAcquisition = false

        do {
            try audioSession.configureInputCapableSession()
        } catch {
            FileLog.shared.addMessage("[VoicePipeline] acquisition: configure failed — \(error)")
            releaseAcquisitionRoute(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: false, isPlaybackActive: isPlaybackActive)
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
                activatedByAcquisition = !sessionAlreadyInUse
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] acquisition: activate failed — \(error)")
                releaseAcquisitionRoute(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: false, isPlaybackActive: isPlaybackActive)
                refreshRoute()
                return .sessionUnavailable
            }
        }

        if let cancelled = cancellationResult(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: false, isPlaybackActive: isPlaybackActive) {
            return cancelled
        }

        refreshRoute()
        if micExposure == .isolated {
            return acquiredResult(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: false, isPlaybackActive: isPlaybackActive)
        }

        let candidates = audioSession.availableInputs.filter { isExternalInput($0.portType) }
        guard let candidate = candidates.first else {
            releaseAcquisitionRoute(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: false, isPlaybackActive: isPlaybackActive)
            refreshRoute()
            let builtInAvailable = audioSession.availableInputs.contains { $0.portType == .builtInMic }
                || audioSession.currentInputs.contains { $0.portType == .builtInMic }
            return builtInAvailable ? .builtInOnly : .noCandidate
        }

        do {
            try audioSession.selectPreferredInput(uid: candidate.uid)
            lastAcquisitionTargetUID = candidate.uid
        } catch {
            FileLog.shared.addMessage("[VoicePipeline] acquisition: select failed — \(error)")
            releaseAcquisitionRoute(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: true, isPlaybackActive: isPlaybackActive)
            refreshRoute()
            return .selectionFailed
        }

        refreshRoute()
        if micExposure == .isolated {
            // Checked as late as possible: cancellation can land after the last
            // mid-run checkpoint, and the acquisition must not report success
            // with the external input route left selected.
            return acquiredResult(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: true, isPlaybackActive: isPlaybackActive)
        }

        // `setPreferredInput` often settles via a later route-change
        // notification; declaring failure from the immediate read would undo a
        // selection the platform was about to take. Wait (bounded) for the live
        // route to confirm before giving up.
        if await confirmExternalInput() {
            return acquiredResult(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: true, isPlaybackActive: isPlaybackActive)
        }

        // Availability is not selection: the candidate was listed and selected
        // but the live route still reports the built-in mic.
        releaseAcquisitionRoute(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: true, isPlaybackActive: isPlaybackActive)
        refreshRoute()
        if Task.isCancelled { return .cancelled }
        return .selectionFailed
    }

    /// DIAGNOSTIC ONLY (Debug simulator): make the session input-capable so the built-in
    /// microphone can be captured. Mirrors the normal path's configure/activate bookkeeping so
    /// release-on-failure still undoes exactly what was opened, and reports `.acquired` only when
    /// a built-in input is actually present in the live route.
    ///
    /// This is not a relaxation of the requirement: it is never reached on device or in Release
    /// (both `DiagnosticMicOverride` constants are compile-time), it does not alter
    /// `micExposure`, and it cannot select an external input.
    @MainActor
    private func acquireBuiltInInputForDiagnostic(isPlaybackActive: @escaping () -> Bool) async -> RouteAcquisitionResult {
        FileLog.shared.addMessage("[VoicePipeline] acquisition: \(DiagnosticMicOverride.logLabel) — opening built-in input")
        let sessionAlreadyInUse = audioSession.isActive || isPlaybackActive()
        var activatedByAcquisition = false

        do {
            try audioSession.configureInputCapableSession()
        } catch {
            FileLog.shared.addMessage("[VoicePipeline] acquisition: diagnostic configure failed — \(error)")
            releaseAcquisitionRoute(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: false, isPlaybackActive: isPlaybackActive)
            refreshRoute()
            return .sessionUnavailable
        }

        if audioSession.currentInputs.isEmpty, audioSession.availableInputs.isEmpty {
            do {
                try audioSession.setSessionActive(true)
                activatedByAcquisition = !sessionAlreadyInUse
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] acquisition: diagnostic activate failed — \(error)")
                releaseAcquisitionRoute(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: false, isPlaybackActive: isPlaybackActive)
                refreshRoute()
                return .sessionUnavailable
            }
        }

        refreshRoute()
        if Task.isCancelled {
            releaseAcquisitionRoute(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: false, isPlaybackActive: isPlaybackActive)
            return .cancelled
        }

        let hasBuiltIn = audioSession.currentInputs.contains { $0.portType == .builtInMic }
            || audioSession.availableInputs.contains { $0.portType == .builtInMic }
        guard hasBuiltIn else {
            // No built-in microphone either: this is a genuinely mic-less device, and the
            // diagnostic must not invent one.
            releaseAcquisitionRoute(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: false, isPlaybackActive: isPlaybackActive)
            refreshRoute()
            return .noCandidate
        }

        // Deliberately does NOT select a preferred input: on the built-in route there is nothing
        // to select, and the diagnostic must not touch input selection at all.
        return acquiredResult(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: false, isPlaybackActive: isPlaybackActive)
    }

    /// Bounded wait for the live route to confirm an external input. Re-reads
    /// the route on each step; a cancelled enclosing task aborts the wait and
    /// returns false (the caller releases whatever acquisition opened).
    @MainActor
    private func confirmExternalInput() async -> Bool {
        if micExposure == .isolated { return true }
        let deadline = ContinuousClock.now + confirmationTimeout
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
            refreshRoute()
            if micExposure == .isolated { return true }
        }
        refreshRoute()
        return micExposure == .isolated
    }

    /// Release an external input route that a successful acquisition opened when
    /// the service did not start capture (e.g. a conflict landed between the
    /// exposure flip and the gate transition). Clears only the preferred input
    /// acquisition selected and deactivates only a session acquisition itself
    /// activated — never one playback owns.
    func releaseAcquiredExternalInput(sessionInUseByPlayback: Bool = false) {
        releaseAcquisitionRoute(
            activatedByAcquisition: lastAcquisitionActivatedSession,
            hadSelectedInput: lastAcquisitionSelectedInput,
            isPlaybackActive: { sessionInUseByPlayback }
        )
        refreshRoute()
    }

    /// `.acquired`, unless the enclosing task was cancelled after the route was
    /// confirmed — then release what acquisition opened and report `.cancelled`.
    private func acquiredResult(activatedByAcquisition: Bool, hadSelectedInput: Bool, isPlaybackActive: () -> Bool) -> RouteAcquisitionResult {
        if let cancelled = cancellationResult(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: hadSelectedInput, isPlaybackActive: isPlaybackActive) {
            return cancelled
        }
        // Ownership for a later release if capture never starts.
        lastAcquisitionActivatedSession = activatedByAcquisition
        lastAcquisitionSelectedInput = hadSelectedInput
        return .acquired
    }

    /// If the enclosing task was cancelled while acquisition ran, close whatever
    /// acquisition opened so a blocked/`Off` posture retains no input route.
    private func cancellationResult(activatedByAcquisition: Bool, hadSelectedInput: Bool, isPlaybackActive: () -> Bool) -> RouteAcquisitionResult? {
        guard Task.isCancelled else { return nil }
        releaseAcquisitionRoute(activatedByAcquisition: activatedByAcquisition, hadSelectedInput: hadSelectedInput, isPlaybackActive: isPlaybackActive)
        refreshRoute()
        return .cancelled
    }

    /// The one release primitive for an acquired input route, shared by acquisition cleanup and
    /// `releaseAcquiredExternalInput`. Any preferred input acquisition selected is always cleared
    /// so no external input route is retained, and the session is deactivated only when acquisition
    /// itself activated it — never when playback is already using the shared session. Ownership is
    /// re-read live at this point, not the value sampled when acquisition started, because playback
    /// can begin during the confirmation wait.
    private func releaseAcquisitionRoute(activatedByAcquisition: Bool, hadSelectedInput: Bool, isPlaybackActive: () -> Bool) {
        if hadSelectedInput {
            audioSession.clearPreferredInput()
        }
        // Restore the playback category whether or not we deactivate: an acquisition that never
        // became capture must not leave the shared session input-capable, and nothing else restores
        // it for `.playAndRecord`.
        audioSession.restorePlaybackCategory()
        lastAcquisitionActivatedSession = false
        lastAcquisitionSelectedInput = false
        // Re-check live playback ownership at cleanup time, not the value
        // sampled when acquisition started: playback can begin during the
        // confirmation wait, and deactivating then would stop the podcast.
        // `releaseAcquiredExternalInput` makes the same live re-check.
        guard activatedByAcquisition, !isPlaybackActive() else { return }
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

    func isExternalInput(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .headsetMic, .bluetoothHFP, .bluetoothLE:
            return true
        default:
            return false
        }
    }
    func classifyOutputForTesting(_ port: AVAudioSessionPortDescription?) -> AudioRouteOutput {
        classifyOutput(port)
    }

    /// Classifies the current output port, defaulting to `unknown` rather than to any named
    /// route.
    ///
    /// A missing port and an unrecognised port type are both "not known to be the built-in
    /// speaker", and they must not acquire its alignment: `forOutput` gives `.builtInSpeaker`
    /// the correlation window, which is justified by that route's bounded local latency. A USB
    /// DAC, car head unit, hearing aid or any future port type has codec latency this client
    /// has not measured, so claiming the built-in window for it would align the filter against
    /// a latency that is not there. `unknown` maps to `.external`, which is the honest scope
    /// for a route whose behaviour has not been established.
    /// The ABSTRACTION-side overload: `audioSession.currentOutputs` yields `AudioPort` values, so the
    /// monitor's own callers classify through this. It dispatches on the port TYPE only, so it shares
    /// the classification with the AVAudioSession overload rather than duplicating it.
    func classifyOutput(_ port: AudioPort?) -> AudioRouteOutput {
        classifyOutput(portType: port?.portType)
    }

    private func classifyOutput(_ port: AVAudioSessionPortDescription?) -> AudioRouteOutput {
        classifyOutput(portType: port?.portType)
    }

    /// Shared classification: dispatches on the port TYPE raw value, so both overloads agree on every
    /// route. A missing port and an unrecognised type both map to `unknown`.
    private func classifyOutput(portType: AVAudioSession.Port?) -> AudioRouteOutput {
        guard let portType else { return .unknown }
        switch portType {
        case .headphones: return .headphones
        case .bluetoothHFP: return .bluetoothHFP
        case .bluetoothA2DP: return .bluetoothA2DP
        case .bluetoothLE: return .bluetoothLE
        case .builtInSpeaker: return .builtInSpeaker
        case .airPlay: return .airPlay
        // Every other port type — USB, car audio, hearing aids, and anything Apple adds — is
        // unknown rather than assumed. The previous `.builtInSpeaker` default silently enabled
        // the correlation window on routes the alignment does not hold for.
        default: return .unknown
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
