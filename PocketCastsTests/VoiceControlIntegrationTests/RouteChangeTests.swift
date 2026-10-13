import AVFoundation
import XCTest
@testable import podcasts

/// Controllable `AudioSessionControlling` for acquisition tests. Models the
/// distinction the spec cares about: a `.playback` session exposes no inputs,
/// `availableInputs` is only a list of what *could* be selected, and selecting a
/// port changes `currentRoute.inputs` only when the platform actually takes it.
final class FakeAudioSessionControlling: AudioSessionControlling {
    var outputs: [AudioPort] = []
    var inputs: [AudioPort] = []
    var available: [AudioPort] = []

    /// Populated when the session becomes input-capable, mirroring AVAudioSession
    /// (a `.playback` session reports no `availableInputs`).
    var availableAfterConfigure: [AudioPort] = []
    var availableAfterActivate: [AudioPort] = []
    /// When false, `setPreferredInput` is accepted but the live route keeps the
    /// built-in mic — the "availability is not selection" case.
    var selectionTakesEffect = true

    private(set) var configureCount = 0
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var selectedUIDs: [String] = []
    private(set) var isActive = false

    var currentOutputs: [AudioPort] { outputs }
    var currentInputs: [AudioPort] { inputs }
    var availableInputs: [AudioPort] { available }

    func configureInputCapableSession() throws {
        configureCount += 1
        available = availableAfterConfigure
    }

    func setSessionActive(_ active: Bool) throws {
        if active {
            activateCount += 1
        } else {
            deactivateCount += 1
        }
        isActive = active
        if active, !availableAfterActivate.isEmpty {
            available = availableAfterActivate
        }
    }

    func selectPreferredInput(uid: String) throws {
        selectedUIDs.append(uid)
        guard selectionTakesEffect, let port = available.first(where: { $0.uid == uid }) else { return }
        inputs = [port]
    }
}

final class RouteChangeTests: XCTestCase {

    private func port(_ type: AVAudioSession.Port, uid: String = UUID().uuidString) -> AudioPort {
        AudioPort(portType: type, uid: uid)
    }

    private func makeMonitor(_ session: FakeAudioSessionControlling) -> IOSAudioRouteMonitor {
        IOSAudioRouteMonitor(gracePeriodSignal: GracePeriodSignal(), audioSession: session)
    }

    // MARK: - Classifier

    func test_micExposureClassifier_isolatedCases() {
        let testCases: [(AudioRouteInput, MicExposure)] = [
            (.headsetMic, .isolated),
            (.bluetoothHFP, .isolated),
            (.bluetoothLE, .isolated),
        ]
        for (input, expected) in testCases {
            let route = AudioRoute(output: .headphones, input: input)
            XCTAssertEqual(MicExposureClassifier.classify(route), expected, "Input \(input) should be \(expected)")
        }
    }

    func test_micExposureClassifier_builtInMic_isExposed() {
        let route = AudioRoute(output: .builtInSpeaker, input: .builtInMic)
        XCTAssertEqual(MicExposureClassifier.classify(route), .exposed)
    }

    func test_micExposureClassifier_noInput_isNoMic() {
        let route = AudioRoute(output: .bluetoothA2DP, input: nil)
        XCTAssertEqual(MicExposureClassifier.classify(route), .noMic)
    }

    // MARK: - Route acquisition

    func test_acquisition_playbackSessionWithBluetooth_selectsAndConfirmsIsolated() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []  // playback session: no input ports
        session.available = []  // and no availableInputs either
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        let monitor = makeMonitor(session)

        // Before acquisition the playback session exposes nothing → NoMic.
        XCTAssertEqual(monitor.micExposure, .noMic)

        let result = await monitor.acquireExternalInput()

