import Foundation
import Accelerate
import PocketCastsUtils

class NativeVadSegmenter {
    private let threshold: Float
    private let silenceTimeoutMs: Int
    private let minSpeechFrames: Int
    private let maxUtteranceSamples: Int?  // nil = unlimited
    private var buffer: [Float] = []
    private var speechActive = false
    private var silenceStart: Date?
    private var speechFrameCount = 0

    var onUtterance: (([Float]) -> Void)?

    /// - Parameters:
    ///   - threshold: RMS energy threshold above which audio is considered speech
    ///   - silenceTimeoutMs: milliseconds of silence before ending an utterance
    ///   - minSpeechFrames: minimum consecutive speech frames before triggering
    ///   - maxUtteranceMs: maximum utterance duration in ms (nil = unlimited). Forces end when buffer exceeds this.
    init(threshold: Float = 0.002, silenceTimeoutMs: Int = 500, minSpeechFrames: Int = 5, maxUtteranceMs: Int? = nil) {
        self.threshold = threshold
        self.silenceTimeoutMs = silenceTimeoutMs
        self.minSpeechFrames = minSpeechFrames
        self.maxUtteranceSamples = maxUtteranceMs.map { $0 * 16000 / 1000 }
    }

    func process(_ samples: [Float]) {
        let energy = rms(samples)

        if energy >= threshold {
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
        onUtterance?(utterance)
    }

    func reset() {
        buffer.removeAll()
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
