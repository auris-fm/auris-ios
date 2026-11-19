import Foundation

typealias MonotonicTime = CFTimeInterval

protocol MonotonicClock {
    func now() -> MonotonicTime
}

struct SystemMonotonicClock: MonotonicClock {
    func now() -> MonotonicTime {
        CACurrentMediaTime()
    }
}

/// Wake/ASR stage durations for the `voice_recognition_latency` event
/// (recognition-pipeline.md "Production Recognition Latency Metrics").
/// All durations are milliseconds; `wakeToAsrResultMs` is nil when the wake
/// detector did not run or did not detect.
struct PipelineStageTiming {
    let segmentToWakeMs: Double
    let wakeToAsrStartMs: Double
    let asrMs: Double
    let wakeToAsrResultMs: Double?
    let segmentToAsrResultMs: Double
    let wakeResult: String
    let confidenceMargin: String?
    let listeningMode: String
    let backend: String
}

extension PipelineStageTiming {
    /// The persisted-log form of these durations. Milliseconds are printed with one decimal so
    /// sub-10ms stages stay distinguishable instead of all rounding to `0` or `1`; a whole
    /// millisecond of reportable resolution is lost otherwise, and this log exists to be measured
    /// from. Every field is named, so a reader does not have to know the builder's order.
    var logField: String {
        let ms: (Double) -> String = { String(format: "%.1f", $0) }
        var parts = [
            "seg->wake=\(ms(segmentToWakeMs))ms",
            "wake->asrStart=\(ms(wakeToAsrStartMs))ms",
            "asr=\(ms(asrMs))ms",
            "seg->asrResult=\(ms(segmentToAsrResultMs))ms"
        ]
        if let wakeToAsrResultMs {
            parts.append("wake->asrResult=\(ms(wakeToAsrResultMs))ms")
        }
        parts.append("wake=\(wakeResult)")
        return parts.joined(separator: " ")
    }
}

/// Records monotonic boundary marks for one utterance and derives the stage
/// durations. The four marks are: segment ready, wake result, ASR start, ASR
/// result. Timing measures the actual operations the fields name — it never
/// backfills or reuses timestamps.
final class RecognitionStageTimer {
    private let clock: MonotonicClock
    private var marks: [MonotonicTime] = []

    init(clock: MonotonicClock) {
        self.clock = clock
    }

    func mark() {
        marks.append(clock.now())
    }

    func build(
        wakeResult: String,
        confidenceMargin: String?,
        listeningMode: String,
        backend: String
    ) -> PipelineStageTiming? {
        guard marks.count == 4 else { return nil }
        let t0 = marks[0]
        let t1 = marks[1]
        let t2 = marks[2]
        let t3 = marks[3]
        let milliseconds: (MonotonicTime, MonotonicTime) -> Double = { ($1 - $0) * 1000 }
        return PipelineStageTiming(
            segmentToWakeMs: milliseconds(t0, t1),
            wakeToAsrStartMs: milliseconds(t1, t2),
            asrMs: milliseconds(t2, t3),
            wakeToAsrResultMs: wakeResult == "detected" ? milliseconds(t1, t3) : nil,
            segmentToAsrResultMs: milliseconds(t0, t3),
            wakeResult: wakeResult,
            confidenceMargin: confidenceMargin,
            listeningMode: listeningMode,
            backend: backend
        )
    }
}
