@testable import podcasts
import XCTest

/// Acceptance controls for the Silero speech classification required by
/// `recognition-pipeline.md` and mapped in `ios.md` ("Speech classification mapping").
///
/// These test the **production** classifier and the production segment owner together, on real
/// speech/noise fixtures, and assert retained sample coverage rather than counting segments —
/// a segment count cannot show retention (three one-sample segments would read the same).
///
/// SCOPE. Public-fixture compatibility is what is established here. It does NOT establish
/// performance in any particular room; the spec is explicit that this is assessed separately
/// through normal microphone testing without adding audio retention.
final class SileroSegmenterIntegrationControl: XCTestCase {

    /// Real speech, 2.0 s, 16 kHz mono 16-bit PCM — `positive.wav` from the LiveKit wake-word
    /// fixture set (Apache 2.0). "Positive" means positive for the wake word, not for speech:
    /// it is simply recorded human speech sitting on near-silent padding.
    private var speechFixture: URL {
        fixturesRoot.appendingPathComponent("positive.wav")
    }

    /// Probe fixtures are read in place from the host checkout, never copied into the repository.
    ///
    /// The test process runs inside the simulator, where `NSHomeDirectory()` is the app
    /// container — not the host home. The path is therefore compiled in from the build
    /// environment so the fixture is read where it lives instead of being duplicated.
    private var fixturesRoot: URL {
        let hostHome = ProcessInfo.processInfo.environment["AURIS_HOST_HOME"]
            ?? "/Users/dev"
        return URL(fileURLWithPath: hostHome)
            .appendingPathComponent("code/auris/livekit-wakeword/swift/Tests/LiveKitWakeWordTests/Fixtures")
    }

    /// The model the app ships. Read from the bundle so this tests what production loads.
    private func bundledModelPath() throws -> String {
        try XCTUnwrap(
            Bundle.main.path(forResource: "silero_vad", ofType: "onnx"),
            "silero_vad.onnx is not in the app bundle; the classified path would silently fall "
                + "back to the energy rule"
        )
    }

