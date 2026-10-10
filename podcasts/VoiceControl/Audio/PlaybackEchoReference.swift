import AVFoundation

/// The shared emitted-PCM reference the echo filter correlates against.
///
/// Per `recognition-pipeline.md` "Signal Filter", the clients must feed the audio
/// actually sent to the output device into one shared reference, so an echo-only
/// segment can be rejected before it becomes accepted speech. The reference is
/// bounded: correlation only needs the recent window, and an unbounded buffer would
/// grow with playback length.
final class PlaybackEchoReference {
    /// How much emitted audio is retained. The correlation window only needs enough
    /// recent audio to align a VAD segment against it; keeping the whole answer would
    /// cost memory proportional to playback length for no additional discrimination.
    static let retainedSeconds: Double = 2.0

    /// One retained span of emitted audio, with the instant it began.
    struct Span {
        let samples: [Float]
        /// Start of this span on the shared monotonic basis.
        let startedAt: MonotonicTime
    }

    private let lock = NSLock()
    private var samples: [Float] = []
    /// Monotonic instant of the first retained sample.
    ///
    /// A common sample rate is not alignment: two producers resampled to 16 kHz still
    /// need to be placed in time relative to the captured segment, or correlation
    /// compares the right rate at the wrong offset. The clock is the same
    /// `MonotonicClock` the recognition stages use, so playback and capture share one
    /// basis and are unaffected by wall-clock changes.
    private var startTime: MonotonicTime = 0
    private let capacity: Int
    private let clock: MonotonicClock

    /// The pipeline's rate. Sources that render at a different rate are resampled
    /// here so every producer contributes audio in one domain.
    static let pipelineSampleRate: Double = 16_000

    init(sampleRate: Double = PlaybackEchoReference.pipelineSampleRate,
         retainedSeconds: Double = PlaybackEchoReference.retainedSeconds,
         clock: MonotonicClock = SystemMonotonicClock()) {
        self.capacity = Int(sampleRate * retainedSeconds)
        self.clock = clock
    }

    /// Appends emitted PCM, keeping only the retained window.
    func append(_ frame: [Float]) {
        guard !frame.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if samples.isEmpty {
            startTime = clock.now()
        }
        samples.append(contentsOf: frame)
        if samples.count > capacity {
            let dropped = samples.count - capacity
            samples.removeFirst(dropped)
            // The retained window now begins `dropped` samples later.
            startTime += Double(dropped) / PlaybackEchoReference.pipelineSampleRate
        }
    }

    /// The retained emitted audio, oldest first.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// The retained audio with the monotonic instant its first sample was emitted.
    /// Empty (and unaligned) when nothing is retained.
    func span() -> Span? {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        return Span(samples: samples, startedAt: startTime)
    }

    /// Retires the reference.
    ///
    /// Called when the output route changes: audio retained from a previous output
    /// path must not be correlated against microphone audio from a new one, whose
    /// delay characteristics are different.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }

    /// Retires the reference for a route change or a stop, retaining the acoustic tail.
    ///
    /// Audio already submitted to the output is still audible after the route moves or
    /// playback stops, so clearing immediately would lose exactly the echo the filter
    /// still needs to reject. The tail is kept for `delaySeconds`, after which the
    /// reference is empty — it is no longer a valid reference for the *new* route,
    /// which has its own delay characteristics, so it is only retained long enough to
    /// cover the old path's sound.
    func retire(retainingAcousticTail delaySeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return }
        let tail = max(0, min(samples.count, Int(delaySeconds * PlaybackEchoReference.pipelineSampleRate)))
        guard tail > 0 else {
            samples.removeAll(keepingCapacity: true)
            return
        }
        let dropped = samples.count - tail
        samples.removeFirst(dropped)
        startTime += Double(dropped) / PlaybackEchoReference.pipelineSampleRate
    }
}

/// Resamples emitted audio into the pipeline's rate.
enum PlaybackResampler {
    /// Linear resampling from `sourceRate` to the pipeline rate, matching the
    /// interpolation `NativeAudioCapture` already uses for the microphone path, so
    /// both sides of the correlation are produced the same way.
    ///
    /// Linear interpolation is adequate here: the filter aligns a segment against this
    /// buffer to detect residual bleed, so small interpolation error does not change the
    /// correlation's decision — whereas a rate mismatch would change the alignment
    /// entirely.
    static func toPipelineRate(_ frame: [Float], sourceRate: Double) -> [Float] {
        guard sourceRate > 0, sourceRate != PlaybackEchoReference.pipelineSampleRate else { return frame }
        let outputCount = Int(Double(frame.count) * PlaybackEchoReference.pipelineSampleRate / sourceRate)
        guard outputCount > 0, frame.count > 1 else { return frame }

        // Map on the true ratio, not by stretching the frame end-to-end.
        //
        // Anchoring both endpoints (`i * (count-1) / (outputCount-1)`) spans 959
        // intervals of source samples for an exact 3:1 frame, giving a per-sample step
        // of 3.00627 instead of 3.0 and representing each 20 ms chunk as 19.979 ms.
        // Every frame boundary then carries a phase discontinuity. Advancing by the
        // true ratio keeps consecutive frames contiguous, so the stream stays on one
        // timeline — which is what the correlation depends on.
        let step = sourceRate / PlaybackEchoReference.pipelineSampleRate
        var result = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let pos = Double(i) * step
            let lower = Int(pos)
            guard lower < frame.count else { break }
            let upper = min(lower + 1, frame.count - 1)
            let fraction = Float(pos - Double(lower))
            let a = frame[lower]
            let b = frame[upper]
            result[i] = a + (b - a) * fraction
        }
        return result
    }
}
