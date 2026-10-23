import XCTest
@testable import podcasts

/// LOCK-ORDER CONTROLS (review 086c0172/5fa6e007): a deterministic proof for the service
/// `transcriptLock`/`stop()` main-queue inversion. The sink's coherent-admission controls live in
/// CloudRouteSinkTests.swift where the file-private admission helpers live.
final class LockOrderControls: XCTestCase {
    /// THE SERVICE CYCLE: an off-main capture thread executes the grace-read + `transcriptLock`
    /// capture phase (the exact structure `enqueueRoutingInput` runs from the ASR callback), while
    /// the MAIN thread repeatedly runs `stop()` — which takes `transcriptLock` on main. Pre-fix
    /// (grace reads INSIDE the lock), the off-main holder waits for the main queue while main waits
    /// for `transcriptLock`: a deterministic self-deadlock. Post-fix the capture reads happen before
    /// the lock, so both sides complete. Bounded by explicit deadlines, not the global test timeout.
    @MainActor
    func testAnOffMainRoutingCaptureAndAMainStopLoopCompleteWithoutDeadlock() async throws {
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

        // Off-main capture thread: performs the capture-phase reads + transcriptLock repeatedly.
        let captureThread = Thread {
            for _ in 0..<200 {
                _ = service.captureRoutingOrigin(utteranceId: "utterance-lockorder")
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        // Main-side stop()/start loop: takes transcriptLock ON main, interleaved with the captures.
        captureThread.start()
        for _ in 0..<100 {
            service.stop()
            service.startIfAllowed()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        // Bounded join: if the off-main capture deadlocked, this deadline expires and the test fails.
        let deadline = Date().addingTimeInterval(10)
        while !captureThread.isFinished {
            XCTAssertTrue(Date() < deadline, "the off-main capture thread deadlocked against the main stop() loop")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitUntilListening(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
