@testable import podcasts
import XCTest

/// CONTROLS FOR THE ACOUSTIC END OF SPEECH (reviewer 77e5f4bc, iOS PR 65).
///
/// A latency figure has to start when the USER stopped talking. The retained utterance buffer is
/// not that: every silent frame of the endpoint hangover is appended to it too ("Hangover frames
/// are retained audio"), so the buffer's end marks the end of the hangover — `silenceTimeoutMs`
/// later than the user. Measuring from there shrinks every `end_of_speech_to_*` figure, and the
/// hangover is precisely the delay the measurement exists to expose.
///
/// The segmenter therefore records how many samples the buffer held when the FINAL silence run
/// opened, and reports end of speech at that offset. These controls pin that offset.
final class AcousticEndOfSpeechControl: XCTestCase {
    private let frame = 320
    private let rate = Double(NativeVadSegmenter.captureSampleRate)

    /// THE PROPERTY: with N speech frames followed by a hangover, end of speech lands at frame N —
    /// not at frame N plus the hangover.
    ///
    /// The hangover is forced to close on the FIRST silent frame (`silenceTimeoutMs: -1`), so the
    /// retained buffer is exactly `speechFrames + 1` frames long while the acoustic end is exactly
    /// `speechFrames` frames in. Returning the buffer's length instead is the defect this control
    /// exists to catch, and it is a one-frame difference here rather than the real 500 ms, which is
    /// the point: the error is structural and this makes it visible without waiting on wall clock.
    func test_endOfSpeechExcludesTheTrailingHangover() {
        let speechFrames = 12
        let start: MonotonicTime = 1_000.0
        let segmenter = NativeVadSegmenter(silenceTimeoutMs: -1)
        var ends: [MonotonicTime] = []
        segmenter.onUtterance = { _, _, _, _, speechEndedAt in ends.append(speechEndedAt) }

        for index in 0..<speechFrames {
            segmenter.process(
                [Float](repeating: 1.0, count: frame),
                capturedAt: start + Double(index * frame) / rate
            )
        }
        // One silent frame: retained in the buffer, and enough to close the utterance above.
        segmenter.process(
            [Float](repeating: 0.0, count: frame),
            capturedAt: start + Double(speechFrames * frame) / rate
        )

        let ended = try? XCTUnwrap(ends.first)
        guard let ended else { return XCTFail("the utterance was never emitted") }
        let speechSamples = Double(speechFrames * frame)
        XCTAssertEqual(ended, start + speechSamples / rate, accuracy: 1e-6,
                       "end of speech is the last SPEECH sample, not the end of the retained "
                           + "hangover; including it would understate the user's wait by the hangover")
        XCTAssertLessThan(ended, start + Double((speechFrames + 1) * frame) / rate,
                          "the silent frame is retained but is not speech")
    }

    /// A pause INSIDE an utterance is not mistaken for its end.
    ///
    /// The end of speech must come from the silence run that CLOSED the utterance. An earlier run
    /// inside the same utterance is retained audio too, and reading the FIRST one would place the
    /// end in the middle of the command and report a wait shorter than the user actually had.
    ///
    /// The pause is real elapsed time below the timeout, so it does not close the utterance;
    /// speech then resumes and disarms it. Only the trailing silence closes the utterance.
    func test_endOfSpeechIsTheFinalSilenceRunNotAnEarlierPause() {
        let start: MonotonicTime = 2_000.0
        let firstSpeech = 8
        let pauseFrames = 2
        let secondSpeech = 6
        // A short timeout that the in-utterance pause stays under, so the pause survives as part
        // of the utterance; the closing silence is then held past it.
        let timeoutMs = 120
        let segmenter = NativeVadSegmenter(silenceTimeoutMs: timeoutMs)
        var ends: [MonotonicTime] = []
        segmenter.onUtterance = { _, _, _, _, speechEndedAt in ends.append(speechEndedAt) }

        var cursor = 0
        /// The wait happens BEFORE the frame is processed, because the endpoint is evaluated
        /// inside `process` against elapsed wall-clock time: sleeping afterwards would leave the
        /// decision for the following frame and shift the delay by one.
        func feed(_ value: Float, count: Int, pauseSeconds: TimeInterval = 0) {
            for _ in 0..<count {
                if pauseSeconds > 0 { Thread.sleep(forTimeInterval: pauseSeconds) }
                segmenter.process(
                    [Float](repeating: value, count: frame),
                    capturedAt: start + Double(cursor * frame) / rate
                )
                cursor += 1
            }
        }
        feed(1.0, count: firstSpeech)
        // Under the timeout: the pause is inside the utterance and speech resumes after it.
        feed(0.0, count: pauseFrames, pauseSeconds: Double(timeoutMs) / 4_000)
        feed(1.0, count: secondSpeech)
        XCTAssertTrue(ends.isEmpty,
                      "a short pause followed by resumed speech must not close the utterance")
        // The closing silence. The first frame opens the run and is always appended; the endpoint
        // is then evaluated on a SUBSEQUENT frame against elapsed time, so the wait goes between
        // the two and the second frame is the one that trips it.
        feed(0.0, count: 1)
        feed(0.0, count: 1, pauseSeconds: Double(timeoutMs) * 2 / 1_000)

        guard let ended = ends.first else {
            return XCTFail("the utterance was never emitted")
        }
        let speechEndsAt = Double((firstSpeech + pauseFrames + secondSpeech) * frame)
        XCTAssertEqual(ended, start + speechEndsAt / rate, accuracy: 1e-6,
                       "end of speech belongs to the FINAL silence run; the pause inside the "
                           + "utterance is retained audio but is not the end of the command")
    }
}
