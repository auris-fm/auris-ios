import XCTest

@testable import podcasts

/// The engine must actually use the early wake result, not merely compute it.
///
/// The defect this guards against is the one that makes a policy look implemented: a prefix scored
/// while the user speaks, and then the finished segment scored again anyway. Both produce the same
/// decision, so nothing observable goes wrong — the latency saving simply never happens, and no
/// outcome test would notice.
final class EarlyWakeResultUsageControl: XCTestCase {

    /// Counts calls and answers distinguishably, so the control can tell WHICH audio was scored.
    private final class CountingDetector: WakeWordDetectorProtocol {
        private(set) var calls: [Int] = []
        private(set) var sampleCounts: [Int] = []

        func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
            calls.append(samples.count)
            sampleCounts.append(samples.count)
            // The prefix is shorter than the finished utterance, so the call order alone shows
            // whether the second (finished-segment) call happened.
            return .detected(confidence: 0.9, completionSample: samples.count - 1)
        }

        func release() {}
    }

    private final class SwitchableClassifier: SpeechFrameClassifier {
        var speaking = true
        func isSpeech(_ samples: [Float]) -> Bool { speaking }
        func reset() {}
    }

    private func makeEngine(detector: CountingDetector,
                            classifier: SwitchableClassifier,
                            segmenter segmenterIn: NativeVadSegmenter? = nil) -> VoiceAsrEngine {
        VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: segmenterIn ?? NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: classifier),
            backend: WhisperCppBackend(modelPath: "/tmp/test"),
            signalFilter: SignalFilter(),
            wakeWordDetector: detector,
            gracePeriodSignal: GracePeriodSignal()
        )
    }

    private func drainQueue() {
        let drained = expectation(description: "queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)
    }

    /// One detector call per utterance when the prefix was scored early. A second call would mean
    /// the finished segment was rescored, which is the latency regression in silence.
    func testEngineDoesNotRescoreTheFinishedSegmentWhenThePrefixWasScored() {
        let detector = CountingDetector()
        let classifier = SwitchableClassifier()
        let segmenter = NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: classifier)
        let engine = makeEngine(detector: detector, classifier: classifier, segmenter: segmenter)
        engine.installCaptureCallbacksForTesting()

        // Drive the segmenter directly through its own capture path: enough speech to cross the
        // eligible span, so the early prefix fires.
        let frame = 320
        let frames = (NativeVadSegmenter.wakeEligibleSpanSamples / frame) + 10
        for _ in 0..<frames {
            segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
        }
        XCTAssertEqual(detector.sampleCounts.count, 1, "the prefix must be scored while speaking")
        XCTAssertEqual(detector.sampleCounts.first, NativeVadSegmenter.wakeEligibleSpanSamples)

        // Close the utterance; a rescore would add a second, longer call.
        classifier.speaking = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            segmenter.process([Float](repeating: 0, count: frame), capturedAt: nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        drainQueue()

        XCTAssertEqual(detector.sampleCounts.count, 1,
                       "the finished segment must not be rescored when the prefix was already scored; "
                           + "calls seen: \(detector.sampleCounts)")
    }

    /// A result from a turn that never consumed it must not address the next turn. The failure
    /// would be a command answered using the previous command's audio.
    func testEarlyResultIsConsumedOncePerUtterance() {
        let detector = CountingDetector()
        let classifier = SwitchableClassifier()
        let segmenter = NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: classifier)
        let engine = makeEngine(detector: detector, classifier: classifier, segmenter: segmenter)
        engine.installCaptureCallbacksForTesting()

        let frame = 320
        let frames = (NativeVadSegmenter.wakeEligibleSpanSamples / frame) + 10
        func speak() {
            classifier.speaking = true
            for _ in 0..<frames {
                segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
            }
        }
        func close() {
            classifier.speaking = false
            let deadline = Date().addingTimeInterval(1.2)
            while Date() < deadline {
                segmenter.process([Float](repeating: 0, count: frame), capturedAt: nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            drainQueue()
        }

        speak()
        close()
        let afterFirst = detector.sampleCounts.count
        speak()
        close()

        // Each utterance contributes exactly one call: its own prefix. A leaked result would make
        // the second utterance skip its own scoring or reuse the first's count.
        XCTAssertEqual(detector.sampleCounts.count, afterFirst * 2,
                       "each utterance must score its own prefix exactly once; calls: \(detector.sampleCounts)")
        XCTAssertEqual(detector.sampleCounts.filter { $0 == NativeVadSegmenter.wakeEligibleSpanSamples }.count,
                       detector.sampleCounts.count,
                       "every call must be a prefix, never a finished segment")
    }
}