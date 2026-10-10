import XCTest
@testable import podcasts

/// Production echo-reference wiring and the two-sided answer-echo acceptance.
///
/// Per recognition-pipeline.md "Signal Filter", both clients must wire their episode,
/// local-feedback and cloud-answer renderers into the shared emitted-PCM reference and
/// demonstrate, with capture active, that:
///
///   * answer-only playback produces **no** accepted speech, wake/reset, request or
///     allowance spend, and
///   * **simultaneous** user speech retains its onset and interrupts output.
///
/// Scope follows the owning clause, which distinguishes route classes rather than
/// being an Exposed-only flag:
///   * built-in loudspeaker — aligned playback cross-correlation against the reference;
///   * external routes — delay tracking, *not* the built-in correlation window;
///   * isolated route — reduced exposure, but **not** proof that echo is absent.
///
/// These cases drive the engine's consumed seam, never `SignalFilter` directly: a test
/// that constructs `SignalFilter` and calls `isPlaybackBleed` passes forever over a
/// filter the app never reaches, which is why the gap this closes survived.
///
/// What the route-scope cases in this file establish is **filter behaviour given
/// emitted PCM**. Whether production actually fills the reference is a separate
/// property, covered by the producer cases further down; supplying PCM here would
/// otherwise leave a passing suite that says nothing about the renderer.
final class EchoReferenceWiringTests: XCTestCase {

    // MARK: - Built-in loudspeaker: echo-only must be rejected

