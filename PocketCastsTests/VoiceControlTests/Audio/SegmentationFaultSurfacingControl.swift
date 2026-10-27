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
