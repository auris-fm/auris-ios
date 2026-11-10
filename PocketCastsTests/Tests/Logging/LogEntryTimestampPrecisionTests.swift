import XCTest

@testable import PocketCastsUtils

/// The persisted app log is the only record of a session that a person can read afterwards, so its
/// timestamps decide what can be measured from it at all.
///
/// A latency investigation over the stored log could not place two stages of one utterance in order,
/// because every line carried second resolution and several stages complete inside the same second.
/// Whole steps were reported as "not logged" for that reason alone. The plan for latency work
/// requires the log to carry the client clock at millisecond precision for every step it names.
final class LogEntryTimestampPrecisionTests: XCTestCase {

    /// A second-resolution log cannot distinguish stages that finish within one second of each
    /// other — which is the ordinary case for utterance stages. These two times differ by 400ms.
    ///
    /// Compares the timestamp field only. Comparing whole lines proves nothing here: two entries one
    /// second apart also differ in their message text, and my first version of this test passed
    /// against the second-resolution log for exactly that reason.
    func test_timestampFieldDistinguishesSubSecondTimes() {
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        let earlier = LogEntryFormat.timestampField(of: base)
        let later = LogEntryFormat.timestampField(of: base.addingTimeInterval(0.400))

        XCTAssertNotEqual(earlier, later,
                          "stages 400ms apart must not share a timestamp: got \(earlier)")
    }

    /// Milliseconds are recorded, not merely a finer-looking format: reading the number back must
    /// recover the actual offset. A format that prints three digits it did not measure would pass a
    /// string-shape check while carrying no more information than before.
    func test_logLineMillisecondsMatchTheRecordedTime() throws {
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        let offsetMs = 137.0
        let line = LogEntry("cloud request sent", timestamp: base.addingTimeInterval(offsetMs / 1000))
            .formattedForLog

        let millis = try XCTUnwrap(LogEntryFormat.millisecondOfMinute(in: line),
                                   "the line must carry a parseable millisecond field: \(line)")
        XCTAssertEqual(millis, 137, accuracy: 0.5,
                       "the printed milliseconds must be the measured ones, not padding")
    }

    /// The added field must not shift or truncate the existing date/time, or every tool that reads
    /// the current log prefix would break.
    func test_existingSecondResolutionPrefixIsUnchanged() {
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        let line = LogEntry("anything", timestamp: base).formattedForLog
        let expectedPrefix = DateFormatHelper.sharedHelper.localTimeJsonDateFormatter.string(from: base)
        XCTAssertTrue(line.hasPrefix(expectedPrefix),
                      "the existing `yyyy-MM-dd HH:mm:ss` prefix must remain a prefix: \(line)")
    }
}