    /// The positive control. With the reference populated and a built-in-speaker route,
    /// an exact copy of our own playback must be dropped **before** it can reset grace,
    /// spend a dispatch allowance or reach wake/ASR.
    ///
    /// Before this change the filter could not fire at all: the route flag and the
    /// emitted-PCM reference each had setters with no callers, so the flag stayed
    /// `false` and the buffer stayed empty. This case drives the route scope, and the
    /// reference is supplied by the harness, so it verifies filter behaviour **given**
    /// PCM — not that production fills the reference. The producer is covered
    /// separately below.
    func test_echoOnlyPlayback_onBuiltInSpeaker_producesNoAcceptedSpeechOrReset() async throws {
        let harness = EchoWiringHarness()
        let before = harness.gracePeriodSignal.isActive

        let playbackPCM = [Float](repeating: 0.5, count: 320)
        harness.engine.updatePlaybackBuffer(playbackPCM)
        harness.engine.setEchoFilterRoute(.builtInSpeaker)

        await harness.engine.processUtterance(playbackPCM, capturedAt: 0)

        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 0,
            "an exact copy of our own playback reached ASR instead of being rejected as echo"
        )
        XCTAssertEqual(
            harness.gracePeriodSignal.isActive, before,
            "echo reset the conversation grace period"
        )
        XCTAssertEqual(
            harness.wakeWordDetector.detectCount, 0,
            "echo was submitted to wake detection"
        )
    }

    // MARK: - The other half: simultaneous speech must survive

    /// Guards against over-filtering: genuine user speech **mixed with** our own output
    /// must be preserved rather than dropped wholesale with the echo.
    @MainActor
    func test_simultaneousUserSpeech_isPreservedNotDiscardedWithEcho() async throws {
        let harness = EchoWiringHarness()
        // Grace active: a negative wake result outside grace is dropped before ASR by
        // WakeGate, which is unrelated to the echo filter under test here. Established
        // on the main queue because onCommandRecognized hops there asynchronously from
        // a background thread, and this test asserts on the filter, not on that hop.
        harness.gracePeriodSignal.onCommandRecognized()
        harness.engine.updatePlaybackBuffer([Float](repeating: 0.5, count: 320))
        harness.engine.setEchoFilterRoute(.builtInSpeaker)

        // Orthogonal to constant playback audio: this is our own words, not echo.
        let userSpeech = (0..<320).map { $0 % 2 == 0 ? Float(0.5) : Float(-0.5) }
        await harness.engine.processUtterance(userSpeech)

        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 1,
            "simultaneous user speech was discarded along with the echo"
        )
    }

    // MARK: - Route classes

    /// External routes must not use the built-in correlation window, whose alignment
    /// assumption does not hold where codec latency is large and variable.
    @MainActor
    func test_externalRoute_doesNotUseTheBuiltInCorrelationWindow() async throws {
        let harness = EchoWiringHarness()
        harness.gracePeriodSignal.onCommandRecognized()
        let playbackPCM = [Float](repeating: 0.5, count: 320)
        harness.engine.updatePlaybackBuffer(playbackPCM)
        harness.engine.setEchoFilterRoute(.external)

        await harness.engine.processUtterance(playbackPCM)

        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 1,
            "the built-in-speaker correlation window was applied on an external route"
        )
    }

    /// An isolated route reduces exposure but is not proof that echo is absent, so the
    /// filter must not be treated as satisfied merely because the route is a headset.
    func test_isolatedRoute_isNotTreatedAsProofOfNoEcho() async throws {
        let harness = EchoWiringHarness()
        let playbackPCM = [Float](repeating: 0.5, count: 320)
        harness.engine.updatePlaybackBuffer(playbackPCM)
        harness.engine.setEchoFilterRoute(.isolated)

        await harness.engine.processUtterance(playbackPCM)

        // Nothing is dropped by correlation here, but the route must not be *recorded*
        // as echo-free: the owning clause says exposure is reduced, not eliminated.
        XCTAssertFalse(
            harness.engine.echoFilterRouteConsidersEchoImpossible,
            "an isolated route was recorded as proof that echo is impossible"
        )
    }

    // MARK: - The reference is fed by the real producer, not a test seam

    /// The emitted-PCM reference must be populated by the renderer that actually sends
    /// audio to the output. Driving the engine's setter would prove the filter's logic
    /// and say nothing about whether production ever fills the reference — which is
    /// exactly how this gap survived, so the producer is exercised directly here.
    func test_emittedPlaybackPCM_reachesTheSharedReference() {
        let reference = PlaybackEchoReference()
        let emitted = [Float](repeating: 0.25, count: 1600)

        // What the cloud-answer renderer does before handing a buffer to the output.
        reference.append(emitted)

        XCTAssertEqual(
            reference.snapshot().count, 1600,
            "emitted playback PCM did not reach the shared reference"
        )
    }

    /// The reference is bounded: correlation needs only the recent window, and an
    /// unbounded buffer would grow with the length of the answer.
    func test_referenceRetainsABoundedWindow() {
        let reference = PlaybackEchoReference(sampleRate: 16_000, retainedSeconds: 1.0)
        // Appending more than the 16 000-sample window forces a trim; exactly the
        // capacity would leave the oldest audio in place.
        reference.append([Float](repeating: 0.1, count: 8_000))
        reference.append([Float](repeating: 0.2, count: 12_000))

        XCTAssertEqual(
            reference.snapshot().count, 16_000,
            "the reference did not bound itself to the retained window"
        )
        // The window keeps the LAST capacity samples, so it straddles both blocks:
        // the head is still the tail of the first block and the last sample is the
        // newest audio. Checking the last sample is what proves recency was retained.
        XCTAssertEqual(
            reference.snapshot().last, 0.2,
            "the retained window should end with the most recently emitted audio"
        )
    }

    /// Route invalidation must retire the retained audio: it belonged to the previous
    /// output path, whose delay characteristics differ from the new one.
    func test_referenceInvalidation_dropsRetainedAudio() {
        let reference = PlaybackEchoReference()
        reference.append([Float](repeating: 0.5, count: 1600))
        XCTAssertFalse(reference.snapshot().isEmpty)

        reference.invalidate()

        XCTAssertTrue(
            reference.snapshot().isEmpty,
            "stale emitted audio survived route invalidation"
        )
    }

    /// A source rendering at a different rate must be resampled into the pipeline's
    /// domain, or the correlation would compare misaligned signals.
    func test_emittedPCMFromAHigherRateSource_isResampledToThePipelineRate() {
        let at48k = [Float](repeating: 0.3, count: 4_800)  // 100 ms at 48 kHz
        let converted = PlaybackResampler.toPipelineRate(at48k, sourceRate: 48_000)

        XCTAssertEqual(
            converted.count, 1_600,
            "100 ms at 48 kHz should become 100 ms at 16 kHz, not stay at the source rate"
        )
    }

    /// A 20 ms frame at the baseline codec rate must map to exactly 20 ms, and successive
    /// frames must join on one timeline. Stretching a frame end-to-end instead anchors
    /// both endpoints and makes the last source sample land on the last output sample,
    /// so the step becomes 3.00627 rather than 3.0 and each frame boundary carries a
    /// phase discontinuity. Correlation is alignment-sensitive, so that distortion is
    /// the failure this case exists to catch.
    func test_resamplingPreservesFrameDurationAndKeepsFramesContiguous() {
        // Baseline codec: 48 kHz mono, 20 ms frames (cloud-assistant.md).
        let frame = (0..<960).map { Float($0) }
        let converted = PlaybackResampler.toPipelineRate(frame, sourceRate: 48_000)

        XCTAssertEqual(converted.count, 320, "a 20 ms frame must remain 20 ms at the pipeline rate")
        // The true ratio is exactly 3: output sample i reads source sample 3i.
        XCTAssertEqual(converted[1], frame[3], accuracy: 0.0001)
        XCTAssertEqual(converted[100], frame[300], accuracy: 0.0001)
        // The last output reads source 957, not 959: the frame covers [0, 960) so the
        // following frame continues from 960 without a gap or an overlap.
        XCTAssertEqual(converted[319], frame[957], accuracy: 0.0001)
    }

    /// The spec also offers `pcm_s16le@24k`, where 24 -> 16 kHz is **3:2** rather than
    /// 3:1. An integer ratio can be right by construction; this one is right by
    /// arithmetic, which is exactly the case worth pinning: the step is 1.5, the last
    /// output reads source 478.5, and the frame covers [0, 480) so the next begins at
    /// 480 without a gap.
    func test_resamplingHandlesANonIntegerRateRatio() {
        // 20 ms at 24 kHz = 480 frames -> 320 at 16 kHz.
        let frame = (0..<480).map { Float($0) }
        let converted = PlaybackResampler.toPipelineRate(frame, sourceRate: 24_000)

        XCTAssertEqual(converted.count, 320, "a 20 ms frame at 24 kHz must remain 20 ms")
        // Step 1.5: output i reads source 1.5i.
        XCTAssertEqual(converted[1], frame[1] + (frame[2] - frame[1]) * 0.5, accuracy: 0.0001)
        XCTAssertEqual(converted[2], frame[3], accuracy: 0.0001)
        // Coverage reaches source 478.5 and stops short of 480, leaving the join contiguous.
        XCTAssertEqual(converted[319], frame[478] + (frame[479] - frame[478]) * 0.5, accuracy: 0.0001)
    }

    /// Both route-change directions must retire the reference. Retiring only when the
    /// incoming route stops correlating leaves external -> built-in reusing audio from
    /// the old output path as though it were an aligned reference for the new one.
    func test_routeRetirementHappensInBothDirections() async throws {
        let harness = EchoWiringHarness()
        let playbackPCM = [Float](repeating: 0.5, count: 320)

        // Start on the external route, with a full reference retained.
        harness.engine.setEchoFilterRoute(.external)
        harness.engine.updatePlaybackBuffer([Float](repeating: 0.5, count: 16_000))
        XCTAssertEqual(harness.reference.snapshot().count, 16_000)

        // external -> built-in: this is the direction the previous guard skipped.
        harness.engine.setEchoFilterRoute(.builtInSpeaker)

        XCTAssertLessThanOrEqual(
            harness.reference.snapshot().count, Int(VoiceAsrEngine.acousticTailSeconds * 16_000),
            "moving onto the built-in route kept the whole old-path reference instead of retiring it"
        )
    }

    /// The aligned window must be a span of the segment's own length ending at the
    /// segment's end. Anchoring it at the segment's start and running forward collapses
    /// the window when the segment sits at the end of the reference, and because the
    /// normalised correlation divides by the window length, a one-sample window scores
    /// ~1.0 for unrelated signals — genuine speech is then rejected as bleed.
    func test_alignedWindowKeepsTheSegmentLengthSoSpeechIsNotFalselyRejected() {
        let filter = SignalFilter()
        // Reference is constant playback; the "segment" alternates sign, so it does not
        // correlate with it and must not be treated as bleed.
        let reference = [Float](repeating: 0.5, count: 320)
        let speech = (0..<320).map { $0 % 2 == 0 ? Float(0.5) : Float(-0.5) }

        XCTAssertFalse(
            filter.isPlaybackBleed(mic: speech, reference: reference, segmentEndOffset: reference.count),
            "genuine speech was rejected because the aligned window collapsed to a few samples"
        )
    }

    /// The same construction with a true echo must still be rejected, so the fix above
    /// has not simply disabled the filter.
    func test_alignedWindowStillRejectsActualEcho() {
        let filter = SignalFilter()
        let playback = (0..<320).map { Float(sin(Double($0) * 0.3)) }

        XCTAssertTrue(
            filter.isPlaybackBleed(mic: playback, reference: playback, segmentEndOffset: playback.count),
            "an exact copy of playback was not rejected as echo"
        )
    }

    /// The audible end must come from the node's rendered position, not from the end of
    /// the retained audio. The retained end is the newest *submitted* sample, which is
    /// ahead of what has been heard by however much audio is still queued, so using it is
    /// misaligned whenever the queue is non-empty — which is most of streaming playback,
    /// not only across a restart.
    func test_audibleEndComesFromRenderedPositionNotTheRetainedEnd() throws {
        let reference = PlaybackEchoReference(sampleRate: 16_000, retainedSeconds: 2.0)
        // 1 s of audio submitted, but the node has only rendered half of it.
        reference.append([Float](repeating: 0.2, count: 16_000))
        reference.recordRenderPosition(
            PlaybackRenderAnchor(renderedFrames: 8_000, sourceSampleRate: 16_000, hostTime: 0)
        )

        let offset = try XCTUnwrap(reference.audibleEndOffsetInRetainedWindow())
        XCTAssertEqual(
            offset, 8_000,
            "the offset should mark where playback has actually reached, not where submission ended"
        )
        XCTAssertNotEqual(
            offset, reference.snapshot().count,
            "the offset must not be the retained end while audio is still queued"
        )
    }

    /// Trimming must not shift the mapping: the render position lives in the emitted
    /// stream's index space, so the window's start has to be accounted for or the offset
    /// addresses the wrong samples once the window has removed audio from its front.
    func test_audibleEndOffsetSurvivesWindowTrimming() throws {
        let reference = PlaybackEchoReference(sampleRate: 16_000, retainedSeconds: 1.0)
        // 2 s submitted into a 1 s window: the first second is dropped.
        reference.append([Float](repeating: 0.1, count: 16_000))
        reference.append([Float](repeating: 0.2, count: 16_000))
        // The node has rendered 1.5 s of the emitted stream.
        reference.recordRenderPosition(
            PlaybackRenderAnchor(renderedFrames: 24_000, sourceSampleRate: 16_000, hostTime: 0)
        )

        let offset = try XCTUnwrap(reference.audibleEndOffsetInRetainedWindow())
        XCTAssertEqual(
            offset, 8_000,
            "1.5 s rendered with a window starting at 1.0 s leaves 0.5 s inside the window"
        )
    }

    /// A node that is not rendering has no position, so no alignment claim is made rather
    /// than falling back to the retained end.
    func test_noAudibleOffsetWithoutARenderedPosition() {
        let reference = PlaybackEchoReference()
        reference.append([Float](repeating: 0.5, count: 1_600))

        XCTAssertNil(
            reference.audibleEndOffsetInRetainedWindow(),
            "an unrendered reference must not offer an alignment offset"
        )
    }

    /// Insufficient overlap must decline rather than decide. Asking for a segment-length
    /// span does not guarantee one exists: with the segment near the window's start, the
    /// span clamps and the overlap is a fraction of the segment. A short overlap can score
    /// high on a partial match, so a decision made on it can be wrong in either direction.
    func test_insufficientOverlapIsDeclinedRatherThanDecided() {
        let filter = SignalFilter()
        let speech = (0..<320).map { $0 % 2 == 0 ? Float(0.5) : Float(-0.5) }

        // Only 40 samples exist before the segment's end: far less than its 320.
        let shortReference = [Float](repeating: 0.5, count: 40)

        XCTAssertFalse(
            filter.isPlaybackBleed(mic: speech, reference: shortReference, segmentEndOffset: 40),
            "a 40-sample overlap against a 320-sample segment was treated as decision-bearing"
        )
    }

    /// The same shape with an exact echo in the short overlap must also decline, so the
    /// guard is not merely suppressing positive results.
    func test_insufficientOverlapDeclinesEvenWhenTheOverlapMatches() {
        let filter = SignalFilter()
        let playback = (0..<320).map { Float(sin(Double($0) * 0.3)) }
        let shortReference = Array(playback.prefix(40))

        XCTAssertFalse(
            filter.isPlaybackBleed(mic: playback, reference: shortReference, segmentEndOffset: 40),
            "a partial overlap was allowed to decide, however promising it looked"
        )
    }

    /// A segment longer than the whole reference cannot be placed at all, so it declines
    /// rather than correlating against whatever is there.
    func test_segmentLongerThanTheReferenceIsDeclined() {
        let filter = SignalFilter()
        let longSegment = [Float](repeating: 0.4, count: 4_000)
        let reference = [Float](repeating: 0.4, count: 320)

        XCTAssertFalse(
            filter.isPlaybackBleed(mic: longSegment, reference: reference, segmentEndOffset: reference.count),
            "a segment longer than the available reference was accepted as aligned"
        )
    }

    /// A segment with no capture instant must not be aligned. Callback arrival is the only
    /// other clock available, and it is not a substitute: the tap runs on a processing
    /// queue, so arrival lags capture by an indeterminate amount and would place the
    /// segment later than it was spoken.
    func test_segmentWithoutACaptureInstantIsNotAligned() async throws {
        let harness = EchoWiringHarness()
        harness.engine.setEchoFilterRoute(.builtInSpeaker)
        harness.gracePeriodSignal.onCommandRecognized()

        let playbackPCM = [Float](repeating: 0.5, count: 320)
        harness.engine.updatePlaybackBuffer(playbackPCM)

        // No capture instant: the position is unknown, so the filter must decline rather
        // than fall back to arrival time.
        await harness.engine.processUtterance(playbackPCM)

        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 1,
            "a segment with no capture instant was aligned anyway"
        )
    }

    /// The segmenter must carry the instant of its FIRST retained sample, not the buffer
    /// that completed the utterance. A multi-buffer utterance spans its own length, so
    /// using the completing buffer's time would shift the segment later by that much.
    func test_segmenterCarriesTheFirstSamplesCaptureInstant() {
        let segmenter = NativeVadSegmenter(threshold: 0.002, silenceTimeoutMs: -1, minSpeechFrames: 2)
        var received: (samples: [Float], capturedAt: MonotonicTime?)?
        segmenter.onUtterance = { samples, capturedAt in
            received = (samples, capturedAt)
        }

        let speech = [Float](repeating: 1.0, count: 320)
        // Three speech buffers arriving at different instants, then the endpoint.
        segmenter.process(speech, capturedAt: 100)
        segmenter.process(speech, capturedAt: 200)
        segmenter.process(speech, capturedAt: 300)
        segmenter.process([Float](repeating: 0, count: 320), capturedAt: 400)

        XCTAssertEqual(
            received?.capturedAt, 100,
            "the utterance should carry the first retained sample's instant, not the last buffer's"
        )
    }

    // MARK: - Paired normalization at the permitted-overlap boundary

    /// The numerator and both energies must come from the same sample pairs. With mixed
    /// supports, energy in the segment **outside** the overlap raises the segment's energy
    /// without appearing in the numerator, so the score drifts with how much audio sits
    /// beyond the window rather than with how well the two match.
    ///
    /// The reference must be at least as long as the segment, otherwise the offset clamps
    /// the window and the overlap guard declines before the score is computed — a different
    /// case, covered separately.
    func test_loudAudioOutsideTheOverlapDoesNotChangeTheEchoDecision() {
        let filter = SignalFilter()
        let echoBody = (0..<1_200).map { Float(sin(Double($0) * 0.25)) }
        let reference = echoBody + [Float](repeating: 0.001, count: 400)

        // Identical echo inside the segment; only the tail's energy differs.
        let quietTail = echoBody + [Float](repeating: 0.001, count: 400)
        let loudTail = echoBody + [Float](repeating: 0.9, count: 400)

        let quietDecision = filter.isPlaybackBleed(mic: quietTail, reference: reference, segmentEndOffset: reference.count)
        let loudDecision = filter.isPlaybackBleed(mic: loudTail, reference: reference, segmentEndOffset: reference.count)

        XCTAssertEqual(
            quietDecision, loudDecision,
            "the decision changed with energy outside the overlap, so the score is not a match measure"
        )
        XCTAssertTrue(quietDecision, "an exact echo in the overlap was not rejected")
    }

    /// **The user-preservation control.** A match inside the overlap must not discard
    /// genuine speech outside it. The score establishes that the *compared* portion matches;
    /// audio the comparison never saw could be the user speaking, and dropping it on the
    /// strength of a match elsewhere is exactly the failure the owning clause forbids.
    func test_echoInTheOverlapDoesNotDiscardUserSpeechOutsideIt() {
        let filter = SignalFilter()
        // The reference covers only the first 1 200 samples of the segment.
        let echoBody = (0..<1_200).map { Float(sin(Double($0) * 0.25) * 0.1) }

        // Segment = matching echo, then genuine user speech the reference cannot see.
        let userSpeech = (0..<400).map { $0 % 2 == 0 ? Float(0.8) : Float(-0.8) }
        let mic = echoBody + userSpeech

        XCTAssertFalse(
            filter.isPlaybackBleed(mic: mic, reference: echoBody, segmentEndOffset: echoBody.count),
            "a match in the overlap discarded user speech the comparison never saw"
        )
    }

    /// Simultaneous user speech must survive with echo present, which is the case the owning
    /// clause calls out.
    func test_simultaneousUserSpeechSurvivesWithEchoPresent() {
        let filter = SignalFilter()
        let reference = (0..<1_200).map { Float(sin(Double($0) * 0.25)) }
            + [Float](repeating: 0.001, count: 400)
        // User speech dominates the mixture: the clause preserves the user's words even
        // while our own output is audible underneath them.
        let mixed = (0..<1_600).map { index -> Float in
            let echo = Float(sin(Double(index % 1_200) * 0.25))
            let user = index % 2 == 0 ? Float(0.8) : Float(-0.8)
            return echo * 0.1 + user
        }

        XCTAssertFalse(
            filter.isPlaybackBleed(mic: mixed, reference: reference, segmentEndOffset: reference.count),
            "simultaneous user speech was rejected as echo"
        )
    }

    // MARK: - Paired normalization, isolated

    /// **The isolating case for the denominator, and it must bypass the aligned caller.**
    ///
    /// On the aligned path the coverage guard (`window >= mic`) and the positional
    /// overload's own guard (`mic >= playback`, called with `playback = window`) together
    /// force `mic == window`. At equal lengths the correlation has exactly one entry, `lag`
    /// is always zero, and `paired` is the whole segment — so `rms(paired)` and `rms(mic)`
    /// are the *same array* and the pairing is unobservable there.
    ///
    /// This case therefore calls the positional overload directly with **differing** lengths,
    /// where `paired` is a strict sub-span of the segment: it passes on the pairing and fails
    /// when the energy is taken over the whole segment.
    func test_pairedNormalizationIsObservableOnlyWithDifferingLengths() {
        let filter = SignalFilter()
        // The compared span is quiet; the remainder of the segment is loud and not compared.
        let quietEcho = (0..<800).map { Float(sin(Double($0) * 0.25) * 0.05) }
        let loudTail = [Float](repeating: 0.9, count: 800)
        let segment = quietEcho + loudTail          // 1600 samples, mic.count > playback.count
        let playback = quietEcho                     // 800 samples

        XCTAssertTrue(
            filter.isPlaybackBleed(mic: segment, playback: playback),
            "the compared span is an exact echo match and must be rejected"
        )
    }

    /// Control for the case above: changing only the audio *outside* the compared span must
    /// not change the decision, which is what pairing the energies establishes.
    func test_audioOutsideTheComparedSpanDoesNotChangeTheDecision() {
        let filter = SignalFilter()
        let quietEcho = (0..<800).map { Float(sin(Double($0) * 0.25) * 0.05) }
        let playback = quietEcho

        let quietTail = quietEcho + [Float](repeating: 0.01, count: 800)
        let loudTail = quietEcho + [Float](repeating: 0.9, count: 800)

        XCTAssertEqual(
            filter.isPlaybackBleed(mic: quietTail, playback: playback),
            filter.isPlaybackBleed(mic: loudTail, playback: playback),
            "the decision changed with audio outside the compared span"
        )
    }

    /// The engine reads the shared reference, so audio appended by a producer is what
    /// the filter correlates against — not a buffer the engine happens to hold.
    func test_engineCorrelatesAgainstTheSharedReference() async throws {
        let harness = EchoWiringHarness()
        let reference = PlaybackEchoReference()
        harness.engine.setEchoReference(reference)
        harness.engine.setEchoFilterRoute(.builtInSpeaker)

        let playbackPCM = [Float](repeating: 0.5, count: 320)
        reference.append(playbackPCM)

        await harness.engine.processUtterance(playbackPCM)

        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 0,
            "the engine did not correlate against the shared reference"
        )
    }

    // MARK: - Alignment is timely, not merely equal-rate

    /// A common sample rate is not alignment. Two producers resampled to the pipeline
    /// rate still have to be placed in time relative to each other, so the reference
    /// carries the monotonic instant its window began.
    func test_referenceSpan_carriesAMonotonicStartTime() {
        let clock = FixedMonotonicClock(time: 1_000)
        let reference = PlaybackEchoReference(clock: clock)
        reference.append([Float](repeating: 0.1, count: 1_600))

        let span = reference.span()
        XCTAssertNotNil(span, "a populated reference should expose a span")
        XCTAssertEqual(span?.startedAt, 1_000, "the span did not carry the emission instant")
    }

    /// Trimming the retained window must move its start time forward by exactly the
    /// audio dropped, or the window would claim to begin earlier than the audio it holds.
    func test_trimmingAdvancesTheStartTimeByTheDroppedAudio() throws {
        let clock = FixedMonotonicClock(time: 500)
        let reference = PlaybackEchoReference(sampleRate: 16_000, retainedSeconds: 1.0, clock: clock)
        reference.append([Float](repeating: 0.1, count: 8_000))
        // 0.5 s of audio forces 4 000 samples to be dropped.
        reference.append([Float](repeating: 0.2, count: 12_000))

        let span = reference.span()
        XCTAssertEqual(span?.samples.count, 16_000)
        let startedAt = try XCTUnwrap(span?.startedAt, "the span should carry a start time")
        XCTAssertEqual(
            startedAt, 500 + 4_000.0 / 16_000.0, accuracy: 0.0001,
            "the window start did not advance by the dropped audio"
        )
    }

    /// Retiring for a route change must keep the acoustic tail: audio already submitted
    /// is still audible while the old path drains, so clearing it outright would leave
    /// exactly that echo unfiltered during the handover.
    func test_routeRetirementRetainsTheAcousticTail() {
        let reference = PlaybackEchoReference(sampleRate: 16_000, retainedSeconds: 2.0)
        reference.append([Float](repeating: 0.1, count: 16_000))
        reference.append([Float](repeating: 0.2, count: 16_000))

        reference.retire(retainingAcousticTail: 0.25)

        let span = reference.span()
        XCTAssertEqual(
            span?.samples.count, 4_000,
            "retirement should keep 0.25 s of emitted audio for the acoustic tail"
        )
        XCTAssertEqual(
            span?.samples.last, 0.2,
            "the retained tail should be the most recent audio, which is what is still audible"
        )
    }

    /// A reference with nothing in it has no tail to keep and must not claim one.
    func test_routeRetirementOnAnEmptyReferenceStaysEmpty() {
        let reference = PlaybackEchoReference()
        reference.retire(retainingAcousticTail: 0.25)
        XCTAssertNil(reference.span())
    }

    /// Nothing retained means no alignment claim at all, rather than a stale instant.
    func test_emptyReferenceExposesNoSpan() {
        let reference = PlaybackEchoReference()
        XCTAssertNil(reference.span(), "an empty reference must not claim a span")
    }

    /// Retiring the reference on stop/drain and route change must clear the span too,
    /// so a later segment cannot be aligned against audio that is no longer emitting.
    func test_invalidationClearsTheSpan() {
        let reference = PlaybackEchoReference()
        reference.append([Float](repeating: 0.5, count: 1_600))
        XCTAssertNotNil(reference.span())

        reference.invalidate()

        XCTAssertNil(reference.span(), "a retired reference still claimed an alignment span")
    }

    // MARK: - Route classification

    /// Only the built-in loudspeaker may use the aligned correlation window. Every
    /// other output has large or variable codec latency, so the window's alignment
    /// assumption does not hold and a wired/Bluetooth route must not be treated as
    /// though it were the built-in speaker.
    func test_routeClassification_mapsOutputsToFilterScopes() {
        let buildIn = VoiceAsrEngine.EchoFilterRoute.forOutput(.builtInSpeaker)
        XCTAssertTrue(buildIn.appliesCorrelationWindow)
        XCTAssertFalse(buildIn.provesEchoImpossible)

        for output: AudioRouteOutput in [.headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .airPlay, .unknown] {
            let route = VoiceAsrEngine.EchoFilterRoute.forOutput(output)
            XCTAssertFalse(
                route.appliesCorrelationWindow,
                "\(output) must not apply the built-in-speaker correlation window"
            )
            XCTAssertFalse(
                route.provesEchoImpossible,
                "\(output) must not be recorded as proof that echo is impossible"
            )
        }
    }

    // MARK: - Invalidation

    /// Stale route state must not survive a route change: after the filter stops
    /// applying, a subsequent identical utterance must not be dropped by leftover state.
    @MainActor
    func test_routeChangeInvalidation_clearsAppliedFilterState() async throws {
        let harness = EchoWiringHarness()
        let playbackPCM = [Float](repeating: 0.5, count: 320)

        harness.engine.updatePlaybackBuffer(playbackPCM)
        harness.engine.setEchoFilterRoute(.builtInSpeaker)
        await harness.engine.processUtterance(playbackPCM)
        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 0,
            "precondition: echo is rejected while the built-in route applies"
        )

        // Route change: the reference is retired and the state cleared. Grace is
        // active so the surviving utterance can reach ASR rather than being dropped
        // by the wake gate for an unrelated reason.
        harness.gracePeriodSignal.onCommandRecognized()
        harness.engine.setEchoFilterRoute(.external)
        harness.engine.updatePlaybackBuffer([])
        await harness.engine.processUtterance(playbackPCM)

        XCTAssertEqual(
            harness.backend.transcribeSamples.count, 1,
            "stale filter state survived route invalidation and kept dropping audio"
        )
    }
}

