import XCTest

@testable import podcasts

/// Streaming wake detection must produce exactly the windows and maximum score that scoring the
/// finished segment would. If it does not, the same utterance can be addressed to Auris or not
/// depending only on when the detection ran — which is a correctness bug, not a latency tradeoff.
///
/// These controls pin the geometry rather than a score. The detector admits classifier windows
/// whose final embedding ends within the eligible span after onset; the last one ends just inside
/// 2 seconds. `StreamingWakePolicy.finalWindowEndSeconds` must agree with that, because it decides
/// when the streaming result is acted on.
final class StreamingWakeWindowTests: XCTestCase {

    /// The detector's own constants, restated here so a change on either side fails this test
    /// instead of silently moving the deadline.
    private enum Detector {
        static let melFrameStrideSamples = 160
        static let embedStrideMelFrames = 8
        static let melWindowFrames = 76
        static let virtualContextSamples = 32_000
        static let onsetCutoffSamples = 32_000
        static let sampleRate = 16_000
        static let classifierContext = 16
    }

    /// Recomputes the endpoint of the last eligible window from the geometry, and asserts the
    /// policy's deadline matches it. The endpoint must remain INSIDE the eligible span: a window
    /// that ends beyond it is not scored at all, so treating its position as the deadline would
    /// make the pipeline wait for audio that never contributes.
    func test_policyDeadlineMatchesTheLastEligibleWindowEndpoint() {
        let embedStride = Detector.embedStrideMelFrames * Detector.melFrameStrideSamples
        let embedOffset = Detector.melWindowFrames * Detector.melFrameStrideSamples
        let maxLastEmbeddingIndex =
            (Detector.virtualContextSamples + Detector.onsetCutoffSamples - embedOffset) / embedStride
        let maxWindowStart = maxLastEmbeddingIndex - (Detector.classifierContext - 1)
        let lastEndpointSamples = embedOffset + embedStride * (maxWindowStart + Detector.classifierContext - 1)
            - Detector.virtualContextSamples
        let lastEndpointSeconds = Double(lastEndpointSamples) / Double(Detector.sampleRate)

        XCTAssertLessThanOrEqual(lastEndpointSamples, Detector.onsetCutoffSamples,
                                 "the last eligible window must end inside the eligible span")
        XCTAssertEqual(StreamingWakePolicy.finalWindowEndSeconds, lastEndpointSeconds, accuracy: 0.001,
                       "the streaming deadline must be the detector's real last-window endpoint, "
                       + "otherwise it waits past the windows that actually count")
    }

    /// The spec's "2 seconds after onset" is the eligible span, and no eligible window may end
    /// later than that. Stated separately from the exact endpoint so a future geometry change
    /// that overruns the span fails even if both sides move together.
    func test_noEligibleWindowEndsAfterTwoSeconds() {
        let embedStride = Detector.embedStrideMelFrames * Detector.melFrameStrideSamples
        let embedOffset = Detector.melWindowFrames * Detector.melFrameStrideSamples
        let maxLastEmbeddingIndex =
            (Detector.virtualContextSamples + Detector.onsetCutoffSamples - embedOffset) / embedStride
        let maxWindowStart = maxLastEmbeddingIndex - (Detector.classifierContext - 1)
        let lastEndpointSamples = embedOffset + embedStride * (maxWindowStart + Detector.classifierContext - 1)
            - Detector.virtualContextSamples
        XCTAssertLessThanOrEqual(Double(lastEndpointSamples) / Double(Detector.sampleRate), 2.0)
    }

    /// Once the final window's audio exists there is nothing left to wait for, so a result is
    /// final and the end-of-speech decision must not add a wait.
    func test_resultIsFinalOnceTheLastWindowHasAudio() {
        XCTAssertTrue(StreamingWakePolicy.isFinal(speechSeconds: StreamingWakePolicy.finalWindowEndSeconds))
        XCTAssertFalse(StreamingWakePolicy.mustWaitAtEndOfSpeech(
            speechSeconds: StreamingWakePolicy.finalWindowEndSeconds))
        XCTAssertEqual(StreamingWakePolicy.endOfSpeechWaitSeconds(
            speechSeconds: StreamingWakePolicy.finalWindowEndSeconds), 0)
    }

    /// A segment shorter than the final window cannot be final yet, so the end-of-speech decision
    /// must wait — and the wait is bounded by the window's own position, which is what makes it
    /// brief.
    func test_shortSegmentWaitsBrieflyAtEndOfSpeech() {
        XCTAssertTrue(StreamingWakePolicy.mustWaitAtEndOfSpeech(speechSeconds: 0.5))
        XCTAssertLessThanOrEqual(StreamingWakePolicy.endOfSpeechWaitSeconds(speechSeconds: 0.5), 2.0)
        // Just below the deadline, not just below 2s: the deadline is the last window's endpoint
        // (1.96s), so 1.99 is already final and asserting otherwise would be testing 2.0 as if it
        // were the cutoff.
        XCTAssertTrue(StreamingWakePolicy.mustWaitAtEndOfSpeech(speechSeconds: 1.9))
    }

    /// A long utterance is final well before it ends: scoring started at onset, so by the time the
    /// user stops speaking there is nothing to wait for. This is the case streaming detection
    /// exists to remove the wait from, and an implementation that waited on every segment would
    /// pass the short-segment test while losing the entire benefit.
    func test_longUtteranceWaitsForNothingAtEndOfSpeech() {
        XCTAssertTrue(StreamingWakePolicy.isFinal(speechSeconds: 5.0))
        XCTAssertEqual(StreamingWakePolicy.endOfSpeechWaitSeconds(speechSeconds: 5.0), 0)
    }
}