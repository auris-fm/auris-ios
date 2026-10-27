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

    /// Capture stub that records whether the microphone was actually opened, so "refused to
    /// listen" can be asserted as "capture never started" rather than inferred from a return value.
    private final class RecordingCapture: AudioCaptureSource {
        var onCapturedSamples: (([Float], MonotonicTime?) -> Void)?
        private(set) var startCount = 0

        func start() throws { startCount += 1 }
        func stop() {}
    }

    /// Fault deliveries hop to the main actor, so a control must drain that queue before
    /// asserting. Draining also preserves the order the deliveries were produced in.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func makeEngine(segmenter: NativeVadSegmenter) -> VoiceAsrEngine {
        VoiceAsrEngine(
            capture: NativeAudioCapture(),
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

        XCTAssertNil(service.segmentationFault, "no fault should be presented before one occurs")
        service.presentSegmentationFault(VoiceAsrEngine.SegmentationFault(
            kind: .durationLimitReached,
            discardedSamples: 3_840_000,
            elapsedMs: 240_000,
            reason: nil
        ))

        XCTAssertNotNil(service.segmentationFault, "the interruption was not published")
        XCTAssertEqual(
            service.playedEarconsForTesting, [.error],
            "no earcon was requested, so the interruption has no audible presentation"
        )
    }

    func testPresentingClassifierUnavailabilityRequestsFeedbackToo() {
        let service = VoiceControlAssembly().buildVoiceControlService(
            audioSession: FakeAudioSessionControlling(),
            capture: RecordingCapture()
        )
        guard let service else { return XCTFail("service could not be built") }

        service.presentSegmentationFault(VoiceAsrEngine.SegmentationFault(
            kind: .classifierUnavailable,
            discardedSamples: 0,
            elapsedMs: 0,
            reason: "model missing"
        ))

        XCTAssertEqual(service.segmentationFault?.kind, .classifierUnavailable)
        XCTAssertEqual(service.playedEarconsForTesting, [.error])
    }
}

final class RecordingCapture: AudioCaptureSource {
    var onCapturedSamples: (([Float], MonotonicTime?) -> Void)?
    func start() throws {}
    func stop() {}
}
