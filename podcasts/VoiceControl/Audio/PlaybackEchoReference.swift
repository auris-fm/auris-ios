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
    /// Total pipeline-rate samples ever appended, so a position in the emitted stream can
    /// be mapped into the trimmed window. Without it, trimming makes the retained window's
    /// index space drift away from the emission stream and the render position no longer
    /// addresses the right samples.
    private var totalAppended = 0

    /// Stream index one past the last appended sample.
    ///
    /// The anchor recorded against the reference is expressed in this space, so a producer
    /// that wants to say "the audio I just emitted ends here" needs it rather than its own
    /// block length.
    var streamIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalAppended
    }
    /// Last observed position of the output node, used to place a captured segment
    /// against the retained audio. Cleared when the node stops rendering.
    private var renderAnchor: PlaybackRenderAnchor?
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
        totalAppended += frame.count
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

    /// Where the audible end of the emitted stream sits within the retained window.
    ///
    /// The retained end is the newest **submitted** sample, which is ahead of what has
    /// actually been heard by however much audio is still queued in the output node. So
    /// the retained end is not an alignment reference even during steady playback — it is
    /// simply less wrong when nothing is queued. This maps the node's **rendered**
    /// position into the window's index space so a segment is placed against what was
    /// audible when it was captured.
    ///
    /// Returns nil when the node is not rendering: the position is then unknown, and no
    /// alignment claim can be made.
    func audibleEndOffsetInRetainedWindow() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let anchor = renderAnchor, !samples.isEmpty else { return nil }
        // Index of the first retained sample within the emitted stream.
        let windowStart = totalAppended - samples.count
        let renderedIndex = Int(anchor.renderedPipelineSamples)
        let offset = renderedIndex - windowStart
        guard offset >= 0 else { return nil }
        return min(offset, samples.count)
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
        renderAnchor = nil
        totalAppended = 0
    }

    /// Records where the output node has actually rendered to.
    ///
    /// A nil anchor means the node is not rendering — it has not started, or it has
    /// stopped/underrun. Either way the reference cannot claim a position for the audio
    /// it holds, so the last known anchor is cleared rather than left in place: stale
    /// render state would let the filter align a segment against audio that is no longer
    /// playing.
    func recordRenderPosition(_ anchor: PlaybackRenderAnchor?) {
        lock.lock()
        defer { lock.unlock() }
        renderAnchor = anchor
    }

    /// The last observed render position, or nil when the node is not rendering.
    var currentRenderAnchor: PlaybackRenderAnchor? {
        lock.lock()
        defer { lock.unlock() }
        return renderAnchor
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

/// Maps the output node's render position onto the reference's timeline.
///
/// The node reports what it has rendered, not what was submitted, so the reference has
/// to know which of its retained samples correspond to that position. The node's
/// `playerTime` advances in the audio's own sample frames while the reference is held at
/// the pipeline rate, so the conversion is a frame-count mapping rather than a wall-clock
/// subtraction: converting seconds first would lose the frame alignment the correlation
/// depends on.
struct PlaybackRenderAnchor: Equatable {
    /// Frames the node has rendered, in the source audio's rate.
    let renderedFrames: Double
    /// The rate those frames were rendered at.
    let sourceSampleRate: Double
    /// Instant the render position corresponds to, on the shared monotonic basis.
    let hostTime: MonotonicTime

    /// The rendered position expressed in pipeline-rate samples.
    ///
    /// Derived from `renderedFrames`, which is what the node reports, rather than from
    /// elapsed host time: the two can disagree when the node underruns or restarts, and
    /// using the clock would then silently misplace the reference instead of showing the
    /// discontinuity. `sourceSampleRate` converts frames across the two rates.
    var renderedPipelineSamples: Double {
        guard sourceSampleRate > 0 else { return 0 }
        return renderedFrames / sourceSampleRate * PlaybackEchoReference.pipelineSampleRate
    }
}