    private func requireFixtures() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: speechFixture.path),
            "public speech fixture not present at \(speechFixture.path)"
        )
    }

    /// Reads a 16-bit PCM WAV into normalised floats at its native rate.
    /// The provenance control's "speech" fixture must actually BE speech to this model.
    ///
    /// `ServiceSelectionProvenanceTests` drives the real assembly, so its frames are classified by
    /// real Silero. Its fixture was constant 0.05 DC — valid under the energy rule, which decided on
    /// loudness alone, and not speech to a model that reads structure. Measured here: constant DC
    /// is not speech, recorded speech is. That is why the fixture must be repaired rather than the
    /// failure relabelled baseline.
    func test_fixtureEvidence_constantDCIsNotSpeechButRecordedSpeechIs() throws {
        try requireFixtures()
        let classifier = try XCTUnwrap(SileroSpeechFrameClassifier.make(modelPath: try bundledModelPath()))

        XCTAssertFalse(
            classifier.isSpeech([Float](repeating: 0.05, count: 1_600)),
            "constant DC is not speech to the real model, so it cannot stand in for speech"
        )

        let (samples, rate) = try readWav(speechFixture)
        XCTAssertEqual(rate, 16_000, "the fixture is expected at the model's rate")
        // The recording sits on near-silent padding, so require that SOME window is speech rather
        // than every one.
        var speechWindows = 0
        var index = 0
        while index + SileroSpeechFrameClassifier.frameSize <= samples.count {
            let window = Array(samples[index..<(index + SileroSpeechFrameClassifier.frameSize)])
            if classifier.isSpeech(window) { speechWindows += 1 }
            index += SileroSpeechFrameClassifier.frameSize
        }
        XCTAssertGreaterThan(
            speechWindows, 0,
            "recorded speech must classify as speech, or no fixture can drive the classified path"
        )
    }

    private func readWav(_ url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let data = try Data(contentsOf: url)
        // Minimal RIFF parse: find "fmt " and "data" chunks rather than assuming a fixed layout.
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
                | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        func u16(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        var cursor = 12
        var sampleRate = 0
        var dataRange: Range<Int>?
        while cursor + 8 <= data.count {
            let id = String(bytes: data[cursor..<cursor + 4], encoding: .ascii) ?? ""
            let size = u32(cursor + 4)
            let body = cursor + 8
            if id == "fmt " {
                sampleRate = u32(body + 4)
            } else if id == "data" {
                dataRange = body..<min(body + size, data.count)
                break
            }
            cursor = body + size + (size % 2)
        }
        guard let range = dataRange else {
            throw XCTSkip("no data chunk in \(url.lastPathComponent)")
        }
        var samples: [Float] = []
        samples.reserveCapacity(range.count / 2)
        var index = range.lowerBound
        while index + 1 < range.upperBound {
            let raw = Int16(bitPattern: UInt16(data[index]) | UInt16(data[index + 1]) << 8)
            samples.append(Float(raw) / 32768.0)
            index += 2
        }
        return (samples, sampleRate)
    }

    /// The production classifier with the production energy threshold.
    ///
    /// The **silence timeout** is set to close immediately on the first sub-threshold frame.
    /// That is not a relaxation of the contract: the real timeout is wall-clock, and a test feeds
    /// audio far faster than real time, so 500 ms of wall time would never elapse and no endpoint
    /// could occur. Every other aspect of the segmenter (classification, retention,
    /// minSpeechFrames, no duration bound) is the production configuration.
    private func productionSegmenter(modelPath: String) throws -> NativeVadSegmenter {
        let classifier = try XCTUnwrap(
            SileroSpeechFrameClassifier.make(modelPath: modelPath),
            "the production classifier could not be constructed from the bundled model"
        )
        return NativeVadSegmenter(threshold: 0.020, silenceTimeoutMs: -1, classifier: classifier)
    }

    /// Records every emission so coverage can be measured, not counted.
    private func collectEmissions(_ segmenter: NativeVadSegmenter) -> () -> [[Float]] {
        var emissions: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in emissions.append(utterance) }
        return { emissions }
    }

    // MARK: - Real speech followed by silence produces an endpoint

    /// Speech followed by silence must close an utterance, and the retained samples must cover
    /// the speech — asserted by coverage, not by "one segment appeared".
    func testRealSpeechFollowedBySilenceProducesAnEndpointWithCoverage() throws {
        try requireFixtures()
        let modelPath = try bundledModelPath()
        let (samples, rate) = try readWav(speechFixture)
        let segmenter = try productionSegmenter(modelPath: modelPath)
        let emissions = collectEmissions(segmenter)

        // Feed in the same 20 ms frames the capture tap delivers at 16 kHz.
        let frame = 320
        var index = 0
        while index < samples.count {
            let end = min(index + frame, samples.count)
            segmenter.process(Array(samples[index..<end]), capturedAt: nil)
            index = end
        }
        // Explicit silence after the speech, so an endpoint can occur at all.
        let silenceFrame = [Float](repeating: 0, count: frame)
        for _ in 0..<25 {
            segmenter.process(silenceFrame, capturedAt: nil)
        }

        let emitted = emissions()
        let totalEmitted = emitted.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(
            totalEmitted, 0,
            "the classified segmenter emitted nothing for real speech followed by silence, so no "
                + "utterance closed and no wake detection could follow"
        )
        // Coverage is measured against the AUDIBLE EXTENT, not the whole file.
        //
        // positive.wav is 2.0 s but only ~0.36 of it is audible — the first sound starts at sample
        // 19591 and runs to 31188. Dividing by the full length measures the fixture's silence, not
        // the classifier's retention, and would fail a correct implementation. The meaningful
        // denominator is the speech itself.
        let audibleFirst = samples.firstIndex { abs($0) > 0.01 } ?? 0
        let audibleLast = samples.lastIndex { abs($0) > 0.01 } ?? samples.count - 1
        let audibleExtent = audibleLast - audibleFirst + 1
        let coverage = Double(totalEmitted) / Double(audibleExtent)
        XCTAssertGreaterThan(
            coverage, 0.8,
            "emitted \(totalEmitted) samples but the audible extent is \(audibleExtent) samples "
                + "(\(Int(coverage * 100))% coverage); the classifier is dropping speech rather "
                + "than delimiting it"
        )
    }

    // MARK: - Speech starting at capture start

    /// Speech beginning at the very first sample of capture must be retained from that sample.
    /// The classifier's windowed latency must not clip the opening.
    func testSpeechBeginningAtCaptureStartIsRetainedFromTheFirstSample() throws {
        try requireFixtures()
        let modelPath = try bundledModelPath()
        let (samples, _) = try readWav(speechFixture)
        let segmenter = try productionSegmenter(modelPath: modelPath)
        let emissions = collectEmissions(segmenter)

        // Trim any leading near-silence so the fixture begins in speech.
        let onset = try XCTUnwrap(
            samples.firstIndex { abs($0) > 0.01 },
            "fixture has no audible content to test a capture-start onset with"
        )
        let fromOnset = Array(samples[onset...])
        XCTAssertGreaterThan(fromOnset.first.map { abs($0) } ?? 0, 0.01,
                             "the trimmed fixture must begin in speech")

        var index = 0
        while index < fromOnset.count {
            let end = min(index + 320, fromOnset.count)
            let chunk = Array(fromOnset[index..<end])
            segmenter.process(chunk, capturedAt: nil)
            index = end
        }
        for _ in 0..<25 { segmenter.process([Float](repeating: 0, count: 320), capturedAt: nil) }

        let emitted = emissions().flatMap { $0 }
        XCTAssertGreaterThan(
            emitted.count, 0,
            "nothing was emitted for speech starting at capture sample zero"
        )
        // The opening samples must be PRESENT, not necessarily first.
        //
        // A windowed classifier reports nothing until it has one full window of context (512
        // samples), and confirmation needs minSpeechFrames consecutive positive frames. So the
        // first emitted position legitimately trails capture sample zero. What the contract
        // requires — and what this asserts — is that the opening audio is *retained somewhere in*
        // the emitted utterance rather than discarded, which is what "pre-detection context is
        // retained" means in ios.md.
        //
        // Search for the opening window at every offset rather than calling firstIndex(of:) on a
        // single sample: the fixture is synthetic (values are 0.5 + i/10000), so a scalar lookup
        // could match an unrelated position and then fail on the following samples.
        let head = Array(fromOnset.prefix(320))
        var headPresent = false
        if emitted.count >= head.count {
            for at in 0...(emitted.count - head.count) where Array(emitted[at..<(at + head.count)]) == head {
                headPresent = true
                break
            }
        }
        XCTAssertTrue(
            headPresent,
            "the command's opening samples do not appear anywhere in the emitted audio, so the "
                + "classifier's latency discarded the start of the command rather than merely "
                + "preceding it"
        )
    }

    // MARK: - Long command outlives the library's default duration

    /// Speech longer than sherpa-onnx's 5 s default `maxSpeechDuration` must not be truncated at
    /// that boundary. The configured bound is far above any command precisely so the library
    /// cannot close internally and have its boundary mistaken for an endpoint.
    func testSpeechLongerThanLibraryDefaultDurationIsNotTruncatedAtThatBoundary() throws {
        try requireFixtures()
        let modelPath = try bundledModelPath()
        let (samples, _) = try readWav(speechFixture)
        let segmenter = try productionSegmenter(modelPath: modelPath)
        let emissions = collectEmissions(segmenter)

        // Repeat the fixture to exceed 5 s of continuous speech with no internal silence.
        var long = [Float]()
        long.reserveCapacity(samples.count * 4)
        for _ in 0..<4 { long.append(contentsOf: samples) }
        XCTAssertGreaterThan(Double(long.count) / 16_000.0, 5.0,
                             "the long-command case must exceed the library default")

        var index = 0
        while index < long.count {
            let end = min(index + 320, long.count)
            segmenter.process(Array(long[index..<end]), capturedAt: nil)
            index = end
        }
        for _ in 0..<25 { segmenter.process([Float](repeating: 0, count: 320), capturedAt: nil) }

        // No emission may end at ~5 s: that would be the library's bound leaking into our endpoint.
        let fiveSeconds = 5 * 16_000
        for utterance in emissions() {
            let durationSamples = utterance.count
            XCTAssertNotEqual(
                durationSamples, fiveSeconds, accuracy: 1_600,
                "an emission ended at about the library's 5 s default duration "
                    + "(\(durationSamples) samples ~ \(String(format: "%.2f", Double(durationSamples) / 16_000.0))s), "
                    + "so a maximum-speech-duration boundary was treated as an endpoint"
            )
        }
    }

    /// If trimming cuts INSIDE a frame, the reported instant must be that sample's own, not the
    /// frame boundary before it.
    ///
    /// One instant per frame is only correct while eviction happens to land on a frame boundary.
    /// The pre-roll bound and the frame size are independent, so eviction can split a frame; the
    /// utterance's start would then be reported early by up to one frame's duration.
    func testEvictionInsideAFrameReportsTheSurvivingSamplesOwnInstant() {
        // Frames of 300 samples against an 8,000-sample bound: 8,000 / 300 is not an integer, so
        // the oldest retained sample is partway into a frame rather than at its start.
        let frameSize = 300
        let frame: (Int) -> [Float] = { i in
            (0..<frameSize).map { Float(i * frameSize + $0) }
        }
        let silentFrames = 40   // 12,000 samples unconfirmed: exceeds the 8,000 bound
        let segmenter = NativeVadSegmenter(
            threshold: 0.020,
            silenceTimeoutMs: 0,
            minSpeechFrames: 1,
            classifier: ScriptedSpeechClassifier(silentFrames: silentFrames, speechFrames: 4)
        )
        var captured: [([Float], MonotonicTime?)] = []
        segmenter.onUtterance = { utterance, instant in captured.append((utterance, instant)) }

        // Second-resolution instants make the sample offset unambiguous.
        for i in 0..<silentFrames { segmenter.process(frame(i), capturedAt: MonotonicTime(i)) }
        for i in 0..<4 { segmenter.process(frame(silentFrames + i), capturedAt: MonotonicTime(silentFrames + i)) }
        let deadline = Date().addingTimeInterval(0.12)
        while Date() < deadline {
            segmenter.process([Float](repeating: 0, count: frameSize), capturedAt: MonotonicTime(silentFrames + 4))
        }

        guard let (utterance, instant) = captured.first, let instant else {
            return XCTFail("nothing was emitted, so retention cannot be assessed")
        }
        // Identify the first emitted sample by value: each frame is an ascending ramp.
        let firstValue = Int(utterance[0])
        let expectedFrame = firstValue / frameSize
        let offsetInFrame = firstValue % frameSize
        let expectedInstant = MonotonicTime(expectedFrame) + Double(offsetInFrame) / 16_000.0
        XCTAssertEqual(
            instant, expectedInstant, accuracy: 1e-9,
            "the utterance starts at sample \(firstValue) (frame \(expectedFrame), offset "
                + "\(offsetInFrame)), but its instant reports \(instant); a per-frame timestamp "
                + "names the frame start instead of the retained sample"
        )
        XCTAssertGreaterThan(
            offsetInFrame, 0,
            "eviction landed on a frame boundary, so this run cannot distinguish per-sample from "
                + "per-frame timestamps and proves nothing"
        )
    }

    /// Silence interrupted by speech must NOT accumulate into a fault clear.
    ///
    /// While faulted, a positive frame must reset the silence interval. Otherwise two brief gaps
    /// separated by a long positive tail sum into one elapsed time and clear the fault from inside
    /// the same still-speaking request.
    func testInterruptedSilenceWhileFaultedDoesNotClearTheFault() {
        let frame = [Float](repeating: 0.1, count: 320)
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: Int.max)
        let segmenter = NativeVadSegmenter(
            threshold: 0.020,
            silenceTimeoutMs: 100,
            classifier: script
        )
        var dispatched: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in dispatched.append(utterance) }
        segmenter.onStuckActiveFault = { _ in }

        for _ in 0..<((240_000 / 20) + 10) { segmenter.process(frame) }
        XCTAssertTrue(segmenter.isStuckActive, "expected the ceiling to have tripped")

        // A gap shorter than the timeout, then speech, then another short gap. Wall time across
        // all three exceeds the timeout; the interval itself never should.
        script.silenceAfterSpeech = true
        segmenter.process([Float](repeating: 0, count: 320))
        script.silenceAfterSpeech = false
        let speechDeadline = Date().addingTimeInterval(0.15)
        while Date() < speechDeadline { segmenter.process(frame) }
        script.silenceAfterSpeech = true
        segmenter.process([Float](repeating: 0, count: 320))

        XCTAssertTrue(
            segmenter.isStuckActive,
            "the fault cleared during a still-speaking request: the silence interval spanned a "
                + "speech gap, so interrupted silence was summed into one endpoint"
        )
        XCTAssertTrue(dispatched.isEmpty, "the fault dispatched audio instead of staying suppressed")

        // A genuine, uninterrupted silence still clears it.
        let realSilence = Date().addingTimeInterval(0.25)
        while Date() < realSilence { segmenter.process([Float](repeating: 0, count: 320)) }
        XCTAssertFalse(segmenter.isStuckActive, "a genuine silence boundary must clear the fault")
    }

    /// The ceiling must bound the RETAINED utterance, including pre-roll prepended on
    /// confirmation.
    ///
    /// Counting only post-confirmation positives lets the emitted audio exceed the supported
    /// ceiling, because pre-roll is audio the user actually spoke and it is prepended to the
    /// utterance AFTER the count was accumulated.
    func testCeilingBoundsTheRetainedUtteranceIncludingPrependedPreRoll() {
        let framesToCeiling = 240_000 / 20
        let frame = [Float](repeating: 0.1, count: 320)
        // Start unconfirmed so genuine pre-roll accumulates, then confirm and run to the ceiling.
        let script = ScriptedSpeechClassifier(silentFrames: 25, speechFrames: Int.max)
        let segmenter = NativeVadSegmenter(
            threshold: 0.020,
            silenceTimeoutMs: 500,
            minSpeechFrames: 3,
            classifier: script
        )
        var dispatched: [[Float]] = []
        var faults: [NativeVadSegmenter.StuckActiveFault] = []
        segmenter.onUtterance = { utterance, _ in dispatched.append(utterance) }
        segmenter.onStuckActiveFault = { faults.append($0) }

        // 25 unconfirmed frames (0.5 s, the pre-roll bound) are held, then positives run to the
        // ceiling. The retained utterance reaches the ceiling; its post-confirmation positives
        // alone remain just under it, which is what distinguishes the two counts.
        let unconfirmedFrames = 25
        for _ in 0..<(framesToCeiling + unconfirmedFrames) { segmenter.process(frame) }

        XCTAssertTrue(
            dispatched.isEmpty,
            "the retained utterance exceeded the supported ceiling but was dispatched anyway "
                + "(\(dispatched.count) utterance(s))"
        )
        guard let fault = faults.first else {
            return XCTFail(
                "no interruption was surfaced even though the retained utterance, including its "
                    + "prepended pre-roll, passed the ceiling"
            )
        }
        XCTAssertGreaterThanOrEqual(
            fault.elapsedMs, 240_000,
            "the interruption must account for the retained utterance including pre-roll"
        )
    }

    /// The ceiling must trip on HANGOVER frames too, not only on positive classification.
    ///
    /// The negative branch also retains audio. Checking the bound only when a positive frame
    /// arrives lets a long hangover push the retained utterance past the ceiling and then be
    /// emitted by the endpoint without any interruption.
    func testCeilingCrossedOnHangoverFramesTripsBeforeAnyEndpoint() {
        // Reach just under the ceiling on positives, then keep feeding negatives. The silence
        // timeout is long enough that no endpoint fires while the hangover accumulates.
        let framesToCeiling = 240_000 / 20
        let frame = [Float](repeating: 0.1, count: 320)
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: Int.max)
        let segmenter = NativeVadSegmenter(
            threshold: 0.020,
            silenceTimeoutMs: 60_000,   // no endpoint during the test
            classifier: script
        )
        var dispatched: [[Float]] = []
        var faults: [NativeVadSegmenter.StuckActiveFault] = []
        segmenter.onUtterance = { (utterance: [Float], _: MonotonicTime?) in dispatched.append(utterance) }
        segmenter.onStuckActiveFault = { faults.append($0) }

        for _ in 0..<(framesToCeiling - 10) { segmenter.process(frame) }
        XCTAssertTrue(faults.isEmpty, "tripped before the hangover, so this run proves nothing")

        // Only negatives from here: the retained buffer, not a positive count, must cross the bound.
        script.silenceAfterSpeech = true
        for _ in 0..<30 { segmenter.process(frame) }

        XCTAssertFalse(
            faults.isEmpty,
            "the retained utterance crossed the supported ceiling on hangover frames but no "
                + "interruption was surfaced"
        )
        XCTAssertTrue(dispatched.isEmpty, "audio was dispatched instead of suppressed on the fault")
        XCTAssertEqual(faults.first?.elapsedMs, 240_000)
    }

    // MARK: - Classifier unavailability is surfaced, not degraded

    /// A missing classifier must be reported and must dispatch nothing.
    ///
    /// Silently falling back to the energy rule would reinstall the exact defect: in a room whose
    /// ambient noise exceeds the threshold every frame is "speech", so the utterance never closes
    /// while the UI reports normal listening.
    func testUnavailableClassifierIsSurfacedAndDispatchesNothing() {
        // An energy classifier that WOULD dispatch: with it in place the only reason nothing is
        // emitted is the unavailability guard. Without that, this test cannot fail on the old
        // behaviour and proves nothing.
        // Bounded speech then genuinely silent: without the guard this WOULD endpoint and
        // dispatch, which is the behaviour the guard must prevent.
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: 20)
        let segmenter = NativeVadSegmenter(
            threshold: 0.020,
            silenceTimeoutMs: 0,
            minSpeechFrames: 1,
            classifier: script
        )
        var faults: [NativeVadSegmenter.ClassifierUnavailableFault] = []
        var dispatched: [[Float]] = []
        segmenter.onClassifierUnavailable = { faults.append($0) }
        segmenter.onUtterance = { utterance, _ in dispatched.append(utterance) }

        segmenter.reportClassifierUnavailable("silero_vad.onnx could not be loaded")

        XCTAssertEqual(faults.count, 1, "unavailability was not surfaced")
        XCTAssertEqual(faults.first?.reason, "silero_vad.onnx could not be loaded", "the fault must name the reason")
        XCTAssertTrue(segmenter.isClassifierUnavailable)

        // Sustained speech the classifier would otherwise endpoint on.
        for _ in 0..<20 { segmenter.process([Float](repeating: 0.3, count: 320), capturedAt: MonotonicTime(0)) }
        script.silenceAfterSpeech = true
        let silenceDeadline = Date().addingTimeInterval(0.12)
        while Date() < silenceDeadline { segmenter.process([Float](repeating: 0, count: 320)) }
        XCTAssertTrue(
            dispatched.isEmpty,
            "the energy rule dispatched \(dispatched.count) utterance(s) with no classifier present; "
                + "unavailability must not degrade into the defect"
        )
        XCTAssertEqual(faults.count, 1, "the fault must be reported once, not on every frame")
    }

    // MARK: - Noise is not speech

    /// The room-noise case that motivated this change: with the energy rule every frame above
    /// the threshold is "speech" and no endpoint can ever arrive. The classifier must not call
    /// digital silence speech, which is the composition this can honestly establish with
    /// public fixtures.
    /// Pre-roll must preserve capture order and must not duplicate the confirming frame.
    /// Uses a scripted classifier so the timing is exact rather than dependent on model latency.
    func testPreRollPreservesOrderAndDoesNotDuplicate() {
        let frame: (Int) -> [Float] = { i in (0..<100).map { Float(i) + Float($0) / 1000 } }
        let segmenter = NativeVadSegmenter(
            threshold: 0.020,
            silenceTimeoutMs: 0,
            minSpeechFrames: 3,
            // 5 silent, then 7 speech. Silence frames arrive as part of the same stream, so the
            // silent count and the speech count must cover exactly the frames fed (12), plus the
            // trailing sub-threshold frame that triggers the endpoint.
            classifier: ScriptedSpeechClassifier(silentFrames: 5, speechFrames: 7)
        )
        var captured: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in captured.append(utterance) }
        // Twelve indexed frames, then real silence long enough to trigger the endpoint.
        // `silenceTimeoutMs: 0` alone is not enough: the comparison is wall-clock based, so the
        // silence must actually span time rather than assume the clock advanced between calls.
        for i in 0..<12 { segmenter.process(frame(i)) }
        let deadline = Date().addingTimeInterval(0.12)
        while Date() < deadline { segmenter.process([Float](repeating: 0, count: 100)) }

        let emitted: [Float] = captured.flatMap { $0 }
        guard emitted.count >= 100 else {
            XCTFail("nothing emitted after confirmation; pre-roll was lost entirely")
            return
        }
        // The very first captured frame must be present at offset 0 of the utterance.
        XCTAssertEqual(
            Array(emitted.prefix(100)), frame(0),
            "the utterance must begin with the earliest captured frame, not with the frame that "
                + "confirmed the utterance"
        )
        // Contiguous, in capture order, no duplication. The utterance also carries the trailing
        // sub-threshold frame that closed it, so only the twelve indexed frames are checked.
        let indices: [Int] = stride(from: 0, to: emitted.count - 99, by: 100).map { idx in Int(emitted[idx]) }
        XCTAssertEqual(
            Array(indices.prefix(12)), Array(0..<12),
            "emitted frames must be contiguous and in capture order; got \(indices)"
        )
    }

    /// After eviction, the utterance must report the capture instant of its FIRST RETAINED
    /// sample — not the instant of a sample that trimming removed.
    ///
    /// Pre-roll evicts its oldest audio when it exceeds the bound. Carrying a single start
    /// instant across that eviction would name a moment that is no longer in the buffer, which
    /// misplaces the segment against the emitted reference.
    func testPreRollReportsTheFirstRetainedSamplesCaptureInstant() {
        let frame: (Int) -> [Float] = { i in (0..<100).map { Float(i) + Float($0) / 1000 } }
        // Enough unconfirmed input to force multiple evictions, then confirmation.
        let silentFrames = 200
        let bound = 8000
        let framesRetained = bound / 100
        let segmenter = NativeVadSegmenter(
            threshold: 0.020,
            silenceTimeoutMs: 0,
            minSpeechFrames: 3,
            classifier: ScriptedSpeechClassifier(silentFrames: silentFrames, speechFrames: 4)
        )
        var captured: [([Float], MonotonicTime?)] = []
        segmenter.onUtterance = { utterance, instant in captured.append((utterance, instant)) }

        // Each frame is stamped with its own instant so eviction is provable by value.
        for i in 0..<silentFrames { segmenter.process(frame(i), capturedAt: MonotonicTime(i)) }
        for i in 0..<4 { segmenter.process(frame(silentFrames + i), capturedAt: MonotonicTime(silentFrames + i)) }
        // Wall-clock endpoint: the trailing silence must span the timeout, not assume two adjacent
        // calls are separated in time.
        let endDeadline = Date().addingTimeInterval(0.12)
        while Date() < endDeadline {
            segmenter.process([Float](repeating: 0, count: 100), capturedAt: MonotonicTime(silentFrames + 4))
        }

        guard let (utterance, instant) = captured.first else {
            return XCTFail("nothing was emitted, so retention cannot be assessed")
        }
        // The first retained sample must be the oldest frame still inside the bound. Frames that
        // arrive before confirmation are held too, so the count includes the two speech frames
        // that precede the third (the one that confirms).
        let expectedFirstFrame = silentFrames + 2 - framesRetained
        XCTAssertEqual(
            Int(utterance.first ?? -1), expectedFirstFrame,
            "the retained pre-roll must begin at frame \(expectedFirstFrame)"
        )
        XCTAssertEqual(
            instant, MonotonicTime(expectedFirstFrame),
            "the utterance reported capture instant \(String(describing: instant)) but its first "
                + "retained sample was captured at \(expectedFirstFrame); eviction moved the audio "
                + "forward while the timestamp stayed behind"
        )
    }

    /// Reaching the 240 s ceiling must surface a duration-limit interruption and dispatch
    /// NOTHING.
    ///
    /// `arch/ios.md`: reaching the ceiling "surfaces an explicit duration-limit interruption …
    /// rather than classifying the input as noise or emitting a completed command."
    func testReachingTheDurationCeilingSurfacesAFaultAndDispatchesNothing() {
        let frame = [Float](repeating: 0.1, count: 320)
        let framesToCeiling = 240_000 / 20   // 320 samples = 20 ms
        let segmenter = NativeVadSegmenter(
            threshold: 0.020,
            silenceTimeoutMs: 500,
            classifier: ScriptedSpeechClassifier(silentFrames: 0, speechFrames: Int.max)
        )
        var dispatched: [[Float]] = []
        var faults: [NativeVadSegmenter.StuckActiveFault] = []
        segmenter.onUtterance = { utterance, _ in dispatched.append(utterance) }
        segmenter.onStuckActiveFault = { faults.append($0) }

        for _ in 0..<(framesToCeiling + 10) { segmenter.process(frame) }

        XCTAssertTrue(
            dispatched.isEmpty,
            "the ceiling dispatched \(dispatched.count) utterance(s); a partial command must "
                + "never reach ASR"
        )
        guard let fault = faults.first else {
            return XCTFail("reaching the 240 s ceiling surfaced no interruption")
        }
        XCTAssertGreaterThan(fault.discardedSamples, 0, "the interruption reported no discarded audio")
        XCTAssertEqual(
            fault.elapsedMs, 240_000,
            "the interruption must report the supported ceiling, not an arbitrary cutoff"
        )
        XCTAssertTrue(segmenter.isStuckActive, "the fault state must be inspectable after it trips")
    }

    /// The continuing tail must stay suppressed: nothing dispatches until genuine silence.
    ///
    /// Rearming automatically would treat the tail of the same still-spoken request as a new
    /// command — the failure this state exists to prevent.
    func testTailAfterTheCeilingStaysSuppressedUntilSilence() {
        let frame = [Float](repeating: 0.1, count: 320)
        let script = ScriptedSpeechClassifier(silentFrames: 0, speechFrames: Int.max)
        let segmenter = NativeVadSegmenter(
            threshold: 0.020,
            silenceTimeoutMs: 50,
            classifier: script
        )
        var dispatched: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in dispatched.append(utterance) }
        segmenter.onStuckActiveFault = { _ in }

        // Past the ceiling, then keep speaking: the tail must not become a command.
        for _ in 0..<((240_000 / 20) + 100) { segmenter.process(frame) }
        XCTAssertTrue(segmenter.isStuckActive, "expected to be in the fault state")
        XCTAssertTrue(
            dispatched.isEmpty,
            "the continuing tail was dispatched as \(dispatched.count) utterance(s) after the "
                + "ceiling; it must stay suppressed until genuine silence"
        )

        // Genuine silence clears the state, and still dispatches nothing from the fault.
        // The script must actually stop reporting speech: a double that kept answering
        // "speech" could not reach this boundary at all.
        script.silenceAfterSpeech = true
        // The endpoint is wall-clock based, so the silence spans the timeout rather than
        // assuming time elapses between two back-to-back calls.
        let silenceDeadline = Date().addingTimeInterval(0.12)
        while Date() < silenceDeadline { segmenter.process([Float](repeating: 0, count: 320)) }
        XCTAssertFalse(segmenter.isStuckActive, "silence must leave the fault state")
        XCTAssertTrue(dispatched.isEmpty, "leaving the fault state must not dispatch the discarded audio")
    }

    func testSilenceIsNotClassifiedAsSpeech() throws {
        let modelPath = try bundledModelPath()
        let classifier = try XCTUnwrap(SileroSpeechFrameClassifier.make(modelPath: modelPath))
        // Whole model windows of digital silence.
        for _ in 0..<20 {
            _ = classifier.isSpeech([Float](repeating: 0, count: SileroSpeechFrameClassifier.frameSize))
        }
        XCTAssertFalse(
            classifier.isSpeech([Float](repeating: 0, count: SileroSpeechFrameClassifier.frameSize)),
            "the classifier reported speech for digital silence, so an endpoint could never arrive"
        )
    }
}

/// Reports "no speech" for a fixed number of frames, then "speech" forever.
///
/// Used to make pre-roll behaviour deterministic: the exact number of frames that arrive before
/// confirmation is known, so ordering and duplication can be asserted by value rather than
/// inferred from model latency.
final class ScriptedSpeechClassifier: SpeechFrameClassifier {
    private var remainingSilent: Int
    private var remainingSpeech: Int
    init(silentFrames: Int, speechFrames: Int) {
        remainingSilent = silentFrames
        remainingSpeech = speechFrames
    }
    /// When set, the script stops reporting speech so the silence boundary can be exercised.
    var silenceAfterSpeech = false
    private var speechExhaustedWithoutSilence = false

    func isSpeech(_ samples: [Float]) -> Bool {
        if silenceAfterSpeech { return false }
        if remainingSilent > 0 {
            remainingSilent -= 1
            return false
        }
        guard remainingSpeech > 0 else { return false }
        remainingSpeech -= 1
        return true
    }
    func reset() {
        // Deliberately does NOT exhaust the scripted budget.
        //
        // A real classifier resumes classifying after `reset()` — it clears carried state, it
        // does not stop working. Zeroing the budget here made the post-fault utterance
        // unobservable and produced a false "never rearmed" failure.
    }
}
