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
        segmenter.onSpeechAccumulated = { _, bufferCount in counts.append(bufferCount) }

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

    /// The accumulation hook carries the ACTUAL new PCM, not a count or a placeholder: the slice appended is
    /// byte-for-byte the samples this call added to the segmenter's own buffer. A contribution copy built
    /// from these slices equals the segmenter's buffer exactly — which is what makes "the collector retains
    /// real audio" verifiable rather than claimed.
    func test_onSpeechAccumulated_carriesActualNewPCM() {
        let segmenter = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 2)
        var slices: [[Float]] = []
        segmenter.onSpeechAccumulated = { newSamples, _ in slices.append(Array(newSamples)) }

        // All above the 0.5 RMS threshold (rms of a constant frame is its amplitude).
        let a = [Float](repeating: 0.6, count: 320)
        let b = [Float](repeating: 0.7, count: 320)
        let c = [Float](repeating: 0.9, count: 320)
        segmenter.process(a)
        segmenter.process(b)          // confirms here (minSpeechFrames = 2)
        segmenter.process(c)

        XCTAssertEqual(slices.count, 2, "only post-confirmation calls carry PCM")
        // CONFIRMATION DELIVERS THE WHOLE CONFIRMED PREFIX (a + b) exactly once; later calls deliver only
        // their own delta. Pre-confirmation frames are part of the segment (the segmenter kept them), so
        // losing them would make the contribution copy permanently shorter than the emitted audio.
        XCTAssertEqual(slices[0], a + b, "confirmation delivers the buffered prefix exactly once")
        XCTAssertEqual(slices[1], c, "later calls deliver only their own delta")

        // Reconstructing from the delivered slices equals the segmenter's retained audio — no duplication.
        var reconstructed: [Float] = []
        reconstructed.append(contentsOf: slices[0])
        reconstructed.append(contentsOf: slices[1])
        XCTAssertEqual(reconstructed, a + b + c)
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
        instrumented.onSpeechAccumulated = { _, _ in }
        instrumented.onSpeechCancelled = { }
        instrumented.process(speech); instrumented.process(speech); instrumented.process(silence)

        XCTAssertEqual(observed, baseline, "instrumentation changed the audio handed to recognition")
    }

    /// Pre-speech frames dropped by confirmation are NOT part of the segment, and the collector must not see
    /// them as contribution audio (spec: no synthetic detector padding persisted).
    func test_accumulationDoesNotReportDiscardedPreSpeech() {
        let segmenter = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 3)
        var counts: [Int] = []
        segmenter.onSpeechAccumulated = { _, bufferCount in counts.append(bufferCount) }

        // Two interrupted bursts: each is discarded before confirmation.
        segmenter.process(speech); segmenter.process(speech); segmenter.process(silence)
        segmenter.process(speech); segmenter.process(speech); segmenter.process(silence)
        XCTAssertTrue(counts.isEmpty, "unconfirmed bursts must not surface as accumulated contribution audio")
    }


    /// End-to-end PCM parity: after a full segment flows through the real engine wiring (segmenter slices →
    /// collector appendSamples), the collector's retained copy must equal the segmenter's buffer BYTE FOR
    /// BYTE — including the confirming frame. A count-based or placeholder path diverges here.
    func test_contributionCopy_matchesSegmenterBufferByteForByte() {
        let segmenter = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 2)
        let delivered = LockedBoxes()
        segmenter.onSpeechAccumulated = { newSamples, total in
            delivered.appendSegmenter(samples: Array(newSamples), total: total)
        }

        let speech1 = [Float](repeating: 0.6, count: 320)
        let speech2 = [Float](repeating: 0.75, count: 320)
        let speech3 = [Float](repeating: 0.9, count: 320)
        let hangover = [Float](repeating: 0.05, count: 320)

        // Collector side: same calls the engine's hook makes.
        let policy = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        policy.identityBecameReadable()
        _ = policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart())
        var enrolled = VoiceSharingEnrollmentStore.State()
        enrolled.localOptIn = true
        enrolled.hasAuthoritativeProjection = true
        enrolled.membership = VoiceSharingMembership(
            membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
            enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09",
            withdrawalState: .active
        )
        let collector = VoiceSharingCollector(policy: policy, membership: { enrolled },
                                              epochProvider: { "epoch-1" },
                                              sessionIdentity: { "gen-A" })
        collector.deliversSynchronouslyForTesting = true

        segmenter.process(speech1)
        segmenter.process(speech2)          // confirms here
        if let ctx = collector.speechStarted(confirmationFrameSamples: 320) {
            // Engine wires onSpeechAccumulated to appendSamples; replay exactly what was delivered.
            for call in delivered.segmenterCalls {
                collector.appendSamples(call.samples, reportedTotal: call.total)
            }
            segmenter.process(speech3)
            delivered.replayInto(collector)
            segmenter.process(hangover)     // silence -> immediate natural end
            delivered.replayInto(collector)

            var utterance: [Float] = []
            segmenter.onUtterance = { utterance = $0 }
            segmenter.process([Float](repeating: 0.001, count: 320))
            collector.speechCompleted(utterance, context: ctx)

            XCTAssertEqual(collector.retainedCopyForTesting, utterance,
                           "the contribution copy must equal the segmenter's emitted audio byte for byte")
        } else {
            XCTFail("premise: capture should open")
        }
    }
}

/// Thread-safe record of what the segmenter delivered, so the test can replay it into the collector the way
/// the engine's hook does.
private final class LockedBoxes {
    private let lock = NSLock()
    private var calls: [(samples: [Float], total: Int)] = []
    var segmenterCalls: [(samples: [Float], total: Int)] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
    func appendSegmenter(samples: [Float], total: Int) {
        lock.lock(); calls.append((samples, total)); lock.unlock()
    }
    func replayInto(_ collector: VoiceSharingCollector) {
        for c in segmenterCalls { collector.appendSamples(c.samples, reportedTotal: c.total) }
    }
}
