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

    /// The result must travel with its own utterance, exercised through the real callback
    /// handoff.
    ///
    /// @reviewer was right that the earlier version of this test called `processUtterance` with
    /// explicit results and never touched the callback, so it could not have caught a slot being
    /// overwritten — the defect it is named for. This drives the segmenter: two utterances are
    /// emitted with DIFFERENT early scores, and the values the callback delivered must match them.
    func test_twoUtterancesDeliverTheirOwnEarlyResults() {
        let classifier = SwitchableClassifier()
        let segmenter = NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: classifier)
        var delivered: [WakeWordResult?] = []
        segmenter.onUtterance = { _, _, result in delivered.append(result) }

        let frame = 320
        func speak(briefly: Bool, result: WakeWordResult?) {
            classifier.speaking = true
            let frames = briefly ? (6_000 / frame) : (10_000 / frame)
            for _ in 0..<frames {
                segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
            }
            // The score for THIS utterance, exactly as the engine's prefix callback sets it. When
            // nil the assignment is SKIPPED rather than writing nil: writing nil would erase a
            // stale value and hide the very defect this control exists to catch.
            if let result {
                segmenter.earlyWakeResultForCurrentUtterance = result
            }

            classifier.speaking = false
            let deadline = Date().addingTimeInterval(1.2)
            while Date() < deadline {
                segmenter.process([Float](repeating: 0, count: frame), capturedAt: nil)
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        speak(briefly: false, result: .detected(confidence: 0.93, completionSample: 0))
        // The second utterance's OWN value is deliberately left unset before it closes. Under the
        // old shared-slot defect the first utterance's score was still sitting there and would be
        // delivered as the second's; carrying the result with the utterance delivers nil instead.
        // This is what makes the control able to tell the two designs apart.
        speak(briefly: true, result: nil)

        XCTAssertEqual(delivered.count, 2, "both utterances must be delivered")
        guard delivered.count == 2 else { return }
        switch delivered[0] {
        case .detected(let confidence, _):
            XCTAssertEqual(confidence, 0.93, accuracy: 0.0001,
                           "the first utterance must carry its own positive score")
        default:
            XCTFail("the first utterance must carry the positive score, got \(String(describing: delivered[0]))")
        }
        XCTAssertNil(delivered[1] ?? nil,
                     "the second utterance scored nothing, so it must carry nothing — a shared slot "
                         + "would hand it the first utterance's positive score")
    }

    /// A wake-negative follow-up spoken during grace is a real turn and must open early.
    ///
    /// Requiring a positive wake score would open for first commands and never for follow-ups,
    /// which is the half a user in a conversation is most likely to be waiting on.
    func test_graceFollowUpOpensDespiteNegativeWake() {
        let classifier = SwitchableClassifier()
        let segmenter = NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: classifier)
        let grace = GracePeriodSignal()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: segmenter,
            backend: WhisperCppBackend(modelPath: "/tmp/test"),
            signalFilter: SignalFilter(),
            wakeWordDetector: CountingDetector(),
            gracePeriodSignal: grace
        )
        var opens = 0
        engine.onAddressedTrailingSilenceBegan = { opens += 1 }
        engine.installCaptureCallbacksForTesting()

        // Grace is active: the session was opened by a previous command.
        grace.onWakeWordDetected()

        let frame = 320
        classifier.speaking = true
        for _ in 0..<(10_000 / frame) {
            segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
        }
        segmenter.earlyWakeResultForCurrentUtterance = .notDetected(confidence: 0.01)

        classifier.speaking = false
        segmenter.process([Float](repeating: 0, count: frame), capturedAt: nil)
        XCTAssertEqual(opens, 1,
                       "a follow-up during grace is routable, so it must open the connection")
    }

    /// A short utterance has no early prefix at silence onset, so its open must happen later, when
    /// the wake result turns positive. Without this the most common short command never opens.
    func test_shortUtteranceOpensWhenItsResultTurnsPositive() {
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
        // Short speech: under the eligible span, so no early prefix is emitted.
        classifier.speaking = true
        for _ in 0..<(6_000 / frame) {
            segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
        }
        classifier.speaking = false
        segmenter.process([Float](repeating: 0, count: frame), capturedAt: nil)
        XCTAssertTrue(segmenter.isInTrailingSilence, "silence has begun")
        XCTAssertEqual(opens, 0, "nothing can open before the result exists")

        // The result arrives while the silence is still running. This calls production's own
        // decision function, so removing the check inside it turns this RED.
        engine.openEarlyConnectionForLateResultForTesting(
            result: .detected(confidence: 0.9, completionSample: 0)
        )
        XCTAssertEqual(opens, 1,
                       "once the result is final during silence, the open must happen — there is no "
                           + "second onset to wait for")
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