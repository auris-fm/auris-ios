import XCTest
@testable import podcasts

/// LOCK-ORDER CONTROL (review 086c0172/5fa6e007/92de14ea/47328768): one real-path control on the
/// shared production capture operation `captureRoutingOrigin`.
///
/// The control parks the off-main capture INSIDE the operation, after its grace reads and before its
/// lock acquisition (via the production-adjacent test barrier), runs the REAL `stop()` on main —
/// which acquires `transcriptLock` there — then releases the park and requires BOTH sides to finish
/// within bounded waits. The lock-reorder mutation (grace reads moved back INSIDE
/// `transcriptLock`, the post-reads barrier with them) parks the capture HOLDING the lock, so
/// main `stop()` blocks and the 3s bound fails — that mutation is run IN-TREE against these
/// committed controls (receipt: lockreorder-mutant1, stop() blocked 10.05s); the earlier
/// out-of-tree RED receipt from the ordering handoff is retained alongside it.
final class LockOrderControls: XCTestCase {
    @MainActor
    func testCaptureParkedAfterItsReadsCompletesAfterMainStopsWithoutDeadlock() async throws {
        let session = FakeAudioSessionControlling()
        // Bluetooth pattern (mirrors the passing RouteChange acquisition tests): the gate refuses
        // a built-in-mic-only acquisition ("builtInOnly"), so the control needs an external
        // candidate that confirms on configure.
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = [AudioPort(portType: .bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true

        let gracePeriodSignal = GracePeriodSignal()
        let conditionMonitor = LiveConditionMonitor(gracePeriodSignal: gracePeriodSignal)
        let service = VoiceControlAssembly()
            .buildVoiceControlService(audioSession: session, conditionMonitor: conditionMonitor, capture: SucceedingCapture())!
        service.startIfAllowed()
        await waitUntilListening(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening,
                      "the control requires a LISTENING service; without it stop() guard-returns and "
                          + "the control is vacuous")

        // Park the capture AFTER its reads, BEFORE its acquisition. The barrier itself blocks the
        // capture thread on a semaphore; the test releases it — an explicit park/release handoff.
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        service.captureBeforeAcquisitionBarrierForTesting = {
            parked.signal()
            _ = release.wait(timeout: .now() + 10)
        }

        let captureThread = Thread {
            _ = service.captureRoutingOrigin(utteranceId: "utterance-parked-handoff")
        }
        captureThread.start()

        // Bounded wait for the park, WITHOUT blocking the main thread (the capture's reads
        // main.sync onto main only BEFORE the barrier; while parked it makes no main requests,
        // but we stay non-blocking on principle and to keep the pump live).
        let isParked = await Task.detached { parked.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(isParked, "the capture must park between its grace reads and its lock acquisition")

        // MAIN-SIDE stop(), on the main actor, while the capture is parked: acquires the lock,
        // bumps the epoch, releases. Post-fix the parked capture holds NO lock, so this cannot
        // block; the await below is bounded and would time out under the pre-fix ordering.
        let stopStarted = Date()
        service.stop()
        let stopDuration = Date().timeIntervalSince(stopStarted)
        XCTAssertLessThan(stopDuration, 3,
                          "main stop() must complete while the capture is parked before acquisition — "
                              + "blocking here is the pre-fix deadlock")

        // Release the park; the capture acquires (post-stop the lock is free), hits the listening
        // gate, and returns. Join the thread with a bounded pump so a hang surfaces as a failure.
        release.signal()
        let joined = await Task.detached { captureThread.waitUntilExit(withTimeout: 5) }.value
        XCTAssertTrue(joined, "the capture thread must finish after release — a hang here is the deadlock")
        service.captureBeforeAcquisitionBarrierForTesting = nil
    }

    /// STOPPED-CAPTURE REFUSAL, through the REAL enqueue entry (review 47328768/ece440bc):
    /// drives `asrEngine.onRoutingInput` — the callback the ASR engine actually invokes — so the
    /// control exercises `enqueueRoutingInput`'s `guard let capture else { return false }` guard,
    /// not the capture operation in isolation. The stop/restart race is deterministic: the
    /// service is stopped when the callback's capture runs (so the capture is nil), the
    /// post-capture barrier parks the enqueue BETWEEN the capture's return and the guard, and
    /// while it is parked the gate conditions flip to restart the service — making the LOCK-TIME
    /// `isListening` recheck the enqueue would fall through to read TRUE. With the guard present
    /// the enqueue refuses on the nil capture (returns false). Deleting the guard falls through
    /// to that true recheck, the late callback whose origin reads ran while stopped is admitted,
    /// and the control fails. No restart-timing luck is involved: the restart completes BEFORE
    /// the parked enqueue reaches the guard.
    @MainActor
    func testAStopRestartBetweenCaptureAndLockCheckRefusesTheLateCallback() async throws {
        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .bluetoothA2DP, uid: "bt-out")]
        session.inputs = []
        session.available = []
        session.availableAfterConfigure = [AudioPort(portType: .bluetoothHFP, uid: "bt-mic")]
        session.selectionTakesEffect = true

        let gracePeriodSignal = GracePeriodSignal()
        let conditionMonitor = LiveConditionMonitor(gracePeriodSignal: gracePeriodSignal)
        let service = VoiceControlAssembly()
            .buildVoiceControlService(audioSession: session, conditionMonitor: conditionMonitor, capture: SucceedingCapture())!
        service.startIfAllowed()
        await waitUntilListening(timeout: 5) { service.isListening }
        XCTAssertTrue(service.isListening, "premise: the control needs a listening service")

        // The restart mechanism is proven BEFORE it is needed: the gate republishes .listening
        // when the monitored context flips, and `start(in:)` runs against the SucceedingCapture.
        service.stop()
        conditionMonitor.context = .none
        conditionMonitor.context = .appInForeground
        let proofDeadline = Date().addingTimeInterval(5)
        while !service.isListening && Date() < proofDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(service.isListening, "premise: the context flip must deterministically restart the service")
        service.stop()

        // Park the REAL enqueue AFTER the capture returns (nil — the service is stopped) and
        // BEFORE the nil-capture guard, holding no lock. The park result is RECORDED, not
        // discarded: a timeout means the capture never reached the barrier and every later
        // assertion would be vacuous, so it is asserted before the restart.
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        service.enqueueAfterCaptureForTesting = { [weak service] in
            parked.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        // UNCONDITIONAL CLEANUP: the gate is released, the seam cleared and the service stopped
        // on EVERY exit path, so a failed assertion cannot leave a parked enqueue or a listening
        // service behind for subsequent tests.
        defer {
            release.signal()
            service.enqueueAfterCaptureForTesting = nil
            service.stop()
        }

        let input = IntentRoutingInput(
            sourceTranscript: "late turn", sourceLanguage: nil,
            routerTranscript: "late turn", translationKind: .none, selection: nil,
            utteranceId: "utterance-stop-restart")
        // The enqueue's completion is observed through a semaphore + lock-protected box with a
        // BOUNDED wait: awaiting the detached task directly would hang this control if the
        // enqueue wedged, and an unbounded hang is not a failure signal.
        let resultBox = ResultBox()
        let enqueueDone = DispatchSemaphore(value: 0)
        Task.detached {
            let refused = service.asrEngineForTesting.onRoutingInput?(input) ?? false // real entry
            resultBox.store(refused)
            enqueueDone.signal()
        }

        let parkedOutcome = await Task.detached { parked.wait(timeout: .now() + 5) }.value
        XCTAssertEqual(parkedOutcome, .success,
                       "the late callback's enqueue must park between the capture and the guard "
                           + "within the bound; a timeout means the control's window never opened")
        guard parkedOutcome == .success else { return }

        // THE RESTART, while the enqueue is parked between its capture and its guard: the
        // lock-time listening recheck the guard protects against will read TRUE.
        conditionMonitor.context = .none
        conditionMonitor.context = .appInForeground
        let restartDeadline = Date().addingTimeInterval(5)
        while !service.isListening && Date() < restartDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(service.isListening, "the deterministic restart must land while the late callback is parked")

        // RELEASE the gate BEFORE the bounded completion wait (the defer is cleanup for failure
        // paths only): the guard must refuse on the nil capture regardless of the
        // restart-made-true lock-time listening state, and the refusal must arrive through the
        // released gate, not the gate's own 10s timeout.
        release.signal()
        let doneOutcome = await Task.detached { enqueueDone.wait(timeout: .now() + 10) }.value
        XCTAssertEqual(doneOutcome, .success,
                       "the enqueue must complete within the bound after release; a hang here is a defect")
        XCTAssertTrue(resultBox.stored, "premise: the enqueue returned a verdict")
        let refused = resultBox.value ?? true
        XCTAssertFalse(refused,
                       "a late callback whose origin reads ran while stopped must be refused by the "
                           + "nil-capture guard even though the restart made the lock-time listening check true")
    }

    /// Lock-protected one-shot result box for the bounded-completion observation.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Bool?
        var stored: Bool { lock.lock(); defer { lock.unlock() }; return storedValue != nil }
        var value: Bool? { lock.lock(); defer { lock.unlock() }; return storedValue }
        func store(_ v: Bool) { lock.lock(); storedValue = v; lock.unlock() }
    }

    private func waitUntilListening(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

extension Thread {
    /// Bounded join: polls isFinished from a non-main context (never call from the thread itself).
    func waitUntilExit(withTimeout seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isFinished { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }
}
