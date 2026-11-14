import XCTest

@testable import podcasts

/// The stage durations already existed as an analytics event, which needs a build to read back.
/// The persisted log is what a person can inspect on a device after the fact, so the same numbers
/// are written there. These tests fix the two properties that make the log usable for measurement:
/// every stage is present and named, and the values keep sub-millisecond-visible resolution.
final class PipelineStageTimingLogTests: XCTestCase {

    private func timing(
        segmentToWake: Double = 100,
        wakeToAsrStart: Double = 20,
        asr: Double = 300,
        wakeToAsrResult: Double? = 320,
        segmentToAsrResult: Double = 420
    ) -> PipelineStageTiming {
        PipelineStageTiming(
            segmentToWakeMs: segmentToWake,
            wakeToAsrStartMs: wakeToAsrStart,
            asrMs: asr,
            wakeToAsrResultMs: wakeToAsrResult,
            segmentToAsrResultMs: segmentToAsrResult,
            wakeResult: "detected",
            confidenceMargin: "0.42",
            listeningMode: "wake_word",
            backend: "sensevoice"
        )
    }

    /// Each stage must be findable by name. A reader was unable to attribute a duration to a stage
    /// from the log alone, because the numbers arrived unlabelled — measuring anything then meant
    /// guessing the order the builder printed them in.
    func test_everyStageIsNamedInTheLog() {
        let field = timing().logField
        for label in ["seg->wake", "wake->asrStart", "asr=", "seg->asrResult", "wake->asrResult"] {
            XCTAssertTrue(field.contains(label), "`\(label)` missing from log field: \(field)")
        }
    }

    /// Sub-10ms stages must not collapse into the same printed value. Whole-millisecond printing
    /// made a 4ms and a 9ms stage both read `0`/`1`, which is coarser than the numbers already
    /// measured for the detector and router.
    func test_fractionalMillisecondsAreNotRoundedAway() {
        let field = timing(wakeToAsrStart: 4.25).logField
        XCTAssertTrue(field.contains("4.2") || field.contains("4.3"),
                      "a 4.25ms stage must keep its fraction: \(field)")
    }

    /// When the detector did not run, the dependent duration is absent rather than printed as a
    /// zero. A printed `0ms` reads as a measured zero-length stage, which is a different claim from
    /// "this stage never happened".
    func test_absentWakeToAsrResultIsOmittedNotZeroed() {
        let field = timing(wakeToAsrResult: nil).logField
        XCTAssertFalse(field.contains("wake->asrResult"),
                       "an unmeasured stage must be omitted, not reported as a value: \(field)")
        // Matches the stage label, not a formatted number: this test is about omission, and
        // asserting a literal `300.0` made it also fail on a precision change it does not cover.
        XCTAssertTrue(field.contains("asr=300"), "the measured stages must still be present: \(field)")
    }

    /// The wake outcome belongs in the same line: without it a duration cannot be read in context,
    /// since the stage sequence differs between a detection and a drop.
    func test_wakeResultIsIncluded() {
        XCTAssertTrue(timing().logField.contains("wake=detected"))
    }
}