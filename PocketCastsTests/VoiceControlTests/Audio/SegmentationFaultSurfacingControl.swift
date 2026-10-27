import XCTest
@testable import podcasts

/// A segmentation fault must reach an observer outside the audio component.
///
/// `recognition-pipeline.md` calls a detector stuck active a **surfaced** segmentation fault and
/// `arch/ios.md` requires an inspectable fault state. A flag private to the segmenter satisfies
/// neither: nothing outside it can see the interruption, so the user gets silence with no reason.
final class SegmentationFaultSurfacingControl: XCTestCase {
    private final class SilentDetector: WakeWordDetectorProtocol {
        func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
            .notDetected(confidence: 0)
        }

        func release() {}
    }

    /// Fault deliveries hop to the main actor, so a control must drain that queue before
    /// asserting. Draining also preserves the order the deliveries were produced in.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func makeEngine(segmenter: NativeVadSegmenter, capture: AudioCaptureSource? = nil) -> VoiceAsrEngine {
        VoiceAsrEngine(
            capture: capture ?? NativeAudioCapture(),
            segmenter: segmenter,
            backend: WhisperCppBackend(modelPath: "/tmp/test"),
            signalFilter: SignalFilter(),
            wakeWordDetector: SilentDetector(),
            gracePeriodSignal: GracePeriodSignal()
        )
    }

    /// The engine must forward a duration-ceiling fault to an installed observer.
    ///
    /// This drives the engine's own forwarding wiring rather than the segmenter's, because the
    /// question is whether the interruption escapes the audio component at all.
    func testEngineForwardsTheDurationCeilingToItsObserver() {
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: Int.max)
        let segmenter = NativeVadSegmenter(threshold: 0.020, silenceTimeoutMs: 500, classifier: script)
        let engine = makeEngine(segmenter: segmenter)

        var faults: [VoiceAsrEngine.SegmentationFault] = []
        var dispatched: [[Float]] = []
        engine.onSegmentationFault = { faults.append($0) }
        // Install the engine's forwarding without opening the microphone, then reach the ceiling.
        engine.installCaptureCallbacksForTesting()
        segmenter.onUtterance = { (utterance: [Float], _: MonotonicTime?) in dispatched.append(utterance) }

        for _ in 0..<((240_000 / 20) + 10) { segmenter.process([Float](repeating: 0.1, count: 320)) }
        drainMainQueue()

        guard let fault = faults.first else {
            return XCTFail(
                "the duration ceiling produced no fault observable through the engine, so the "
                    + "interruption never leaves the audio component"
            )
        }
        XCTAssertEqual(fault.kind, .durationLimitReached)
        XCTAssertGreaterThan(fault.elapsedMs, 0)
        XCTAssertTrue(dispatched.isEmpty, "the fault dispatched audio instead of suppressing it")
    }

    /// A fault produced by a STOPPED session must not reappear after the restart cleared it.
    ///
    /// `capture.stop()` does not drain callbacks the capture already queued. Those late samples
    /// can still raise a fault, and main-queue delivery alone cannot order events produced on
    /// different threads — so the session itself must be the fence.
    func testAStaleSessionFaultDoesNotReviveAfterRestart() {
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: Int.max)
        let segmenter = NativeVadSegmenter(threshold: 0.020, silenceTimeoutMs: 60_000, classifier: script)
        let capture = RecordingCapture()
        let engine = makeEngine(segmenter: segmenter, capture: capture)
        var faults: [VoiceAsrEngine.SegmentationFault] = []
        var recovered = 0
        engine.onSegmentationFault = { faults.append($0) }
        engine.onSegmentationFaultRecovered = { recovered += 1 }
        engine.installCaptureCallbacksForTesting()

        // Reach the ceiling so a fault is pending on the main queue, but do NOT drain yet: this is
        // the real ordering, where stop() runs before the queued delivery is executed.
        for _ in 0..<((240_000 / 20) + 10) { capture.deliver([Float](repeating: 0.1, count: 320)) }
        XCTAssertTrue(segmenter.isStuckActive, "the ceiling did not trip")

        // stop() clears the fault and queues its own recovery behind the pending fault delivery.
        engine.stop()
        drainMainQueue()

        XCTAssertEqual(recovered, 1, "restart did not clear the fault")
        XCTAssertEqual(
            faults.count, 0,
            "a fault produced by the stopped session was delivered after the restart, so the "
                + "interruption reappears with no way to clear it (\(faults.count) fault(s) shown)"
        )
        XCTAssertFalse(segmenter.isStuckActive)
    }

    /// A buffer the OLD tap queued before stop must not be treated as new-session audio.
    ///
    /// This is the case the delivery-time check cannot catch: the buffer is released after the
    /// restart, so reading the session at delivery would label it as the new session and let
    /// stale PCM change the next utterance.
    func testABufferQueuedByTheOldTapBeforeStopDoesNotReachTheNewSession() {
        let capture = HoldableCapture()
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: Int.max)
        let segmenter = NativeVadSegmenter(threshold: 0.020, silenceTimeoutMs: 60_000, classifier: script)
        let engine = makeEngine(segmenter: segmenter, capture: capture)
        engine.installCaptureCallbacksForTesting()

        // Queue a buffer while the old tap is live, without letting it reach the segmenter yet.
        capture.hold(samples: [Float](repeating: 0.5, count: 320))
        engine.stop()
        drainMainQueue()
        XCTAssertFalse(segmenter.isStuckActive)

        // Release it now that the session has been replaced.
        capture.releaseHeld()
        drainMainQueue()

        XCTAssertFalse(
            segmenter.isStuckActive,
            "a buffer captured by the stopped tap was processed as new-session audio, so stale "
                + "PCM can shape the next utterance"
        )
        XCTAssertEqual(
            segmenter.activeSamples, 0,
            "stale samples were retained into the new session (\(segmenter.activeSamples) kept)"
        )
    }

    /// The full sequence: old buffer queued, stop, START, then the old buffer released.
    ///
    /// The restart overwrites the capture's current session, so a buffer that reads that value at
    /// delivery reports the NEW session and passes the fence. Ownership must travel with the
    /// buffer. Asserts no old sample, fault or utterance reaches the new session.
    func testAnOldBufferReleasedAfterARestartNeverReachesTheNewSession() {
        let capture = HoldableCapture()
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: 3)
        // Observe what reaches the segmenter. State alone cannot prove this: engine.start() resets
        // the segmenter, so a stale buffer that IS processed would then look identical to one that
        // was correctly dropped. The classifier is only consulted for accepted audio.
        let counting = CountingClassifier(wrapping: script)
        let segmenter = NativeVadSegmenter(threshold: 0.020, silenceTimeoutMs: 60_000, classifier: counting)
        let engine = makeEngine(segmenter: segmenter, capture: capture)
        var utterances = 0
        var faults = 0
        segmenter.onUtterance = { _, _ in utterances += 1 }
        segmenter.onStuckActiveFault = { _ in faults += 1 }
        engine.installCaptureCallbacksForTesting()

        // Hold a buffer that alone would confirm speech, while the first tap is live.
        capture.hold(samples: Array(repeating: 0.5, count: 320 * 6))
        engine.stop()
        drainMainQueue()

        // Restart: the capture's session value now names the new tap.
        engine.start()
        let sessionsBefore = (segmenter.currentSession, segmenter.activeSamples)
        XCTAssertEqual(segmenter.activeSamples, 0, "restart did not reset segmentation state")

        // Release the OLD buffer now.
        capture.releaseHeld()
        drainMainQueue()

        XCTAssertEqual(
            counting.calls, 0,
            "the old buffer reached the segmenter (\(counting.calls) classifier call(s)), so stale "
                + "PCM was treated as new-session audio (session before=\(String(describing: sessionsBefore.0)))"
        )
        XCTAssertEqual(utterances, 0, "an utterance was assembled from stale PCM")
        XCTAssertEqual(faults, 0, "stale PCM raised a fault in the new session")
    }

    /// An ordinary partially buffered utterance must not survive a restart.
    ///
    /// This is not a fault, so clearing only the fault state leaves the partial buffer in place
    /// and old-session PCM concatenates with the new session's audio.
    func testAPartialUtteranceDoesNotSurviveARestart() {
        let capture = RecordingCapture()
        // Enough speech frames to CONFIRM (so real samples are retained in the utterance buffer)
        // but too few to close: the silence timeout is long, so nothing is dispatched and this is
        // a genuinely partial utterance rather than a fault.
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: 12)
        let segmenter = NativeVadSegmenter(threshold: 0.020, silenceTimeoutMs: 60_000, minSpeechFrames: 5, classifier: script)
        let engine = makeEngine(segmenter: segmenter, capture: capture)
        engine.installCaptureCallbacksForTesting()

        for _ in 0..<12 { capture.deliver(Array(repeating: 0.5, count: 320)) }
        XCTAssertFalse(segmenter.isStuckActive, "the case must not be a fault")
        XCTAssertGreaterThan(
            segmenter.activeSamples, 0,
            "the utterance was never confirmed, so a restart would not have anything to discard"
        )

        engine.stop()
        drainMainQueue()
        XCTAssertEqual(
            segmenter.activeSamples, 0,
            "a partial utterance survived the restart, so old and new session PCM can concatenate"
        )
    }

    /// A start-time classifier fault must survive its own main-queue delivery.
    ///
    /// Installing callbacks replays current state through the session fence; if the new session
    /// is established after that, the replay is tagged stale and dropped, so the user is refused
    /// capture with no explanation.
    func testStartupClassifierFaultSurvivesMainQueueDrain() {
        let capture = RecordingCapture()
        // Unavailability is decided at assembly, before the engine exists and before it can
        // install its forwarding — exactly the startup ordering that loses a one-shot event.
        let segmenter = NativeVadSegmenter(threshold: 0.02)
        segmenter.reportClassifierUnavailable("silero_vad.onnx could not be loaded from the app bundle")
        let engine = makeEngine(segmenter: segmenter, capture: capture)
        var unavailableReasons: [String] = []
        engine.onClassifierUnavailable = { unavailableReasons.append($0) }

        XCTAssertFalse(engine.start(), "start must be refused without a classifier")
        XCTAssertEqual(capture.startCount, 0, "capture was opened without a classifier")
        drainMainQueue()

        XCTAssertEqual(
            unavailableReasons.count, 1,
            "the startup fault was dropped as stale, so the refused start is unexplained"
        )
    }

    /// An explicit restart must clear a surfaced fault and its published state.
    ///
    /// `arch/ios.md` names "explicit listening restart" as an escape from the fault state. If
    /// stop/start leaves the fault set, the advertised escape does not exist: the user is told an
    /// interruption is ongoing with no way to clear it.
    func testExplicitRestartClearsASurfacedFault() {
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: Int.max)
        let segmenter = NativeVadSegmenter(threshold: 0.020, silenceTimeoutMs: 60_000, classifier: script)
        let engine = makeEngine(segmenter: segmenter)
        var faults: [VoiceAsrEngine.SegmentationFault] = []
        var recovered = 0
        engine.onSegmentationFault = { faults.append($0) }
        engine.onSegmentationFaultRecovered = { recovered += 1 }
        engine.installCaptureCallbacksForTesting()

        for _ in 0..<((240_000 / 20) + 10) { segmenter.process([Float](repeating: 0.1, count: 320)) }
        drainMainQueue()
        XCTAssertEqual(faults.count, 1, "the ceiling did not surface a fault")
        XCTAssertTrue(segmenter.isStuckActive)

        // The advertised escape: stop, then start again.
        engine.stop()
        drainMainQueue()
        XCTAssertFalse(
            segmenter.isStuckActive,
            "an explicit restart left the fault state set, so the escape path does not work"
        )
        XCTAssertEqual(recovered, 1, "the published interruption was not cleared on restart")
    }

    /// Routine frames must NOT clear the fault: only silence or an explicit restart may.
    ///
    /// Otherwise the tail of the still-spoken request becomes a new command.
    func testRoutineFramesDoNotClearTheFault() {
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: Int.max)
        let segmenter = NativeVadSegmenter(threshold: 0.020, silenceTimeoutMs: 60_000, classifier: script)
        var dispatched: [[Float]] = []
        segmenter.onUtterance = { (utterance: [Float], _: MonotonicTime?) in dispatched.append(utterance) }
        segmenter.onStuckActiveFault = { _ in }

        for _ in 0..<((240_000 / 20) + 10) { segmenter.process([Float](repeating: 0.1, count: 320)) }
        XCTAssertTrue(segmenter.isStuckActive)

        // Keep speaking: the tail must stay suppressed and the fault must stay set.
        for _ in 0..<200 { segmenter.process([Float](repeating: 0.1, count: 320)) }
        XCTAssertTrue(segmenter.isStuckActive, "routine positive frames cleared the fault")
        XCTAssertTrue(dispatched.isEmpty, "the tail was dispatched after the fault")
    }

    /// A classifier that was unavailable at construction must still reach an observer.
    ///
    /// Assembly decides availability before the engine installs its forwarding, so an event fired
    /// only at that moment is lost. The engine must learn the current state when it wires up.
    func testClassifierUnavailabilitySurvivesTheStartupOrdering() {
        let segmenter = NativeVadSegmenter(threshold: 0.020)
        // Same order as assembly: report BEFORE the engine exists and installs callbacks.
        segmenter.reportClassifierUnavailable("silero_vad.onnx could not be loaded from the app bundle")

        let engine = makeEngine(segmenter: segmenter)
        var faults: [VoiceAsrEngine.SegmentationFault] = []
        engine.onSegmentationFault = { faults.append($0) }
        engine.installCaptureCallbacksForTesting()
        drainMainQueue()

        XCTAssertEqual(
            faults.count, 1,
            "the startup-time unavailability was lost: the engine installed its forwarding after "
                + "the only notification, so nothing can show the interruption"
        )
        XCTAssertEqual(faults.first?.kind, .classifierUnavailable)
        XCTAssertTrue(engine.isClassifierUnavailable)
    }

    /// Starting capture without a classifier must be refused.
    ///
    /// Otherwise the microphone opens and can never close an utterance, which presents a broken
    /// pipeline as listening.
    func testStartIsRefusedWhenNoClassifierIsAvailable() {
        let segmenter = NativeVadSegmenter(threshold: 0.020)
        segmenter.reportClassifierUnavailable("model missing")
        let capture = RecordingCapture()
        let engine = VoiceAsrEngine(
            capture: capture,
            segmenter: segmenter,
            backend: WhisperCppBackend(modelPath: "/tmp/test"),
            signalFilter: SignalFilter(),
            wakeWordDetector: SilentDetector(),
            gracePeriodSignal: GracePeriodSignal()
        )

        XCTAssertFalse(engine.start(), "start reported success with no speech classifier")
        XCTAssertEqual(capture.startCount, 0, "capture was opened even though nothing can segment it")
    }

    /// Recovery must clear the surfaced fault.
    func testRecoveryClearsTheSurfacedFault() {
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: Int.max)
        let segmenter = NativeVadSegmenter(threshold: 0.020, silenceTimeoutMs: 20, classifier: script)
        let engine = makeEngine(segmenter: segmenter)
        var faults: [VoiceAsrEngine.SegmentationFault] = []
        var recovered = 0
        engine.onSegmentationFault = { faults.append($0) }
        engine.onSegmentationFaultRecovered = { recovered += 1 }
        engine.installCaptureCallbacksForTesting()

        for _ in 0..<((240_000 / 20) + 10) { segmenter.process([Float](repeating: 0.1, count: 320)) }
        drainMainQueue()
        XCTAssertEqual(faults.count, 1, "the ceiling did not surface a fault")

        script.silenceAfterSpeech = true
        let deadline = Date().addingTimeInterval(0.12)
        while Date() < deadline { segmenter.process([Float](repeating: 0, count: 320)) }
        drainMainQueue()

        XCTAssertEqual(
            recovered, 1,
            "recovery was not announced, so a listener would keep presenting an interruption that "
                + "has already ended"
        )
        XCTAssertFalse(segmenter.isStuckActive)
    }

    /// A missing classifier must be observable too, not just logged.
    ///
    /// Asserts through the segmenter's own callback — the exact seam the engine forwards from —
    /// because a flag plus a log line is not the surfaced state the spec requires.
    func testClassifierUnavailabilityReachesAnEngineObserver() {
        let segmenter = NativeVadSegmenter(threshold: 0.020)
        var faults: [NativeVadSegmenter.ClassifierUnavailableFault] = []
        var dispatched: [[Float]] = []
        segmenter.onClassifierUnavailable = { faults.append($0) }
        segmenter.onUtterance = { (utterance: [Float], _: MonotonicTime?) in dispatched.append(utterance) }

        segmenter.reportClassifierUnavailable("model missing")
        for _ in 0..<50 { segmenter.process([Float](repeating: 0.3, count: 320)) }

        XCTAssertEqual(faults.count, 1, "classifier unavailability was not surfaced through its callback")
        XCTAssertEqual(faults.first?.reason, "model missing")
        XCTAssertTrue(dispatched.isEmpty, "no classifier must mean no dispatch")
    }
}

