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
            service.gracePeriodSignalForTesting.claimEscalationBudget(),
            "the model-call completion must have restored the window's escalation allowance"
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
        service.gracePeriodSignalForTesting.endPlaybackHold(forGeneration: generationAtWake)
        service.gracePeriodSignalForTesting.endPlaybackHold(forGeneration: generationAtWake + 99)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(
            service.gracePeriodSignalForTesting.isActive,
            "stale stop/hold-end events must not reopen or extend another window"
        )
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
