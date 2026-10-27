import Foundation

/// Capture telemetry accumulator.
///
/// WHY THIS EXISTS (#core:25b91a1b `98ba5c48`): after a successful start the capture path logged
/// exactly one line per process (`First buffer`) and the VAD logged only when an utterance was
/// EMITTED. A user reporting "everything is ready but still no wake word" therefore could not be
/// diagnosed at all: a quiet room, a level that never crosses the VAD threshold, and a tap that
/// stopped delivering buffers are three different defects producing identical logs — none.
///
/// This accumulator answers the question the log could not: are samples still arriving, and how
/// loud are they. It deliberately does NOT judge the level against a speech threshold — that value
/// belongs to the segmenter and is not visible from here, and a wrong comparison is worse than none.
///
/// Kept free of AVFoundation and of `FileLog` so the reporting rule is unit-testable without an
/// audio engine; `NativeAudioCapture` owns an instance and asks it whether to report.
struct CaptureTelemetry {
    /// Number of buffers received since the last report.
    private(set) var buffersSinceReport = 0
    /// Peak RMS observed since the last report — the same measure the VAD compares to its own
    /// configured threshold, so the logged figure is directly comparable to it.
    private(set) var peakRmsSinceReport: Float = 0
    private var lastReport: Date?

    /// Records one delivered buffer.
    mutating func record(rms: Float) {
        buffersSinceReport += 1
        if rms > peakRmsSinceReport { peakRmsSinceReport = rms }
    }

    /// Consumes the accumulated window and returns the line to log.
    ///
    /// Returns nil when nothing is due, so the caller has no reporting policy of its own.
    mutating func takeReport(now: Date, interval: TimeInterval) -> String? {
        guard buffersSinceReport > 0 else { return nil }
        // Start the clock on the first buffer without reporting it.
        guard let lastReport else {
            self.lastReport = now
            return nil
        }
        guard now.timeIntervalSince(lastReport) >= interval else { return nil }
        let buffers = buffersSinceReport
        let peak = peakRmsSinceReport
        buffersSinceReport = 0
        peakRmsSinceReport = 0
        self.lastReport = now
        // NO above/below verdict. The threshold that decides speech belongs to the SEGMENTER, which
        // is constructed with its own value (production: 0.020, not the type's 0.002 default), and
        // this type has no reliable way to see it. An earlier version compared against the default
        // and printed "above utterance threshold 0.002" for levels that were far below the real
        // 0.020 — a confidently wrong label during a live diagnosis. Report the measurement; let the
        // reader compare it to the configured threshold.
        return "[VoicePipeline] capture: \(buffers) buffers, peak rms \(String(format: "%.6f", peak))"
    }

    /// Root-mean-square, matching `NativeVadSegmenter`'s own measure.
    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
