import Foundation
import Accelerate
import PocketCastsUtils

class NativeVadSegmenter {
    /// The level this segmenter treats as speech. Read by the wake trimmer so
    /// the two agree by construction rather than by a shared default that the
    /// wiring can override (it does: the app builds this with 0.020).
    let threshold: Float
    private let silenceTimeoutMs: Int
    private let minSpeechFrames: Int
    private let maxUtteranceSamples: Int?  // nil = unlimited
    private var buffer: [Float] = []
    private var speechActive = false
    private var silenceStart: Date?
    private var speechFrameCount = 0
    /// Index into `buffer` of the last frame at or above `threshold`.
    private var lastSpeechSample = -1

    /// The emitted capture, plus the index of its last frame at or above the
    /// threshold — the producer's own answer to "where did speech stop".
    ///
    /// A consumer cannot recover this from the buffer: once `speechActive`, a
    /// sub-threshold frame is appended and starts the silence clock, so the
    /// capture ends `silenceTimeoutMs` after the *first* quiet frame rather than
    /// after the last loud one. A consumer reasoning from energy is asking a
    /// question the producer already answered, and mis-answers it for a quietly
    /// spoken command.
    var onUtterance: ((_ samples: [Float], _ lastSpeechSample: Int) -> Void)?

    /// - Parameters:
    ///   - threshold: RMS energy threshold above which audio is considered speech
    ///   - silenceTimeoutMs: milliseconds of silence before ending an utterance
    ///   - minSpeechFrames: minimum consecutive speech frames before triggering
    ///   - maxUtteranceMs: maximum utterance duration in ms (nil = unlimited). Forces end when buffer exceeds this.
    static let defaultThreshold: Float = 0.002

    /// How long the segmenter waits after the last speech before emitting, so a
    /// consumer reasoning about a capture's length can discount the trailing
    /// silence the producer added rather than reading it as the user's speech.
    static let defaultSilenceTimeoutMs = 500

    init(threshold: Float = NativeVadSegmenter.defaultThreshold, silenceTimeoutMs: Int = NativeVadSegmenter.defaultSilenceTimeoutMs, minSpeechFrames: Int = 5, maxUtteranceMs: Int? = nil) {
        self.threshold = threshold
        self.silenceTimeoutMs = silenceTimeoutMs
        self.minSpeechFrames = minSpeechFrames
        self.maxUtteranceSamples = maxUtteranceMs.map { $0 * 16000 / 1000 }
    }

    func process(_ samples: [Float]) {
        let energy = rms(samples)

        if energy >= threshold {
            buffer.append(contentsOf: samples)
            lastSpeechSample = buffer.count - 1
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
        let speechEnd = lastSpeechSample
        buffer.removeAll()
        lastSpeechSample = -1
        speechActive = false
        silenceStart = nil
        speechFrameCount = 0
        onUtterance?(utterance, speechEnd)
    }

    func reset() {
        buffer.removeAll()
        lastSpeechSample = -1
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
