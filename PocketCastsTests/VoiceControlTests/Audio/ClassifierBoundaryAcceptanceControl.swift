@testable import podcasts
import XCTest

/// DESIGN ACCEPTANCE CONTROL for the classifier segmenter boundary (requested in review).
///
/// WHAT THIS IS NOT. It is not evidence that today's `NativeVadSegmenter` clips speech.
/// `StartOfCapturePreservationControl` measured that it does not: above-threshold frames are buffered
/// before the confirmation check, so a command starting at capture sample zero survives
/// (`STARTRETENTION emitted=8320, fed=8000, missing=-320`).
///
/// WHAT THIS IS. The proposed change replaces an *energy* decision with a *classifier* decision. A
/// classifier is a windowed model whose first outputs lag its input: frames at the start of speech can
/// initially report "no speech" while the model fills its context, and only later report speech. An
/// energy gate has no such lag. So the risk this control addresses is real and specific to the
/// proposed design: **the classifier's own latency could drop the command's opening.**
///
/// Feeding above-threshold synthetic frames — as the energy tests do — cannot exercise that, because
/// those frames are speech by construction on frame one. This control therefore models the classifier
/// as a gate that reports false for the first N frames of genuine speech, and asserts the command's
/// exact opening samples still reach the emitted PCM.
///
/// SCOPE, STATED PLAINLY: the boundary under test here is a **private toy segmenter** defined at the
/// bottom of this file. A green result therefore proves the *assertions and inputs* are the right ones;
/// it does NOT validate a production boundary, because no production classifier adapter exists yet.
/// When that change is authorized, these same inputs and assertions must be re-run against the real
/// adapter. No new protocol is required solely for this illustration.
final class ClassifierBoundaryAcceptanceControl: XCTestCase {

    /// THE ACCEPTANCE PROPERTY: known command samples from capture sample zero, preceded by classifier
    /// frames that (wrongly) report no speech, followed by a natural endpoint — the emitted PCM must
    /// preserve the **exact initial samples**.
    ///
    /// A pre-roll is the mechanism expected to satisfy this. Any implementation must: feed audio to the
    /// classifier, keep the pre-classification PCM, and hand over command audio starting at capture
    /// sample zero.
    func testClassifierLatencyDoesNotDropTheCommandsOpeningSamples() {
        // 320 samples = 20 ms at 16 kHz, matching the frame size used elsewhere in these tests.
        let frameCount = 320
        // The classifier reports "not speech" for this many frames of genuine speech while its
        // windowed context fills. Chosen to be clearly larger than zero so a gate that starts
        // retaining only on the first positive result is forced to drop audio.
        let classifierNegativeFrames = 9

        let harness = BoundaryHarness(classifierNegativeFrames: classifierNegativeFrames)

        // The command is recognisable by value: sample i carries 0.5 + i/10_000. The opening frames
        // must be identifiable in the output, not merely counted.
        var fed: [Float] = []
        for frame in 0..<(classifierNegativeFrames + 12) {
            var f = [Float](repeating: 0, count: frameCount)
            for k in 0..<frameCount {
                let index = frame * frameCount + k
                f[k] = 0.5 + Float(index) / 10_000.0
            }
            fed.append(contentsOf: f)
            // Modelled classifier: negative for the first frames of genuine speech, then positive.
            harness.feed(samples: f, classifierSaysSpeech: frame >= classifierNegativeFrames, capturedAt: nil)
        }
        // Natural endpoint.
        harness.feed(samples: [Float](repeating: 0, count: frameCount), classifierSaysSpeech: false,
                     endsUtterance: true)

        guard let emitted = harness.utterances.first else {
            XCTFail(
                "no utterance was emitted. The boundary must still close on a natural endpoint even "
                    + "while the classifier initially reported no speech."
            )
            return
        }

        // Exactly one utterance: a fragmented command is a different defect that must not hide behind
        // a correct-looking first emission.
        XCTAssertEqual(
            harness.utterances.count, 1,
            "expected exactly one emission, got \(harness.utterances.count). A command split across "
                + "emissions is not a single preserved command."
        )

        // The ENTIRE intended command PCM, in order, from capture sample zero — not just its opening
        // frames. Comparing only a prefix would pass if the middle or end were lost.
        XCTAssertEqual(
            emitted, fed,
            "the emitted PCM is not the complete intended command. "
                + "emitted=\(emitted.count) samples, fed=\(fed.count), "
                + "missing=\(fed.count - emitted.count). Pre-classification audio was not retained, so "
                + "the command reaches ASR clipped."
        )
    }

    /// A TRANSIENT classifier-negative interval INSIDE a continuing command must not delete audio.
    ///
    /// This is the post-confirmation half of the same defect class: a windowed classifier can briefly
    /// report "no speech" mid-command (a stop consonant, a breath). Treating that as an endpoint, or
    /// simply not retaining such frames, silently removes mid-command audio.
    func testTransientNegativeInsideACommandDoesNotDeleteAudio() {
        let frameCount = 320
        let classifierNegativeFrames = 9
        let harness = BoundaryHarness(classifierNegativeFrames: classifierNegativeFrames)

        var fed: [Float] = []
        func frame(_ index: Int) -> [Float] {
            var f = [Float](repeating: 0, count: frameCount)
            for k in 0..<frameCount {
                f[k] = 0.5 + Float(index * frameCount + k) / 10_000.0
            }
            return f
        }

        // Speech, with a negative interval in the MIDDLE after confirmation.
        let total = 40
        for index in 0..<total {
            let f = frame(index)
            fed.append(contentsOf: f)
            // Frames 20..<25 are a transient misclassification, mid-command.
            let saysSpeech = !(20..<25).contains(index) || index < classifierNegativeFrames
            harness.feed(samples: f, classifierSaysSpeech: saysSpeech, capturedAt: nil)
        }
        harness.feed(samples: [Float](repeating: 0, count: frameCount), classifierSaysSpeech: false,
                     endsUtterance: true)

        guard let emitted = harness.utterances.first else {
            XCTFail("no utterance emitted")
            return
        }
        XCTAssertEqual(
            emitted, fed,
            "a transient classifier-negative interval inside the command deleted audio: "
                + "emitted=\(emitted.count) of \(fed.count) samples fed "
                + "(missing \(fed.count - emitted.count)). Mid-command frames must be retained until "
                + "the independently determined endpoint."
        )
    }

