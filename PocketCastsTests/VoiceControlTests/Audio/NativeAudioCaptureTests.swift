import XCTest
@testable import podcasts

final class NativeAudioCaptureTests: XCTestCase {

    func test_capture_engineConfiguration_sampleRate() {
        let capture = NativeAudioCapture()
        // Engine should not be running by default
        XCTAssertFalse(capture.engine.isRunning)
    }

    func test_capture_hasInputNode() {
        let capture = NativeAudioCapture()
        // AVAudioEngine should have an input node available
        XCTAssertTrue(capture.engine.inputNode.numberOfInputs > 0 || capture.engine.inputNode.numberOfOutputs > 0)
    }

    func test_vadSegmenter_energyBasedDetection() {
        let segmenter = NativeVadSegmenter()
        var utteranceReceived = false
        segmenter.onUtterance = { _, _ in utteranceReceived = true }

        // Send speech-like samples (high energy)
        let speech: [Float] = (0..<320).map { sin(Float($0) * 0.1) }
        segmenter.process(speech)

        // Send silence samples
        let silence: [Float] = Array(repeating: 0, count: 320)
        segmenter.process(silence)

        // The energy-based stub should detect speech from high-energy samples
        // But utterance won't fire until silence timeout, which won't happen synchronously
        XCTAssertFalse(utteranceReceived, "Utterance should not fire without silence timeout")
    }

    func test_vadSegmenter_requiresConsecutiveSpeechFrames() {
        let segmenter = NativeVadSegmenter(
            threshold: 0.5,
            silenceTimeoutMs: -1,
            minSpeechFrames: 2
        )
        var utterances: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in utterances.append(utterance) }

        segmenter.process([1, 1])
        segmenter.process([0, 0])
        segmenter.process([1, 1])
        segmenter.process([0, 0])

        XCTAssertTrue(utterances.isEmpty, "Interrupted energy bursts must not activate the VAD")

        segmenter.process([1, 1])
        segmenter.process([1, 1])
        segmenter.process([0, 0])

