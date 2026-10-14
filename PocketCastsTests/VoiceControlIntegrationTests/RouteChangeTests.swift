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
    private(set) var clearCount = 0
    private(set) var selectedUIDs: [String] = []
    var isActive = false
    /// Invoked when the session is activated — lets a test cancel the
    /// enclosing acquisition task mid-run.
    var onActivate: (() -> Void)?
    /// Invoked when a preferred input is selected — lets a test cancel the
    /// enclosing acquisition task after selection.
    var onSelect: (() -> Void)?

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
        if active { onActivate?() }
    }

    func selectPreferredInput(uid: String) throws {
        selectedUIDs.append(uid)
        onSelect?()
        guard selectionTakesEffect, let port = available.first(where: { $0.uid == uid }) else { return }
        inputs = [port]
    }

    func clearPreferredInput() {
        clearCount += 1
        // Only a selection this fake actually applied is released; a built-in
        // default input is not manufactured into the route.
        if let selected = selectedUIDs.last, inputs.first?.uid == selected {
            inputs = []
        }
    }
}

/// Test double whose `start()` succeeds without touching the shared
/// `AVAudioEngine`/`AVAudioSession`, so service-level tests are deterministic
/// about whether capture started.
final class SucceedingCapture: NativeAudioCapture {
    override func start() throws {}
}

/// Test double whose `start()` fails, to drive the failed-capture-start path.
/// `VoiceAsrEngine.start()` must report this and the service must not listen.
final class FailingCapture: NativeAudioCapture {
    override func start() throws {
        throw NSError(
            domain: "FailingCapture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "capture start failed"]
        )
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
        XCTAssertEqual(session.deactivateCount, 0, "a session acquisition never activated is not deactivated")
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
        XCTAssertEqual(session.deactivateCount, 0, "a session acquisition never activated is not deactivated")
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

    func test_acquisition_inputsAppearOnlyAfterActivate_activatesAndAcquires() async {
        // The route only settles on an active session: nothing is discoverable
        // until `setSessionActive(true)`, then the external mic appears and can
        // be selected. This is the activation branch of acquisition.
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = []
        session.availableAfterActivate = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput()

        XCTAssertEqual(result, .acquired)
        XCTAssertEqual(session.configureCount, 1)
        XCTAssertEqual(session.activateCount, 1, "the input-capable session is activated when nothing is discoverable before activation")
        XCTAssertEqual(session.selectedUIDs, ["bt-mic"])
        XCTAssertEqual(monitor.micExposure, .isolated)
        XCTAssertEqual(session.deactivateCount, 0)
    }

    @MainActor
    func test_acquisition_cancelledBeforeRun_returnsCancelledWithoutTouchingSession() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        let monitor = makeMonitor(session)

        // Create the task, then cancel before the main actor ever runs it, so
        // acquisition sees a cancelled task on entry.
        let task = Task { @MainActor in
            await monitor.acquireExternalInput()
        }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(result.failureReason, "a cancelled acquisition is not a failure to log")
        XCTAssertEqual(session.configureCount, 0, "a cancelled acquisition must not touch the session")
        XCTAssertEqual(session.activateCount, 0)
        XCTAssertEqual(session.deactivateCount, 0)
        XCTAssertEqual(monitor.micExposure, .noMic)
    }

    @MainActor
    func test_acquisition_cancelledMidRun_closesActivatedSession() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterActivate = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        let monitor = makeMonitor(session)

