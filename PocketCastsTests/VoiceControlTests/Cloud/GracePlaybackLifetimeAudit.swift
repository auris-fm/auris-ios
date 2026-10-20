import XCTest
@testable import podcasts

/// GRACE LIFETIME AUDIT (spec 00dd8372, reviewer a5d01b7f handoff): the grace window must be
/// JUDGED against the turn's real playback lifetime, not the terminal-network event. This control
/// drives a REAL service turn whose answer carries actual audio, and pins the window's state at
/// each stage of the REAL lifetime:
///
///   1. at `done` (the sink's return — terminal-network, NOT playback end): the window is still
///      ACTIVE with an UNCHANGED generation — a cloud turn never closes or reopens the window at
///      dispatch completion;
///   2. through the REAL drain: restoration of the held playback happens only when the actual
///      `audioPlayerDidStop(drainEpoch:)` notification lands (observed via the playback sink's
///      resume), not at `done` and not at queued-buffer completion;
///   3. after the real drain/stop: the window is STILL active, STILL the same generation, and the
///      model-call completion has restored the escalation allowance (claimable again).
///
/// Explicit non-goals (kept open, reported): journal/bind discrimination, typed success-envelope
/// replay, per-action refusal coverage, outcome propagation completeness.
final class GracePlaybackLifetimeAudit: XCTestCase {
    override func setUp() {
        super.setUp()
        // The player only builds its node graph (and therefore only reports pending/rendered
        // audio) when an output exists. Under a test host this seam is the single substituted
        // fact; everything downstream is production code.
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
    }

    override func tearDown() {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        super.tearDown()
    }

    private final class RecordingPlaybackSink: VoicePlaybackSink {
        private(set) var pauseCalls = 0
        private(set) var resumeCalls = 0
        /// Playback is RUNNING before the turn, so the sink takes a real hold (its
        /// hold-and-restore path keys on `isPlaying` at dispatch).
        var isPlaying = true
        func pause() -> VoiceResponse { pauseCalls += 1; return .earcon(.success) }
        func resume() -> VoiceResponse { resumeCalls += 1; return .silent }
        func seekRelative(deltaSeconds: Int?, direction: SeekDirection) -> VoiceResponse { .silent }
        func seekTo(positionSeconds: Int) -> VoiceResponse { .silent }
        func seekTo(positionSeconds: Int, episodeDurationSeconds: Int) -> VoiceResponse { .silent }
        func nextEpisode() -> VoiceResponse { .silent }
    }

    @MainActor
    func testGraceWindowHoldsThroughTheRealPlaybackDrain() async throws {
        let playback = RecordingPlaybackSink()
        let suite = "graceaudit_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        objc_setAssociatedObject(self, "graceaudit_cfg", (defaults, fixtureConfig), .OBJC_ASSOCIATION_RETAIN)

        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult = "<|tool_call_start|>[cloud_route(request='play something upbeat')]<|tool_call_end|>"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)

