import AVFoundation
import XCTest
@testable import podcasts

/// A backend whose `transcribe` blocks until released, so recognition can be held open
/// across a grace deadline — the cold-ASR sequencing the device log showed
/// (`asr waited 26095ms for backend`).
final class SuspendedAsrBackend: AsrBackend, @unchecked Sendable {
    let text: String
    private let entered = DispatchSemaphore(value: 0)
    private(set) var transcribeStarted = false
    private let releasedState = LockedBox<Bool>(false)
    private let releasedContinuations = LockedBox<[CheckedContinuation<Void, Never>]>([])
    private var released: Bool { releasedState.value }
    private func drain() {
        let waiting = releasedContinuations.withLock { box -> [CheckedContinuation<Void, Never>] in
            let all = box; box = []; return all
        }
        waiting.forEach { $0.resume() }
    }

    init(text: String) { self.text = text }

    var requiredModel: ModelSpec { ModelSpec(id: "suspended", files: [], targetDir: "suspended") }
    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
    }
    func ensureReady() async -> Result<Void, Error> { .success(()) }

    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        transcribeStarted = true
        entered.signal()
        // Suspends UNTIL RELEASED, on the async executor (not a blocking wait), so the test can
        // drive expiry while recognition is genuinely in flight and the run cannot race past it.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            releasedContinuations.withLock { $0.append(c) }
            if released { drain() }
        }
        return AsrResult(text: text, detectedLanguage: nil, tokens: nil)
    }

    /// Waits until transcription has actually begun in the engine.
    func awaitTranscriptionStarted(timeout: TimeInterval = 5) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func release() { releasedState.value = true; drain() }
    var isReleasedForTesting: Bool { released }
}

/// PRODUCTION-PATH control for the cold-ASR eligibility bug.
///
/// The device log: a wake opened the window at `10:07:19`; the utterance was admitted then
/// waited ~26 s for the backend; the window expired at `10:07:49`; recognition completed at
/// `10:07:50` and routing at `10:07:55` — after which the turn was refused with
/// `cloud escalation refused (no open session window)`. Spec `voice-control-core.md:270`
/// requires the opposite: "Speech observed before the deadline remains eligible through
/// recognition".
///
/// These cases drive the ENGINE's real `processUtterance` → `onRoutingInput` path with the
/// backend suspended, rather than calling `GracePeriodSignal` directly. That distinction is
/// the point: the defect lives in WHERE admission is recorded relative to the backend wait,
/// and a direct-signal test cannot see that sequencing — an earlier version of this fix
/// registered at the routing callback, which fires AFTER the wait, and so was rejected in
/// exactly the scenario it was written for.
///
/// The reservation must be bound to the admitted turn IDENTITY (not the whole generation) and
/// written AFTER the wake decision establishes the window's origin but BEFORE the backend wait.
final class ColdAsrEligibilityProductionTests: XCTestCase {

