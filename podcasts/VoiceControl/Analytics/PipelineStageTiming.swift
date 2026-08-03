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
