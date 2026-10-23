import XCTest
@testable import podcasts

/// LOCK-ORDER CONTROL (review 086c0172/5fa6e007/92de14ea/47328768): one real-path control on the
/// shared production capture operation `captureRoutingOrigin`, plus a mutation run proving it fails
/// under the pre-fix ordering (grace reads inside the lock — RED receipt preserved at handoff).
///
/// The control parks the off-main capture INSIDE the operation, after its grace reads and before its
/// lock acquisition (via the production-adjacent test barrier), runs the REAL `stop()` on main —
/// which acquires `transcriptLock` there — then releases the park and requires BOTH sides to finish
/// within bounded waits. Under the pre-fix ordering this cannot complete: the parked capture would
/// already hold the lock while making main-bound reads, so main's `stop()` blocks and the release
/// never serves the reads — the bounded completion asserts fail.
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
