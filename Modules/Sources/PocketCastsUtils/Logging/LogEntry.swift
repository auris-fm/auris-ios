import Foundation

struct LogEntry {

    // MARK: - Public Properties

    let message: String
    let timestamp: Date

    var formattedForLog: String {
        "\(LogEntryFormat.timestampField(of: timestamp)) \(message)"
    }

    // MARK: - Private Properties

    private var formatter: DateFormatter {
        DateFormatHelper.sharedHelper.localTimeJsonDateFormatter
    }

    // MARK: - Initializers

    init(_ message: String, timestamp: Date) {
        self.message = message
        self.timestamp = timestamp
    }
}

/// The sub-second part of a log timestamp.
///
/// The shared date formatter prints whole seconds, which is right for display but not for the log:
/// several stages of one utterance complete inside the same second, so a second-resolution log
/// cannot put them in order and whole steps become unmeasurable after the fact. Milliseconds are
/// appended to the existing `yyyy-MM-dd HH:mm:ss` prefix rather than replacing it, so every reader
/// that parses the current format keeps working.
enum LogEntryFormat {
    /// The full timestamp field: the shared display format, then milliseconds. Both halves derive
    /// from the one `Date` so they cannot disagree.
    static func timestampField(of timestamp: Date) -> String {
        DateFormatHelper.sharedHelper.localTimeJsonDateFormatter.string(from: timestamp)
            + millisecondSuffix(of: timestamp)
    }

    /// `.SSS` for `timestamp`, derived from the same `Date` the prefix came from so the two can
    /// never disagree.
    static func millisecondSuffix(of timestamp: Date) -> String {
        let wholeSeconds = timestamp.timeIntervalSince1970.rounded(.down)
        let millis = Int(((timestamp.timeIntervalSince1970 - wholeSeconds) * 1000).rounded())
        // Rounding can carry to 1000; clamp so the field stays three digits.
        return String(format: ".%03d", min(millis, 999))
    }

    /// Reads the millisecond field back from a formatted line, for tests that must prove the number
    /// is the measured one rather than three padded digits. Positioned on the seconds-of-minute so
    /// minute/hour boundaries cannot be miscounted.
    static func millisecondOfMinute(in line: String) -> Double? {
        guard let range = line.range(of: #"^.*?\d{2}:\d{2}:\d{2}\.(\d{3}) "#, options: .regularExpression)
        else { return nil }
        let matched = String(line[range])
        guard let dot = matched.range(of: #"\.\d{3} "#, options: .regularExpression) else { return nil }
        let digits = matched[dot].dropFirst().prefix(3)
        return Double(digits)
    }
}
