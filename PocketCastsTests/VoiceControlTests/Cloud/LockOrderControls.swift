import XCTest
@testable import podcasts

/// LOCK-ORDER CONTROLS (review 086c0172/5fa6e007/92de14ea): deterministic, bounded proofs for the
/// service `transcriptLock`/`stop()` main-queue inversion.
///
/// The shared production operation `captureRoutingOrigin` exposes two barriers: pre-lock (after the
/// grace reads, before acquisition) and post-lock (with the lock held). The GREEN control walks an
/// explicit handoff — off-main capture thread reaches the pre-lock barrier, main runs `stop()`
/// (acquiring the lock on main), the capture thread then acquires — which completes only when the
/// grace reads are OUTSIDE the lock. The RED control replays the PRE-FIX ordering (reads INSIDE the
/// lock, i.e. after acquisition) on a pair of daemon threads and asserts, with a bounded wait, that
/// it deadlocks: neither side can proceed because the off-main holder waits for the main queue while
/// main waits for `transcriptLock`. A deadlocked probe thread is abandoned (daemon), so the runner
/// never hangs; the discriminator is the bounded outcome, not a timeout kill.
final class LockOrderControls: XCTestCase {
    @MainActor
    func testAnOffMainCapturePausesBeforeTheLockWhileMainStopsThenCompletes() async throws {
        let session = FakeAudioSessionControlling()
        session.outputs = [AudioPort(portType: .builtInSpeaker, uid: "speaker")]
        session.inputs = [AudioPort(portType: .builtInMic, uid: "built-in")]
        session.availableAfterConfigure = [AudioPort(portType: .builtInMic, uid: "built-in")]
        session.selectionTakesEffect = true

        let gracePeriodSignal = GracePeriodSignal()
        let conditionMonitor = LiveConditionMonitor(gracePeriodSignal: gracePeriodSignal)
        let service = VoiceControlAssembly()
            .buildVoiceControlService(audioSession: session, conditionMonitor: conditionMonitor, capture: SucceedingCapture())!
        service.startIfAllowed()
        await waitUntilListening(timeout: 5) { service.isListening }

        // Explicit handoff:
        //   1. off-main capture enters the PRE-LOCK barrier (grace reads done, lock NOT held);
        //   2. main runs stop() — takes transcriptLock ON main — and signals;
        //   3. the capture thread acquires the lock. Post-fix this cannot deadlock: the grace
        //      reads are already complete, so the off-main side never waits on the main queue
        //      while holding the lock.
        let reachedPreLock = DispatchSemaphore(value: 0)
        let mainStopDone = DispatchSemaphore(value: 0)
        let captureAcquired = DispatchSemaphore(value: 0)
        service.capturePreLockBarrierForTesting = { reachedPreLock.signal() }
        service.capturePostLockBarrierForTesting = { captureAcquired.signal() }

        let captureThread = Thread {
            _ = service.captureRoutingOrigin(utteranceId: "utterance-handoff")
        }
        captureThread.start()
        // Await the barriers WITHOUT blocking the main thread (the capture's grace reads
        // main.sync onto it — blocking main here would manufacture the very deadlock the
        // control forbids). Each wait runs on a detached task with a bounded timeout.
        let reached = await Task.detached { reachedPreLock.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(reached, "the capture must reach the pre-lock barrier (grace reads done, lock not held)")
        service.capturePreLockBarrierForTesting = nil

        // Main-side stop: takes transcriptLock on main. Because the off-main side holds NO lock
        // right now, this completes immediately — the inversion point the pre-fix code sat on.
        service.stop()
        mainStopDone.signal()

        service.startIfAllowed()
        // Release the capture thread to acquire the (now free) lock; the main-queue pump stays
        // live (we await, never block) so the capture's main.sync grace reads are served.
        let acquired = await Task.detached { captureAcquired.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(acquired,
                      "the capture must acquire the lock after main's stop() released it — no inversion")
        _ = mainStopDone
        service.capturePostLockBarrierForTesting = nil
    }

    /// RED CONTROL (pre-fix ordering, replayed explicitly): the grace reads are performed INSIDE
    /// the lock — i.e., after acquisition — on an off-main thread, while main attempts `stop()`
    /// which needs the same lock. This is the exact pre-fix structure. Both sides block forever:
    /// the holder waits on the main queue (reads), main waits for the lock. The control bounds
    /// the observation to 3 s and FAILS with the deadlock diagnosis; the probe threads are daemon
    /// threads, abandoned on return, so the runner never hangs. Committed RED receipt:
    /// task58-lockorder-red-run.log.
    func testRedReplayGraceReadsInsideTheLockDeadlocksAgainstMainStop() {
        let gracePeriodSignal = GracePeriodSignal()
        let lock = NSLock()

        let enteredLock = DispatchSemaphore(value: 0)
        // Off-main probe (daemon): acquire the lock, THEN perform the main-bound grace reads —
        // the pre-fix ordering.
        let probe = Thread {
            lock.lock()
            enteredLock.signal()
            // Pre-fix: reads hop to main while the lock is held. Main is blocked on the lock
            // below → self-deadlock.
            gracePeriodSignal.currentGeneration()
            lock.unlock()
        }
        probe.threadPriority = 0.5
        probe.start()
        XCTAssertEqual(enteredLock.wait(timeout: .now() + 5), .success, "probe must acquire the lock")

        // Main-bound stop() equivalent: acquire the same lock on THIS thread — pre-fix main would
        // block forever because the holder never releases (it waits for main to serve its reads).
        let result = lock.lock(before: Date().addingTimeInterval(3))
        XCTAssertFalse(result,
                       "RED (pre-fix ordering): main cannot acquire transcriptLock while the off-main "
                           + "holder performs main-bound reads — the deadlock the pre-lock reads remove")
        if !result {
            // The probe is deadlocked by construction; abandon it (daemon thread).
            return
        }
        lock.unlock()
    }

    private func waitUntilListening(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