        XCTAssertEqual(result, .acquired)
        XCTAssertEqual(session.configureCount, 1, "acquisition must configure an input-capable session")
        XCTAssertEqual(session.selectedUIDs, ["bt-mic"], "the discovered candidate is selected with setPreferredInput")
        XCTAssertEqual(monitor.micExposure, .isolated, "only currentRoute.inputs confirming the external mic classifies Isolated")
        XCTAssertEqual(session.deactivateCount, 0, "a successful acquisition leaves the session open for capture")
    }

    func test_acquisition_externalListedButBuiltInStillSelected_isExposed() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = [port(.builtInMic, uid: "built-in")]
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = false  // availability is not selection
        let monitor = makeMonitor(session)
        XCTAssertEqual(monitor.micExposure, .exposed)

        let result = await monitor.acquireExternalInput()

        XCTAssertEqual(result, .selectionFailed)
        XCTAssertEqual(monitor.micExposure, .exposed, "no external mic confirmed → capture must not be allowed")
        XCTAssertEqual(session.deactivateCount, 1, "a failed acquisition closes what it opened")
    }

    func test_acquisition_onlyBuiltInAvailable_isExposed() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = [port(.builtInMic, uid: "built-in")]
        session.availableAfterConfigure = [port(.builtInMic, uid: "built-in")]
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput()

        XCTAssertEqual(result, .builtInOnly)
        XCTAssertEqual(monitor.micExposure, .exposed)
        XCTAssertTrue(session.selectedUIDs.isEmpty, "never select the built-in mic")
        XCTAssertEqual(session.deactivateCount, 1)
    }

    func test_acquisition_noExternalInput_logsFailureReason() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.availableAfterConfigure = []
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput()

        XCTAssertEqual(result, .noCandidate)
        XCTAssertNotNil(result.failureReason)
        XCTAssertNotEqual(monitor.micExposure, .isolated)
        XCTAssertEqual(session.deactivateCount, 1)
    }

    func test_bluetoothDisconnectMidCapture_reEvaluatesToExposed() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        let monitor = makeMonitor(session)
        _ = await monitor.acquireExternalInput()
        XCTAssertEqual(monitor.micExposure, .isolated)

        // Bluetooth disconnects: output falls back to the speaker, input to the
        // built-in mic, and the external mic disappears from availableInputs.
        session.outputs = [port(.builtInSpeaker, uid: "speaker")]
        session.inputs = [port(.builtInMic, uid: "built-in")]
        session.available = []
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )

        XCTAssertEqual(monitor.micExposure, .exposed, "a disconnected external mic must stop capture eligibility")
    }

    func test_builtInSpeakerRoute_noAcquisitionAttempted() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.builtInSpeaker, uid: "speaker")]
        session.inputs = [port(.builtInMic, uid: "built-in")]
        // Even a Bluetooth candidate in the discovery list cannot be reached
        // without an external output hint.
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput()

        XCTAssertEqual(result, .notApplicable)
        XCTAssertEqual(session.configureCount, 0, "no acquisition is attempted for a built-in route")
        XCTAssertEqual(session.activateCount, 0)
    }

    func test_builtInReceiverRoute_noAcquisitionAttempted() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.builtInReceiver, uid: "receiver")]
        session.inputs = [port(.builtInMic, uid: "built-in")]
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput()

        XCTAssertEqual(result, .notApplicable)
        XCTAssertEqual(session.configureCount, 0)
    }

    // MARK: - Gate matrix

    func test_gate_modeResolution_matrix() {
        // Only an Isolated route permits capture; mode-policy cases use `.isolated`.
        // Grace period active → continuous
        let graceGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .appInForeground,
            micExposure: .isolated,
            gracePeriodActive: true
        )
        XCTAssertEqual(graceGate.state, .listening(mode: .continuous))

        // No grace period → wake word (appInForeground, isolated)
        let foregroundGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .appInForeground,
            micExposure: .isolated,
            gracePeriodActive: false
        )
        XCTAssertEqual(foregroundGate.state, .listening(mode: .wakeWord))

        // No grace period → wake word (playbackActive, isolated)
        let backgroundGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .playbackActive,
            micExposure: .isolated,
            gracePeriodActive: false
        )
        XCTAssertEqual(backgroundGate.state, .listening(mode: .wakeWord))

        // Built-in microphone route blocks capture even with grace active.
        let exposedGate = VoiceControlGate(
            setup: .allAllowed,
            conflicts: .noneBlocked,
            context: .appInForeground,
            micExposure: .exposed,
            gracePeriodActive: true
        )
        XCTAssertEqual(exposedGate.state, .off(reason: .exposedMicrophone))
    }
}
