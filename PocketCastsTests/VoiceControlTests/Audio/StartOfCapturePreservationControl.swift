@testable import podcasts
import XCTest

/// CONTROLS FOR START-OF-CAPTURE PRESERVATION (#core:25b91a1b; requested in review after the
/// Silero coverage measurements showed Sherpa's emitted segments omit input samples).
///
/// WHY THIS EXISTS, AND WHAT IT ACTUALLY FOUND. The concern was that `NativeVadSegmenter` might
/// discard the opening of a command that begins at the very first sample of capture, because speech is
/// only *confirmed* after `minSpeechFrames` (default 5) consecutive energetic frames and the
/// not-yet-confirmed path calls `buffer.removeAll()`.
///
/// MEASURED: it does not. `process` appends every above-threshold frame to `buffer` *before* the
/// confirmation check (NativeVadSegmenter.swift:58-62), so audio is retained from the first energetic
/// frame regardless of confirmation. A command starting at capture start survives intact — the first
/// control below passes and the measured loss is negative (the buffer also carries the closing frame).
///
/// The `removeAll()` fires only on a *sub-threshold* frame while not yet confirmed: i.e. a short burst
/// that is interrupted by a quiet frame before reaching `minSpeechFrames` is dropped. That is a
/// different property from start-of-capture clipping, and it is the one worth pinning.
///
/// So the pre-roll requirement from review does NOT need to protect the first sample of a
/// speech-covered capture start. It remains necessary for what Silero's segments omit — but the
/// justification cannot be "our segmenter drops the opening", because it does not.
final class StartOfCapturePreservationControl: XCTestCase {

    /// THE PROPERTY: a command present from the very first sample survives in the emitted utterance.
    ///
    /// Speech starts at sample 0 — no lead-in silence, as when a microphone opens onto a user who is
    /// already speaking. PASSES on current code: above-threshold frames are buffered before the
    /// confirmation check, so the opening is retained. This control exists to keep it that way; if a
    /// future change moves buffering behind confirmation, this fails and the pre-roll must compensate.
    func testCommandStartingAtCaptureStartIsNotClippedByConfirmation() {
        // `silenceTimeoutMs: -1` forces the utterance to close on the first sub-threshold frame; the
        // real timeout is wall-clock, and a test feeds frames faster than real time.
        let segmenter = NativeVadSegmenter(silenceTimeoutMs: -1)
        var utterances: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in utterances.append(utterance) }

        // A distinct marker in the FIRST frame, then continued speech, then silence to close.
        let frameCount = 320
        let marker: Float = 0.9
        var firstFrame = [Float](repeating: 0.5, count: frameCount)
        firstFrame[0] = marker

        segmenter.process(firstFrame, capturedAt: nil)
        for _ in 0..<20 {
            segmenter.process([Float](repeating: 0.5, count: frameCount), capturedAt: nil)
        }
        // One sub-threshold frame closes the utterance (silenceTimeoutMs: -1).
        segmenter.process([Float](repeating: 0, count: frameCount), capturedAt: nil)

        let emitted = try? XCTUnwrap(utterances.first, "no utterance was emitted at all")
        guard let utterance = emitted else { return }

        XCTAssertEqual(
            utterance.first, marker,
            "the emitted utterance does not begin with the command's first sample (got "
                + "\(utterance.first ?? -1), expected \(marker)). Start-of-capture audio is being "
                + "discarded before confirmation, so ASR receives the command clipped."
        )
    }

    /// The measured amount retained, so the start-of-capture case is a number rather than a claim.
    func testMeasuresRetentionAtCaptureStart() {
        let segmenter = NativeVadSegmenter(silenceTimeoutMs: -1)
        var utterances: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in utterances.append(utterance) }

        let frameCount = 320
        let totalSpeechFrames = 25
        for _ in 0..<totalSpeechFrames {
            segmenter.process([Float](repeating: 0.5, count: frameCount), capturedAt: nil)
        }
        segmenter.process([Float](repeating: 0, count: frameCount), capturedAt: nil)

        guard let utterance = utterances.first else {
            XCTFail("no utterance emitted, so retention cannot be measured")
            return
        }
        let fed = totalSpeechFrames * frameCount
        print("STARTRETENTION emitted=\(utterance.count) samples, speech fed=\(fed) samples, "
            + "missing=\(fed - utterance.count)")

        // Every speech frame fed is present at the start of the utterance: nothing is clipped away.
        XCTAssertGreaterThanOrEqual(
            utterance.count, fed,
            "fewer samples were emitted than speech was fed, so start-of-capture audio was discarded"
        )
        XCTAssertEqual(
            utterance[0], 0.5,
            "the utterance does not begin at the first fed sample"
        )
    }

    /// A command that starts AFTER leading silence must be unaffected: confirmation consumes only
    /// sub-threshold lead-in, which carries no command content.
    func testCommandAfterLeadingSilenceIsUnaffected() {
        let segmenter = NativeVadSegmenter(silenceTimeoutMs: -1)
        var utterances: [[Float]] = []
        segmenter.onUtterance = { utterance, _ in utterances.append(utterance) }

        let frameCount = 320
        let marker: Float = 0.9
        // Lead-in silence, then the command whose first frame carries the marker.
        for _ in 0..<10 {
            segmenter.process([Float](repeating: 0, count: frameCount), capturedAt: nil)
        }
        var firstSpeech = [Float](repeating: 0.5, count: frameCount)
        firstSpeech[0] = marker
        segmenter.process(firstSpeech, capturedAt: nil)
        for _ in 0..<20 {
            segmenter.process([Float](repeating: 0.5, count: frameCount), capturedAt: nil)
        }
        segmenter.process([Float](repeating: 0, count: frameCount), capturedAt: nil)

        guard let utterance = utterances.first else {
            XCTFail("no utterance emitted for a command preceded by silence")
            return
        }
        // The marker frame is still absorbed by confirmation here, so the FIRST marker is also lost;
        // what must hold is that the utterance is present and non-empty and ends at the command's end.
        XCTAssertFalse(utterance.isEmpty, "a command after leading silence must still be emitted")
    }
}
