import Foundation
import Accelerate
import PocketCastsUtils

class NativeVadSegmenter {
    /// The level this segmenter treats as speech.
    ///
    /// It decides where an utterance starts and ends — not whether a command
    /// follows the wake. The wake trimmer does not read it: a positive detection
    /// and its window do not establish that nothing was said after it, so no
    /// consumer may use this level to discard a transcript.
    let threshold: Float
    private let silenceTimeoutMs: Int
    private let minSpeechFrames: Int
    private let maxUtteranceSamples: Int?  // nil = unlimited
    private var buffer: [Float] = []
    private var speechActive = false
    private var silenceStart: Date?
    private var speechFrameCount = 0
    /// Capture instant of the first retained sample, preserved across the buffers that
    /// make up one utterance.
    private var utteranceCapturedAt: MonotonicTime?

    /// Delivers the completed utterance with the instant its **first retained sample** was
    /// captured.
    ///
    /// Preserved through buffering: the segmenter appends several tap buffers before it
    /// emits, so the utterance's start is not the start of the buffer that completed it.
    /// Carrying the first buffer's instant is what lets the echo filter place the segment
    /// against the emitted reference; using the completing buffer's time would shift it by
    /// the segment's own length.
    var onUtterance: (([Float], MonotonicTime?) -> Void)?

    /// - Parameters:
    ///   - threshold: RMS energy threshold above which audio is considered speech
    ///   - silenceTimeoutMs: milliseconds of silence before ending an utterance
    ///   - minSpeechFrames: minimum consecutive speech frames before triggering
    ///   - maxUtteranceMs: maximum utterance duration in ms (nil = unlimited). Forces end when buffer exceeds this.
    static let defaultThreshold: Float = 0.002

    /// How long the segmenter waits after the last speech before emitting.
    ///
    /// Only this segmenter's own timing needs it; nothing outside reads it to
    /// discount the hangover, because the hangover cannot be separated from a
    /// quietly spoken word by a consumer that only has the buffer.
    static let defaultSilenceTimeoutMs = 500

    init(threshold: Float = NativeVadSegmenter.defaultThreshold, silenceTimeoutMs: Int = NativeVadSegmenter.defaultSilenceTimeoutMs, minSpeechFrames: Int = 5, maxUtteranceMs: Int? = nil) {
        self.threshold = threshold
        self.silenceTimeoutMs = silenceTimeoutMs
        self.minSpeechFrames = minSpeechFrames
        self.maxUtteranceSamples = maxUtteranceMs.map { $0 * 16000 / 1000 }
    }

    func process(_ samples: [Float], capturedAt: MonotonicTime? = nil) {
        let energy = rms(samples)

        if energy >= threshold {
            if buffer.isEmpty { utteranceCapturedAt = capturedAt }
            buffer.append(contentsOf: samples)
            speechFrameCount += 1
            if !speechActive && speechFrameCount >= minSpeechFrames {
                speechActive = true
            }
            silenceStart = nil
            // Max duration: force utterance end when buffer exceeds limit
            if let maxSamples = maxUtteranceSamples, speechActive, buffer.count >= maxSamples {
                emitUtterance()
                return
            }
        } else if speechActive {
            if silenceStart == nil {
                silenceStart = Date()
            }
            buffer.append(contentsOf: samples)
            if let start = silenceStart,
               Date().timeIntervalSince(start) * 1000 > Double(silenceTimeoutMs) {
                emitUtterance()
            }
        } else {
            // Speech confirmation requires consecutive energetic frames. An
            // interruption invalidates both the pending count and its audio.
            buffer.removeAll(keepingCapacity: true)
            speechFrameCount = 0
            silenceStart = nil
        }
    }

    private func emitUtterance() {
        let utterance = buffer
        let durationMs = Int(Float(utterance.count) / 16.0)
        FileLog.shared.addMessage("[VoicePipeline] vad ~\(durationMs)ms (\(utterance.count) samples)")
        buffer.removeAll()
        speechActive = false
        silenceStart = nil
        speechFrameCount = 0
        onUtterance?(utterance, utteranceCapturedAt)
    }

    func reset() {
        buffer.removeAll()
        utteranceCapturedAt = nil
        speechActive = false
        silenceStart = nil
        speechFrameCount = 0
    }

    /// Root-mean-square energy of the signal.
    /// Uses vDSP for vectorized computation.
    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSq: Float = 0
        vDSP_measqv(samples, 1, &meanSq, vDSP_Length(samples.count))
        return sqrt(meanSq)
    }
}
