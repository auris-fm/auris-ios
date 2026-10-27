@testable import podcasts
import XCTest

/// Controls for the capture telemetry that makes "no wake word" attributable
/// (#core:25b91a1b `98ba5c48`).
///
/// The observed problem was not a missing feature but a missing OBSERVATION: after `First buffer`
/// (logged once per process) and the VAD's emit-only `vad ~` line, the log reported nothing about
/// whether audio was still arriving or how loud it was. "Everything is ready but still no wake
/// word" could therefore not be attributed to a quiet room, a level below the VAD threshold, or a
/// tap that stopped delivering.
///
/// A second trap made this worse and is pinned here: `FileLog` buffers entries in memory until 100
/// accumulate, so a telemetry line that is only `addMessage`d is invisible for minutes while
/// capture runs — and lost outright if the process is terminated first. Measured on the simulator:
/// the log sat frozen at the `First buffer` line while the app was alive, because that line is one
/// of the few that forces a flush. A diagnostic must force it too.
final class CaptureTelemetryControl: XCTestCase {

    /// The defect being fixed: a running capture must periodically say it is still receiving.
    func testARunningCaptureReportsPeriodically() throws {
        var telemetry = CaptureTelemetry()
        let start = Date()

        // The first buffer alone must NOT report: `First buffer` already covers it, and a single
        // buffer is not evidence of a healthy stream. This call also starts the interval clock.
        telemetry.record(rms: 0.004)
        XCTAssertNil(
            telemetry.takeReport(now: start, interval: 5),
            "the first buffer must not produce a telemetry line; `First buffer` already reports it"
        )

        // Sustained buffers after the interval DO report.
        telemetry.record(rms: 0.004)
        telemetry.record(rms: 0.005)
        let report = try XCTUnwrap(
            telemetry.takeReport(now: start.addingTimeInterval(5), interval: 5),
            "a running capture must report after the interval, otherwise silence is again "
                + "indistinguishable from a dead tap"
        )
        // 3 buffers arrived before the report: the one that started the clock plus the two after.
        XCTAssertTrue(report.contains("3 buffers"), "the report must state how many buffers arrived: \(report)")
        XCTAssertTrue(report.contains("peak rms"), "the report must state the measured level: \(report)")
    }

    /// The report states the MEASUREMENT only. It must not claim a level is above or below the
    /// speech threshold: the threshold belongs to the segmenter, which production constructs with
    /// its own value (0.020) that differs from the type's default (0.002). An earlier version
    /// printed a verdict against the default and was confidently wrong during a live diagnosis.
    func testAReportStatesTheMeasurementWithoutAVerdict() throws {
        var telemetry = CaptureTelemetry()
        let start = Date()
        telemetry.record(rms: 0.0001)
        _ = telemetry.takeReport(now: start, interval: 5) // starts the clock
        telemetry.record(rms: 0.0002)

        let report = try XCTUnwrap(telemetry.takeReport(now: start.addingTimeInterval(5), interval: 5))
        XCTAssertFalse(
            report.contains("above") || report.contains("below"),
            "the report must not assert a threshold verdict it cannot know: \(report)"
        )
        XCTAssertTrue(report.contains("peak rms"), "it must still state the measured level: \(report)")
    }

    /// A tap that stops delivering must not keep reporting the level it last saw, because a stale
    /// healthy line is worse than none. Silence after the tap dies is the honest signal, and the
    /// absence of the periodic line is what makes it visible.
    func testAStoppedTapStopsReporting() {
        var telemetry = CaptureTelemetry()
        let start = Date()
        telemetry.record(rms: 0.01)
        _ = telemetry.takeReport(now: start, interval: 5) // starts the clock
        telemetry.record(rms: 0.01)
        _ = telemetry.takeReport(now: start.addingTimeInterval(5), interval: 5)

        // No further buffers arrive: once the window is consumed, nothing more is reported however
        // long passes. Critically the last healthy line must not be repeated, since a stale level
        // would claim a live tap.
        XCTAssertNil(
            telemetry.takeReport(now: start.addingTimeInterval(60), interval: 5),
            "a tap that stopped delivering must produce no further reports"
        )
        XCTAssertNil(
            telemetry.takeReport(now: start.addingTimeInterval(120), interval: 5),
            "a stopped tap must stay silent, not repeat its last level"
        )
    }

    /// Spam guard: a continuously reporting pipeline must respect the interval.
    func testReportsAreThrottledToTheInterval() throws {
        var telemetry = CaptureTelemetry()
        let start = Date()
        telemetry.record(rms: 0.01)
        _ = telemetry.takeReport(now: start, interval: 5)

        telemetry.record(rms: 0.01)
        XCTAssertNil(
            telemetry.takeReport(now: start.addingTimeInterval(1), interval: 5),
            "a report must not be emitted before the interval elapses"
        )
        XCTAssertNotNil(
            telemetry.takeReport(now: start.addingTimeInterval(5), interval: 5),
            "a report must be emitted once the interval has elapsed"
        )
    }

    /// The reported level is the same measure the VAD decides on, so the numbers in the log are
    /// directly comparable to its threshold rather than an unrelated unit.
    func testRmsMatchesTheVadMeasure() {
        // RMS of a constant signal is its absolute value; of silence, zero.
        XCTAssertEqual(CaptureTelemetry.rms(of: [0.5, 0.5, 0.5, 0.5]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(CaptureTelemetry.rms(of: [0, 0, 0, 0]), 0, accuracy: 1e-9)
        XCTAssertEqual(CaptureTelemetry.rms(of: []), 0)
        // A constant signal reports exactly its own value, so a level printed in the log is the
        // level the segmenter will compare against its threshold — same measure, real units.
        let constant: Float = 0.02
        let atThreshold = [Float](repeating: constant, count: 64)
        XCTAssertEqual(CaptureTelemetry.rms(of: atThreshold), constant, accuracy: 1e-7)
    }
}