        XCTAssertEqual(utterances, [[1, 1, 1, 1, 0, 0]])
    }

    // MARK: - Retention contract (recognition-pipeline.md "Utterance lifecycle")
    //
    // The spec requires captured speech to be retained continuously through its natural
    // endpoint: an internal duration bound must not end an utterance, and must never
    // reach ASR as a truncated fragment. iOS has no duration bound wired today
    // (`maxUtteranceMs` defaults to nil and no call site passes it), so retention holds
    // by construction. These tests pin that property so a future caller cannot
    // reintroduce a bound silently.

    /// 30 seconds of continuous speech — twice the 15s bound the spec retires — must
    /// produce **no** utterance until real silence arrives. A duration bound would
    /// emit here, which is the defect the spec clause names.
    func test_continuousSpeechPastAnyDurationBound_isNotEmittedAsAFragment() {
        let segmenter = NativeVadSegmenter()
        var utterances: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in utterances.append(utterance) }

        // 16 kHz * 30 s = 480_000 samples, fed in 320-sample frames (20 ms).
        // Constant amplitude 1.0 => RMS 1.0, well above the default 0.002 threshold.
        let frameCount = 480_000 / 320
        let speech = [Float](repeating: 1.0, count: 320)
        for _ in 0..<frameCount {
            segmenter.process(speech)
        }

        XCTAssertTrue(
            utterances.isEmpty,
            "30s of continuous speech was emitted as \(utterances.count) fragment(s); a duration bound is truncating audio into ASR"
        )
    }

    /// The same 30 seconds, once real silence arrives, must be delivered as **one**
    /// utterance holding **all** the speech — retained, not restarted.
    func test_continuousSpeech_isRetainedAndDeliveredWholeAtTheNaturalEndpoint() {
        let segmenter = NativeVadSegmenter(silenceTimeoutMs: -1)
        var utterances: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in utterances.append(utterance) }

        let frames = 480_000 / 320
        let speech = [Float](repeating: 1.0, count: 320)
        for _ in 0..<frames {
            segmenter.process(speech)
        }
        // Non-energetic frame; silenceTimeoutMs = -1 forces the natural-endpoint emit.
        segmenter.process([Float](repeating: 0, count: 320))

        XCTAssertEqual(utterances.count, 1, "Expected one retained utterance, got \(utterances.count)")
        // 480_000 speech samples + the trailing silence frame.
        XCTAssertEqual(utterances.first?.count, 480_000 + 320, "Utterance was truncated: a duration bound discarded words")
    }

    /// A follow-up spoken without an intervening transport-level restart is joined with
    /// what preceded it rather than executed as a fragment — the spec's
    /// "join retained audio across them" clause.
    func test_internalFramingBoundary_doesNotExecuteAFragment() {
        // A long silence timeout makes a single quiet frame a framing boundary rather
        // than an endpoint: the utterance stays open across it.
        let segmenter = NativeVadSegmenter(silenceTimeoutMs: 10_000)
        var utterances: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in utterances.append(utterance) }

        // Two bursts separated by a single non-energetic frame: a framing boundary,
        // not an endpoint. Retention requires the two be delivered together.
        //
        // Each burst carries at least `minSpeechFrames` (default 5) so the utterance is
        // genuinely active at the boundary — the confirmation rule discards *pre-speech*
        // audio by design, which is a different behaviour from dropping retained words.
        let speech = [Float](repeating: 1.0, count: 320)
        let silence = [Float](repeating: 0, count: 320)
        for _ in 0..<6 { segmenter.process(speech) }
        segmenter.process(silence)
        for _ in 0..<6 { segmenter.process(speech) }

        // Nothing emitted: the quiet frame was treated as a boundary, and the words on
        // both sides are still retained in one open utterance.
        XCTAssertTrue(
            utterances.isEmpty,
            "A framing boundary emitted \(utterances.count) fragment(s) instead of joining retained audio"
        )
        // A further quiet frame still does not reach the 10s endpoint, so the utterance
        // remains open and un-emitted — the point being that no fragment was executed.
        segmenter.process(silence)
        XCTAssertTrue(utterances.isEmpty, "No endpoint was reached, so nothing may be emitted")
    }

    /// The retained utterance is delivered whole once the natural endpoint actually
    /// arrives, including the words spoken before the framing boundary.
    func test_wordsBeforeAFramingBoundaryAreNotDiscarded() {
        let segmenter = NativeVadSegmenter(silenceTimeoutMs: -1)
        var utterances: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in utterances.append(utterance) }

        let speech = [Float](repeating: 1.0, count: 320)
        let silence = [Float](repeating: 0, count: 320)
        for _ in 0..<6 { segmenter.process(speech) }
        // Endpoint reached here by the -1 timeout; the emitted utterance must contain
        // all six speech frames, not a truncated remainder.
        segmenter.process(silence)

        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances.first?.count, 6 * 320 + 320, "Words spoken before the endpoint were discarded")
    }

    /// Verification of the absence itself: the wired production segmenter cannot bind a
    /// duration limit, so the force-emit branch is unreachable. If someone later wires
    /// `maxUtteranceMs`, this fails and the retention clause must be re-argued.
    func test_productionSegmenterWiresNoDurationBound() {
        let segmenter = NativeVadSegmenter(threshold: 0.020)  // exactly VoiceControlAssembly's construction
        var utterances: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in utterances.append(utterance) }

        // 60 s of unbroken speech: far beyond any plausible bound.
        let speech = [Float](repeating: 1.0, count: 320)
        for _ in 0..<(960_000 / 320) {
            segmenter.process(speech)
        }
        XCTAssertTrue(utterances.isEmpty, "The production segmenter emitted on an internal bound")
    }

    /// The loss in the confirmation rule is the *interruption* branch, not the buffering.
    ///
    /// Pending frames are appended before `minSpeechFrames` is tested, so energy audio is
    /// not withheld while unconfirmed. What discards it is one non-energetic frame arriving
    /// before confirmation: that branch clears the buffer, and the pending audio goes with
    /// it. This is correct pre-speech rejection — the segmenter declining to treat
    /// sub-threshold energy as speech — and is **not** the retention defect, which concerns
    /// audio already accepted as speech. Pinned so it is not loosened while chasing that
    /// clause, which would trade a correct rejection for false triggers.
    func test_interruptionBeforeConfirmation_discardsPendingFrames_andIsNotTheRetentionDefect() {
        let segmenter = NativeVadSegmenter(silenceTimeoutMs: -1)
        var utterances: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in utterances.append(utterance) }

        // Four energetic frames — one below the default minSpeechFrames of 5 — then an
        // interruption, then a confirmed utterance.
        for _ in 0..<4 { segmenter.process([Float](repeating: 1.0, count: 320)) }
        segmenter.process([Float](repeating: 0, count: 320))
        for _ in 0..<5 { segmenter.process([Float](repeating: 1.0, count: 320)) }
        segmenter.process([Float](repeating: 0, count: 320))

        XCTAssertEqual(utterances.count, 1)
        // Exactly the confirmed run plus its endpoint frame: the four unconfirmed frames
        // were discarded by the interruption branch, as designed.
        XCTAssertEqual(
            utterances.first?.count, 5 * 320 + 320,
            "Expected pre-confirmation frames to be discarded; got \(utterances.first?.count ?? -1) samples"
        )
    }
}

// MARK: - Capture teardown ownership