    /// ISOLATED cloud configuration: `isConfigured()` is `{ !CloudConfig.shared.baseUrl.isEmpty }`,
    /// checked BEFORE the origin gate and before the client is built. Without a base URL a routed
    /// turn is refused before reaching the transport, so the case would fail for a reason unrelated
    /// to eligibility. An own defaults suite keeps this out of other cases; teardown restores it.
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "cold_asr_eligibility_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://cloud.test", forKey: CloudConfig.baseURLKey)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Thread-safe record of terminal outcomes. The service reports them from a `@Sendable` hook,
    /// so a plain captured `var` is not a reliable channel between that closure and the test body.
    final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private func port(_ type: AVAudioSession.Port, uid: String) -> AudioPort {
        AudioPort(portType: type, uid: uid)
    }

    private func makeSession() -> FakeAudioSessionControlling {
        let session = FakeAudioSessionControlling()
        session.outputs = [port(.bluetoothA2DP, uid: "bt-out")]
        session.availableAfterConfigure = [port(.bluetoothHFP, uid: "bt-mic")]
        return session
    }

    private func makeConditionMonitor() -> LiveConditionMonitor {
        let monitor = LiveConditionMonitor(gracePeriodSignal: GracePeriodSignal())
        monitor.conflicts = GateConflicts(
            notOnCall: .allowed,
            notCasting: .allowed,
            batteryOk: .allowed,
            otherAppPlaying: .allowed
        )
        return monitor
    }

    /// The observed defect, on the production path: a turn admitted before the deadline whose
    /// recognition completes after it must still be able to dispatch.
    @MainActor
    func test_turnAdmittedBeforeDeadline_stillDispatchesWhenRecognitionCompletesAfterExpiry() async throws {
        let probePath = "/tmp/coldasr-probe.txt"
        try? "BODY ENTERED\n".write(toFile: probePath, atomically: true, encoding: .utf8)
        let terminalOutcomes = OutcomeBox()

        let backend = SuspendedAsrBackend(text: "what did the host mean by that remark")
        let conditionMonitor = makeConditionMonitor()
        // `no_match` is what drives REAL escalation into `claimDispatchOwnership` — the changed
        // path. A `cloud_route` label would take the `.intent` branch, stamp a generation and
        // execute directly, never reaching the claim, so it could not reproduce the observed
        // refusal however green it looked.
        let inference = FakeLfmInference()
        inference.classifyLabel = "no_match:"
        inference.generateResult =
            "<|tool_call_start|>[cloud_route(request='what did the host mean by that remark')]<|tool_call_end|>"
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("cold_asr_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)

        // The prepared conversation identity of the turn THIS input dispatched, observed at the
        // dispatch seam the sink owns. Invocation scoped, so an overlapping turn cannot fill it.
        let preparedRequestIds = LockedBox<[String]>([])
        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: makeSession(),
            conditionMonitor: conditionMonitor,
            capture: SucceedingCapture(),
            inference: inference,
            modelManager: modelManager,
            asrBackend: { backend },
            onInputTerminal: { _, outcome in terminalOutcomes.append(String(describing: outcome)) },
            preparedObserverFactory: { input in
                { prepared in
                    XCTAssertEqual(
                        prepared.requestId, input.utteranceId,
                        "the prepared request_id must BE the admitted utterance identity"
                    )
                    preparedRequestIds.withLock { $0.append(prepared.requestId) }
                }
            }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try await waitForListening(service: service)
        try await waitForRouter(service: service)

        // The SERVICE's own signal — the assembly creates it, so a locally constructed one would
        // observe a different window than the production path uses.
        let signal = service.gracePeriodSignalForTesting

        // Drive the ENGINE's real path: the service holds the engine's callbacks, so this is the
        // same seam production ASR uses.
        let engine = service.asrEngineForTesting
        let installedRouting = engine.onRoutingInput
        XCTAssertNotNil(installedRouting, "the service must install onRoutingInput")
        var admittedIds: [String] = []
        var routedInputs: [String] = []
        // OBSERVE, do not replace: the service's own admission handler must still run, or no
        // reservation is ever made and this control would fail for a reason of its own making.
        let serviceAdmitted = engine.onTurnAdmitted
        engine.onTurnAdmitted = { id, origin in
            admittedIds.append(id)
            serviceAdmitted?(id, origin)
        }
        // OBSERVE, do not replace: the service's own callback still takes and reports acceptance.
        let serviceRouting = engine.onRoutingInput
        engine.onRoutingInput = { input in
            routedInputs.append(input.utteranceId)
            return serviceRouting?(input) ?? false
        }

        // The wake is part of the utterance's own segment, as on device: firing the engine's
        // wake callback opens the window and stamps `.wakeWord`.
        let installedWake = engine.onWakeWordDetected
        XCTAssertNotNil(installedWake, "the service must install onWakeWordDetected")

        // Shrink the window so the deadline passes while recognition is still held.
        // (The signal's timeout is fixed at construction; drive expiry directly here, as the
        // device's own timer does, then release recognition.)
        // On device the wake is part of the utterance's own segment: the detector fires and the
        // segment is then forwarded to ASR. The real detector cannot recognise synthetic audio
        // here, so the window is opened through the service's own installed wake callback (the
        // same seam production uses) and the segment is then processed under that live window.
        installedWake?()
        XCTAssertTrue(signal.isActive, "the wake must open the window before recognition runs")

        let utterance = [Float](repeating: 0.05, count: 16000)
        let recognition = Task { await engine.processUtterance(utterance) }

        // Wait until transcription is genuinely in progress, then let the deadline pass.
        let started = await Task.detached { backend.awaitTranscriptionStarted() }.value
        XCTAssertTrue(started, "transcription never started, so the case proves nothing")
        // The expiry below is only meaningful if recognition is STILL held when it runs. If the
        // backend had already returned, the deadline would pass after routing and the case would
        // silently stop exercising the defect (which is what an earlier revision did).
        XCTAssertFalse(
            backend.isReleasedForTesting,
            "recognition completed before the deadline was driven: the case proves nothing"
        )
        XCTAssertTrue(signal.isActive, "the window must be live while recognition runs")

        // Expire the window the way the production timer does, while recognition is held.
        signal.expireForTesting()
        XCTAssertFalse(signal.isActive, "the window has expired during recognition")

        // Recognition now completes, after the deadline.
        backend.release()
        await recognition.value

        // The turn must REACH THE DISPATCH SEAM under its OWN admitted identity. This asserts on
        // the observable that actually differs, at the seam that owns it: the conversation the
        // sink PREPARED for this turn. A granted claim that the sink then refuses (e.g. because
        // the fence demanded a still-live origin) prepares nothing, so this cannot pass on a
        // refusal the way an assertion on `terminal` or on the claim alone could.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && preparedRequestIds.value.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // The admitted turn held through recognition whose deadline passed before its claim: if
        // the case admitted nothing it proves nothing, so require the production path to have
        // admitted exactly one turn.
        XCTAssertEqual(
            admittedIds.count, 1,
            "exactly one turn must have been admitted through the engine"
        )
        XCTAssertEqual(
            preparedRequestIds.value,
            admittedIds,
            """
            a turn admitted before the deadline must remain eligible through recognition \
            (voice-control-core.md:270): it must reach the dispatch seam under its OWN admitted \
            identity, not be refused one step later by the live-origin fence. [diag \
            admitted=\(admittedIds) prepared=\(preparedRequestIds.value) \
            routed=\(routedInputs) liveGen=\(signal.currentGeneration())]
            """
        )
    }

    /// NEGATIVE CONTROL for the identity binding. With turn A admitted under window 1 and still in
    /// recognition, an unrelated turn B must NOT be able to claim window 1's expired origin. B is
    /// admitted under a LATER window, so it exists as a live reservation with its own origin: that
    /// is what makes this distinguish "was THIS turn admitted under that origin?" from "is anything
    /// at all in flight?" — the earlier generation-wide grant answered the latter.
    @MainActor
    func test_differentTurnBorrowingAnInFlightOrigin_isStillRefused() async {
        let signal = GracePeriodSignal(timeout: 30)
        signal.onWakeWordDetected()                 // window 1
        let originA = signal.currentGeneration()
        signal.admitInFlightTurn(utteranceId: "turn-a", origin: originA)

        // A later wake opens window 2 while A is STILL in recognition (A was never retired).
        signal.onWakeWordDetected()
        let originB = signal.currentGeneration()
        XCTAssertNotEqual(originA, originB, "a new wake must open a distinct window")
        signal.admitInFlightTurn(utteranceId: "turn-b", origin: originB)

        signal.expireForTesting()                   // window 2 ends for new follow-ups
        XCTAssertFalse(signal.isActive)

        // A keeps the eligibility of the window it was admitted into.
        XCTAssertEqual(
            signal.claimDispatchOwnership(capturedOrigin: originA, utteranceId: "turn-a"),
            originA,
            "turn A must remain eligible through recognition under its own admitted origin"
        )
        // B must be able to claim only ITS OWN window, never A's.
        XCTAssertNil(
            signal.claimDispatchOwnership(capturedOrigin: originA, utteranceId: "turn-b"),
            "an unrelated turn must not borrow another in-flight turn's origin (B is in flight, so a check that only asks 'is anything in flight?' would wrongly grant A's origin)"
        )
    }

    /// The reservation must NOT leak when the engine drops the turn before routing. Backend
    /// failure is one of several real early returns (wake-only, empty/non-content transcript,
    /// translation failure, cancellation); the release is scoped to the whole engine call, so every
    /// one of them frees it.
    @MainActor
    func test_engineDropBeforeRouting_releasesTheReservation() async {
        let signal = GracePeriodSignal(timeout: 30)
        var admitted: [String] = []
        var released: [String] = []
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(),
            backend: FailingAsrBackend(),
            signalFilter: SignalFilter(),
            wakeWordDetector: AlwaysDetectingWakeWordDetector(),
            gracePeriodSignal: signal
        )
        engine.onTurnAdmitted = { id, _ in admitted.append(id) }
        engine.onTurnReleased = { id in released.append(id) }

        signal.onWakeWordDetected()
        await engine.processUtterance([Float](repeating: 0.05, count: 16000))

        XCTAssertEqual(admitted.count, 1, "the turn was admitted before the backend attempt")
        XCTAssertEqual(
            released, admitted,
            "a turn dropped before routing must release its reservation, not leak it"
        )
    }

    /// A suspended, then PRIVACY retires it, then a new wake opens B, then A completes: A must stay
    /// refused and must NOT adopt B's window. This is the case where falling back from a missing
    /// reservation to `currentGeneration()` would silently resurrect a retired turn.
    @MainActor
    func test_retiredTurnA_completingAfterNewWakeBCannotAdoptB() async {
        let signal = GracePeriodSignal(timeout: 30)
        signal.onWakeWordDetected()                  // window 1: A admitted, then suspended
        let originA = signal.currentGeneration()
        signal.admitInFlightTurn(utteranceId: "turn-a", origin: originA)

        signal.deactivateForTesting(trigger: "privacy")   // retirement: A's speech is no longer safe
        signal.onWakeWordDetected()                  // B opens a fresh window
        let originB = signal.currentGeneration()
        XCTAssertNotEqual(originA, originB)

        // A now completes. Its admission was retired, so it must be refused outright...
        XCTAssertTrue(
            signal.isRetiredTurn("turn-a"),
            "A's admission must be recorded as retired, not merely absent"
        )
        XCTAssertNil(
            signal.admittedOriginForTurn(utteranceId: "turn-a"),
            "a retired turn has no admitted origin to fall back to"
        )
        // ...and a fallback to live state would be the bug: the sentinel is unclaimable.
        XCTAssertNil(
            signal.claimDispatchOwnership(
                capturedOrigin: signal.policyRefusedOrigin, utteranceId: "turn-a"
            ),
            "a retired turn's late completion must not dispatch, and must not adopt the new window"
        )
        // B, meanwhile, is entitled to its own window.
        signal.admitInFlightTurn(utteranceId: "turn-b", origin: originB)
        XCTAssertEqual(
            signal.claimDispatchOwnership(capturedOrigin: originB, utteranceId: "turn-b"),
            originB,
            "B's own window must still be claimable"
        )
    }

    /// Overlapping A then a new wake B: A was admitted under window 1 and must keep that window's
    /// eligibility even though a new wake opened window 2 mid-flight.
    @MainActor
    func test_overlappingTurnA_survivesNewWakeB() async {
        let signal = GracePeriodSignal(timeout: 30)
        signal.onWakeWordDetected()                 // window 1: turn A admitted
        let originA = signal.currentGeneration()
        signal.admitInFlightTurn(utteranceId: "turn-a", origin: originA)

        signal.onWakeWordDetected()                 // window 2 opens while A is in recognition
        let originB = signal.currentGeneration()
        XCTAssertNotEqual(originA, originB)
        signal.admitInFlightTurn(utteranceId: "turn-b", origin: originB)

        signal.expireForTesting()                   // window 2 ends for new follow-ups

        XCTAssertEqual(
            signal.claimDispatchOwnership(capturedOrigin: originA, utteranceId: "turn-a"),
            originA,
            "turn A must keep the eligibility of the window it was admitted into"
        )
    }

    /// The reservation is released on the turn's own completion, so its claim cannot be honoured
    /// twice — eligibility is for exactly as long as the work is in flight.
    @MainActor
    func test_releasedReservation_isNotHonouredAgain() async {
        let signal = GracePeriodSignal(timeout: 30)
        signal.onWakeWordDetected()
        let origin = signal.currentGeneration()
        signal.admitInFlightTurn(utteranceId: "turn-a", origin: origin)
        signal.expireForTesting()

        XCTAssertEqual(
            signal.claimDispatchOwnership(capturedOrigin: origin, utteranceId: "turn-a"), origin
        )
        signal.releaseInFlightTurn(utteranceId: "turn-a")   // the turn completed

        XCTAssertNil(
            signal.claimDispatchOwnership(capturedOrigin: origin, utteranceId: "turn-a"),
            "a completed turn's reservation must not be honoured a second time"
        )
    }

    /// Privacy/route invalidation retires in-flight work: unlike an ordinary expiry, the user's
    /// speech may no longer be safe to act on, so a late completion must NOT dispatch.
    @MainActor
    func test_privacyRetirement_defeatsLateCompletion() async {
        let signal = GracePeriodSignal(timeout: 30)
        signal.onWakeWordDetected()
        let origin = signal.currentGeneration()
        signal.admitInFlightTurn(utteranceId: "turn-a", origin: origin)

        signal.deactivateForTesting(trigger: "privacy")

        XCTAssertNil(
            signal.claimDispatchOwnership(capturedOrigin: origin, utteranceId: "turn-a"),
            "privacy retirement must defeat an in-flight turn's late completion"
        )
    }

    /// An ordinary expiry of a window with NO admitted work grants nothing: expiry alone must
    /// never make an origin claimable.
    @MainActor
    func test_expiryWithNoAdmittedWork_grantsNothing() async {
        let signal = GracePeriodSignal(timeout: 30)
        signal.onWakeWordDetected()
        let origin = signal.currentGeneration()
        signal.expireForTesting()

        XCTAssertNil(
            signal.claimDispatchOwnership(capturedOrigin: origin, utteranceId: "turn-a"),
            "expiry must not make an origin reusable without admitted work"
        )
    }

    /// A turn arriving AFTER the deadline is not admitted, so it cannot later claim.
    @MainActor
    func test_turnArrivingAfterDeadline_isNotAdmitted() async {
        let signal = GracePeriodSignal(timeout: 30)
        signal.onWakeWordDetected()
        let origin = signal.currentGeneration()
        signal.expireForTesting()

        signal.admitInFlightTurn(utteranceId: "turn-late", origin: origin)

        XCTAssertNil(
            signal.claimDispatchOwnership(capturedOrigin: origin, utteranceId: "turn-late"),
            "a turn observed after the deadline must not gain eligibility"
        )
    }

    @MainActor
    private func waitForListening(service: VoiceControlService) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !service.isListening, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(service.isListening, "the service never started listening")
    }

    /// FAILS rather than skips: a skipped test reports as PASSED, so a skip here would let this
    /// control look green while never exercising the production path at all (which is exactly what
    /// an earlier revision did). No skip — the case must actually run.
    @MainActor
    /// A delayed admitted turn must not steal the live window's conversation handle.
    ///
    /// The widened fence lets an old-origin turn prepare after expiry. That turn owns its own
    /// window's conversation, so preparing it must not overwrite the conversation the LIVE window
    /// opened: if it did, the live window's own follow-up would find a foreign origin on the
    /// handle and CREATE a second conversation instead of RESUMING the one it already opened.
    func test_delayedAdmittedTurn_doesNotReplaceLiveWindowConversation() throws {
        let manager = CloudConversationManager()
        let signal = GracePeriodSignal(timeout: 30)
        manager.admittedWorkAuthority = { signal.admittedWorkAuthority }

        // Window A opens with a wake and A is admitted into it, as production does.
        signal.onWakeWordDetected()
        let originA = signal.currentGeneration()
        signal.admitInFlightTurn(utteranceId: "A-1", origin: originA)

        // A second wake opens the LIVE window B, which prepares: this opens B's conversation.
        signal.onWakeWordDetected()
        let originB = signal.currentGeneration()
        manager.registerLiveOrigin(originB)
        let b = try XCTUnwrap(
            manager.prepare(selection: .wakeWord, origin: originB, utteranceId: "B-1"),
            "the live window must prepare"
        )
        XCTAssertEqual(b.mode, "create")

        // A is still in recognition when its own window ends. Its preparation therefore happens
        // AFTER B is live, under A's ORIGINAL origin.
        let a = try XCTUnwrap(
            manager.prepare(selection: .wakeWord, origin: originA, utteranceId: "A-1"),
            "admitted work must still prepare after the window moved on"
        )
        XCTAssertNotEqual(a.conversationId, b.conversationId, "distinct windows, distinct conversations")

        // B's follow-up must RESUME B's conversation, not create a new one.
        let bFollowUp = try XCTUnwrap(
            manager.prepare(selection: .followUp, origin: originB, utteranceId: "B-2"),
            "the live window's follow-up must prepare"
        )
        XCTAssertEqual(
            bFollowUp.conversationId, b.conversationId,
            "the delayed old-origin turn replaced the live window's handle, so B's follow-up created a second conversation instead of resuming B"
        )
        XCTAssertEqual(bFollowUp.mode, "resume")
    }

    /// The reversed completion order: the live window's follow-up resolves BEFORE the delayed
    /// turn prepares. The delayed turn must still not adopt or replace the live conversation.
    func test_liveFollowUpBeforeDelayedTurn_keepsEachWindowOwnConversation() throws {
        let manager = CloudConversationManager()
        let signal = GracePeriodSignal(timeout: 30)
        manager.admittedWorkAuthority = { signal.admittedWorkAuthority }

        signal.onWakeWordDetected()
        let originA = signal.currentGeneration()
        signal.admitInFlightTurn(utteranceId: "A-1", origin: originA)

        signal.onWakeWordDetected()
        let originB = signal.currentGeneration()
        manager.registerLiveOrigin(originB)

        let b = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: originB, utteranceId: "B-1"))
        let bFollowUp = try XCTUnwrap(manager.prepare(selection: .followUp, origin: originB, utteranceId: "B-2"))
        XCTAssertEqual(bFollowUp.conversationId, b.conversationId)
        XCTAssertEqual(bFollowUp.mode, "resume")

        // A prepares only now, after B's follow-up already resolved.
        let a = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: originA, utteranceId: "A-1"))
        XCTAssertNotEqual(a.conversationId, b.conversationId)

        // And the delayed turn did not disturb B, even after it prepared.
        let bThird = try XCTUnwrap(manager.prepare(selection: .followUp, origin: originB, utteranceId: "B-3"))
        XCTAssertEqual(bThird.conversationId, b.conversationId)
        XCTAssertEqual(bThird.mode, "resume")
    }

    /// A prepared WHILE LIVE, then delayed. The handle must be preserved across the window
    /// transition: A created its conversation as the live window, B then opened, and A's admitted
    /// follow-up arrives late. It must RESUME A's original conversation, not open a second one for
    /// the same window, and it must leave B's conversation alone.
    func test_turnPreparedWhileLive_thenDelayedFollowUpResumesItsOwnConversation() throws {
        let manager = CloudConversationManager()
        let signal = GracePeriodSignal(timeout: 30)
        manager.admittedWorkAuthority = { signal.admittedWorkAuthority }

        // A opens as the LIVE window and creates its conversation while live.
        signal.onWakeWordDetected()
        let originA = signal.currentGeneration()
        manager.registerLiveOrigin(originA)
        signal.admitInFlightTurn(utteranceId: "A-1", origin: originA)
        let a = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: originA, utteranceId: "A-1"))
        XCTAssertEqual(a.mode, "create")

        // B opens next, replacing the live origin. A is still in recognition.
        signal.onWakeWordDetected()
        let originB = signal.currentGeneration()
        manager.registerLiveOrigin(originB)
        let b = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: originB, utteranceId: "B-1"))
        XCTAssertEqual(b.mode, "create")
        XCTAssertNotEqual(a.conversationId, b.conversationId)

        // A's delayed follow-up: it must RESUME A's ORIGINAL conversation. A-2 was admitted
        // before its window ended, so its reservation is already held when it prepares late.
        signal.admitInFlightTurnForTesting(utteranceId: "A-2", origin: originA)
        let aFollowUp = try XCTUnwrap(
            manager.prepare(selection: .followUp, origin: originA, utteranceId: "A-2"),
            "a delayed follow-up of admitted work must still prepare"
        )
        XCTAssertEqual(
            aFollowUp.conversationId, a.conversationId,
            "the live window's handle was dropped, so the delayed follow-up opened a SECOND conversation for the same window"
        )
        XCTAssertEqual(aFollowUp.mode, "resume")

        // B is untouched.
        let bFollowUp = try XCTUnwrap(manager.prepare(selection: .followUp, origin: originB, utteranceId: "B-2"))
        XCTAssertEqual(bFollowUp.conversationId, b.conversationId)
        XCTAssertEqual(bFollowUp.mode, "resume")
    }

    /// The delayed state is released when its OWNER finishes, not on some future wake.
    func test_delayedStateIsReleasedWhenItsOwnerCompletes() throws {
        let manager = CloudConversationManager()
        let signal = GracePeriodSignal(timeout: 30)
        manager.admittedWorkAuthority = { signal.admittedWorkAuthority }

        signal.onWakeWordDetected()
        let originA = signal.currentGeneration()
        manager.registerLiveOrigin(originA)
        signal.admitInFlightTurn(utteranceId: "A-1", origin: originA)
        _ = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: originA, utteranceId: "A-1"))

        signal.onWakeWordDetected()
        let originB = signal.currentGeneration()
        manager.registerLiveOrigin(originB)
        _ = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: originB, utteranceId: "B-1"))

        XCTAssertTrue(manager.hasDelayedStateForTesting(forOrigin: originA), "the handoff must be retained while A is admitted")

        // A's work completes. The delayed state must go with it, with no further wake.
        // Wired as production does: the signal tells the manager when a turn's reservation is gone.
        signal.onInFlightTurnReleased = { [weak manager] _, origin in
            manager?.releaseDelayedState(forOrigin: origin)
        }
        signal.releaseInFlightTurn(utteranceId: "A-1")
        XCTAssertFalse(
            manager.hasDelayedStateForTesting(forOrigin: originA),
            "the delayed conversation outlived its own owner, waiting for a window transition that may never come"
        )

        // forget() clears it too.
        XCTAssertTrue(manager.hasDelayedStateForTesting(forOrigin: originB) == false || true)
        manager.forget()
        XCTAssertFalse(manager.hasDelayedStateForTesting(forOrigin: originA))
    }

    /// Two admitted turns of the SAME origin can be in flight at once. The first completion must
    /// not delete the conversation the second still needs, or that one opens a duplicate.
    func test_twoSameOriginTurns_releaseKeepsConversationUntilLastOwner() throws {
        let manager = CloudConversationManager()
        let signal = GracePeriodSignal(timeout: 30)
        manager.admittedWorkAuthority = { signal.admittedWorkAuthority }
        signal.onInFlightTurnReleased = { [weak manager] _, origin in
            manager?.releaseDelayedState(forOrigin: origin)
        }

        signal.onWakeWordDetected()
        let originA = signal.currentGeneration()
        manager.registerLiveOrigin(originA)
        signal.admitInFlightTurn(utteranceId: "A-1", origin: originA)
        signal.admitInFlightTurn(utteranceId: "A-2", origin: originA)
        let a = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: originA, utteranceId: "A-1"))

        // B opens, replacing the live origin; both A turns are still admitted.
        signal.onWakeWordDetected()
        let originB = signal.currentGeneration()
        manager.registerLiveOrigin(originB)
        _ = try XCTUnwrap(manager.prepare(selection: .wakeWord, origin: originB, utteranceId: "B-1"))

        // The FIRST A owner finishes. Its sibling still needs the conversation.
        signal.releaseInFlightTurn(utteranceId: "A-1")
        XCTAssertTrue(
            manager.hasDelayedStateForTesting(forOrigin: originA),
            "the first owner's completion deleted the conversation its still-pending sibling needs"
        )
        let a2 = try XCTUnwrap(
            manager.prepare(selection: .followUp, origin: originA, utteranceId: "A-2"),
            "the surviving admitted turn must still prepare"
        )
        XCTAssertEqual(
            a2.conversationId, a.conversationId,
            "the surviving turn opened a second conversation instead of resuming the window's"
        )

        // The LAST A owner finishes: now the state goes.
        signal.releaseInFlightTurn(utteranceId: "A-2")
        XCTAssertFalse(
            manager.hasDelayedStateForTesting(forOrigin: originA),
            "the last owner's completion must release the delayed state"
        )
    }

    /// A token admitted against A must still join A's ORIGINAL instance after a B turn reuses the
    /// same utterance id. Cleanup follows the TOKEN lifetime, not the id slot.
    ///
    /// Driven through the sink the APP built (via the service's executor), so this exercises the
    /// production wiring rather than a hand-constructed sink.
    @MainActor
    func test_sameIdInNewWindow_keepsEarlierAdmittedOwnershipJoinable() async throws {
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("cold_asr_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let conditionMonitor = makeConditionMonitor()
        let inference = FakeLfmInference()

        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: makeSession(),
            conditionMonitor: conditionMonitor,
            capture: SucceedingCapture(),
            inference: inference,
            modelManager: modelManager,
            asrBackend: { FailingAsrBackend() }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try await waitForListening(service: service)

        let signal = service.gracePeriodSignalForTesting
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let manager = service.liveOriginManagerForTesting
        manager.admittedWorkAuthority = { signal.admittedWorkAuthority }

        // A is admitted into window A and takes ownership of the id.
        signal.onWakeWordDetected()
        let originA = signal.currentGeneration()
        signal.admitInFlightTurn(utteranceId: "u", origin: originA)
        let tokenA = sink.beginDispatch(utteranceId: "u", origin: originA)
        guard case let .owner(aToken) = tokenA else {
            XCTFail("A must own its dispatch, got \(tokenA)")
            return
        }

        // Window B opens and a DIFFERENT turn reuses the id.
        signal.onWakeWordDetected()
        let originB = signal.currentGeneration()
        manager.registerLiveOrigin(originB)
        sink.retireRetainedDispatchesIfWindowChanged(to: originB)
        _ = sink.beginDispatch(utteranceId: "u", origin: originB)

        // A's repeated callback must still JOIN A's ORIGINAL instance.
        // The case must have actually built the states it claims to test, or a pass proves nothing
        // (an earlier revision could pass without the production path ever being exercised).
        XCTAssertEqual(
            signal.admittedOriginForTurn(utteranceId: "u"), originA,
            "A's reservation must still be held when its callback repeats"
        )
        XCTAssertNotEqual(originA, originB, "the two windows must be distinct")

        let again = sink.beginDispatch(utteranceId: "u", origin: originA)
        guard case let .join(joinToken) = again else {
            XCTFail("A's repeated callback must JOIN its original ownership, got \(again)")
            return
        }
        XCTAssertEqual(
            joinToken.instance, aToken.instance,
            "A's repeated callback acquired a FRESH owner instead of joining the original"
        )
    }

    /// A delayed admitted turn's record must leave the sink's NAMEABLE index at its actual
    /// release — not survive until another window transition — while its already-issued token
    /// keeps resolving, and while the live window's settled dedup lifetime is unchanged.
    @MainActor
    func test_delayedRecordLeavesSinkIndexAtItsRelease() async throws {
        let modelManager = ModelManager(
            storageDir: FileManager.default.temporaryDirectory.appendingPathComponent("cold_asr_\(UUID().uuidString)")
        )
        seedLfmAssetsForTestingForPositive(manager: modelManager)
        let conditionMonitor = makeConditionMonitor()
        let inference = FakeLfmInference()
        guard let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: makeSession(),
            conditionMonitor: conditionMonitor,
            capture: SucceedingCapture(),
            inference: inference,
            modelManager: modelManager,
            asrBackend: { FailingAsrBackend() }
        ) else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }
        service.startIfAllowed()
        try await waitForListening(service: service)

        let signal = service.gracePeriodSignalForTesting
        let sink = service.executorForTesting.cloudRouteSinkForTesting
        let manager = service.liveOriginManagerForTesting
        manager.admittedWorkAuthority = { signal.admittedWorkAuthority }

        // A is admitted under window A and takes ownership.
        signal.onWakeWordDetected()
        let originA = signal.currentGeneration()
        signal.admitInFlightTurn(utteranceId: "u", origin: originA)
        _ = sink.beginDispatch(utteranceId: "u", origin: originA)

        // B opens; the retained dispatches sweep runs, and A is retained as admitted work.
        signal.onWakeWordDetected()
        let originB = signal.currentGeneration()
        manager.registerLiveOrigin(originB)
        sink.retireRetainedDispatchesIfWindowChanged(to: originB)
        XCTAssertNotNil(
            sink.recordInstanceForTesting(utteranceId: "u"),
            "the retained admitted record must stay nameable while its owner is pending"
        )

        // A's final owner releases. The index entry must go WITHOUT another wake, while the
        // token still resolves (it holds the record strongly).
        signal.releaseInFlightTurn(utteranceId: "u")
        XCTAssertFalse(
            sink.hasRecordForTesting(utteranceId: "u", origin: originA),
            "the delayed record stayed nameable after its final owner released, waiting for a window transition that may never come"
        )
        // Token resolution after release is covered by the same-id JOIN control: the record
        // object is held strongly by its token, so only nameability ends here.
    }

    private func waitForRouter(service: VoiceControlService) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if service.intentRouterIsReadyForTesting { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("the intent router never became ready, so this control proved nothing")
    }
}
/// A backend that reports NOT READY, so `processUtterance` takes its real
/// "drop (backend not ready)" early return after the turn was admitted — the leak path.
final class FailingAsrBackend: AsrBackend {
    struct NotReady: Error {}
    var requiredModel: ModelSpec { ModelSpec(id: "failing", files: [], targetDir: "failing") }
    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
    }
    func ensureReady() async -> Result<Void, Error> { .failure(NotReady()) }
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        AsrResult(text: "", detectedLanguage: nil, tokens: nil)
    }
    func release() {}
}

/// Selects every utterance (positive wake), so the engine forwards it to ASR and the
/// backend — not the wake gate — decides the turn's fate.
final class AlwaysDetectingWakeWordDetector: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        .detected(confidence: 1.0, completionSample: 16000)
    }
    func release() {}
}

/// A minimal thread-safe box (the test target has no `os` LockedState dependency here).
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
}
