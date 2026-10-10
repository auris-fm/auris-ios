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

    private let lock = NSLock()
    private var samples: [Float] = []
    private let capacity: Int

    /// The pipeline's rate. Sources that render at a different rate are resampled
    /// here so every producer contributes audio in one domain.
    static let pipelineSampleRate: Double = 16_000

    init(sampleRate: Double = PlaybackEchoReference.pipelineSampleRate,
         retainedSeconds: Double = PlaybackEchoReference.retainedSeconds) {
        self.capacity = Int(sampleRate * retainedSeconds)
    }

    /// Appends emitted PCM, keeping only the retained window.
    func append(_ frame: [Float]) {
        guard !frame.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: frame)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// The retained emitted audio, oldest first.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
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
        guard outputCount > 1, frame.count > 1 else { return frame }
        var result = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let pos = Double(i) * (Double(frame.count) - 1) / Double(outputCount - 1)
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = frame[min(idx, frame.count - 1)]
            let b = frame[min(idx + 1, frame.count - 1)]
            result[i] = a + (b - a) * frac
        }
        return result
    }
}