    /// Guard against the trivial pass: a boundary that emits everything fed would satisfy the property
    /// above for the wrong reason. The emitted audio must stop at the natural endpoint rather than
    /// trailing into the closing silence.
    func testEmittedAudioEndsAtTheNaturalEndpointRatherThanTrailingSilence() {
        let frameCount = 320
        let harness = BoundaryHarness(classifierNegativeFrames: 9)

        var speechSampleCount = 0
        for _ in 0..<20 {
            let f = [Float](repeating: 0.5, count: frameCount)
            speechSampleCount += f.count
            harness.feed(samples: f, classifierSaysSpeech: true, capturedAt: nil)
        }
        harness.feed(samples: [Float](repeating: 0, count: frameCount), classifierSaysSpeech: false,
                     endsUtterance: true)
        // Feed MORE frames after the endpoint, so this actually demonstrates that trailing input is
        // rejected rather than merely that none was supplied.
        for _ in 0..<30 {
            harness.feed(samples: [Float](repeating: 0.9, count: frameCount), classifierSaysSpeech: true,
                         capturedAt: nil)
        }

        guard let emitted = harness.utterances.first else {
            XCTFail("no utterance emitted")
            return
        }
        XCTAssertEqual(
            harness.utterances.count, 1,
            "post-endpoint audio produced \(harness.utterances.count) emissions; the endpoint did not "
                + "terminate the utterance"
        )

        // FULL speech coverage first: a negative trailing length (most speech dropped) would otherwise
        // satisfy a bounded-tail check.
        XCTAssertGreaterThanOrEqual(
            emitted.count, speechSampleCount,
            "emitted \(emitted.count) samples for \(speechSampleCount) samples of speech — speech was "
                + "dropped, so a bounded tail cannot be the only guard"
        )
        // Then a bounded tail, so "preserves the opening" cannot be satisfied by emitting the raw stream.
        let trailing = emitted.count - speechSampleCount
        XCTAssertGreaterThanOrEqual(
            trailing, 0, "trailing length is negative, which means speech was lost rather than trailing")
        XCTAssertLessThanOrEqual(
            trailing, 40 * frameCount,
            "emitted audio trails \(trailing) samples past the speech, so the boundary is forwarding "
                + "raw input rather than delimiting an utterance"
        )
    }
}

/// Minimal classifier-bounded segmenter used only by `ClassifierBoundaryAcceptanceControl`.
///
/// Models the property under test and nothing else: a windowed classifier reports negative for the
/// first `classifierNegativeFrames` frames of genuine speech, PCM is retained independently in a
/// pre-roll from capture sample zero, and the utterance is assembled from retained PCM once the
/// classifier confirms — then closed at a natural endpoint. It is intentionally NOT wired into
/// production; it exists so the acceptance property is executable and reviewable before the real
/// adapter is built.
///
/// IMPORTANT: classifier decisions are **injected**, not derived from PCM energy. An energy-derived
/// gate inside this harness would silently discard low-energy command frames on its own and could
/// mask or manufacture the very defect under test. `feed(samples:classifierSaysSpeech:capturedAt:)`
/// takes the decision as an argument; the default wrapper supplies it from the modelled delay so the
/// picturing of a windowed model stays explicit.
private final class BoundaryHarness {
    var utterances: [[Float]] = []

    private let classifierNegativeFrames: Int
    private var framesSeen = 0
    private var confirmed = false
    /// PCM owner: retained from capture sample zero, independent of the classifier.
    private var preRoll: [Float] = []

    init(classifierNegativeFrames: Int) {
        self.classifierNegativeFrames = classifierNegativeFrames
    }

    /// Feeds a frame with the classifier's decision supplied explicitly. PCM retention is independent
    /// of that decision and of any energy computation here.
    /// The harness distinguishes "classifier said no" from "the utterance is over". Conflating the two
    /// would make the harness itself discard the command during modelled classifier latency — the very
    /// defect under test — and it did, until the full-PCM assertion caught it.
    func feed(samples: [Float], classifierSaysSpeech: Bool, endsUtterance: Bool = false,
              capturedAt: MonotonicTime? = nil) {
        if endsUtterance {
            if confirmed {
                utterances.append(preRoll)
            }
            preRoll.removeAll()
            confirmed = false
            framesSeen = 0
            return
        }

        if !confirmed {
            // ALWAYS retain pre-classification PCM — this is the pre-roll requirement. The classifier's
            // current opinion does not gate retention.
            preRoll.append(contentsOf: samples)
            if classifierSaysSpeech {
                framesSeen += 1
                if framesSeen > classifierNegativeFrames {
                    confirmed = true
                }
            } else {
                framesSeen = 0
            }
            return
        }

        // Retain unconditionally until the independently determined endpoint. A classifier-negative
        // frame inside a continuing command is a transient decision, not an end: dropping it would
        // delete mid-command audio, which is the same defect as dropping the opening.
        preRoll.append(contentsOf: samples)
    }
}