// MARK: - Harness

/// Wires the engine the way `VoiceControlAssembly` does, so these cases exercise the
/// production construction rather than a bespoke one.
private final class EchoWiringHarness {
    let engine: VoiceAsrEngine
    let backend = CountingAsrBackend()
    let wakeWordDetector = RecordingWakeWordDetector()
    let gracePeriodSignal = GracePeriodSignal()

    let reference = PlaybackEchoReference()

    init() {
        engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(threshold: 0.020),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: wakeWordDetector,
            gracePeriodSignal: gracePeriodSignal
        )
        // Mirror production: the engine always has a reference once wired, so the
        // route-scope cases exercise the same path the app does.
        engine.setEchoReference(reference)
    }
}

private final class CountingAsrBackend: AsrBackend {
    private(set) var transcribeSamples: [[Float]] = []
    var requiredModel: ModelSpec {
        ModelSpec(id: "test", files: [], targetDir: "/tmp/test")
    }
    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
    }
    func ensureReady() async -> Result<Void, Error> { .success(()) }
    func release() {}
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        transcribeSamples.append(samples)
        return AsrResult(text: "test", detectedLanguage: "en")
    }
}

private final class RecordingWakeWordDetector: WakeWordDetectorProtocol {
    private(set) var detectCount = 0
    func release() {}
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        detectCount += 1
        return .notDetected(confidence: 0)
    }
}


/// A determinate clock, so alignment cases assert an instant rather than observe one.
private final class FixedMonotonicClock: MonotonicClock {
    private var time: MonotonicTime
    init(time: MonotonicTime) { self.time = time }
    func now() -> MonotonicTime { time }
}
