import XCTest
@testable import podcasts

/// Task 3, part 1: the observe-only hooks the contribution collector needs on the real segmenter.
///
/// The plan verified that accumulation happens privately inside `process(_:)` and that only completion is
/// observable (`onUtterance`). A collector that keys off completion cannot satisfy three spec rules:
///
///   * `capture_id` must be assigned when an eligible segment BEGINS, before wake/bleed rejection decisions
///     exist — those rejections are silent `return`s downstream, so a completion-only view never sees them.
///   * Long in-progress speech must be admitted against clip ceilings BEFORE completion, because a segment
///     that never completes (permission closes mid-speech) still must not exceed memory/disk bounds.
///   * A reset while speech is active must CANCEL the partial contribution rather than emit it.
///
/// These tests pin the hooks' contract WITHOUT changing any buffer or timing semantics: recognition behaviour
/// stays byte-identical, which the existing NativeAudioCaptureTests already prove for retention.
final class VoiceSharingCollectorSegmenterHookTests: XCTestCase {

    private let speech = [Float](repeating: 1.0, count: 320)
    private let silence = [Float](repeating: 0.0, count: 320)

    /// Confirmed start fires at `minSpeechFrames`, not at the first energetic frame: an unconfirmed burst is
    /// discarded by design and must not open a contribution.
    func test_onSpeechStarted_firesAtConfirmation_notOnPendingEnergy() {
        let segmenter = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 3)
        var starts = 0
        segmenter.onSpeechStarted = { _ in starts += 1 }

        segmenter.process(speech)          // pending 1
        XCTAssertEqual(starts, 0, "an unconfirmed burst must not open a contribution")
        segmenter.process(silence)         // interruption resets the pending count
        XCTAssertEqual(starts, 0)

        for _ in 0..<3 { segmenter.process(speech) }
        XCTAssertEqual(starts, 1, "confirmation opens exactly one contribution")

        // Still inside the same utterance: no second start.
        segmenter.process(speech)
        segmenter.process(speech)
        XCTAssertEqual(starts, 1, "start is edge-triggered, not per-frame")
    }

    /// Incremental admission is what bounds long speech before completion. It reports how many samples are
    /// currently retained so the collector can enforce a ceiling while the utterance is still open.
    func test_onSpeechAccumulated_reportsRetainedSampleCount_whileActive() {
        let segmenter = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 2)
        var counts: [Int] = []
        segmenter.onSpeechAccumulated = { counts.append($0) }

        for _ in 0..<4 { segmenter.process(speech) }     // 2 to confirm, then 2 more retained
        XCTAssertFalse(counts.isEmpty, "accumulation must be observable while speech is active")
        XCTAssertEqual(counts.last!, 4 * 320, "reports the retained sample count, not the frame size")

        counts.removeAll()
        segmenter.process(silence)                        // silenceTimeoutMs = -1 -> immediate natural end
        XCTAssertEqual(counts, [5 * 320],
                       "the hangover frame is retained audio that belongs to this segment, so it is reported "
                     + "once before the emit; nothing is admitted after the segment closes")
        counts.removeAll()
        segmenter.process(speech)                         // idle again: a new burst is pending, not active
        XCTAssertEqual(counts, [], "no admission signal outside an open segment")
    }

    /// Reset while ACTIVE must be distinguishable from a natural end, because the collector cancels the
    /// partial instead of finalizing it. Reset while idle is nothing.
    func test_onSpeechCancelled_firesOnlyWhenResetDuringActiveSpeech() {
        let segmenter = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 2)
        var cancellations = 0
        var emissions = 0
        segmenter.onSpeechCancelled = { cancellations += 1 }
        segmenter.onUtterance = { _ in emissions += 1 }

        segmenter.reset()
        XCTAssertEqual(cancellations, 0, "reset with nothing open is not a cancellation")

        segmenter.process(speech)
        segmenter.process(speech)
        segmenter.reset()
        XCTAssertEqual(cancellations, 1, "reset during active speech cancels the in-progress contribution")
        XCTAssertEqual(emissions, 0, "and it must NOT emit an utterance — cancelling is not completing")

        // After cancelling, a fresh confirmation starts clean.
        segmenter.process(speech)
        segmenter.process(speech)
        segmenter.process(silence)
        XCTAssertEqual(emissions, 1, "the next segment proceeds normally")
        XCTAssertEqual(cancellations, 1, "a completed segment is not counted as a cancellation")
    }

    /// Hooks are observe-only: adding them must not change what recognition receives. This asserts the exact
    /// utterance bytes are unchanged with all three hooks attached.
    func test_hooks_areObserveOnly_recognitionAudioUnchanged() {
        let plain = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 2)
        var baseline: [[Float]] = []
        plain.onUtterance = { baseline.append($0) }
        plain.process(speech); plain.process(speech); plain.process(silence)

        let instrumented = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 2)
        var observed: [[Float]] = []
        instrumented.onUtterance = { observed.append($0) }
        instrumented.onSpeechStarted = { _ in }
        instrumented.onSpeechAccumulated = { _ in }
        instrumented.onSpeechCancelled = { }
        instrumented.process(speech); instrumented.process(speech); instrumented.process(silence)

        XCTAssertEqual(observed, baseline, "instrumentation changed the audio handed to recognition")
    }

    /// Pre-speech frames dropped by confirmation are NOT part of the segment, and the collector must not see
    /// them as contribution audio (spec: no synthetic detector padding persisted).
    func test_accumulationDoesNotReportDiscardedPreSpeech() {
        let segmenter = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 3)
        var counts: [Int] = []
        segmenter.onSpeechAccumulated = { counts.append($0) }

        // Two interrupted bursts: each is discarded before confirmation.
        segmenter.process(speech); segmenter.process(speech); segmenter.process(silence)
        segmenter.process(speech); segmenter.process(speech); segmenter.process(silence)
        XCTAssertTrue(counts.isEmpty, "unconfirmed bursts must not surface as accumulated contribution audio")
    }
}
