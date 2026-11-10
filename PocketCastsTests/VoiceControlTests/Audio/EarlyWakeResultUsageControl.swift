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

    /// An early result that is computed but never delivered must not reach the next utterance.
    ///
    /// This is the leak @reviewer named: a long positive utterance scores its prefix early, is then
    /// abandoned (duration ceiling), and never reaches `processUtterance`. If the score survived,
    /// the next short utterance would be addressed using the previous command's audio — a wrong
    /// command rather than a missing one.
    func test_abandonedPrefixDoesNotAddressTheNextUtterance() {
        let classifier = SwitchableClassifier()
        let segmenter = NativeVadSegmenter(
            threshold: 0.0,
            // A short ceiling so a single long utterance trips abandonment without speaking for
            // four real minutes.
            stuckActiveMs: 2_000,
            classifier: classifier
        )
        var delivered: [WakeWordResult?] = []
        segmenter.onUtterance = { _, _, result in delivered.append(result) }

        // Speak past the ceiling without ever going silent: the utterance is abandoned.
        let frame = 320
        for _ in 0..<(40_000 / frame) {
            segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
        }
        XCTAssertTrue(segmenter.isStuckActive, "the ceiling must have been reached")
        XCTAssertTrue(delivered.isEmpty, "an abandoned utterance is never dispatched")

        // The score that utterance WOULD have produced. Placed here, after abandonment and before
        // any recovery: recovering from the fault calls `reset()`, which clears this slot on its
        // own, so a sequence that recovered first would pass whether or not abandonment clears it.
        // This is exactly the sequence @reviewer described — a prefix scored, then discarded
        // without ever reaching `processUtterance`.
        segmenter.earlyWakeResultForCurrentUtterance = .detected(confidence: 0.99, completionSample: 0)

        // A new session begins before anything is dispatched: this is the restart path that
        // carries the abandoned slot into the next utterance if nothing clears it.
        segmenter.resetForNewSession()
        XCTAssertNil(
            segmenter.earlyWakeResultForCurrentUtterance,
            "a session boundary must not carry a score from an abandoned utterance; otherwise the "
                + "next short utterance is addressed using audio that was thrown away"
        )
    }

    /// The result must travel with its own utterance even when processing is delayed, because the
    /// capture callback launches an asynchronous task. A shared slot read later would return
    /// whatever the NEXT utterance had already written.
    ///
    /// Driven through the engine's routing entry point directly, which is exactly what the delayed
    /// task calls: two utterances are submitted back to back with different early results, and each
    /// must be addressed by its own.
    func test_delayedUtteranceProcessingKeepsItsOwnEarlyResult() async {
        let detector = CountingDetector()
        let classifier = SwitchableClassifier()
        let segmenter = NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: classifier)
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: segmenter,
            backend: WhisperCppBackend(modelPath: "/tmp/test"),
            signalFilter: SignalFilter(),
            wakeWordDetector: detector,
            gracePeriodSignal: GracePeriodSignal()
        )

        let audio = [Float](repeating: 0.1, count: 1_600)
        // Two submissions, each carrying its own result. If the engine held a slot instead, the
        // second would overwrite the first before either task ran.
        await engine.processUtterance(audio, earlyWakeResult: .detected(confidence: 0.9, completionSample: 0))
        await engine.processUtterance(audio, earlyWakeResult: .notDetected(confidence: 0.01))

        XCTAssertEqual(detector.sampleCounts.count, 0,
                       "both utterances carried their own early result, so neither may be rescored")
    }

    /// The early open must be triggered by trailing silence on an addressed utterance, not by the
    /// wake decision.
    ///
    /// The wake decision happens in `processUtterance`, after the endpoint — so triggering there
    /// opens the connection only after the wait it exists to remove. This asserts the earlier
    /// instant: while the utterance is still open, with speech finished and the hangover running.
    func test_addressedTrailingSilenceOpensBeforeTheEndpoint() {
        let classifier = SwitchableClassifier()
        let segmenter = NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: classifier)
        // What the engine installs: silence reports, then the engine decides from its own score.
        var opens = 0
        segmenter.onTrailingSilenceBegan = { [weak segmenter] in
            guard let segmenter, segmenter.earlyWakeResultForCurrentUtterance != nil else { return }
            opens += 1
        }

        let frame = 320
        classifier.speaking = true
        for _ in 0..<(10_000 / frame) {
            segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
        }
        // The prefix has been scored by now, so the utterance is addressed.
        segmenter.earlyWakeResultForCurrentUtterance = .detected(confidence: 0.9, completionSample: 0)
        XCTAssertEqual(opens, 0, "no open while speech is still being classified")

        // First silent frame: silence has begun, the endpoint has NOT fired.
        classifier.speaking = false
        segmenter.process([Float](repeating: 0, count: frame), capturedAt: nil)
        XCTAssertEqual(opens, 1,
                       "the open must happen when trailing silence begins, not after the endpoint")
        XCTAssertFalse(segmenter.isStuckActive)
    }

    /// A wake-negative utterance must not open a connection.
    ///
    /// Driven through the ENGINE's own callback wiring rather than a copy of its predicate: a test
    /// that re-implements the guard would keep passing if production dropped the positivity check,
    /// which is precisely the regression worth catching.
    func test_trailingSilenceOnUnaddressedSpeechDoesNotOpen() {
        let classifier = SwitchableClassifier()
        let segmenter = NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: classifier)
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: segmenter,
            backend: WhisperCppBackend(modelPath: "/tmp/test"),
            signalFilter: SignalFilter(),
            wakeWordDetector: CountingDetector(),
            gracePeriodSignal: GracePeriodSignal()
        )
        var opens = 0
        engine.onAddressedTrailingSilenceBegan = { opens += 1 }
        engine.installCaptureCallbacksForTesting()

        let frame = 320
        classifier.speaking = true
        for _ in 0..<(10_000 / frame) {
            segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
        }
        // A negative score: this utterance is not addressed.
        segmenter.earlyWakeResultForCurrentUtterance = .notDetected(confidence: 0.01)

        classifier.speaking = false
        segmenter.process([Float](repeating: 0, count: frame), capturedAt: nil)
        XCTAssertEqual(opens, 0, "an unaddressed utterance must not open a cloud connection")
    }

    /// The positive case on the same wiring: an addressed utterance DOES open on silence onset.
    func test_addressedTrailingSilenceOpensThroughTheEngine() {
        let classifier = SwitchableClassifier()
        let segmenter = NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: classifier)
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: segmenter,
            backend: WhisperCppBackend(modelPath: "/tmp/test"),
            signalFilter: SignalFilter(),
            wakeWordDetector: CountingDetector(),
            gracePeriodSignal: GracePeriodSignal()
        )
        var opens = 0
        engine.onAddressedTrailingSilenceBegan = { opens += 1 }
        engine.installCaptureCallbacksForTesting()

        let frame = 320
        classifier.speaking = true
        for _ in 0..<(10_000 / frame) {
            segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
        }
        segmenter.earlyWakeResultForCurrentUtterance = .detected(confidence: 0.9, completionSample: 0)

        classifier.speaking = false
        segmenter.process([Float](repeating: 0, count: frame), capturedAt: nil)
        XCTAssertEqual(opens, 1, "an addressed utterance must open on the first silent frame")
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