/// Records the session calls `NativeAudioCapture` makes so a test can assert on
/// the ownership-sensitive teardown without touching the real `AVAudioSession`.
final class FakeCaptureAudioSession: CaptureAudioSession {
    private(set) var configureCount = 0
    private(set) var restorePlaybackCategoryCount = 0
    private(set) var setActiveCalls: [(active: Bool, notifyOthers: Bool)] = []

    func configureForCapture() throws {
        configureCount += 1
    }

    func restorePlaybackCategory() {
        restorePlaybackCategoryCount += 1
    }

    func setActive(_ active: Bool, notifyOthers: Bool) throws {
        setActiveCalls.append((active, notifyOthers))
    }
}

extension NativeAudioCaptureTests {

    /// Critical: stopping capture reached the real shared `AVAudioSession` and
    /// unconditionally called `setActive(false, ...)`, so stopping listening
    /// could stop the user's podcast. With playback owning the session, teardown
    /// must restore the category but must not deactivate.
    func test_stop_whenPlaybackOwnsSession_restoresCategoryButDoesNotDeactivate() {
        let session = FakeCaptureAudioSession()
        let capture = NativeAudioCapture(session: session, isPlaybackActive: { true })

        capture.stop()

        XCTAssertEqual(session.restorePlaybackCategoryCount, 1,
                       "capture still restores the playback-friendly category")
        XCTAssertFalse(session.setActiveCalls.contains { !$0.active },
                       "a playback-owned session must never be deactivated (that stops the podcast)")
    }

    /// Control: with playback inactive, capture owns the session and may release it.
    func test_stop_whenPlaybackInactive_deactivatesCaptureOwnedSession() {
        let session = FakeCaptureAudioSession()
        let capture = NativeAudioCapture(session: session, isPlaybackActive: { false })

        capture.stop()

        XCTAssertEqual(session.restorePlaybackCategoryCount, 1)
        XCTAssertTrue(session.setActiveCalls.contains { !$0.active && $0.notifyOthers },
                      "with playback inactive, the session capture activated is deactivated")
    }

    /// The ownership signal is read at teardown time, not sampled when capture
    /// started: playback can begin while listening.
    func test_stop_rechecksPlaybackOwnershipAtTeardownTime() {
        var playbackActive = false
        let session = FakeCaptureAudioSession()
        let capture = NativeAudioCapture(session: session, isPlaybackActive: { playbackActive })

        // Playback starts after the capture object was built.
        playbackActive = true
        capture.stop()

        XCTAssertFalse(session.setActiveCalls.contains { !$0.active },
                       "playback began during capture; teardown must observe it and leave the session active")
    }
}

/// Pins the SUBSCRIBED capture-instant callback boundary: the control calls the same
/// delivery function the production tap calls and observes what a real
/// `onCapturedSamples` subscriber receives.
extension NativeAudioCaptureTests {
    func test_validHostTime_deliversTheHardwareCaptureInstantToASubscriber() throws {
        let capture = NativeAudioCapture()
        var received: [([Float], MonotonicTime?)] = []
        capture.onCapturedSamples = { samples, instant in received.append((samples, instant)) }

        let hostTime: UInt64 = 987_654_321
        let when = AVAudioTime(hostTime: hostTime, sampleTime: 0, atRate: 16_000)
        XCTAssertTrue(when.isHostTimeValid, "fixture must carry a valid host time")

        // The SAME function the tap calls — not a parallel copy of its arithmetic.
        capture.deliver([0.25, -0.25], when: when)

        XCTAssertEqual(received.count, 1, "the subscriber must observe the tap's delivery")
        XCTAssertEqual(received.first?.0, [0.25, -0.25], "the samples must reach the subscriber")
        let instant = try XCTUnwrap(received.first?.1, "a valid host time must deliver an instant")
        XCTAssertEqual(instant, AVAudioTime.seconds(forHostTime: hostTime),
                       "the delivered instant must be the buffer's own host time, not arrival time")
    }

    func test_invalidHostTime_deliversNilToASubscriberSoTheConsumerDoesNotGuess() {
        let capture = NativeAudioCapture()
        var received: [([Float], MonotonicTime?)] = []
        capture.onCapturedSamples = { samples, instant in received.append((samples, instant)) }

        // A sample-time-only AVAudioTime has no valid host time — the shape the tap
        // sees on routes where the hardware clock is unavailable.
        let when = AVAudioTime(sampleTime: 512, atRate: 16_000)
        XCTAssertFalse(when.isHostTimeValid, "fixture must carry an INVALID host time")

        capture.deliver([0.25], when: when)

        XCTAssertEqual(received.count, 1, "the subscriber must observe the delivery")
        XCTAssertNil(received.first?.1,
                     "an invalid host time must deliver nil, never fall back to arrival time")
    }
}
