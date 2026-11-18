import XCTest

@testable import podcasts

/// Early wake scoring must not change the answer.
///
/// Streaming detection exists to move the detector off the end-of-speech path, not to score
/// differently. The detector only scores classifier windows whose final embedding ends within the
/// eligible span after onset (~1.96s), so audio past that point cannot affect the maximum. Scoring
/// that prefix while the user is still speaking therefore has to produce exactly the score the
/// finished segment would.
///
/// These controls pin that equality on the segmenter's side: the prefix it hands over is exactly
/// the span that can matter, it is emitted once, and a short utterance never emits one at all. The
/// detector's contribution is covered by `StreamingWakeScoreEqualityTests`, which runs the real
/// detector over the same prefixes.
final class WakeScorablePrefixTests: XCTestCase {

    /// Reports speech until the test turns it off, and stays usable across utterances.
    ///
    /// `ScriptedSpeechClassifier` cannot be used here: it spends a fixed frame budget and its
    /// `reset()` deliberately does not replenish it, so a second utterance would never classify as
    /// speech and the re-arm control would fail for a reason unrelated to the re-arm.
    private final class SwitchableClassifier: SpeechFrameClassifier {
        var speaking = true
        func isSpeech(_ samples: [Float]) -> Bool { speaking }
        func reset() {}
    }

    private func makeSegmenter() -> NativeVadSegmenter {
        NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: SwitchableClassifier())
    }

    /// The prefix must be exactly the eligible span — not the whole buffer, and not a shorter
    /// guess. A longer prefix would make the early score depend on how long the user kept talking;
    /// a shorter one could miss the window that decides the maximum.
    func test_prefixIsTheEligibleSpan() {
        let segmenter = makeSegmenter()
        var prefixes: [[Float]] = []
        segmenter.onWakeScorablePrefix = { prefixes.append($0) }

        // Enough speech to pass the threshold, delivered in 20ms frames.
        let frame = 320
        let totalFrames = (NativeVadSegmenter.wakeEligibleSpanSamples / frame) + 20
        for _ in 0..<totalFrames {
            segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
        }

        XCTAssertEqual(prefixes.count, 1, "the prefix must be emitted exactly once per utterance")
        XCTAssertEqual(prefixes.first?.count, NativeVadSegmenter.wakeEligibleSpanSamples,
                       "the prefix must be the eligible span, not the in-progress buffer")
    }

    /// A prefix already emitted must not be emitted again while the utterance continues. Scoring
    /// repeatedly would re-run the detector on every frame for no change in result.
    func test_prefixIsEmittedOncePerUtterance() {
        let segmenter = makeSegmenter()
        var count = 0
        segmenter.onWakeScorablePrefix = { _ in count += 1 }

        let frame = 320
        for _ in 0..<((NativeVadSegmenter.wakeEligibleSpanSamples / frame) * 3) {
            segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
        }
        XCTAssertEqual(count, 1, "a longer utterance must not emit a second prefix")
    }

    /// A short utterance never produces a prefix: there is nothing to score early, and it is
    /// handled at end of speech exactly as before. An implementation that emitted a partial prefix
    /// would score audio that cannot contain the deciding window.
    func test_shortUtteranceEmitsNoPrefix() {
        let segmenter = makeSegmenter()
        var emitted = false
        segmenter.onWakeScorablePrefix = { _ in emitted = true }

        let frame = 320
        // 0.5s of speech: well under the eligible span.
        for _ in 0..<(8_000 / frame) {
            segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
        }
        XCTAssertFalse(emitted, "a segment shorter than the eligible span must not score early")
    }

    /// The next utterance scores early again. Without the per-utterance reset only the first
    /// command of a session would be scored early and every later one would silently fall back to
    /// end-of-speech scoring — a regression invisible in output, because the fallback still works.
    func test_prefixIsReEmittedForTheNextUtterance() async {
        let classifier = SwitchableClassifier()
        let segmenter = NativeVadSegmenter(threshold: 0.0, silenceTimeoutMs: 500, classifier: classifier)
        var count = 0
        segmenter.onWakeScorablePrefix = { _ in count += 1 }

        let frame = 320
        let speechFrames = (NativeVadSegmenter.wakeEligibleSpanSamples / frame) + 5
        func speakLongUtterance() {
            classifier.speaking = true
            for _ in 0..<speechFrames {
                segmenter.process([Float](repeating: 0.1, count: frame), capturedAt: nil)
            }
        }
        // The endpoint needs real elapsed time: the segmenter compares wall-clock against the
        // silence timeout, so feeding silence frames faster than real time never closes the
        // utterance. Waiting is the honest way to cross a real time threshold; faking it would
        // test a code path that does not exist.
        func endUtterance() async {
            classifier.speaking = false
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                segmenter.process([Float](repeating: 0, count: frame), capturedAt: nil)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        speakLongUtterance()
        await endUtterance()
        XCTAssertEqual(count, 1, "the first utterance scored early")

        speakLongUtterance()
        XCTAssertEqual(count, 2, "the second utterance must score early too")
    }
}