        var acquisition: Task<RouteAcquisitionResult, Never>?
        session.onActivate = { acquisition?.cancel() }
        let task = Task { @MainActor in
            await monitor.acquireExternalInput()
        }
        acquisition = task
        let result = await task.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(session.deactivateCount, 1, "cancellation closes the session acquisition activated")
        XCTAssertEqual(monitor.micExposure, .noMic)
    }

    func test_failedAcquisition_onSessionAppAlreadyHeldActive_doesNotDeactivate() async {
        // The app shares one AVAudioSession for playback. Acquisition must not
        // deactivate a session it did not activate, or it would stop playback.
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.isActive = true
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput()

        XCTAssertEqual(result, .noCandidate)
        XCTAssertEqual(session.deactivateCount, 0, "a session the app already had active is left untouched")
    }

    func test_failedAcquisition_whenPlaybackActive_doesNotDeactivateSession() async {
        // A live `.playback` session reports `isActive == false` to this fake
        // (as AVAudioSession does: it exposes no active-state query). Playback
        // is the signal that actually reflects the shared session is in use, so
        // a failed acquisition must not deactivate it and stop playback.
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.isActive = false
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput(isPlaybackActive: { true })

        XCTAssertEqual(result, .noCandidate)
        XCTAssertEqual(session.deactivateCount, 0, "playback owns the shared session; a failed acquisition must not deactivate it")
    }

    @MainActor
    func test_acquisition_cancelledAfterSelection_releasesInputAndClosesSession() async {
        // Cancellation can land after the last mid-run checkpoint (between the
        // checkpoint and the `.acquired` return). It must not report `.acquired`
        // with the external input left selected.
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        let monitor = makeMonitor(session)

        var acquisition: Task<RouteAcquisitionResult, Never>?
        session.onSelect = { acquisition?.cancel() }
        let task = Task { @MainActor in
            await monitor.acquireExternalInput()
        }
        acquisition = task
        let result = await task.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(session.clearCount, 1, "cancellation releases the external input selection")
        XCTAssertNotEqual(monitor.micExposure, .isolated, "a cancelled acquisition must not leave an isolated route")
    }

    func test_acquisition_settlesViaLaterRouteConfirmation() async {
        // `setPreferredInput` commonly moves the live route on a later
        // route-change notification. The immediate read still reports the
        // built-in mic; acquisition must wait (bounded) instead of undoing the
        // selection with `.selectionFailed`.
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = [port(.builtInMic, uid: "built-in")]
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = false
        let monitor = makeMonitor(session)

        // The platform applies the selection one runloop turn later, as a route
        // change would.
        session.onSelect = {
            DispatchQueue.main.async {
                session.inputs = session.available.filter { $0.uid == "bt-mic" }
            }
        }

        let result = await monitor.acquireExternalInput()

        XCTAssertEqual(result, .acquired, "the later route confirmation must count as a successful acquisition")
        XCTAssertEqual(monitor.micExposure, .isolated)
        XCTAssertEqual(session.selectedUIDs, ["bt-mic"])
    }

    func test_releaseAcquiredExternalInput_clearsSelection() async {
        // An acquisition that succeeds but never leads to capture must not leave
        // the external input route selected.
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput()
        XCTAssertEqual(result, .acquired)
        XCTAssertEqual(monitor.micExposure, .isolated)

        monitor.releaseAcquiredExternalInput()

        XCTAssertEqual(session.clearCount, 1, "the selected external input is released")
        XCTAssertNotEqual(monitor.micExposure, .isolated, "no external input is retained without capture")
        XCTAssertEqual(session.deactivateCount, 0, "a session acquisition never activated is not deactivated")
    }

    func test_releaseAcquiredExternalInput_neverDeactivatesPlaybackSession() async {
        // The acquired route is released, but a session playback owns must not
        // be deactivated even if acquisition had to activate it to discover the
        // input.
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterActivate = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput(isPlaybackActive: { true })
        XCTAssertEqual(result, .acquired)
        XCTAssertEqual(session.activateCount, 1)

        monitor.releaseAcquiredExternalInput()

        XCTAssertEqual(session.clearCount, 1)
        XCTAssertEqual(session.deactivateCount, 0, "playback owns the shared session; release must not deactivate it")
    }

    func test_releaseAcquiredExternalInput_whenPlaybackStartsAfterAcquisition_doesNotDeactivate() async {
        // Playback is not active when acquisition samples it, so acquisition
        // activates the shared session itself. Playback then starts during the
        // acquisition/confirmation window; release must re-check the live
        // playback state rather than trust the value sampled at task start.
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterActivate = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput(isPlaybackActive: { false })
        XCTAssertEqual(result, .acquired)
        XCTAssertEqual(session.activateCount, 1, "acquisition activated the shared session")

        monitor.releaseAcquiredExternalInput(sessionInUseByPlayback: true)

        XCTAssertEqual(session.clearCount, 1, "the selected external input is still released")
        XCTAssertEqual(session.deactivateCount, 0, "playback now owns the shared session; release must not deactivate it")
    }

    func test_releaseAcquiredExternalInput_whenPlaybackStillInactive_deactivatesSession() async {
        // Control for the re-check above: the same acquisition with playback
        // still inactive at release time does deactivate the session it opened.
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterActivate = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true
        let monitor = makeMonitor(session)

        let result = await monitor.acquireExternalInput(isPlaybackActive: { false })
        XCTAssertEqual(result, .acquired)

        monitor.releaseAcquiredExternalInput(sessionInUseByPlayback: false)

        XCTAssertEqual(session.clearCount, 1)
        XCTAssertEqual(session.deactivateCount, 1, "with playback still inactive, the session acquisition activated is released")
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

    // MARK: - Service-level acquisition reentrancy

    /// A successful acquisition flips `micExposure` to `.isolated`, whose
    /// `@Published` emission runs the service's gate sink synchronously *inside*
    /// `acquireExternalInput`. That sink must not cancel the very task committing
    /// the route, and the route must survive once capture starts.
    @MainActor
    func test_service_acquisitionOfBluetoothCandidate_keepsCaptureAndDoesNotClearInput() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true

        let service = VoiceControlAssembly().buildVoiceControlService(audioSession: session, capture: SucceedingCapture())!
        service.startIfAllowed()

        await waitUntil(timeout: 5) { service.isListening }

        XCTAssertEqual(service.micExposure, .isolated,
                       "acquisition must not undo its own successful exposure flip")
        XCTAssertTrue(service.isListening, "a successful acquisition must leave capture running")
        XCTAssertEqual(session.selectedUIDs, ["bt-mic"], "the external candidate is selected")
        XCTAssertEqual(session.clearCount, 0,
                       "the reentrant gate must not clear the preferred input acquisition just selected")
        XCTAssertEqual(session.deactivateCount, 0,
                       "the reentrant gate must not deactivate the acquired session")
    }

    @MainActor
    func test_service_cancelledAcquisition_retriesSameRouteAfterBlockerClears() async {
        // A transient blocker (here: a conflict) cancels a pending acquisition.
        // Once the blocker clears, the same route must be attempted again;
        // otherwise capture silently never starts.
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = [port(.builtInMic, uid: "built-in")]
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = false  // keep the attempt pending in its confirmation wait

        let conditionMonitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        let service = VoiceControlAssembly()
            .buildVoiceControlService(audioSession: session, conditionMonitor: conditionMonitor, capture: SucceedingCapture())!
        service.startIfAllowed()

        await waitUntil(timeout: 5) { session.configureCount >= 1 }
        XCTAssertEqual(session.configureCount, 1, "the eligible route starts an acquisition attempt")

        conditionMonitor.conflicts = GateConflicts(
            notOnCall: .blocked(reason: "call_in_progress"),
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        conditionMonitor.conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )

        await waitUntil(timeout: 5) { session.configureCount >= 2 }
        XCTAssertEqual(session.configureCount, 2, "the same route is retried once the blocker clears")
    }

    // MARK: - Cleanup re-checks live playback ownership

    /// Critical: acquisition samples playback ownership when it starts, but the
    /// async confirmation wait is a window in which playback can begin. A
    /// failure cleanup must re-check live ownership, not trust the sample, or it
    /// deactivates the session playback just started using.
    @MainActor
    func test_failedAcquisition_whenPlaybackStartsDuringConfirmation_doesNotDeactivateSession() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterActivate = [port(.bluetoothHFP, uid: "bt-mic")]
        // Availability is not selection: the confirmation wait never settles, so
        // acquisition fails after the wait.
        session.selectionTakesEffect = false
        let monitor = makeMonitor(session)

        var playbackActive = false
        // Playback starts while acquisition is parked in its confirmation wait,
        // after acquisition itself activated the shared session.
        session.onSelect = {
            DispatchQueue.main.async { playbackActive = true }
        }

        let result = await monitor.acquireExternalInput(isPlaybackActive: { playbackActive })

        XCTAssertEqual(result, .selectionFailed)
        XCTAssertEqual(session.activateCount, 1, "acquisition activated the shared session before playback started")
        XCTAssertEqual(session.deactivateCount, 0,
                       "playback started during the confirmation wait; failure cleanup must not deactivate its session")
    }

    /// Same window, but the task is cancelled instead of failing.
    @MainActor
    func test_cancelledAcquisition_whenPlaybackStartsDuringConfirmation_doesNotDeactivateSession() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterActivate = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = false
        let monitor = makeMonitor(session)

        var playbackActive = false
        var acquisition: Task<RouteAcquisitionResult, Never>?
        session.onSelect = {
            DispatchQueue.main.async {
                playbackActive = true
                acquisition?.cancel()
            }
        }
        let task = Task { @MainActor in
            await monitor.acquireExternalInput(isPlaybackActive: { playbackActive })
        }
        acquisition = task
        let result = await task.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(session.deactivateCount, 0,
                       "playback started during the confirmation wait; cancellation cleanup must not deactivate its session")
    }

    /// Important: a stop of *active* capture must release the acquired preferred
    /// input, not only a successful acquisition that never reached capture. The
    /// release must still re-check live playback ownership.
    @MainActor
    func test_service_activeStopReleasesAcquiredInputWithoutDeactivatingPlayback() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        // Activation-only discovery forces acquisition to activate the shared
        // session itself, so the release path has a session it may deactivate.
        session.availableAfterActivate = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true

        var playbackActive = false
        let service = VoiceControlAssembly()
            .buildVoiceControlService(audioSession: session, capture: SucceedingCapture(), isPlaybackActive: { playbackActive })!
        service.startIfAllowed()

        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertEqual(service.micExposure, .isolated)
        XCTAssertEqual(session.activateCount, 1, "acquisition activated the shared session")
        XCTAssertEqual(session.clearCount, 0, "capture keeps the acquired input while listening")

        // Playback resumes, then capture stops (user disabled, conflict, privacy).
        playbackActive = true
        service.stop()

        XCTAssertEqual(session.clearCount, 1, "an active stop releases the acquired preferred input")
        XCTAssertEqual(session.deactivateCount, 0,
                       "playback owns the shared session; the active-stop release must not deactivate it")
    }

    /// Control for the test above: with playback still inactive, the active-stop
    /// release does deactivate the session acquisition activated.
    @MainActor
    func test_service_activeStopWithPlaybackInactive_deactivatesAcquiredSession() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterActivate = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true

        let service = VoiceControlAssembly()
            .buildVoiceControlService(audioSession: session, capture: SucceedingCapture(), isPlaybackActive: { false })!
        service.startIfAllowed()

        await waitUntil(timeout: 5) { service.isListening }
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(session.clearCount, 0)

        service.stop()

        XCTAssertEqual(session.clearCount, 1, "an active stop releases the acquired preferred input")
        XCTAssertEqual(session.deactivateCount, 1,
                       "with playback inactive, the session acquisition activated is released")
    }

    // MARK: - Dedup is per physical device, not per route type

    /// Two different devices can present the same port *types* (two Bluetooth
    /// headsets are both `.bluetoothA2DP` output / `.bluetoothHFP` input). A
    /// failed attempt on device A must not suppress the attempt for device B:
    /// the dedup key must include port identity, not only the type enums.
    @MainActor
    func test_failedAcquisition_onDeviceA_doesNotSuppressAttemptForDeviceBWithSameRouteTypes() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-A")]
        session.inputs = [port(.builtInMic, uid: "built-in-A")]
        session.availableAfterConfigure = []  // A exposes no external mic → the attempt fails

        let service = VoiceControlAssembly()
            .buildVoiceControlService(audioSession: session, capture: SucceedingCapture())!
        service.startIfAllowed()

        await waitUntil(timeout: 5) { session.configureCount >= 1 }
        XCTAssertEqual(session.configureCount, 1, "device A gets one acquisition attempt")

        // A re-evaluation for the *same* identity must not retry the failed route.
        postRouteChange()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.configureCount, 1, "a failed route is not retried while it is unchanged")

        // Device B: same route types, different physical device (different UIDs).
        session.outputs = [port(.bluetoothA2DP, uid: "bt-B")]
        session.inputs = [port(.builtInMic, uid: "built-in-B")]
        session.available = []
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "mic-B")]
        session.selectionTakesEffect = true
        postRouteChange()

        await waitUntil(timeout: 5) { session.configureCount >= 2 }
        XCTAssertEqual(session.configureCount, 2,
                       "device B must get its own attempt even though it shares A's route types")
    }

    // MARK: - A capture that fails to start must not report listening

    /// The engine catches capture errors internally and `start()` returns void,
    /// so the service used to set `isListening = true` unconditionally. A failed
    /// start must leave `isListening` false and release the acquired external
    /// route (no microphone retained without capture).
    @MainActor
    func test_captureStartFailure_releasesAcquiredRouteAndIsNotListening() async {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true

        let service = VoiceControlAssembly()
            .buildVoiceControlService(audioSession: session, capture: FailingCapture())!
        service.startIfAllowed()

        // Acquisition succeeds (exposure flips isolated), then capture start fails.
        await waitUntil(timeout: 5) { session.clearCount >= 1 }

        XCTAssertFalse(service.isListening, "a failed capture start must not report listening")
        XCTAssertNotEqual(service.micExposure, .isolated,
                          "the acquired external route is released when capture cannot start")
        XCTAssertGreaterThanOrEqual(session.clearCount, 1,
                                    "the preferred external input is released")
    }

    private func postRouteChange() {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
            ]
        )
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