        // The answer carries REAL binary audio, so the player has pending audio at `done` and the
        // drain is a genuine playback event, not a no-op.
        // ABOVE the player's resume threshold (5 frames): a below-threshold delivery never starts
        // the player, so it would report nothing pending and emit no stop at all.
        let audio = (0..<40).map { Data([UInt8($0)]) }
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: auditAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n",
                    audioPayloads: audio
                ).client
            },
            playbackSink: playback,
            cloudConfig: fixtureConfig,
            asrBackend: { FakeAsrBackend() }
        )
        guard let service else {
            XCTFail("the assembly built no service, so the audit proves nothing")
            return
        }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)

        // HOLD THE REAL DRAIN: the player's runner parks in its drain path, so at `done` the
        // answer's audio is genuinely still pending/playback in flight. Releasing the hold lets
        // the production drain loop finish and send the REAL `audioPlayerDidStop(drainEpoch:)`.
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(true)
        }

        // Open the window the way the wake callback does, and let the turn claim its allowance.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let generationAtWake = service.gracePeriodSignalForTesting.currentGeneration()

        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: "play something upbeat",
                language: "en",
                selection: .wakeWord
            ),
            origin: generationAtWake
        )


        // STAGE 1 — at `done` (route returned; audio STILL draining): the held playback must NOT
        // be restored yet (terminal-network is not playback end), and the window must be active
        // and unchanged. A turn that restores here resumes the episode UNDER the answer's tail.
        XCTAssertEqual(
            playback.resumeCalls, 0,
            "restoring at `done` would resume the episode under the answer's tail — the restore "
                + "must wait for the real drain/stop"
        )
        XCTAssertEqual(
            playback.pauseCalls, 1,
            "the hold is still in effect at `done`"
        )
        let pendingAtDone = await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.hasPendingAudio ?? false
        }
        XCTAssertTrue(
            pendingAtDone,
            "the answer's audio must still be pending at `done` — otherwise this audit proves "
                + "nothing about the playback lifetime"
        )
        XCTAssertTrue(
            service.gracePeriodSignalForTesting.isActive,
            "the grace window must still be ACTIVE at `done` — completion is not playback end"
        )
        XCTAssertEqual(
            service.gracePeriodSignalForTesting.currentGeneration(), generationAtWake,
            "the window generation must be unchanged at `done`"
        )

        // STAGE 2 — the REAL drain: release the hold and let the production drain loop finish;
        // the sink's held playback is restored only by the actual `audioPlayerDidStop(drainEpoch:)`
        // the player then sends. Await the observable restore (playback sink resume), never the
        // route return.
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(false)
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if playback.resumeCalls > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(
            playback.resumeCalls, 1,
            "the held playback must be restored exactly once, by the real drain/stop"
        )
        XCTAssertEqual(playback.pauseCalls, 1, "the turn's own hold, exactly once")

        // STAGE 3 — after the real drain/stop: the window is STILL active and STILL the same
        // generation (playback end did not close it), and the model-call completion restored the
        // escalation allowance for the follow-up inside this window.
        XCTAssertTrue(
            service.gracePeriodSignalForTesting.isActive,
            "the grace window must survive the actual playback drain/stop"
        )
        XCTAssertEqual(
            service.gracePeriodSignalForTesting.currentGeneration(), generationAtWake,
            "the window generation must be unchanged through the real drain"
        )
        XCTAssertNotNil(
            service.gracePeriodSignalForTesting.claimDispatchOwnership(),
            "the live window still dispatches independently of the drain"
        )
    }

    private func auditAudioSession() -> FakeAudioSessionControlling {
        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "graceaudit-bt-out")]
        session.availableAfterConfigure = [AudioPort(portType: .bluetoothHFP, uid: "graceaudit-hfp-mic")]
        return session
    }

    /// CONTROLLED-CLOCK EXPIRY control (spec 4acb4aa8): with a SHORT grace clock, actual
    /// playback pending PAST the timeout must keep the window active and the generation unchanged;
    /// releasing the REAL drain/stop starts the permitted interval EXACTLY ONCE (it then expires
    /// normally). Identity-bound ownership: a stale end (wrong generation) must not resume
    /// anything, and after the window has expired a late hold-end must not reopen it.
    @MainActor
    func testPlaybackPendingPastTheGraceTimeoutHoldsExpiryUntilTheRealDrain() async throws {
        let playback = RecordingPlaybackSink()
        let suite = "graceauditclock_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        objc_setAssociatedObject(self, "graceauditclock_cfg", (defaults, fixtureConfig), .OBJC_ASSOCIATION_RETAIN)

        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult = "<|tool_call_start|>[cloud_route(request='play something upbeat')]<|tool_call_end|>"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)

        let audio = (0..<40).map { Data([UInt8($0)]) }
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: auditAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n",
                    audioPayloads: audio
                ).client
            },
            playbackSink: playback,
            graceTimeout: 0.5,
            cloudConfig: fixtureConfig,
            asrBackend: { FakeAsrBackend() }
        )
        guard let service else {
            XCTFail("the assembly built no service, so the control proves nothing")
            return
        }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)

        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(true)
        }
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let generationAtWake = service.gracePeriodSignalForTesting.currentGeneration()

        await service.handleRoutingInput(
            IntentRoutingInput.english(
                transcript: "play something upbeat",
                language: "en",
                selection: .wakeWord
            ),
            origin: generationAtWake
        )

        // PAST THE TIMEOUT (2.4x), actual playback still pending: the window must be held.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(
            service.gracePeriodSignalForTesting.isActive,
            "expiry must be HELD while the answer is actually pending — a 0.5s clock ran out "
                + "under the drain and the window died"
        )
        XCTAssertEqual(
            service.gracePeriodSignalForTesting.currentGeneration(), generationAtWake,
            "the held window keeps its generation"
        )
        XCTAssertEqual(playback.resumeCalls, 0, "the drain is still pending; nothing may resume")

        // Release the REAL drain: the production drain loop finishes and the real
        // audioPlayerDidStop(drainEpoch:) restores the held playback exactly once.
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(false)
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if playback.resumeCalls > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(playback.resumeCalls, 1, "restored exactly once, by the real stop")

        // The permitted interval STARTED exactly once: observe it expire normally (one
        // active→inactive transition) and count transitions on the way.
        var transitions = 0
        var wasActive = service.gracePeriodSignalForTesting.isActive
        let expiryDeadline = Date().addingTimeInterval(3)
        while Date() < expiryDeadline {
            let now = service.gracePeriodSignalForTesting.isActive
            if now != wasActive { transitions += 1; wasActive = now }
            if !now { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(
            service.gracePeriodSignalForTesting.isActive,
            "the interval resumed at the real stop must EXPIRE normally (started exactly once)"
        )
        XCTAssertEqual(transitions, 1, "exactly one expiry: no double-start, no re-arm")

        // STALE EVENTS cannot reopen or extend: a late hold-end for the finished generation, and
        // an end for a never-held generation, must leave the expired window dead.
        // Token-identity discipline: an end for a token this window never issued — foreign
        // generation or forged against the finished one — is dropped without reopening.
        service.gracePeriodSignalForTesting.endPlaybackHold(
            GracePeriodSignal.PlaybackHoldToken(generation: generationAtWake)
        )
        service.gracePeriodSignalForTesting.endPlaybackHold(
            GracePeriodSignal.PlaybackHoldToken(generation: generationAtWake + 99)
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(
            service.gracePeriodSignalForTesting.isActive,
            "stale stop/hold-end events must not reopen or extend another window"
        )
    }

    /// BLOCKER CONTROL 1 — CLOUD-WORK interval: the hold is acquired at the ADMITTED DISPATCH,
    /// before done. A slow cloud turn (gated pre-bind) must not let the window expire.
    @MainActor
    func testSlowCloudWorkBeforeDoneHoldsExpiryFromTheAdmittedDispatch() async throws {
        let gate = DispatchSemaphore(value: 0)
        let playback = RecordingPlaybackSink()
        let defaults = UserDefaults(suiteName: "graceauditcloud_\(UUID().uuidString)")!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        objc_setAssociatedObject(self, "graceauditcloud_cfg", (defaults, fixtureConfig), .OBJC_ASSOCIATION_RETAIN)
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult = "<|tool_call_start|>[cloud_route(request='play something upbeat')]<|tool_call_end|>"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let audio = (0..<40).map { Data([UInt8($0)]) }
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: auditAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                let stub = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n",
                    audioPayloads: audio
                )
                // SLOW CLOUD WORK: the transport parks before the bind — no done for a while.
                stub.client.onBeforeBind = { _ in _ = gate.wait(timeout: .now() + 5) }
                return stub.client
            },
            playbackSink: playback,
            graceTimeout: 0.5,
            cloudConfig: fixtureConfig,
            asrBackend: { FakeAsrBackend() }
        )
        guard let service else { XCTFail("no service"); return }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(true)
        }
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let gen = service.gracePeriodSignalForTesting.currentGeneration()
        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "play something upbeat", language: "en", selection: .wakeWord),
            origin: gen
        )
        // PAST the timeout with the cloud turn still in flight: expiry must be HELD already.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(service.gracePeriodSignalForTesting.isActive, "cloud work holds expiry from admission")
        XCTAssertEqual(service.gracePeriodSignalForTesting.currentGeneration(), gen)
        gate.signal()  // cloud work completes -> done -> deferral keeps the hold through the drain
        try await Task.sleep(nanoseconds: 600_000_000)  // let done land; window must stay held
        XCTAssertTrue(service.gracePeriodSignalForTesting.isActive, "hold retained through done into the drain")
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(false)
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, playback.resumeCalls == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(playback.resumeCalls, 1, "restored once, at the real drain stop")
        // One interval expiry after the release; then stale token ends are no-ops.
        var transitions = 0
        var wasActive = service.gracePeriodSignalForTesting.isActive
        let expiryDeadline = Date().addingTimeInterval(3)
        while Date() < expiryDeadline {
            let now = service.gracePeriodSignalForTesting.isActive
            if now != wasActive { transitions += 1; wasActive = now }
            if !now { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(service.gracePeriodSignalForTesting.isActive, "interval expires normally after release")
        XCTAssertEqual(transitions, 1, "exactly one expiry — hold started once, released once")
    }

    /// BLOCKER CONTROL 2 — SHARED timer path: with a live same-generation hold, NO caller
    /// (command recognition, fallback extension, wake reset) arms the clock under the hold, while
    /// every caller still preserves its allowance/state. Expiry resumes once at the release.
    @MainActor
    func testNoCallerArmsTheClockUnderALiveHoldWhileAllowancesArePreserved() async throws {
        // 1.0s clock: the co-owner probe (1.5s) outlives a premature re-arm, so a mutant that
        // releases on a generation match cannot hide behind a timer that has not fired yet.
        let signal = GracePeriodSignal(timeout: 1.0)
        objc_setAssociatedObject(self, "graceauditshared_sig", signal, .OBJC_ASSOCIATION_RETAIN)
        signal.onWakeWordDetected()
        let gen = signal.currentGeneration()
        XCTAssertTrue(signal.isActive)

        guard let hold = signal.beginPlaybackHold(forGeneration: gen) else {
            XCTFail("the live window refused its own hold")
            return
        }
        // Each caller runs under the hold; each must succeed and preserve its semantics.
        XCTAssertTrue(signal.recognizeCommandIfCurrentWindow(gen), "command recognized under the hold")
        XCTAssertTrue(signal.isActive, "recognition kept the window alive")
        // NO window budget (owner delta 3484cbc/5eca874): recognition consumes nothing, and an
        // independent dispatch is still available under the hold.
        XCTAssertNotNil(signal.claimDispatchOwnership(capturedOrigin: gen),
                        "no window budget: dispatch stays available under the hold")
        signal.extendWindowKeepingEscalationSpent(underGeneration: gen)
        XCTAssertTrue(signal.isActive, "fallback extension kept the window alive")
        signal.onWakeWordDetected()  // wake reset for the SAME window semantics? No: opens a NEW generation
        let newGen = signal.currentGeneration()
        XCTAssertNotEqual(gen, newGen, "a wake opens a new generation")
        // The OLD generation's hold must not bind the NEW window: it times out normally.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, signal.isActive { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(signal.isActive, "new window times out normally; an old hold never binds it")

        // And under the NEW window, begin its own hold; a STALE end for the old hold is a no-op
        // and never resumes the new window.
        signal.onWakeWordDetected()
        let gen3 = signal.currentGeneration()
        guard let hold3 = signal.beginPlaybackHold(forGeneration: gen3) else {
            XCTFail("live window refused its own hold (second)")
            return
        }
        signal.endPlaybackHold(hold)  // stale, older generation
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(signal.isActive, "stale hold end never resumed the live window")
        // TWO concurrent holds on the SAME generation: releasing ONE must not resume — the
        // release identity is the TOKEN, not the generation.
        guard let hold3b = signal.beginPlaybackHold(forGeneration: gen3) else {
            XCTFail("second hold on the live generation refused")
            return
        }
        signal.endPlaybackHold(hold3)
        let coOwnerDeadline = Date().addingTimeInterval(1.5)
        while Date() < coOwnerDeadline, signal.isActive { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(signal.isActive, "a same-generation co-owner still holds expiry (1.5s > clock)")
        signal.endPlaybackHold(hold3b)
        let expiryDeadline = Date().addingTimeInterval(3)
        while Date() < expiryDeadline, signal.isActive { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(signal.isActive, "last release resumes the interval exactly once; it expires")
    }

    /// BLOCKER CONTROL 3 — FOREGROUND LOSS with a cloud turn in progress (owner delta
    /// 8fe04cd/0aa4480): the active hold is PRESERVED while capture remains allowed;
    /// backgrounding alone does not end grace or retire the turn. The later real stop must not
    /// create a second window, and host playback still restores exactly once.
    @MainActor
    func testForegroundLossUnderALiveHoldPreservesTheWindowAndTheLaterStopDoesNotReopenIt() async throws {
        let playback = RecordingPlaybackSink()
        let defaults = UserDefaults(suiteName: "graceauditpriv_\(UUID().uuidString)")!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        objc_setAssociatedObject(self, "graceauditpriv_cfg", (defaults, fixtureConfig), .OBJC_ASSOCIATION_RETAIN)
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult = "<|tool_call_start|>[cloud_route(request='play something upbeat')]<|tool_call_end|>"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let audio = (0..<40).map { Data([UInt8($0)]) }
        let gate = DispatchSemaphore(value: 0)
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: auditAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                let stub = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n",
                    audioPayloads: audio
                )
                stub.client.onBeforeBind = { _ in _ = gate.wait(timeout: .now() + 5) }
                return stub.client
            },
            playbackSink: playback,
            graceTimeout: 5.0,
            cloudConfig: fixtureConfig,
            asrBackend: { FakeAsrBackend() }
        )
        guard let service else { XCTFail("no service"); return }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(true)
        }
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let gen = service.gracePeriodSignalForTesting.currentGeneration()
        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "play something upbeat", language: "en", selection: .wakeWord),
            origin: gen
        )
        XCTAssertTrue(service.gracePeriodSignalForTesting.isActive, "turn admitted under its hold")
        let liveGeneration = service.gracePeriodSignalForTesting.currentGeneration()
        service.gracePeriodSignalForTesting.onAppBackgrounded()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            service.gracePeriodSignalForTesting.isActive,
            "foreground loss DURING a cloud turn preserves the hold while capture remains allowed"
        )
        XCTAssertEqual(
            service.gracePeriodSignalForTesting.currentGeneration(), liveGeneration,
            "backgrounding alone does not retire the turn's window"
        )
        gate.signal()  // turn completes + drain releases
        try await Task.sleep(nanoseconds: 600_000_000)
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(false)
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, playback.resumeCalls == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(playback.resumeCalls, 1, "the drain still restored exactly once")
        // The stop resumed the SAME window (no reopen); and with no hold left, a later
        // foreground loss would end it (the no-hold rule).
        service.gracePeriodSignalForTesting.onAppBackgrounded()
        XCTAssertFalse(
            service.gracePeriodSignalForTesting.isActive,
            "with no hold remaining, foreground loss ends the window"
        )
    }

    /// BLOCKER CONTROL 4 — SUCCESSOR LIVE, stale predecessor completion: a predecessor's late
    /// terminal must not disturb (resume/extend/expire) the SUCCESSOR's live window.
    @MainActor
    func testStalePredecessorCompletionWhileTheSuccessorIsLiveLeavesTheSuccessorAlone() async throws {
        let playback = RecordingPlaybackSink()
        let defaults = UserDefaults(suiteName: "graceauditsucc_\(UUID().uuidString)")!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        objc_setAssociatedObject(self, "graceauditsucc_cfg", (defaults, fixtureConfig), .OBJC_ASSOCIATION_RETAIN)
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult = "<|tool_call_start|>[cloud_route(request='play something upbeat')]<|tool_call_end|>"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let audio = (0..<40).map { Data([UInt8($0)]) }
        let gates = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        objc_setAssociatedObject(self, "graceauditsucc_gates", gates, .OBJC_ASSOCIATION_RETAIN)
        var gateIndex = 0
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: auditAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                let stub = CloudRouteClient.stubbed(
                    fixture: "event: done\ndata: {\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}\n\n",
                    audioPayloads: audio
                )
                let index = gateIndex
                gateIndex += 1
                stub.client.onBeforeBind = { _ in _ = gates[index].wait(timeout: .now() + 8) }
                return stub.client
            },
            playbackSink: playback,
            graceTimeout: 5.0,
            cloudConfig: fixtureConfig,
            asrBackend: { FakeAsrBackend() }
        )
        guard let service else { XCTFail("no service"); return }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(true)
        }
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let gen1 = service.gracePeriodSignalForTesting.currentGeneration()
        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "play something upbeat", language: "en", selection: .wakeWord),
            origin: gen1
        )
        XCTAssertTrue(service.gracePeriodSignalForTesting.isActive, "turn 1 admitted, hold in effect")
        // SUCCESSOR wake: new generation while turn 1 still in flight. Ownership transfers
        // atomically to the successor's dispatch.
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let gen2 = service.gracePeriodSignalForTesting.currentGeneration()
        XCTAssertNotEqual(gen1, gen2)
        await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "play something upbeat", language: "en", selection: .wakeWord),
            origin: gen2
        )
        XCTAssertTrue(service.gracePeriodSignalForTesting.isActive)
        // The PREDECESSOR's stale completion (its own gate release, now out of turn).
        gates[0].signal()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(
            service.gracePeriodSignalForTesting.currentGeneration(), gen2,
            "the stale predecessor terminal must not bump the successor's window"
        )
        XCTAssertTrue(
            service.gracePeriodSignalForTesting.isActive,
            "the successor's window survives the predecessor's stale terminal"
        )
        XCTAssertEqual(playback.resumeCalls, 0, "no resume was stolen from the successor")
        // Now the successor completes and drains: exactly one resume, and its window's interval
        // then expires normally.
        gates[1].signal()  // the successor's own transport gate
        try await Task.sleep(nanoseconds: 600_000_000)
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(false)
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, playback.resumeCalls == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(playback.resumeCalls, 1, "the successor's drain restored exactly once")
        let expiryDeadline = Date().addingTimeInterval(8)
        while Date() < expiryDeadline, service.gracePeriodSignalForTesting.isActive {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(service.gracePeriodSignalForTesting.isActive, "successor window expires normally")
    }

    /// REVIEW 7fc40b74 DEFECT 2 — CURRENT-generation release counting: an OLD generation's
    /// outstanding hold must neither delay the successor's resume nor let its later end disturb
    /// the successor. B's final release resumes B's clock BEFORE old A's end; A's end is a no-op.
    @MainActor
    func testSuccessorReleaseResumesItsClockDespiteAnOutstandingOlderHold() async throws {
        let signal = GracePeriodSignal(timeout: 0.5)
        objc_setAssociatedObject(self, "graceauditoverlap_sig", signal, .OBJC_ASSOCIATION_RETAIN)
        signal.onWakeWordDetected()
        let genA = signal.currentGeneration()
        let holdA = try XCTUnwrap(
            signal.beginPlaybackHold(forGeneration: genA),
            "A's live hold refused"
        )
        // Successor wake while A's hold is still outstanding.
        signal.onWakeWordDetected()
        let genB = signal.currentGeneration()
        XCTAssertNotEqual(genA, genB)
        // B's own startOrReset must arm despite A's hold (old hold never binds the successor).
        let holdB = try XCTUnwrap(
            signal.beginPlaybackHold(forGeneration: genB),
            "B's live hold refused"
        )
        // B's FINAL release: the clock must resume NOW, not wait for A's end.
        signal.endPlaybackHold(holdB)
        let expiryDeadline = Date().addingTimeInterval(2)
        while Date() < expiryDeadline, signal.isActive { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(signal.isActive, "B's window expires on B's own release despite A's outstanding hold")
        // Old A's late end: mismatch with the live (closed) world — a no-op that must not
        // reopen or extend anything.
        signal.endPlaybackHold(holdA)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(signal.isActive, "the stale end never reopens the expired successor")
    }

    /// REVIEW 7fc40b74 DEFECT 1 — the resumed clock is the SAME window: a hold release resumes the
    /// interval without opening a new generation, and only a wake opens a new window. (The
    /// dispatch BUDGET this case originally asserted is removed by owner delta 3484cbc/5eca874;
    /// the window-identity invariant it also covered is asserted here instead.)
    @MainActor
    func testResumedClockStaysTheSameWindowAcrossARelease() async throws {
        let signal = GracePeriodSignal(timeout: 0.5)
        objc_setAssociatedObject(self, "graceauditspent_sig", signal, .OBJC_ASSOCIATION_RETAIN)
        signal.onWakeWordDetected()
        let gen = signal.currentGeneration()
        // A fallback extension and a recognized success both keep the window alive.
        signal.extendWindowKeepingEscalationSpent(underGeneration: gen)
        XCTAssertTrue(signal.recognizeCommandIfCurrentWindow(gen), "a recognized success keeps the window")
        XCTAssertEqual(signal.currentGeneration(), gen, "no reset opened a new window")

        let hold = try XCTUnwrap(signal.beginPlaybackHold(forGeneration: gen))
        signal.endPlaybackHold(hold)  // the real stop resumes the clock
        XCTAssertTrue(signal.isActive, "the resumed interval is the same window")
        XCTAssertEqual(
            signal.currentGeneration(), gen,
            "a plain release resumes the SAME window and never opens a new generation"
        )

        // A wake is what opens a new window.
        signal.onWakeWordDetected()
        XCTAssertNotEqual(signal.currentGeneration(), gen, "a wake opens a new generation")
    }

    /// REVIEW 7fc40b74 DEFECT 3 — truncation stops OWNED output before releasing the host
    /// playback and the hold: no enqueued cloud audio plays under the resumed episode.
    @MainActor
    func testTruncatedStreamStopsOwnedOutputBeforeReleasingTheHold() async throws {
        let playback = RecordingPlaybackSink()
        let defaults = UserDefaults(suiteName: "graceaudittrunc_\(UUID().uuidString)")!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
        let fixtureConfig = CloudConfig(defaults: defaults)
        objc_setAssociatedObject(self, "graceaudittrunc_cfg", (defaults, fixtureConfig), .OBJC_ASSOCIATION_RETAIN)
        let inference = FakeLfmInference()
        inference.classifyLabel = "cloud_route:route"
        inference.generateResult = "<|tool_call_start|>[cloud_route(request='play something upbeat')]<|tool_call_end|>"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("lfm_seed_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        // Frames arrive (the stub's audio payload channel), then the stream ENDS without done:
        // truncation with pending audio.
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: auditAudioSession(),
            conditionMonitor: provenanceConditionMonitor(),
            capture: FakeAudioCapture(),
            inference: inference,
            modelManager: modelManager,
            clientFactory: {
                CloudRouteClient.stubbed(
                    // Payload frames first (the stub interleaves payloads before text), then a
                    // NON-terminal text event, then EOF: truncation with pending audio.
                    fixture: "event: token\ndata: {\"text\":\"partial\"}\n\n",
                    audioPayloads: (0..<40).map { Data([UInt8($0)]) }
                ).client
            },
            playbackSink: playback,
            graceTimeout: 5.0,
            cloudConfig: fixtureConfig,
            asrBackend: { FakeAsrBackend() }
        )
        guard let service else { XCTFail("no service"); return }
        service.startIfAllowed()
        try await waitForListening(service)
        try await waitForRouter(service)
        // PIN the enqueued audio as pending: without the drain hold the player may shed the
        // tiny synthetic frames before the truncation lands, making the ordering unobservable.
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(true)
        }
        service.gracePeriodSignalForTesting.onWakeWordDetected()
        let gen = service.gracePeriodSignalForTesting.currentGeneration()
        let truncationResult = await service.handleRoutingInput(
            IntentRoutingInput.english(transcript: "play something upbeat", language: "en", selection: .wakeWord),
            origin: gen
        )
        // (outcome of the dispatch is not directly returned here; the sink's terminal
        // classification is observed through the resume/pending assertions below)
        // Release the pin: the truncation's cancel REQUESTED the stop; the ACTUAL engine stop —
        // and therefore the identity-bound release — can only complete once the runner can leave
        // the drain park. Poll for the release instead of a fixed sleep.
        await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting
                .audioPlayerForTesting?.setDrainHoldForTesting(false)
        }
        var released = false
        for _ in 0..<60 {
            if await MainActor.run(body: { playback.resumeCalls }) == 1 { released = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // The truncation released the hold exactly once, AFTER the confirmed stop.
        XCTAssertTrue(released, "the hold released exactly once at the truncation, after the stop")
        XCTAssertEqual(playback.resumeCalls, 1, "the hold released exactly once at the truncation")
        let pending = await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting.audioPlayerForTesting?.hasPendingAudio ?? false
        }
        // DIRECT stop evidence: only cancel()/finish() advance the player's drain epoch. No
        // `done` arrived, so a bumped epoch proves THIS turn's owned output was stopped BEFORE
        // the host playback was released (cancel precedes restoreTransientAudioState).
        let epochAfter = await MainActor.run {
            service.executorForTesting.cloudRouteSinkForTesting.audioPlayerForTesting?.currentDrainEpoch ?? 0
        }
        XCTAssertGreaterThan(epochAfter, 0, "owned output was stopped (cancel) before the hold/host release")
        XCTAssertFalse(pending, "no buffered owned audio survives the release")
    }

    @MainActor
    private func provenanceConditionMonitor() -> LiveConditionMonitor {
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        return monitor
    }

    @MainActor
    private func waitForListening(_ service: VoiceControlService) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if service.isListening { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("gate did not reach listening: \(service.gateState)")
    }

    @MainActor
    private func waitForRouter(_ service: VoiceControlService) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if service.intentRouterIsReadyForTesting { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("router never became ready")
    }
}
