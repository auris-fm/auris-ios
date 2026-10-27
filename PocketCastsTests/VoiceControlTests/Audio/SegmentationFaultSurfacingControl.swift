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
        XCTAssertEqual(faults.count, 1, "the ceiling did not surface a fault")

        script.silenceAfterSpeech = true
        let deadline = Date().addingTimeInterval(0.12)
        while Date() < deadline { segmenter.process([Float](repeating: 0, count: 320)) }

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
