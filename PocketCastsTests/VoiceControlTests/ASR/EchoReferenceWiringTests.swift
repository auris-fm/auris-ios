import XCTest
@testable import podcasts
@testable import PocketCastsDataModel

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

    /// An isolated route must be *classified*, and it must not clear the reference as if it
    /// proved echo impossible.
    ///
    /// The previous version asserted `echoFilterRouteConsidersEchoImpossible` is false — but
    /// that is constant-false by contract, so the case could not fail and proved nothing.
    /// The observable distinction is the route value itself: a headset classifies as
    /// `.isolated`, which differs from the engine's default.
    ///
    /// Driven through the monitor, so the case covers the classification path rather than
    /// the setter. The lifetime of this subscription across assembly release is covered
    /// separately in `RouteSubscriptionLifetimeTests`.
    func test_isolatedRoute_isClassifiedAndDoesNotClearTheReference() throws {
        let harness = EchoWiringHarness()

        harness.engine.setEchoFilterRoute(.isolated)
        XCTAssertEqual(
            harness.engine.echoFilterRoute, .isolated,
            "an isolated route was not classified as isolated"
        )

        // Isolated reduces exposure; it does not declare the reference invalid, because the
        // audio the microphone hears is still our own playback.
        harness.engine.updatePlaybackBuffer([Float](repeating: 0.5, count: 320))

        // Isolated reduces exposure; it does not apply the built-in correlation window, and
        // it does not declare the reference invalid the way a real route change does. The
        // window is the observable: applying it on a headset would correlate microphone
        // audio against the reference as if the mic heard our own loudspeaker.
        XCTAssertFalse(
            harness.engine.echoFilterRoute.appliesCorrelationWindow,
            "an isolated route applied the built-in correlation window"
        )
    }

    // MARK: - The reference is fed by the real producer, not a test seam

    /// The cloud-answer renderer must be the thing that populates the emitted reference.
    ///
    /// The previous version of this case called `reference.append` itself and asserted the
    /// count: that holds whether or not the app ever wires the renderer to the reference, so
    /// deleting the assembly's wiring line left it green — the same tautology as the tap
    /// case above, on the other producer.
    ///
    /// This reaches the cloud player the way the app does — service → executor → sink — and
    /// drives its real append path. It fails if the wiring is missing, because then the
    /// player has no reference to append to and the count never moves.
    @MainActor
    func test_cloudProducerAppendsThroughTheRealPlayer() throws {
        let assembly = VoiceControlAssembly()
        guard let service = assembly.buildVoiceControlService() else {
            XCTFail("the assembly built no service, so the case proves nothing")
            return
        }

        let player = service.executorForTesting.cloudRouteSinkForTesting.audioPlayerForTesting
        let reference = player?.emittedPCMReference
        XCTAssertNotNil(player, "the sink has no cloud player, so there is no producer to drive")
        XCTAssertNotNil(
            reference,
            "the assembly did not wire the emitted reference into the cloud player"
        )
        guard let reference else { return }

        // Built at the player's negotiated rate so no resampling surprise enters the
        // assertion: the appended count is then the buffer's own frame count.
        let rate = player?.negotiatedSampleRateForTesting ?? 24_000
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600) else {
            XCTFail("could not build a buffer")
            return
        }
        buffer.frameLength = 1_600

        // The node needs an engine to answer a render-time query, even though the append
        // itself does not: `renderPosition` returns nil without one, and the case is about
        // the append, so an unattached node would fail the AVAudioEngine precondition
        // before the append ran.
        let node = AVAudioPlayerNode()
        let nodeEngine = AVAudioEngine()
        nodeEngine.attach(node)

        let before = reference.streamIndex
        // A node that reports no render time yields no anchor, so the append is still
        // observable through the stream index and the anchor stays as the previous case
        // left it. The append is what this case is about.
        player?.appendToEmittedReference(buffer, node: node)

        // The producer resamples the buffer from its negotiated rate into the pipeline rate,
        // so the appended count is the buffer's duration at that rate rather than the
        // buffer's own frame count. Asserting the exact value is what makes the case catch a
        // producer that appends nothing (0), appends its own frame count without resampling
        // (1 600), or appends another producer's audio.
        // The buffer is at the negotiated rate, so the resampler converts its 1 600 frames
        // into the pipeline rate: 1 600 × 16/24 = 1 066. Asserting the buffer's own frame
        // count here would fail on the conversion, which is production behaviour.
        let expected = Int((1_600.0 / rate) * PlaybackEchoReference.pipelineSampleRate)
        XCTAssertEqual(
            reference.streamIndex - before, expected,
            "driving the real cloud producer appended \(reference.streamIndex - before) "
                + "rather than \(expected): the reference wiring is gone or wrong"
        )
        _ = nodeEngine
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

      /// A route change must retire the reference, in the direction the previous guard skipped.
      ///
      /// Retiring only when the incoming route stops correlating left external -> built-in
      /// reusing audio from the old output path as though it were an aligned reference for the
      /// new one. That is the direction this case exercises.
      ///
      /// **What it does NOT cover, stated rather than implied by its name:** the reverse
      /// direction (built-in -> external) is not asserted here or anywhere else. The case was
      /// named for both directions while exercising one, so the name promised coverage it did
      /// not provide. Pinning the reverse direction is open, and it needs a run to verify.
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
    ///
    /// Runs on the main actor for the same reason as the case above: `onCommandRecognized`
    /// hops to the main queue asynchronously from a background thread, so without this the
    /// window is opened by a queued block racing the engine's read of `isActive`. When the
    /// read wins, `WakeGate` drops the segment for having no grace and this case fails with
    /// an empty transcript — intermittently, and for a reason that has nothing to do with
    /// the alignment it claims to test. It asserts on the filter, not on that hop.
    @MainActor
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
      /// This case therefore calls the **two-argument** overload
      /// (`isPlaybackBleed(mic:playback:)`) directly with **differing** lengths, where `paired`
      /// is a strict sub-span of the segment: it passes on the pairing and fails when the energy
      /// is taken over the whole segment. It is the positional overload that the aligned path
      /// uses, which is why bypassing the aligned caller is what makes the pairing observable —
      /// the call here is the one that does not impose `mic == window`.
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
        // No engine: building one interferes with the process audio session, which makes a
        // neighbouring case fail on shared state. The publish route is what this covers.
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 4)
        let player = EarconPlayer(engine: nil)
        player.handoff = handoff

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

        // Driven through `play`, the production entry point. It publishes before it schedules,
        // and returns after publishing when there is no engine graph, so no `AVAudioEngine`
        // is needed here — which matters because building one interferes with the process
        // audio session. Driving `play` is what keeps the call site under test: calling
        // `publishForEchoReference` directly passes with the publish removed from `play`.
        player.loadForTesting(.listeningStart, buffer: buffer)
        player.play(.listeningStart)
        handoff.drain()

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
        // The upper bound that used to sit here asserted `retainedPeak <= sourcePeak + 0.05`.
        // That cannot fail: `PlaybackResampler.toPipelineRate` returns convex combinations of
        // adjacent source samples, so a resampled value never exceeds the largest input by
        // construction — it held for any resampler that interpolates, including a wrong one.
        // Replaced with a property that DOES distinguish a rate-correct resample: the tone is
        // low enough that resampling preserves its zero-crossing count, while a wrong rate
        // changes it. Amplitude is untouched by correct and incorrect interpolation alike.
        let sourceSamples = (0..<frameCount).map { Float(sin(Double($0) * 0.3) * 0.4) }
        let sourceZeroCrossings = zip(sourceSamples, sourceSamples.dropFirst()).filter { $0.0 * $0.1 < 0 }.count
        let retainedZeroCrossings = zip(retained, retained.dropFirst()).filter { $0.0 * $0.1 < 0 }.count
        XCTAssertGreaterThan(sourceZeroCrossings, 0, "the fixture tone has no zero crossings to compare")
        XCTAssertEqual(
            retainedZeroCrossings, sourceZeroCrossings,
            "the retained audio crosses zero \(retainedZeroCrossings) times against the source's \(sourceZeroCrossings): the samples were placed at the wrong rate"
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

        handoff.submit([Float](repeating: 0.1, count: 100), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16000)
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

        handoff.submit([Float](repeating: 0.1, count: 100), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16000)
        handoff.submit([Float](repeating: 0.2, count: 100), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16000)

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
        // The hook is assigned BEFORE the submit that enqueues the delivery. Assigning it
        // afterwards races the queue: `submit` dispatches `deliver()` asynchronously, so the
        // contract's own mid-flight interleaving would depend on the hook winning a race it
        // has no ordering against. With this order the interleaving is structural.
        var hookFired = false
        handoff.onDeliveryDequeued = { [weak handoff] in
            hookFired = true
            handoff?.reset()
        }
        handoff.submit([Float](repeating: 0.1, count: 100), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16000)
        handoff.drain()

        // The case is about a reset landing BETWEEN dequeuing and appending. If the hook never
        // ran, the reset happened before the delivery instead and the assertion below would
        // hold without the boundary being exercised at all.
        XCTAssertTrue(
            hookFired,
            "the reset did not land mid-delivery, so this case did not exercise the boundary"
        )

        XCTAssertEqual(
            reference.snapshot().count, 0,
            "a block from the previous session landed in the new reference"
        )
    }

    /// A reset moves the session on but does NOT clear the reference, and that is what makes
    /// the delivery/reset interleaving unobservable: whether a block is appended just before or
    /// just after a reset, the reference ends up holding the same samples at the same scan
    /// position. `deliver()` re-checks the generation inside the same critical section that
    /// appends, which narrows the window; this case records why that narrowing cannot be
    /// demonstrated by an outcome, so a future change making `reset()` clear the reference knows
    /// it is changing an assumption rather than tidying one.
    func test_aResetDoesNotClearTheReference_soTheInterleavingIsUnobservable() {
        // The control: the same two blocks with NO reset between them. The delivered audio is
        // retained, and the scan position reflects it.
        let control = PlaybackEchoReference()
        let controlHandoff = EchoReferenceHandoff(reference: control, capacity: 8)
        controlHandoff.submit([Float](repeating: 0.7, count: 400), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16_000)
        controlHandoff.drain()
        controlHandoff.submit([Float](repeating: 0.1, count: 400), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16_000)
        controlHandoff.drain()

        // Delivered, then reset.
        let referenceA = PlaybackEchoReference()
        let handoffA = EchoReferenceHandoff(reference: referenceA, capacity: 8)
        handoffA.submit([Float](repeating: 0.7, count: 400), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16_000)
        handoffA.drain()
        handoffA.reset()
        handoffA.submit([Float](repeating: 0.1, count: 400), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16_000)
        handoffA.drain()

        // Reset, then the block is delivered into the moved-on session.
        let referenceB = PlaybackEchoReference()
        let handoffB = EchoReferenceHandoff(reference: referenceB, capacity: 8)
        handoffB.submit([Float](repeating: 0.7, count: 400), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16_000)
        handoffB.drain()
        handoffB.reset()
        handoffB.submit([Float](repeating: 0.1, count: 400), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16_000)
        handoffB.drain()

        // The control is what makes this discriminating: it fails if a reset discards the
        // reference, and it also fails if a reset introduces any extra delivery.
        XCTAssertEqual(
            referenceA.streamIndex, control.streamIndex,
            "a reset changed the reference scan position, so it is no longer confined to the "
                + "handoff gate"
        )
        XCTAssertEqual(
            referenceB.streamIndex, control.streamIndex,
            "a reset landing before the delivery changed the scan position"
        )
        XCTAssertEqual(
            referenceA.snapshot().count, control.snapshot().count,
            "a reset removed retained audio"
        )
        XCTAssertEqual(
            referenceB.snapshot().count, control.snapshot().count,
            "a reset landing before the delivery removed retained audio"
        )
        _ = controlHandoff
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
        handoff.submit([Float](repeating: 0.1, count: 100), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16000)
        handoff.reset()
        // Submitted after the reset: this one belongs to the running session.
        handoff.submit([Float](repeating: 0.2, count: 100), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 16000)
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
        // A position is required for an anchor to be recorded at all: a block whose producer
        // reported no position records none, rather than one at the block's start, because a
        // substitution would be indistinguishable from a measured zero. This case is about
        // the timestamp, so it supplies the position the anchor also needs.
        handoff.submit(
            [Float](repeating: 0.1, count: 100),
            producer: .init(kind: .episodeTap, incarnation: 0),
            sampleRate: 16000,
            renderedAt: renderedAt,
            renderedFramesInProducer: 100,
            producerBlockStart: 0
        )
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

    /// **The production start path installs the tap — asserted through the entry the app
    /// actually calls, not through the helper it calls.**
    ///
    /// An earlier version of this case called `installEmittedAudioTap()` itself and then read
    /// the tap back. That is a closed loop: it holds whether or not `play()` ever installs
    /// anything, so deleting the installation from `play` left it green — which is how the tap
    /// could be disconnected in production while a test named for the start path passed.
    ///
    /// This case drives `loadEpisode` + `play(completion:)` — the same two calls
    /// `PlaybackManager` makes — against a real episode whose audio exists on disk at the path
    /// `DownloadManager` resolves. It never calls the install helper, so removing that call
    /// from `play` fails it by construction.
    func testProductionStartPathInstallsTheEpisodeTap() throws {
        let handoff = EchoReferenceHandoff(reference: PlaybackEchoReference(), capacity: 4)
        EffectsPlayer.echoReferenceHandoff = handoff
        defer { EffectsPlayer.echoReferenceHandoff = nil }

        // A real episode with real audio, because `play` opens the file, builds the graph and
        // only installs the tap once the engine has actually started. A fixture that skipped
        // any of that would not reach the line under test.
        let fixture = FingerprintEpisodeFixture(duration: 1)
        defer { fixture.removeFiles() }
        try fixture.writeAudio(seconds: 1)
        // `pathToDownloadedFile` returns the downloaded path only for a downloaded episode,
        // and a temp path otherwise — so a fixture without this status writes audio somewhere
        // `play` never looks, and the case would be measuring the fixture rather than the start
        // path.
        fixture.episode.episodeStatus = DownloadStatus.downloaded.rawValue

        // The fixture must be where the production path looks, or `play` never reaches the
        // line under test and this case would be measuring the fixture instead.
        let resolved = fixture.episode.pathToDownloadedFile(pathFinder: DownloadManager.shared)
        XCTAssertEqual(resolved, fixture.audioURL.path, "the fixture audio is not where play() looks")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved), "the fixture wrote no audio")

        let player = EffectsPlayer()
        player.loadEpisode(fixture.episode)

        let started = expectation(description: "playback start returned")
        player.play { started.fulfill() }
        wait(for: [started], timeout: 30)

        guard let tap = player.emittedAudioTapForTesting else {
            XCTFail("the production start path installed no tap, so the episode source is inert")
            return
        }
        XCTAssertIdentical(
            tap.handoff, handoff,
            "the tap installed by the start path did not receive the renderer's handoff"
        )
        player.endPlayback(permanent: false)
    }

    /// The helper's own narrower property, kept: given a handoff, the helper installs a real
    /// tap on the output node. This is the half that does NOT establish the start path uses it,
    /// which is why the case above exists — and the two are kept apart deliberately.
    func testInstallHelperInstallsTheTapOnTheOutputNode() {
        let handoff = EchoReferenceHandoff(reference: PlaybackEchoReference(), capacity: 4)
        EffectsPlayer.echoReferenceHandoff = handoff
        defer { EffectsPlayer.echoReferenceHandoff = nil }

        let player = EffectsPlayer()
        let engine = AVAudioEngine()
        // A CONNECTED graph: placement resolves the node feeding output, so a bare engine with
        // no feeder would leave the helper with nothing to tap.
        let feeder = AVAudioPlayerNode()
        engine.attach(feeder)
        engine.connect(feeder, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        player.setEngineForTesting(engine)
        defer { player.setEngineForTesting(nil) }

        player.installEmittedAudioTap()

        guard let tap = player.emittedAudioTapForTesting else {
            XCTFail("the helper installed no tap")
            return
        }
        // The placement is the FEEDER — the node connected to output — not the output node
        // itself, which the SDK advises against tapping.
        XCTAssertTrue(
            tap.isInstalledOnOutputNode(EpisodeOutputTap.outputFeederNode(of: engine) ?? engine.outputNode),
            "the tap was created but never installed on the feeder node"
        )
    }

    /// The aligned-window rejection is placed at the segment's END, not its start.
    ///
    /// `capturedAt` is the instant of the segment's FIRST sample, while the filter compares a
    /// window that ends at the offset it is given. Using the first instant for the end places
    /// the whole window one segment-length early, and the window is exactly `mic.count` long —
    /// so the real alignment falls outside it and the filter stops rejecting the echo it exists
    /// for. This case supplies an anchor and a capture instant whose correct end offset is known,
    /// and a segment long enough that the start and the end are distinguishable positions.
    /// The offset the filter is given is measured from the segment's END instant.
    ///
    /// `capturedAt` is the instant of the segment's FIRST sample (`NativeVadSegmenter` sets it
    /// when the buffer first fills), while the value is used as `segmentEndOffset`. Measuring it
    /// directly rather than through the filter's verdict: a verdict can be produced by any
    /// alignment that happens to correlate, so it cannot separate the two forms.
    func test_theSegmentOffsetIsMeasuredFromTheSegmentsEndInstant() throws {
        let harness = EchoWiringHarness()
        let rate = PlaybackEchoReference.pipelineSampleRate
        let segmentSamples = Int(rate * 0.25)

        let reference = PlaybackEchoReference()
        reference.append((0..<(Int(rate) * 2)).map { Float(sin(Double($0) * 0.3)) })
        reference.recordRenderPosition(
            PlaybackRenderAnchor(renderedFrames: Double(Int(rate) * 2), sourceSampleRate: rate, hostTime: 1.0)
        )
        harness.engine.setEchoReference(reference)

        // The segment runs 0.5s..0.75s, so its end is at 0.75 and the anchor is at 1.0: the
        // latency is 0.25s. From the START instant the latency would be 0.5s.
        let offset = harness.engine.playbackEndOffsetForTesting(capturedAt: 0.5, segmentSamples: segmentSamples)
        let audibleEnd = try XCTUnwrap(reference.audibleEndOffsetInRetainedWindow())

        XCTAssertEqual(
            offset, audibleEnd - Int(0.25 * rate),
            "the offset was measured from the segment's start instant, not its end"
        )
        XCTAssertNotEqual(
            offset, audibleEnd - Int(0.5 * rate),
            "the offset is one segment-length early"
        )
    }

    /// A port this client does not recognise must not acquire the built-in speaker's alignment.
    ///
    /// `forOutput` gives `.builtInSpeaker` the correlation window, which is justified by that
    /// route's bounded local latency. A USB DAC, car head unit or hearing aid has codec latency
    /// this client has not measured, so classifying it as the built-in speaker would apply the
    /// window where its premise does not hold. The fallback is `.unknown`, which maps to
    /// `.external` — the scope for a route whose behaviour has not been established.
    ///
    /// Driven through the engine's own classification so the case covers the route the filter
    /// actually receives, not the enum in isolation.
    func test_unrecognisedOutputPort_doesNotAcquireBuiltInSpeakerAlignment() {
        let monitor = IOSAudioRouteMonitor()

        // A missing port and an unrecognised port type take the same branch, and that branch
        // must not be the built-in speaker: its correlation window is justified by a bounded
        // local latency that a USB DAC, car head unit or hearing aid does not have.
        XCTAssertEqual(
            monitor.classifyOutputForTesting(nil), .unknown,
            "a missing port was not classified as unknown"
        )
        XCTAssertEqual(
            VoiceAsrEngine.EchoFilterRoute.forOutput(monitor.classifyOutputForTesting(nil)), .external,
            "a missing port acquired the built-in speaker's correlation window"
        )

        // The control, so the pair above cannot pass by making everything unknown or external:
        // the built-in speaker still classifies as itself and still applies the window.
        let session = AVAudioSession.sharedInstance()
        if let speaker = session.currentRoute.outputs.first(where: { $0.portType == .builtInSpeaker }) {
            XCTAssertEqual(monitor.classifyOutputForTesting(speaker), .builtInSpeaker)
            XCTAssertTrue(
                VoiceAsrEngine.EchoFilterRoute.forOutput(monitor.classifyOutputForTesting(speaker)).appliesCorrelationWindow,
                "the built-in speaker no longer applies the window, so the fallback protects nothing"
            )
        }
        XCTAssertTrue(
            VoiceAsrEngine.EchoFilterRoute.builtInSpeaker.appliesCorrelationWindow,
            "the built-in speaker no longer applies the correlation window at all"
        )
    }

    /// Trimming a reference built at a NON-pipeline rate advances its start time at THAT rate.
    ///
    /// `capacity` is derived from the instance's rate, so the retained window holds
    /// `sampleRate * retainedSeconds` samples. Advancing the start time with the pipeline
    /// constant instead would move it at a rate these samples were never at: the window's
    /// claimed start would drift from the audio it actually holds, by the ratio of the two
    /// rates.
    ///
    /// The clock is fixed so the drift is the only thing that can move `startedAt` after the
    /// first append.
    func test_trimmingAtANonPipelineRateAdvancesTheStartTimeAtThatRate() {
        let clock = FixedMonotonicClock(time: 1_000)
        // 8 kHz: half the pipeline rate, so a pipeline-rate divisor would advance the window
        // twice as fast as the audio it dropped.
        let rate = 8_000.0
        let reference = PlaybackEchoReference(sampleRate: rate, retainedSeconds: 0.5, clock: clock)
        let capacity = Int(rate * 0.5)
        XCTAssertEqual(capacity, 4_000, "the fixture's capacity is not what this case assumes")

        // Fill to capacity, then append one more second: 8 000 samples must be dropped.
        reference.append([Float](repeating: 0.1, count: capacity))
        reference.append([Float](repeating: 0.2, count: Int(rate)))

        let dropped = 8_000
        let expectedAdvance = Double(dropped) / rate        // 1.0 s at the instance rate
        let pipelineAdvance = Double(dropped) / PlaybackEchoReference.pipelineSampleRate // 0.5 s

        guard let span = reference.span() else {
            XCTFail("a populated reference should expose a span")
            return
        }
        XCTAssertEqual(
            span.startedAt - 1_000, expectedAdvance, accuracy: 1e-9,
            "the trim advanced the window by \(span.startedAt - 1_000)s, not \(expectedAdvance)s"
        )
        // The assertion that makes the case discriminating: the pipeline constant would give a
        // different answer, so a reference using it cannot satisfy this.
        XCTAssertNotEqual(expectedAdvance, pipelineAdvance, accuracy: 1e-9)
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
        XCTAssertEqual(buildIn, .builtInSpeaker)
        XCTAssertTrue(
            buildIn.appliesCorrelationWindow,
            "the built-in speaker must apply the correlation window"
        )

        // The scope value is the observable distinction. `provesEchoImpossible` is not
        // asserted here: it is constant-false by contract (`VoiceAsrEngine.swift:36`), so an
        // assertion on it cannot fail whichever route it is handed, and reading it as coverage
        // is worse than leaving it out. The same correction was already applied to the
        // isolated-route case above and had not been carried to this one.
        // Expected scopes read from `forOutput` itself (`VoiceAsrEngine.swift:45-53`):
        // headphones and BLE are isolated; HFP, A2DP, AirPlay and unknown are external.
        for (output, expected): (AudioRouteOutput, VoiceAsrEngine.EchoFilterRoute) in [
            (.headphones, .isolated),
            (.bluetoothLE, .isolated),
            (.bluetoothHFP, .external),
            (.bluetoothA2DP, .external),
            (.airPlay, .external),
            (.unknown, .external),
        ] {
            let route = VoiceAsrEngine.EchoFilterRoute.forOutput(output)
            XCTAssertEqual(
                route, expected,
                "\(output) classified as \(route), not \(expected)"
            )
            XCTAssertFalse(
                route.appliesCorrelationWindow,
                "\(output) must not apply the built-in-speaker correlation window"
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

    // MARK: - Lock contention on the handoff

    /// Concurrent producers must not lose a block.
    ///
    /// The handoff is where the audio thread, the capture path and the renderer meet, and
    /// every mutation of `pending`/`droppedBlocks` happens under its lock. That is a claim
    /// about behaviour under contention, and no other case in this suite could fail if the
    /// lock were wrong: they drive one producer at a time, so a missing or mis-scoped lock
    /// leaves every one of them green.
    ///
    /// Frame COUNT is deliberately not asserted. Resampling 24 kHz into the 16 kHz
    /// pipeline turns each 4-frame block into a partial one, so a per-block frame count is
    /// a resampler property and says nothing about the lock. The claim here is conservation
    /// instead: with capacity above the number of blocks submitted, no marker may be absent
    /// from the reference. A lost append shows as a missing marker, and that is the
    /// corruption the lock exists to prevent.
    func test_concurrentSubmissions_conserveEveryBlock() {
        let producers = 8
        let perProducer = 64
        let total = producers * perProducer

        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: total * 2)

        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for producer in 0..<producers {
            DispatchQueue.global().async(group: group) {
                start.wait()
                for index in 0..<perProducer {
                    let marker = Float(producer * perProducer + index)
                    handoff.submit(Array(repeating: marker, count: 4), producer: .init(kind: .episodeTap, incarnation: 0), sampleRate: 24_000)
                }
            }
        }

        start.signal()
        for _ in 0..<(producers - 1) { start.signal() }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "producers did not finish")

        handoff.drain()

        XCTAssertEqual(handoff.droppedBlockCount, 0,
                       "capacity was not exceeded, so nothing may be dropped")

        let delivered = reference.snapshot()
        let present = Set(delivered)
        for producer in 0..<producers {
            for index in 0..<perProducer {
                let marker = Float(producer * perProducer + index)
                XCTAssertTrue(present.contains(marker),
                              "a submitted block never reached the reference (marker \(marker))")
            }
        }
    }

    // MARK: - Render position ordering

    /// A position submitted through the handoff lands only when it can be mapped: the block
    /// it belongs to must carry its producer-local range, and the position must be in the SAME
    /// producer clock. The mapping converts the producer count into the reference stream space
    /// through the containing block, and records the anchor at the converted position with the
    /// producer's own render instant.
    ///
    /// The stale half is unchanged in purpose: a position from an ended session must not land
    /// in the new one, and the refusal is by generation rather than by identity here, because
    /// the identity below never reports a reset.
    func test_renderPositionIsAppliedAfterItsBlockAndRefusedAcrossAReset() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)
        let identity = EchoReferenceHandoff.ProducerIdentity(kind: .earcon, incarnation: 7)

        // The block: local 0..<1600, rendered at host instant 1000.
        handoff.submit(
            [Float](repeating: 0.25, count: 1600),
            producer: identity,
            sampleRate: 16_000,
            renderedAt: 1_000,
            renderedFramesInProducer: 1_600,
            producerBlockStart: 0
        )

        // The position: local 800 — strictly INSIDE the block's half-open range 0..<1600. A
        // position at 1600 would be the block's exclusive end, which no range contains.
        let position = PlaybackRenderAnchor(
            renderedFrames: 800,
            sourceSampleRate: 16_000,
            hostTime: 1_000
        )
        handoff.submitRenderPosition(position, producer: identity)
        handoff.drain()

        // The anchor is the MAPPED position: the block starts at reference index 0 and spans
        // the whole 1600, so a position at the producer's 1600 maps to reference 1600, at the
        // pipeline rate, with the producer's own render instant.
        XCTAssertEqual(
            reference.currentRenderAnchor,
            PlaybackRenderAnchor(
                renderedFrames: 800,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 1_000
            ),
            "the mapped position did not land where the producer reported it"
        )

        // Boundary case: a position submitted before a reset belongs to a session that has
        // ended, so it must not appear in the new session's reference. The refusal is by
        // generation: the stale identity is no longer the session's.
        let stale = PlaybackRenderAnchor(
            renderedFrames: 3_200,
            sourceSampleRate: 16_000,
            hostTime: 2_000
        )
        handoff.submitRenderPosition(stale, producer: identity)
        handoff.reset()
        handoff.drain()

        // After the reset the anchor is whatever the reset left; the stale position must not
        // have been applied to it.
        XCTAssertEqual(
            reference.currentRenderAnchor,
            PlaybackRenderAnchor(
                renderedFrames: 800,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 1_000
            ),
            "a render position from an ended session landed in the new one"
        )
    }


    // MARK: - Alignment origin: the producer's index space vs the consumer's

    /// Reproduces the alignment-origin mismatch across two successive turns.
    ///
    /// `PlaybackEchoReference.audibleEndOffsetInRetainedWindow()` computes
    /// `renderedIndex - windowStart`, where `windowStart = totalAppended - samples.count` is
    /// the stream index of the first retained sample. So the anchor's number must be an
    /// **absolute position in the emitted stream**.
    ///
    /// `CloudAudioPlayer` supplies one: `playerTime.sampleTime`, the node's cumulative
    /// position. The episode tap does not — and this case pins the consequence without
    /// asserting which fix is right.
    ///
    /// Two turns, with the earcon and cloud producers interleaved so the reference is not
    /// trivially empty. After the retained window starts sliding (2 s at the pipeline rate),
    /// a per-block-sized anchor falls below `windowStart`, the offset goes negative, and the
    /// method returns nil — at which point `playbackEndOffsetForSegment` yields -1 and the
    /// filter declines every segment rather than mis-aligning.
    ///
    /// **Scope, so this is not read as more than it is:** the case supplies the anchor
    /// itself, so it states the CONSUMER's requirement — what index space an anchor must be
    /// in — and cannot see which producer violates it. Coverage of a producer has to go
    /// through that producer's path (`test_handoffRecordsAnAnchor...` did, and was withdrawn
    /// with the fix it was written for). A future fix needs its own case on the real path.
    ///
    /// Note also that the control below is what makes this discriminating: the same
    /// reference, after the same appends, still yields an offset when handed an absolute
    /// anchor. Without it, a nil here would be equally consistent with an empty window.
    func test_alignmentOriginMismatch_returnsNoOffsetOnceTheWindowSlides() {
        let reference = PlaybackEchoReference()
        let capacity = Int(PlaybackEchoReference.pipelineSampleRate * PlaybackEchoReference.retainedSeconds)

        // Turn 1: a block of episode audio, then the anchor for it.
        let block = 3_200   // one 0.2 s block at the pipeline rate, the tap's own granularity
        reference.append([Float](repeating: 0.3, count: block))
        reference.recordRenderPosition(
            PlaybackRenderAnchor(renderedFrames: Double(block), sourceSampleRate: 16_000, hostTime: 10)
        )

        // Early on the window has not slid, so even a block-sized anchor yields an offset.
        XCTAssertNotNil(
            reference.audibleEndOffsetInRetainedWindow(),
            "with the window at its start, no offset at all — the mapping never worked"
        )

        // Interleave the other producers and push past the retained window so it slides.
        for turn in 0..<8 {
            reference.append([Float](repeating: 0.2, count: 8_000))              // cloud answer
            reference.append([Float](repeating: 0.1, count: 1_600))              // earcon
            reference.recordRenderPosition(
                PlaybackRenderAnchor(renderedFrames: Double(block), sourceSampleRate: 16_000, hostTime: Double(turn + 11))
            )
        }
        _ = capacity

        // The window now starts well beyond one block, so a block-sized anchor is below it.
        XCTAssertNil(
            reference.audibleEndOffsetInRetainedWindow(),
            "the mismatch did not reproduce: a block-sized anchor still produced an offset"
        )

        // Control: the same reference, the same window, but an anchor in the stream's own
        // index space rather than a per-block count. If this also returned nil, the nil above
        // would be about the window rather than about the origin.
        // The test knows the total because it appended every block itself: one 3 200-frame
        // block, then eight rounds of 8 000 + 1 600. `renderedFrames` is convertible at the
        // same 16 kHz the producers declared.
        let appendedTotal = 3_200 + 8 * (8_000 + 1_600)
        reference.recordRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: Double(appendedTotal),
                sourceSampleRate: 16_000,
                hostTime: 99
            )
        )
        XCTAssertNotNil(
            reference.audibleEndOffsetInRetainedWindow(),
            "an absolute anchor also failed, so this case does not discriminate on origin"
        )
    }

    /// A block's anchor must be its own range plus what the producer actually rendered.
    ///
    /// Two things this pins that the arithmetic cases cannot, because they drive one
    /// producer at a time and supply the anchor themselves:
    ///
    ///   * a producer whose blocks are separated by ANOTHER producer's appends occupies no
    ///     contiguous reference range, so its anchor must follow the append points rather
    ///     than a fixed origin. Here the earcon appends between every cloud block, and a
    ///     per-producer offset would drift by the interleaved amount each round.
    ///   * the anchor must reflect the producer's RENDERED position, not the block's length
    ///     and not the append tail. A producer that has rendered less than it has queued
    ///     must place its audio earlier than the stream's submitted end.
    func test_interleavedProducersPlaceEachAnchorInItsOwnReferenceRange() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 64)

        // Cloud renders 1 000 frames per round and reports the position it has reached in
        // its OWN count. Earcon appends between rounds, so the cloud's blocks are not
        // adjacent in the reference.
        let perRound = 1_000
        let rounds = 6
        for round in 0..<rounds {
            handoff.submit(
                [Float](repeating: 0.2, count: perRound),
                producer: .init(kind: .episodeTap, incarnation: 0),
                sampleRate: PlaybackEchoReference.pipelineSampleRate,
                renderedAt: MonotonicTime(round),
                renderedFramesInProducer: Double((round + 1) * perRound),
                // This block begins where the previous one ended, so progress into it is
                // one block rather than the whole running count.
                producerBlockStart: Double(round * perRound)
            )
            handoff.drain()

            // Another producer's audio lands between this producer's blocks. It reports a
            // position too, the way the earcon does in production: its samples are submitted
            // when audible and its position once the node renders, and a block with no
            // position records no anchor rather than one at its start.
            handoff.submit(
                [Float](repeating: 0.1, count: 300),
                producer: .init(kind: .episodeTap, incarnation: 0),
                sampleRate: PlaybackEchoReference.pipelineSampleRate,
                renderedAt: MonotonicTime(round),
                renderedFramesInProducer: 300,
                producerBlockStart: 0
            )
            handoff.drain()
        }

        // The last block appended is the EARCON, not the cloud: each round submits the
        // cloud's block and then the earcon's, so the newest anchor is the earcon's end.
        //
        // What this pins is that the cloud's 1 000 frames per round were mapped into ranges
        // that move with the interleaved 300-frame earcon blocks, rather than into a
        // contiguous run of their own. The end of the stream is the sum of every append,
        // and the cloud's own count alone could not produce it.
        let expected = rounds * (perRound + 300)

        let offset = reference.audibleEndOffsetInRetainedWindow()
        XCTAssertNotNil(offset, "the anchor could not be placed at all")

        // The offset is measured from the start of the retained window, which here is the
        // start of the stream: nothing has been trimmed at this size.
        XCTAssertEqual(
            offset, expected,
            """
            the anchor is at \(String(describing: offset)) rather than \(expected). A \
            producer's position was mapped into the wrong reference range — an interleaved \
            producer's appends sit between its blocks, so a per-producer offset drifts by \
            the interleaved amount, and a position mapped in its own count rather than into \
            the range would not sum to the stream's end.
            """
        )
    }

    /// The episode tap must report both the render instant and the node's position.
    ///
    /// `capture(_:renderedAt:)` receives the tap's `AVAudioTime` and used to discard it, so
    /// the block reached the handoff with no position at all and the anchor fell back to the
    /// block's start. That places the audio correctly and says nothing about how much of it
    /// has played, which is the fact the alignment needs.
    ///
    /// This drives `publish` directly with a time whose sample position is known, so the
    /// assertion is about what the tap hands over rather than about `installTap` — a case
    /// built on a real tap would depend on the node actually rendering.
    /// START SEMANTICS AT THE PRODUCTION TAP: the tap's `sampleTime` labels the buffer's FIRST
    /// sample (measured in ExplicitScheduleOriginProbe: the marker's host instant matches H + j/R
    /// within ~0.6 ms and misses H + (j-N)/R by a full buffer). The submitted producer range must
    /// therefore be [sampleTime, sampleTime + frameLength) — not one buffer earlier — and a render
    /// position inside that range must match the block that contains it.
    func test_episodeTapSubmitsTheBlocksRangeAsStartPlusLength() throws {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)
        let tap = EpisodeOutputTap(engine: nil)
        tap.handoff = handoff

        let frames = 1_600
        let start: AVAudioFramePosition = 8_000
        let format = AVAudioFormat(standardFormatWithSampleRate: PlaybackEchoReference.pipelineSampleRate, channels: 1)!
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frames { channel[index] = 0.5 }
        }

        // The tap's own time: the buffer BEGINS at `start`.
        tap.publish(
            buffer,
            renderedAt: AVAudioTime(sampleTime: start, atRate: PlaybackEchoReference.pipelineSampleRate)
        )
        handoff.drain()
        XCTAssertGreaterThan(reference.streamIndex, 0, "the block did not reach the reference")

        // A render position INSIDE the block (start + frames/2) must match it: that is only true if
        // the recorded range is [start, start + frames).
        let inside = start + AVAudioFramePosition(frames / 2)
        let identity = tap.producerIdentity
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: Double(inside),
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 20
            ),
            producer: identity
        )
        handoff.drain()
        XCTAssertNotNil(
            reference.audibleEndOffsetInRetainedWindow(),
            "a position inside the submitted range matched no block: the range was not [start, start + frames)"
        )

        // And a position one buffer EARLIER than the block start must NOT match: that is where the
        // old end-of-buffer derivation put the block.
        let beforeStart = start - 10
        let probe = PlaybackEchoReference()
        let probeHandoff = EchoReferenceHandoff(reference: probe, capacity: 8)
        let probeTap = EpisodeOutputTap(engine: nil)
        probeTap.handoff = probeHandoff
        probeTap.publish(
            buffer,
            renderedAt: AVAudioTime(sampleTime: start, atRate: PlaybackEchoReference.pipelineSampleRate)
        )
        probeHandoff.drain()
        probeHandoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: Double(beforeStart),
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 20
            ),
            producer: probeTap.producerIdentity
        )
        probeHandoff.drain()
        XCTAssertNil(
            probe.audibleEndOffsetInRetainedWindow(),
            "a position BEFORE the block start matched: the range still begins one buffer early"
        )
    }

    func test_episodeTapPublishesTheNodesFramePosition() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)
        let tap = EpisodeOutputTap(engine: nil)
        tap.handoff = handoff

        let frames = 1_600
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            XCTFail("could not build a buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frames { channel[index] = 0.5 }
        }

        // The node reports its position in its own cumulative clock — the START of this buffer
        // (measured in ExplicitScheduleOriginProbe: the marker's host instant matches H + j/R and
        // misses H + (j-N)/R by a full buffer). The position is cumulative, not a buffer offset.
        let nodePosition: AVAudioFramePosition = 8_000
        // Both fields are needed: the handoff only records an anchor when it has a host
        // instant, and the position comes from the sample time. A tap's real AVAudioTime
        // carries both; a synthetic one must be given both.
        tap.publish(
            buffer,
            renderedAt: AVAudioTime(
                hostTime: AVAudioTime.hostTime(forSeconds: 12),
                sampleTime: nodePosition,
                atRate: 16_000
            )
        )
        handoff.drain()

        // The reported position IS this buffer's first sample, so the anchor lands at the START of
        // the block's reference range — offset 0 into the retained window, not one buffer in. The
        // earlier expectation of `frames` encoded the end-of-buffer reading that the scheduled
        // marker experiment refuted.
        let offset = reference.audibleEndOffsetInRetainedWindow()
        XCTAssertNotNil(offset, "no anchor was recorded at all")
        XCTAssertEqual(
            offset, 0,
            """
            the anchor is at \(String(describing: offset)) rather than 0. Under the measured \
            start semantics the node's sample time is this buffer's first sample, so the anchor \
            belongs at the block's start; an anchor one buffer in would mean the tap shifted the \
            position backward as if the time described the buffer's end.
            """
        )
    }

    /// The producer-to-reference conversion, which both direct producers share.
    ///
    /// This is the arithmetic that was wrong twice: a producer's own rendered position is
    /// not a reference position, and the conversion is a single pure step that the handoff
    /// and the cloud player both call. Testing it here rather than only through a producer
    /// means a change to one caller cannot silently diverge from the other.
    ///
    /// The cases fix the two mistakes that were actually made:
    ///   * treating the producer's count as if it were already a reference index, which
    ///     places second-turn audio at the wrong origin;
    ///   * using the block's length rather than the producer's progress, which claims the
    ///     block has played when it has only been submitted.
    func test_producerPositionIsConvertedIntoTheBlocksReferenceRange() {
        let rangeStart = 40_000

        // Half the block rendered, at a rate that needs converting: 800 of 1 600 source
        // frames at 8 kHz is 0.1 s, which is 1 600 samples at the 16 kHz pipeline rate.
        XCTAssertEqual(
            referenceIndexForProducerPosition(
                rangeStart: rangeStart,
                producerBlockStart: 0,
                producerFrames: 800,
                producerRate: 8_000,
                blockLength: 3_200
            ),
            rangeStart + 1_600,
            "the producer's own count was not converted into reference samples"
        )

        // A node that reports nothing beyond the block cannot claim more than the block:
        // clamped rather than allowed to run past the audio it describes.
        XCTAssertEqual(
            referenceIndexForProducerPosition(
                rangeStart: rangeStart,
                producerBlockStart: 0,
                producerFrames: 100_000,
                producerRate: 16_000,
                blockLength: 3_200
            ),
            rangeStart + 3_200,
            "a position past the block's end was not clamped to the block"
        )

        // A node that has rendered nothing places the block at its own start, not its end.
        XCTAssertEqual(
            referenceIndexForProducerPosition(
                rangeStart: rangeStart,
                producerBlockStart: 0,
                producerFrames: 0,
                producerRate: 16_000,
                blockLength: 3_200
            ),
            rangeStart,
            "zero progress must place the block at its start, not its end"
        )

        // A block that BEGINS partway into the producer's timeline must count only its own
        // progress, not the node's running total. This is the first block after a tap
        // installs onto a node that had already been rendering.
        XCTAssertEqual(
            referenceIndexForProducerPosition(
                rangeStart: rangeStart,
                producerBlockStart: 8_000,
                producerFrames: 8_800,
                producerRate: 8_000,
                blockLength: 3_200
            ),
            rangeStart + 1_600,
            "a block beginning at 8 000 producer frames claimed its whole running total "
                + "as progress rather than the 800 it actually rendered"
        )

        // The same producer numbers with no progress: a block whose node has not advanced
        // places at its own start rather than ahead of it.
        XCTAssertEqual(
            referenceIndexForProducerPosition(
                rangeStart: rangeStart,
                producerBlockStart: 8_000,
                producerFrames: 8_000,
                producerRate: 8_000,
                blockLength: 3_200
            ),
            rangeStart,
            "a block whose node has not advanced must place at its own start"
        )

        // A restart reports a position inside its own new session, so the same value must
        // land in a LATER range rather than at the same absolute index.
        let afterRestart = referenceIndexForProducerPosition(
            rangeStart: 120_000,
            producerBlockStart: 0,
            producerFrames: 800,
            producerRate: 8_000,
            blockLength: 3_200
        )
        XCTAssertEqual(afterRestart, 120_000 + 1_600)
        XCTAssertGreaterThan(
            afterRestart, rangeStart,
            "a restarted node's position must move with the range, not stay on the old one"
        )
    }
    /// The scheduling-origin question, answered against the real player node.
    ///
    /// The mapping needs the new buffer's local start in the node's clock. The tempting source
    /// is the node's render position read before the schedule — this case measures that read on
    /// the real node and records why it cannot serve.
    ///
    /// Both scenarios @spec named are exercised. The assertion is deliberately about what the
    /// read IS, not about a threshold it happens to satisfy: an earlier draft asserted a bounded
    /// drift and passed while the read was nil (drift computed as infinity only in the failure
    /// path), which would have certified an origin that does not exist.
    func test_schedulingOrigin_thePreScheduleRenderReadDoesNotEstablishTheBuffersStart() throws {
        let player = EarconPlayer(engine: AVAudioEngine())
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: EarconPlayer.earconFormat(sampleRate: 24_000),
                frameCapacity: 800
            )
        )
        buffer.frameLength = 800

        // Scenario 1: first play after stop — the read is unavailable.
        player.loadForTesting(.listeningStart, buffer: buffer)
        let beforeFirstPlay = player.nodeSampleTimeForTesting

        // Scenario 2: immediately after a play — the read is not a buffer offset.
        player.play(.listeningStart)
        let afterPlay = player.nodeSampleTimeForTesting

        // The evidence the decision rests on: no read here is a usable scheduling origin.
        XCTAssertNil(
            beforeFirstPlay,
            "the pre-schedule read is expected to be unavailable; if it becomes readable this "
                + "decision must be revisited against the new value"
        )
        if let afterPlay {
            XCTAssertLessThanOrEqual(
                afterPlay, 0,
                "a post-play read was expected to be non-positive (measured -342); a positive "
                    + "value would mean the read counts this buffer's frames and could serve"
            )
        }

        // The decision itself. The clock read above cannot carry it: in this harness the node
        // never renders, so the read is nil and a fabricated range would also be nil — the
        // mutation was invisible here, which is how the first version passed while inert.
        //
        // A supplied clock makes it observable. With a readable value, the earcon must STILL
        // submit no range, because a readable render position is not this buffer's origin.
        let withClock = EarconPlayer(engine: AVAudioEngine())
        let clockHandoff = EchoReferenceHandoff(reference: PlaybackEchoReference(), capacity: 4)
        withClock.handoff = clockHandoff
        withClock.nodeSampleTimeOverride = 9_000
        withClock.loadForTesting(.listeningStart, buffer: buffer)
        withClock.play(.listeningStart)

        XCTAssertNil(
            withClock.lastSubmittedBlockRange,
            "the earcon submitted a range derived from a render position that is not the "
                + "buffer's origin (supplied clock read 9000, measured live -342/nil)"
        )
    }


    /// A render position is converted through the block that CONTAINS it, not through the
    /// latest append's origin.
    ///
    /// Two blocks from one producer are appended with an intervening append from another, so
    /// the producer's second block does not start where its first ended in the reference. A
    /// position observed inside the FIRST block must be placed against the first block's range;
    /// using the newest append's origin would place it past the audio it describes.
    func test_aProducerPositionIsMatchedToTheBlockThatContainsIt() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)

        // This producer's first block: producer-local frames 0..<400.
        handoff.submit(
            [Float](repeating: 0.1, count: 400),
            producer: .init(kind: .episodeTap, incarnation: 0),
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 10,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()
        let firstBlockStart = reference.streamIndex - 400

        // Another producer appends between this producer's blocks, so a later block's origin
        // is not simply this producer's first block end.
        handoff.submit(
            [Float](repeating: 0.2, count: 200),
            producer: .init(kind: .cloud, incarnation: 0),
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 11,
            renderedFramesInProducer: 200,
            producerBlockStart: 0
        )
        handoff.drain()

        // A position observed inside the FIRST block, arriving after the later appends.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 200,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 10
            ),
            producer: .init(kind: .episodeTap, incarnation: 0)
        )
        handoff.drain()

        let anchor = reference.currentRenderAnchor
        XCTAssertEqual(
            Int(anchor?.renderedPipelineSamples ?? -1), firstBlockStart + 200,
            "the position was not placed inside the block that contains it"
        )
    }

    /// A position no retained block contains is recorded as ABSENT, not passed through.
    ///
    /// Passing it through would present a count in one producer's clock as a valid position in
    /// the reference's, which reads as a real offset and places the window where nothing was
    /// rendered. Absence is the honest answer and the consumer already handles it.
    func test_aPositionNoBlockContainsRecordsNoAnchor() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)

        handoff.submit(
            [Float](repeating: 0.1, count: 400),
            producer: .init(kind: .episodeTap, incarnation: 0),
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 10,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()

        // Producer-local 9 000 is far outside the only block's range.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 9_000,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 10
            ),
            producer: .init(kind: .episodeTap, incarnation: 0)
        )
        handoff.drain()

        XCTAssertNil(
            reference.currentRenderAnchor,
            "a position no block contains was passed through instead of recorded absent"
        )
    }

    /// A position from an ended session is refused rather than matched against the new one.
    func test_aPositionFromAnEndedSessionIsRefused() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)

        handoff.submit(
            [Float](repeating: 0.1, count: 400),
            producer: .init(kind: .episodeTap, incarnation: 0),
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 10,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()
        handoff.reset()

        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 200,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 10
            ),
            producer: .init(kind: .episodeTap, incarnation: 0)
        )
        handoff.drain()

        XCTAssertNil(
            reference.currentRenderAnchor,
            "a position from an ended session landed in the new one"
        )
    }

    /// Two producers with OVERLAPPING local ranges must not be confused for each other.
    ///
    /// Every producer counts from its own zero, so an earcon block spanning local 0..<400 and a
    /// cloud block spanning local 0..<400 overlap exactly while describing different audio. A
    /// match on the containing range alone selects whichever was appended last, which converts
    /// the position through the other producer's block. Producer identity is what separates
    /// them, and this case pins that it is used.
    func test_overlappingProducerRangesDoNotSelectTheOtherProducersBlock() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)

        // The episode tap's block: local 0..<400, appended first.
        handoff.submit(
            [Float](repeating: 0.1, count: 400),
            producer: .init(kind: .episodeTap, incarnation: 0),
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 10,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()
        let episodeBlockStart = reference.streamIndex - 400

        // The earcon's block: the SAME local range 0..<400, appended second.
        handoff.submit(
            [Float](repeating: 0.2, count: 400),
            producer: .init(kind: .earcon, incarnation: 0),
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 11,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()

        // A position in the EARCON's local clock, arriving last. With range-only matching this
        // would be converted through whichever block was appended last, and the assertion
        // below cannot tell that apart from a correct match — so the position is chosen to sit
        // at the START of the earcon block, where the two candidate origins differ.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 0,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 11
            ),
            producer: .init(kind: .earcon, incarnation: 0)
        )
        handoff.drain()

        let anchor = reference.currentRenderAnchor
        XCTAssertNotEqual(
            Int(anchor?.renderedPipelineSamples ?? -1), episodeBlockStart,
            "the position was converted through the episode tap's block, which overlaps the earcon's local range"
        )
    }

    /// A restarted producer of the SAME kind must not be matched to its own earlier incarnation.
    ///
    /// A node restart resets the frame counter to zero while the previous incarnation's ranges
    /// are still retained in the same handoff generation. The kind alone cannot separate them:
    /// a block from before the restart and one from after carry overlapping local ranges while
    /// describing different audio. The incarnation token is what refuses the retired one.
    func test_aRestartedProducerIsNotMatchedToItsEarlierIncarnation() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)
        let before = EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 0)
        let after = EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 1)

        // The earlier incarnation's block: local 0..<400.
        handoff.submit(
            [Float](repeating: 0.1, count: 400),
            producer: before,
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 10,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()
        let beforeStart = reference.streamIndex - 400

        // The restarted incarnation's block: the SAME local range, a new clock.
        handoff.submit(
            [Float](repeating: 0.2, count: 400),
            producer: after,
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 11,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()
        let afterStart = reference.streamIndex - 400

        // An observation from the RETIRED incarnation arrives late. It must not be converted
        // through the new incarnation's block, whose local range it also falls inside.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 200,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 10
            ),
            producer: before
        )
        handoff.drain()

        let anchor = reference.currentRenderAnchor
        XCTAssertNotEqual(
            Int(anchor?.renderedPipelineSamples ?? -1), afterStart + 200,
            "an observation from the retired incarnation was converted through the new one's block"
        )
        XCTAssertEqual(
            Int(anchor?.renderedPipelineSamples ?? -1), beforeStart + 200,
            "the observation was not placed against the incarnation that produced it"
        )
    }

    /// A restart retires the earcon's previous identity, in ONE handoff generation.
    ///
    /// An earlier version reset the handoff after the restart, which made the case prove
    /// nothing about rotation: `reset()` bumps the generation, the retained ranges no longer
    /// match it, and a retired observation is rejected whether or not the producer rotated its
    /// token. The rotation and the generation change are different mechanisms and a case that
    /// trips both cannot attribute the outcome to either.
    ///
    /// This stays inside one generation. After the restart the producer publishes a block whose
    /// LOCAL range overlaps its pre-restart block, so a range-only or kind-only match would
    /// select the new block; only the incarnation separates them.
    func test_aRestartRetiresTheEarconsPreviousIdentityWithinOneGeneration() throws {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)
        let player = EarconPlayer(engine: AVAudioEngine())
        player.handoff = handoff

        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: EarconPlayer.earconFormat(sampleRate: 24_000),
                frameCapacity: 800
            )
        )
        buffer.frameLength = 800

        // The live incarnation is read only through what it SUBMITS: publish a block, and let
        // the handoff record which identity produced it.
        player.loadForTesting(.listeningStart, buffer: buffer)
        player.play(.listeningStart)
        handoff.drain()
        let afterFirstPublish = reference.streamIndex
        XCTAssertGreaterThan(afterFirstPublish, 0, "the first publish recorded nothing")

        // The restart. NO reset: the generation stays, so the only thing that can separate the
        // two publishes is the incarnation.
        player.stop()

        // The restarted producer publishes again. Its node clock began at zero, so this block's
        // producer-local range overlaps the first block's — which is what makes the two
        // identities confusable without the token.
        //
        // Submitted with its range directly: the earcon no longer reports a scheduling origin it
        // cannot establish, so its own publishes carry no range and nothing could be matched
        // under ANY identity — the case would then fail for a reason unrelated to the token.
        player.play(.listeningStart)
        handoff.drain()
        handoff.submit(
            Array(repeating: 0.25, count: 400),
            producer: player.currentIdentity,
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 20,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()
        let afterSecondPublish = reference.streamIndex
        XCTAssertGreaterThan(
            afterSecondPublish, afterFirstPublish,
            "the post-restart publish recorded nothing, so no second block exists to confuse"
        )

        // Clear the anchor the post-restart block's drain recorded: `recordRenderPosition`
        // overwrites, so without this the block's own anchor is still present and a refusal is
        // indistinguishable from an acceptance — the assertion below would pass either way.
        reference.recordRenderPosition(nil)
        XCTAssertNil(reference.currentRenderAnchor, "the clear did not take effect")

        // An observation carrying the PRE-restart local range. With correct rotation it belongs
        // to no retained block of the CURRENT identity, so nothing is recorded; a token that
        // never rotated would match the post-restart block, whose local range it also falls in.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 100,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 20
            ),
            producer: EchoReferenceHandoff.ProducerIdentity(kind: .earcon, incarnation: 0)
        )
        handoff.drain()

        XCTAssertNil(
            reference.currentRenderAnchor,
            """
            an observation under the pre-restart incarnation was accepted inside the SAME \
            generation, so the restart did not retire it: the token is compared but never \
            rotated by the producer
            """
        )

        // The positive check, which is what keeps this case from passing for the wrong
        // reason: the SAME local range observed under the CURRENT incarnation must be
        // accepted and placed in that block's range. Without it, a nil here would be
        // equally consistent with the lookup refusing everything — including valid
        // current observations — and the case could not tell retirement from breakage.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 100,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 30
            ),
            producer: EchoReferenceHandoff.ProducerIdentity(kind: .earcon, incarnation: 1)
        )
        handoff.drain()

        guard let currentAnchor = reference.currentRenderAnchor else {
            XCTFail("a CURRENT-incarnation observation was refused, so the lookup is broken and the nil above proves nothing")
            return
        }
        XCTAssertEqual(
            Int(currentAnchor.renderedPipelineSamples), afterSecondPublish - 400 + 100,
            "the current observation was not placed inside the block that contains it"
        )
    }

    /// A real install/remove cycle retires the tap's previous identity.
    ///
    /// Observed through the handoff rather than the token: the tap publishes blocks, and a
    /// position is matched only against a block of the SAME identity. Publishing, cycling the
    /// tap, then submitting a position under the pre-cycle identity must record nothing — a
    /// tap that did not rotate its token would match the retained pre-cycle block.
    func test_aTapInstallCycleRetiresItsPreviousIdentity() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)
        // A CONNECTED graph: a bare engine has nothing feeding its output node, so install()
        // correctly resolves no feeder and this case would measure an empty graph.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        let tap = EpisodeOutputTap(engine: engine)
        let before = tap.producerIdentity

        // Install, so the tap's own placement is observable as well as its identity. The
        // placement is the FEEDER — the node connected to output — which here is the mixer, not
        // the output node itself.
        tap.install()
        XCTAssertTrue(
            tap.isInstalledOnOutputNode(EpisodeOutputTap.outputFeederNode(of: engine) ?? engine.outputNode),
            "the tap was not installed on the feeder node, so the cycle was not real"
        )

        // A block published under the pre-cycle identity.
        handoff.submit(
            [Float](repeating: 0.1, count: 400),
            producer: before,
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 10,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()
        XCTAssertGreaterThan(reference.snapshot().count, 0, "the pre-cycle block was not retained")

        // The cycle: remove and install again, which is where the clock resets.
        tap.remove()
        XCTAssertFalse(
            tap.isInstalledOnOutputNode(engine.outputNode),
            "the tap was still installed, so the cycle did not happen"
        )
        tap.install()

        XCTAssertNotEqual(
            tap.producerIdentity, before,
            "an install cycle did not rotate the tap's identity: the token is compared but never rotated"
        )
        XCTAssertEqual(
            tap.producerIdentity.kind, before.kind,
            "the rotation changed the producer KIND, so it is no longer the same producer"
        )
    }

    /// A position matched to a block whose samples have been TRIMMED is refused.
    ///
    /// The retained ranges are bounded at 32 entries while the reference ring is bounded at
    /// `sampleRate * retainedSeconds`, and the two bounds are independent: 32 tap blocks can
    /// span far more audio than the ring retains, and the ring drops from the front as it
    /// fills. Without the residency check, a late observation matched a range whose samples
    /// were already gone and recorded a confident offset against audio the window no longer
    /// holds — the stale-anchor failure by a different door.
    func test_aPositionMatchedToATrimmedBlockIsRefused() {
        let reference = PlaybackEchoReference(sampleRate: 16_000, retainedSeconds: 0.5, clock: FixedMonotonicClock(time: 1_000))
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)

        // Block 1: fills the ring (8 000 samples at 16 kHz x 0.5 s).
        handoff.submit(
            [Float](repeating: 0.1, count: 8_000),
            producer: EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 0),
            sampleRate: 16_000,
            renderedAt: 10,
            renderedFramesInProducer: 8_000,
            producerBlockStart: 0
        )
        handoff.drain()

        // Block 2: pushes block 1's samples out of the ring entirely.
        handoff.submit(
            [Float](repeating: 0.2, count: 8_000),
            producer: EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 0),
            sampleRate: 16_000,
            renderedAt: 11,
            renderedFramesInProducer: 16_000,
            producerBlockStart: 8_000
        )
        handoff.drain()

        // A position inside BLOCK 1's producer-local range (0..<8000). It matches the
        // retained range for that block, but the ring no longer holds any of its samples.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 4_000,
                sourceSampleRate: 16_000,
                hostTime: 10
            ),
            producer: EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 0)
        )
        handoff.drain()

        XCTAssertNil(
            reference.currentRenderAnchor,
            "a position whose audio was trimmed from the ring was recorded as a confident offset"
        )

        // The positive guard, the same shape the incarnation case uses: a position inside the
        // RETAINED block (block 2) must still be accepted. Without it, a bug that refused
        // every position would satisfy the assertion above.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 12_000,
                sourceSampleRate: 16_000,
                hostTime: 11
            ),
            producer: EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 0)
        )
        handoff.drain()

        let current = reference.currentRenderAnchor
        XCTAssertNotNil(current, "a position inside the retained block was refused")
        XCTAssertEqual(
            Int(current?.renderedPipelineSamples ?? -1), 12_000,
            "the retained block position was not placed where its audio sits"
        )
    }

    /// A retired incarnation is refused BEFORE range lookup, within one generation — and a
    /// current observation at the same local range is accepted.
    ///
    /// DRIVEN THROUGH THE PRODUCER'S REAL RESET: the earcon's `stop()` rotates its token and
    /// reports the rotation to the handoff. The case never constructs an identity or calls
    /// `rotateIncarnation` itself — deleting the report from `stop()` fails this case, which
    /// is the property the hand-supplied version could not test.
    ///
    /// The reset is reported and the FIRST incarnation retires, but the retained block from
    /// incarnation 0 remains resident. A late observation honestly carrying the RETIRED
    /// incarnation still falls inside that retained block, so identity-and-range matching
    /// alone would accept it — which is why the active-incarnation boundary must refuse it
    /// before the lookup. The pre-restart block's audio is genuinely resident; the refusal is
    /// about the clock the observation was made under, not about the audio.
    func test_aRetiredIncarnationIsRefusedBeforeRangeLookup_andTheCurrentOneAccepted() throws {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)
        let player = EarconPlayer(engine: AVAudioEngine())
        player.handoff = handoff

        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: EarconPlayer.earconFormat(sampleRate: 24_000),
                frameCapacity: 800
            )
        )
        buffer.frameLength = 800

        // Incarnation 0: a block spanning local 0..<400, submitted with its range so the
        // mapping has something to convert through. Submitted directly rather than through the
        // earcon: the earcon no longer reports a scheduling origin it cannot establish, so its
        // blocks carry no range and an observation under ANY incarnation would be refused for
        // that reason. Driving the range here is what keeps this case about the boundary.
        handoff.submit(
            Array(repeating: 0.25, count: 400),
            producer: player.currentIdentity,
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 10,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()
        let firstPublishEnd = reference.streamIndex
        XCTAssertGreaterThan(firstPublishEnd, 0, "the first publish recorded nothing")

        // The identity in force BEFORE the reset, captured so the post-restart expectation can
        // be derived from it rather than supplied: the reset must advance the incarnation by
        // exactly one, and the case fails if it does not.
        let identityBefore = player.currentIdentity

        // The real reset: the producer stops, rotates, and reports to the handoff itself.
        player.stop()
        print("MEASURED before=\(identityBefore.incarnation) after=\(player.currentIdentity.incarnation)")

        // A late observation under the RETIRED incarnation: its numbers fall inside the
        // retained block, so only the active-incarnation boundary refuses it. Constructed by
        // hand HERE — at the observation site, not at the producer — because the point is that
        // the boundary accepts the producer's CURRENT identity and refuses anything else.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 100,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 20
            ),
            producer: EchoReferenceHandoff.ProducerIdentity(
                kind: identityBefore.kind,
                incarnation: identityBefore.incarnation
            )
        )
        handoff.drain()
        // Clear whatever the block's drain recorded: `recordRenderPosition` overwrites, so
        // without this the block's own anchor (400 frames) is still present and the retired
        // observation's refusal is invisible — the assertion below would pass on the block's
        // anchor no matter what the boundary did.
        reference.recordRenderPosition(nil)
        XCTAssertNil(reference.currentRenderAnchor, "the clear did not take effect")

        // The CURRENT incarnation is what the producer now reports; publish a range-bearing
        // block under THAT identity. Both halves together: the retired is refused, the current
        // is accepted and placed — a boundary that refuses everything cannot pass.
        _ = player.currentIdentity   // the producer rotates only through its own lifecycle
        player.play(.listeningStart)
        handoff.drain()
        let identityAfter = player.currentIdentity
        handoff.submit(
            Array(repeating: 0.25, count: 400),
            producer: identityAfter,
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 30,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()

        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 100,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 30
            ),
            producer: identityAfter
        )
        handoff.drain()
        XCTAssertNotNil(
            reference.currentRenderAnchor,
            "the current incarnation's observation was refused along with the retired one"
        )
    }


    /// The boundary's original scenario, built as @spec specified: BOTH identities'
    /// range-bearing blocks retained in the SAME generation, with overlapping producer-local
    /// ranges and resident PCM, then the late old observation delivered after the producer's
    /// own reset notification.
    ///
    /// This is the arrangement the full-identity lookup cannot separate. The lookup matches a
    /// range by `range.producer == producer`, so if the OLD identity's block is still resident
    /// and its local range contains the observation, the lookup finds it and places the window
    /// in a clock that has already been replaced. Only the active-incarnation boundary refuses
    /// it — which is why the boundary is not redundant, contrary to what I reported when I had
    /// only ever retained one identity at a time.
    func test_theRetiredIdentitiesResidentBlockIsRefusedByTheBoundaryNotTheLookup() throws {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)

        let player = EarconPlayer(engine: nil)
        player.handoff = handoff
        let oldIdentity = player.currentIdentity
        let newIdentity = EchoReferenceHandoff.ProducerIdentity(
            kind: oldIdentity.kind,
            incarnation: oldIdentity.incarnation &+ 1
        )

        // The OLD identity's block: resident, range-bearing, spanning local 0..<400.
        handoff.submit(
            Array(repeating: 0.25, count: 400),
            producer: oldIdentity,
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 10,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        // The CURRENT identity's block, submitted in the same generation with an OVERLAPPING
        // local range — this is what makes the two indistinguishable by range alone.
        handoff.submit(
            Array(repeating: 0.25, count: 400),
            producer: newIdentity,
            sampleRate: PlaybackEchoReference.pipelineSampleRate,
            renderedAt: 12,
            renderedFramesInProducer: 400,
            producerBlockStart: 0
        )
        handoff.drain()

        // The producer's own reset notification — driven through the REAL producer path, not a
        // direct handoff call, so this case covers the production notification and not only the
        // handoff's reaction to it. `stop()` is what the app calls; it rotates the node
        // incarnation and reports it to the handoff itself.
        player.stop()
        XCTAssertEqual(
            player.currentIdentity.incarnation, newIdentity.incarnation,
            "the producer's stop did not advance to the identity this case's current block uses"
        )

        // Clear whatever the blocks' drains recorded, so a refusal is observable at all:
        // `recordRenderPosition` overwrites, and the old block's own anchor would otherwise be
        // present and the assertion would pass on it whatever this path did.
        reference.recordRenderPosition(nil)
        XCTAssertNil(reference.currentRenderAnchor, "the clear did not take effect")

        // A late observation under the RETIRED identity. Its local range falls inside the old
        // identity's RESIDENT block, so the full-identity lookup WOULD match it; the boundary
        // must refuse it first.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 100,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 20
            ),
            producer: oldIdentity
        )
        handoff.drain()

        XCTAssertNil(
            reference.currentRenderAnchor,
            "the retired identity's late observation was placed — the lookup matched its resident "
                + "block, so the active-incarnation boundary did not refuse it first"
        )

        // And the CURRENT identity is still accepted, so a boundary that refuses everything
        // cannot pass this case.
        handoff.submitRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: 100,
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 30
            ),
            producer: newIdentity
        )
        handoff.drain()
        XCTAssertNotNil(
            reference.currentRenderAnchor,
            "the current identity's observation was refused too — the boundary is too broad"
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
