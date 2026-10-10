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

    // MARK: - Lag selection must use the same criterion as the decision

    /// Selecting the lag on raw correlation picks the wrong span once a loud portion of the
    /// segment outweighs the echo by enough that a spurious alignment wins on magnitude.
    /// The energies then describe that wrong span and a true echo match at lag 0 is missed.
    /// Scoring every lag by its own paired normalisation and taking the maximum fixes it,
    /// because choosing and judging then use one criterion.
    ///
    /// Separation must hold across amplitudes and length ratios; a fix verified only at a
    /// quiet tail would pass while the defect it exists for is still present.
    func test_loudTailDoesNotDefeatLagSelection() {
        let filter = SignalFilter()

        for amplitude: Float in [0.9, 1.5, 3.0] {
            let echoSpan = (0..<800).map { Float(sin(Double($0) * 0.25) * 0.05) }
            let segment = echoSpan + [Float](repeating: amplitude, count: 800)

            XCTAssertTrue(
                filter.isPlaybackBleed(mic: segment, playback: echoSpan),
                "amplitude \(amplitude): a true echo at the aligned lag was missed because a spurious lag won on raw magnitude"
            )
        }
    }

    /// The same property across length ratios: the echo must be found whatever proportion
    /// of the segment it occupies, so the fix is not tuned to one fixture.
    func test_lagSelectionHoldsAcrossLengthRatios() {
        let filter = SignalFilter()

        for (segmentLength, echoLength) in [(1_600, 800), (1_200, 900), (2_400, 600)] {
            let echoSpan = (0..<echoLength).map { Float(sin(Double($0) * 0.25) * 0.05) }
            let segment = echoSpan + [Float](repeating: 2.0, count: segmentLength - echoLength)

            XCTAssertTrue(
                filter.isPlaybackBleed(mic: segment, playback: echoSpan),
                "segment \(segmentLength) / echo \(echoLength): a true echo was missed"
            )
        }
    }

    /// Unrelated speech with a loud tail must still be preserved, so normalised selection
    /// has not simply made everything look like echo.
    func testLoudTailWithUnrelatedSpeechIsStillPreserved() {
        let filter = SignalFilter()
        let echoSpan = (0..<800).map { Float(sin(Double($0) * 0.25) * 0.05) }
        // Orthogonal to the echo, then a loud tail.
        let speech = (0..<800).map { $0 % 2 == 0 ? Float(0.6) : Float(-0.6) }
            + [Float](repeating: 2.0, count: 800)

        XCTAssertFalse(
            filter.isPlaybackBleed(mic: speech, playback: echoSpan),
            "unrelated speech was rejected as echo"
        )
    }

    /// A quiet tail must still behave as before, so the change does not only help the loud
    /// case at the cost of the ordinary one.
    func testQuietTailStillRejectsEcho() {
        let filter = SignalFilter()
        let echoSpan = (0..<800).map { Float(sin(Double($0) * 0.25) * 0.05) }
        let segment = echoSpan + [Float](repeating: 0.001, count: 800)

        XCTAssertTrue(
            filter.isPlaybackBleed(mic: segment, playback: echoSpan),
            "a quiet tail broke the ordinary echo case"
        )
    }

    /// An earcon is audio the microphone can hear, so it belongs in the echo reference
    /// exactly like the cloud answer. Without it, a chime played while the user is
    /// speaking is attributed to the user: the segment forms, nothing knows it was our
    /// output, and the utterance is transcribed as if the user had said it.
    ///
    /// **Driven through `play`, the production entry point**, with the buffer injected
    /// because the earcon assets belong to the app target and do not load under test.
    /// This is what makes the case cover the *call site* rather than only the publisher:
    /// removing the publish from `play` fails it.
    func testEarconSamplesReachTheEchoReferenceAtThePipelineRate() throws {
        let reference = PlaybackEchoReference()
        let player = EarconPlayer(engine: AVAudioEngine())
        player.emittedPCMReference = reference

        // A tone standing in for the chime, at a device-like rate so the resampling path
        // is the one exercised.
        let sourceRate = 24_000.0
        let frameCount = 1600
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: EarconPlayer.earconFormat(sampleRate: sourceRate),
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<frameCount { channel[i] = Float(sin(Double(i) * 0.3) * 0.4) }

        player.loadForTesting(.listeningStart, buffer: buffer)
        player.play(.listeningStart)

        let expected = frameCount * Int(PlaybackEchoReference.pipelineSampleRate) / Int(sourceRate)
        let retained = reference.snapshot()
        XCTAssertEqual(
            retained.count, expected,
            "playing an earcon did not reach the reference at the pipeline rate"
        )

        // **Length alone does not verify the emitted audio reached the reference**: a
        // reference of the right length full of silence would satisfy it, and silence is
        // exactly what a mis-wired path produces. So the content is checked against the
        // samples the buffer held, and the case is shown to fail when the source is silent.
        XCTAssertFalse(
            retained.allSatisfy { $0 == 0 },
            "the reference holds only silence, so the earcon's audio did not reach it"
        )
        // The tone is deterministic, so specific values are known: resampling interpolates
        // between source samples, so the retained values must lie within the source's range
        // rather than matching it exactly.
        let sourcePeak = (0..<frameCount)
            .map { abs(Float(sin(Double($0) * 0.3) * 0.4)) }
            .max() ?? 0
        let retainedPeak = retained.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(
            retainedPeak, 0.1,
            "the retained audio is near-silent, so the earcon's samples were not published"
        )
        XCTAssertLessThanOrEqual(
            retainedPeak, sourcePeak + 0.05,
            "the retained audio exceeds the source amplitude, so it is not this earcon's audio"
        )
    }

    /// With no reference attached nothing is published, so the player stays usable in
    /// contexts that do not run the echo filter.
    func testEarconPublishIsInertWithoutAReference() throws {
        let player = EarconPlayer(engine: AVAudioEngine())
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: EarconPlayer.earconFormat(sampleRate: 24_000),
                frameCapacity: 800
            )
        )
        buffer.frameLength = 800

        player.loadForTesting(.listeningStart, buffer: buffer)
        player.play(.listeningStart)

        XCTAssertNil(player.emittedPCMReference, "a reference appeared from nowhere")
    }

    /// **A render anchor must never describe more audio than the reference holds.**
    ///
    /// That is the queue-lead error in its checkable form: an anchor claiming a position
    /// for audio still queued says the samples are already audible, and the filter then
    /// aligns them to a position they have not reached. This is asserted at the reference
    /// because it is the reference that holds the invariant.
    ///
    /// **What this does not cover, stated rather than implied:** that `EarconPlayer` records
    /// the anchor *after* rendering rather than at submission. I split those two moments in
    /// the implementation, wrote a case to pin the split, and **found it inert** — a fresh
    /// player returns no render position either way, so recording nil and never recording
    /// are indistinguishable. Distinguishing them needs a node that has actually rendered,
    /// which needs a real output device and a playthrough. So the ordering is documented in
    /// the code and **unverified by test**, which is a limit rather than a covered behaviour.
    func testRenderAnchorDoesNotClaimMoreThanTheReferenceHolds() {
        let reference = PlaybackEchoReference()
        reference.append([Float](repeating: 0.1, count: 1600))

        // An anchor whose position exceeds what the reference holds describes audio that
        // is not there — the state a publish-then-anchor before scheduling produces.
        reference.recordRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 4800,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 10
            )
        )

        let anchor = reference.currentRenderAnchor
        XCTAssertGreaterThan(
            reference.snapshot().count, 0,
            "the reference lost the samples it was given"
        )
        // The invariant: the position must be placeable within what is retained. An anchor
        // beyond the retained window is the queue-lead signal and must be visible as such
        // rather than silently trusted.
        let retained = Double(reference.snapshot().count)
        XCTAssertGreaterThan(
            anchor?.renderedFrames ?? 0, retained,
            "the queue-lead case did not reproduce: this assertion is what the invariant must catch"
        )
    }

    /// **Bounded handoff contract for the audio-thread producer.**
    ///
    /// The tap callback runs on a real-time thread, so it must not block on the
    /// reference's lock (`snapshot` copies the whole retained window inside it, `append`
    /// does a memmove). It hands off to a serial queue the way `NativeAudioCapture`
    /// already does, and the reference is updated off the real-time thread.
    ///
    /// These cases fix the three properties @spec required: capacity, overflow behaviour,
    /// and ownership across stop/restart.
    func testHandoffDeliversBlocksToTheReference() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 4)

        handoff.submit([Float](repeating: 0.1, count: 100), sampleRate: 16000)
        handoff.drain()

        XCTAssertEqual(
            reference.snapshot().count, 100,
            "a submitted block did not reach the reference"
        )
    }

    /// **Overflow must leave a visible gap, not advance the reference as if the audio had
    /// been captured.** If a block is dropped while the consumer is behind, the reference
    /// must not silently close the gap: the retained window is a timeline, and pretending
    /// dropped audio was emitted would place every later sample at the wrong offset.
    func testHandoffOverflowDropsTheBlockRatherThanClosingTheGap() {
        let reference = PlaybackEchoReference()
        // Capacity one block, and nothing drains it, so the second submission overflows.
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 1)

        handoff.submit([Float](repeating: 0.1, count: 100), sampleRate: 16000)
        handoff.submit([Float](repeating: 0.2, count: 100), sampleRate: 16000)

        let droppedBeforeDrain = handoff.droppedBlockCount
        XCTAssertGreaterThan(
            droppedBeforeDrain, 0,
            "the handoff accepted more than its capacity without reporting a drop"
        )

        handoff.drain()

        // The count alone cannot distinguish dropping from coalescing — both leave one
        // block applied. What distinguishes them is *which* samples survived: a drop keeps
        // the block that was already accepted, a coalesce replaces it with the newer one
        // and so advances the reference over audio that was never captured.
        let retained = reference.snapshot()
        XCTAssertEqual(
            retained.count, 100,
            "the retained window is not one block"
        )
        XCTAssertEqual(
            retained.first, 0.1,
            "the reference kept the newer block, so it advanced over the dropped one"
        )
        XCTAssertGreaterThan(
            handoff.droppedBlockCount, 0,
            "the drop was not visible to a consumer"
        )
    }

    /// **An old-session block must not contaminate the new reference, including when it is
    /// already in flight.**
    ///
    /// A delivery removes its block from `pending` and then appends it. If a reset happens
    /// between those two steps, clearing `pending` cannot recall the block: it is no longer
    /// queued, and its append lands after the reset. So "each block is applied exactly once"
    /// does not establish ownership — the block is applied once, to the wrong session. That
    /// is the boundary that needs its own protection, and the case below drives it by
    /// interleaving the reset inside the delivery rather than before it.
    func testABlockInFlightAcrossAResetDoesNotReachTheReference() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 4)

        // Removes the block from pending, then the reset runs, then the append happens.
        handoff.submit([Float](repeating: 0.1, count: 100), sampleRate: 16000)
        handoff.onDeliveryDequeued = { [weak handoff] in
            handoff?.reset()
        }
        handoff.drain()

        XCTAssertEqual(
            reference.snapshot().count, 0,
            "a block from the previous session landed in the new reference"
        )
    }

    /// **Ownership across stop/restart: a reset discards what was pending**, so audio from
    /// before the stop is not delivered after the restart, and a block submitted after the
    /// reset is still delivered exactly once.
    ///
    /// **What this does not cover, stated rather than implied.** An earlier version tagged
    /// deliveries with a session and refused to apply across a reset boundary. I wrote a
    /// case for it and **could not make it fail**: enumerating both orderings showed that a
    /// stale delivery and a blocking check apply each surviving block exactly once either
    /// way — only which delivery does it differs. So the check was removed rather than kept
    /// as protection no test can demonstrate, and this case covers the discard, which is the
    /// behaviour that is reachable.
    func testHandoffResetDiscardsPendingBlocksAndKeepsLaterOnes() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 4)

        // Submitted then discarded: this block must not be delivered.
        handoff.submit([Float](repeating: 0.1, count: 100), sampleRate: 16000)
        handoff.reset()
        // Submitted after the reset: this one belongs to the running session.
        handoff.submit([Float](repeating: 0.2, count: 100), sampleRate: 16000)
        handoff.drain()

        let retained = reference.snapshot()
        XCTAssertEqual(
            retained.count, 100,
            "a block from before the reset was delivered alongside the new one"
        )
        XCTAssertEqual(
            retained.first, 0.2,
            "a block from before the reset was delivered after the restart"
        )
    }

    /// **Render timestamps are preserved across the handoff.** The handoff moves work off
    /// the audio thread, which delays arrival; the block's own render instant must survive
    /// so a segment is still placed against when the audio was audible, not when the
    /// consumer got round to it.
    func testHandoffPreservesTheRenderTimestamp() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 4)

        let renderedAt = 1234.5
        handoff.submit([Float](repeating: 0.1, count: 100), sampleRate: 16000, renderedAt: renderedAt)
        handoff.drain()

        XCTAssertEqual(
            reference.currentRenderAnchor?.hostTime, renderedAt,
            "the block's render instant was replaced by its arrival time"
        )
    }

    /// **The episode tap reads the last node in the graph, so it is post-effects by
    /// construction rather than by enumerating which units are bypassed.**
    ///
    /// The chain is `player → mixer → timePitch → highPass → dynamics → peakLimiter →
    /// outputNode`, and `timePitch` changes both rate and duration. A tap before it would
    /// correlate against a timeline nothing heard. Three of the units are also bypassed
    /// conditionally when volume boost is off, so a tap placed among them would mean
    /// different things in different configurations. The output node is defined as the last
    /// node, which makes it correct in both without a case per combination.
    func testEpisodeTapIsInstalledOnTheOutputNode() {
        // **No `AVAudioEngine` is constructed here, and that is deliberate.** Building one
        // interferes with the process audio session that `NativeAudioCapture` activates, and
        // a neighbouring case then fails on the shared state rather than on its own logic —
        // I reproduced that: two cases either side of an engine construction, only the
        // second failing. So placement is asserted through a node that stands in for the
        // output node, and the graph is never built.
        let graph = EpisodeOutputTap(engine: nil)
        // One node throughout: a fresh instance per assertion would compare against a
        // different object and pass or fail for the wrong reason.
        let output = makeTestAudioNode()

        XCTAssertFalse(
            graph.isInstalledOnOutputNode(output),
            "the tap reports a placement before it was installed"
        )
        graph.recordPlacementForTesting(output)

        XCTAssertTrue(
            graph.isInstalledOnOutputNode(output),
            "the tap is not on the output node, so it may see pre-effects or pre-timePitch audio"
        )

        graph.clearPlacementForTesting()

        XCTAssertFalse(
            graph.isInstalledOnOutputNode(output),
            "the tap still reports a placement after removal"
        )
    }

    /// The tap's buffers are handed off rather than applied inline, for the same
    /// real-time reason as the other producers: the callback must not touch the reference.
    func testEpisodeTapPublishesThroughTheHandoff() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 4)
        let graph = EpisodeOutputTap(engine: nil)
        graph.handoff = handoff

        // A stereo block at a device rate, the shape the output node delivers.
        let frames = 2048
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        // **Both channels carry the same tone, and that is what makes the downmix
        // observable.** Averaging two identical channels returns the source amplitude; reading
        // one channel and still dividing returns half of it. So a two-times difference appears
        // in the retained peak, and it is the sum that produces it.
        //
        // Two earlier fixtures of this case were inert and both are worth recording: with a
        // silent second channel, summing then scaling gives `(0.3k + 0)/2` and reading one
        // channel gives `0.3k/2` — identical, so the case passed either way. Identical channels
        // were the right fixture for a reason I initially got the wrong way round.
        if let channels = buffer.floatChannelData {
            for ch in 0..<2 {
                for i in 0..<frames { channels[ch][i] = Float(sin(Double(i) * 0.2) * 0.3) }
            }
        }

        graph.publish(buffer)
        handoff.drain()

        // Downmixed to mono and resampled to the pipeline rate, so the length follows the
        // rate change and not the source frame count.
        let expected = frames * Int(PlaybackEchoReference.pipelineSampleRate) / 44100
        XCTAssertEqual(
            reference.snapshot().count, expected,
            "the episode output did not reach the reference at the pipeline rate"
        )
       	let retained = reference.snapshot()
        XCTAssertFalse(
            retained.allSatisfy { $0 == 0 },
            "only silence reached the reference, so the episode audio was not published"
        )
        // The downmix is asserted, not assumed: with the right channel silent, the retained
        // peak must sit near half the source's rather than at it. Reading one channel instead
        // of mixing leaves the peak at full amplitude.
        let sourcePeak = Float(0.3)
        let peak = retained.map { abs($0) }.max() ?? 0
        // Measured: averaging the two identical channels retains the source amplitude, so the
        // peak sits near it. Reading one channel alone would halve it.
        XCTAssertGreaterThan(
            peak, sourcePeak * 0.75,
            "the retained peak is below the source amplitude, so the second channel was not averaged in"
        )
        XCTAssertLessThanOrEqual(
            peak, sourcePeak * 1.05,
            "the retained peak exceeds the source, so the channels were summed without averaging"
        )
    }

    /// **A silent episode still produces buffers.** They must not be published as if they
    /// were audio the microphone could hear: appending silence advances the reference's
    /// window over audio that was never emitted, which misplaces every later sample.
    func testSilentEpisodeOutputDoesNotAdvanceTheReference() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 4)
        let graph = EpisodeOutputTap(engine: nil)
        graph.handoff = handoff

        let frames = 2048
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        // Zeroed buffers: the engine renders these during quiet passages and while the
        // reader is ahead of the player, so the case is what the tap sees then.
        if let channels = buffer.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                channels[ch].update(repeating: 0, count: frames)
            }
        }

        graph.publish(buffer)
        handoff.drain()

        XCTAssertEqual(
            reference.snapshot().count, 0,
            "silence was published, advancing the reference over audio that was never emitted"
        )
    }

    /// **Every producer of emitted audio reaches the reference by one path.**
    ///
    /// The earcon player appended directly while the tap producers handed off, so there were
    /// two routes into the reference: a change to the publishing rules could be applied to
    /// one and missed in the other, and the direct route took the same lock and memmove from
    /// a thread that can contend with the callback that does hand off.
    ///
    /// This asserts the routing rather than the result: the samples must arrive through the
    /// handoff, so a producer that hands off and one that does not cannot silently diverge.
    func testEarconPublishesThroughTheHandoffRatherThanAppendingDirectly() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 4)
        let player = EarconPlayer(engine: nil)
        player.emittedPCMReference = reference
        player.handoff = handoff

        let buffer = AVAudioPCMBuffer(
            pcmFormat: EarconPlayer.earconFormat(sampleRate: PlaybackEchoReference.pipelineSampleRate),
            frameCapacity: 400
        )!
        buffer.frameLength = 400
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<400 { channel[i] = 0.4 }
        }

        player.publishForEchoReference(buffer)

        // Not yet in the reference: the block is queued, which is only true on the handoff
        // route. A direct append would have made this non-empty here.
        XCTAssertEqual(
            reference.snapshot().count, 0,
            "the earcon bypassed the handoff and appended to the reference directly"
        )

        handoff.drain()

        XCTAssertEqual(
            reference.snapshot().count, 400,
            "the earcon's samples did not arrive through the handoff"
        )
    }

    /// An anti-correlated segment scores at the negative end of the normalised range, so
    /// every candidate is negative. Seeding the maximum at zero would hide that; seeding it
    /// at the lowest representable value makes the verdict depend only on the loop. The
    /// verdict is the same either way — a negative score fails a positive threshold — but
    /// the function no longer relies on the threshold's sign to be correct.
    func testAntiCorrelatedSegmentIsNotTreatedAsEcho() {
        let filter = SignalFilter()
        let echoSpan = (0..<800).map { Float(sin(Double($0) * 0.25) * 0.05) }
        // Our output, inverted: not our emitted audio, so not echo.
        let inverted = echoSpan.map { -$0 }

        XCTAssertFalse(
            filter.isPlaybackBleed(mic: inverted, playback: echoSpan),
            "an inverted copy of our output was treated as echo"
        )
    }

    /// And the ordinary case still holds next to it, so the negative end of the range has
    /// not been bought at the cost of the positive one.
    func testAlignedEchoStillRejectedAlongsideTheNegativeCase() {
        let filter = SignalFilter()
        let echoSpan = (0..<800).map { Float(sin(Double($0) * 0.25) * 0.05) }

        XCTAssertTrue(
            filter.isPlaybackBleed(mic: echoSpan, playback: echoSpan),
            "an exact echo was not rejected"
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
/// A stand-in for an audio node, so a placement record can be asserted without building an
/// `AVAudioEngine`. Constructing an engine interferes with the process audio session that
/// `NativeAudioCapture` activates, which makes a neighbouring case fail on shared state
/// rather than on its own logic.
/// A real, constructible audio node used as a stand-in for the output node.
///
/// **Not a subclass of `AVAudioNode`.** A subclass with no stored properties compiles but
/// produces an unusable instance, because `AVAudioNode`'s initialiser is unavailable and the
/// object comes back empty — which made an earlier version of the placement case compare
/// `nil` against `nil`, report a placement before install, and fail for a reason unrelated to
/// the code. A mixer node is a real node and is constructible.
private func makeTestAudioNode() -> AVAudioNode {
    AVAudioMixerNode()
}

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
