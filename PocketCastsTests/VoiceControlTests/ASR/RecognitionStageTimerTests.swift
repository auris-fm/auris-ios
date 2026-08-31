import XCTest
@testable import podcasts

final class RecognitionStageTimerTests: XCTestCase {

    func test_timing_computesStageDurationsFromBoundaryMarks() {
        let clock = FakeMonotonicClock()
        clock.setNow(0.100)
        let timer = RecognitionStageTimer(clock: clock)

        timer.mark() // segment ready
        clock.setNow(0.150)
        timer.mark() // wake result
        clock.setNow(0.170)
        timer.mark() // ASR start
        clock.setNow(0.420)
        timer.mark() // ASR result

        let timing = timer.build(
            wakeResult: "detected",
            confidenceMargin: "high",
            listeningMode: "wake_word",
            backend: "whisper"
        )

        XCTAssertEqual(timing?.segmentToWakeMs ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(timing?.wakeToAsrStartMs ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(timing?.asrMs ?? -1, 250, accuracy: 0.001)
        XCTAssertEqual(timing?.wakeToAsrResultMs ?? -1, 270, accuracy: 0.001)
        XCTAssertEqual(timing?.segmentToAsrResultMs ?? -1, 320, accuracy: 0.001)
    }

    func test_timing_withoutDetectedWake_hasNoWakeToAsrResult() {
        let clock = FakeMonotonicClock()
        clock.setNow(0)
        let timer = RecognitionStageTimer(clock: clock)
        for value in [0, 0.010, 0.012, 0.300] {
            clock.setNow(value)
            timer.mark()
        }
        let timing = timer.build(
            wakeResult: "not_detected",
            confidenceMargin: nil,
            listeningMode: "continuous",
            backend: "whisper"
        )
        XCTAssertNil(timing?.wakeToAsrResultMs)
        XCTAssertEqual(timing?.asrMs ?? -1, 288, accuracy: 0.001)
    }

    func test_timing_incompleteMarks_returnsNil() {
        let timer = RecognitionStageTimer(clock: FakeMonotonicClock())
        timer.mark()
        XCTAssertNil(timer.build(wakeResult: "detected", confidenceMargin: nil, listeningMode: "wake_word", backend: "whisper"))
    }
}