/// The interruption must reach the user, not only a stored value.
///
/// `arch/ios.md` requires a surfaced interruption. Published state that nothing renders leaves
/// the user with unexplained silence, so this asserts the product's actual feedback consumer:
/// the earcon the service asks the renderer to play.
final class SegmentationFaultAudibleFeedbackControl: XCTestCase {
    func testPresentingAFaultRequestsAudibleFeedbackAndPublishesState() {
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: FakeAudioSessionControlling(),
            capture: RecordingCapture()
        )
        guard let service else { return XCTFail("service could not be built") }

        var earcons: [EarconId] = []
        service.earconObserverForTesting = { earcons.append($0) }

        XCTAssertNil(service.segmentationFault, "no fault should be presented before one occurs")
        service.presentSegmentationFault(VoiceAsrEngine.SegmentationFault(
            kind: .durationLimitReached,
            discardedSamples: 3_840_000,
            elapsedMs: 240_000,
            reason: nil
        ))

        XCTAssertNotNil(service.segmentationFault, "the interruption was not published")
        XCTAssertEqual(
            earcons, [.error],
            "no earcon was requested, so the interruption has no audible presentation"
        )
    }

    func testPresentingClassifierUnavailabilityRequestsFeedbackToo() {
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: FakeAudioSessionControlling(),
            capture: RecordingCapture()
        )
        guard let service else { return XCTFail("service could not be built") }
        var earcons: [EarconId] = []
        service.earconObserverForTesting = { earcons.append($0) }

        service.presentSegmentationFault(VoiceAsrEngine.SegmentationFault(
            kind: .classifierUnavailable,
            discardedSamples: 0,
            elapsedMs: 0,
            reason: "model missing"
        ))

        XCTAssertEqual(service.segmentationFault?.kind, .classifierUnavailable)
        XCTAssertEqual(earcons, [.error])
    }
}

/// A capture that can withhold a buffer and release it later, standing in for audio the tap
/// queued before `stop()`.
/// Counts classifications, which only happen for audio the segmenter accepted.
final class CountingClassifier: SpeechFrameClassifier {
    private let wrapped: SpeechFrameClassifier
    private(set) var calls = 0
    init(wrapping wrapped: SpeechFrameClassifier) { self.wrapped = wrapped }
    func isSpeech(_ samples: [Float]) -> Bool { calls += 1; return wrapped.isSpeech(samples) }
    func reset() { wrapped.reset() }
}

final class HoldableCapture: AudioCaptureSource {
    var onCapturedSamples: (([Float], MonotonicTime?, Int) -> Void)?
    var tapSession: Int = 0
    private var held: [Float]?
    private var heldAt: MonotonicTime?
    /// Session of the tap that queued the held buffer, frozen at hold time as the real tap does.
    private var heldSession: Int?
    private(set) var startCount = 0
    func start() throws { startCount += 1 }
    func stop() {}
    func hold(samples: [Float], at time: MonotonicTime? = nil) {
        held = samples
        heldAt = time
        heldSession = tapSession
    }
    func releaseHeld() {
        guard let held, let heldSession else { return }
        self.held = nil
        onCapturedSamples?(held, heldAt, heldSession)
    }
}

final class RecordingCapture: AudioCaptureSource {
    var onCapturedSamples: (([Float], MonotonicTime?, Int) -> Void)?
    var tapSession: Int = 0
    private(set) var startCount = 0
    func start() throws { startCount += 1 }
    func stop() {}
    /// Feeds a frame through the callback the engine installed, which is how a queued capture
    /// frame reaches the segmenter.
    func deliver(_ samples: [Float]) { onCapturedSamples?(samples, nil, tapSession) }
}
