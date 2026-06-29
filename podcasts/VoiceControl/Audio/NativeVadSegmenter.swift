import Foundation
import Accelerate

class NativeVadSegmenter {
    private let threshold: Float
    private let silenceTimeoutMs: Int
    private let minSpeechFrames: Int
    private var buffer: [Float] = []
    private var speechActive = false
    private var silenceStart: Date?
    private var speechFrameCount = 0

    var onUtterance: (([Float]) -> Void)?

    /// - Parameters:
    ///   - threshold: RMS energy threshold above which audio is considered speech
    ///   - silenceTimeoutMs: milliseconds of silence before ending an utterance
    ///   - minSpeechFrames: minimum consecutive speech frames before triggering
    init(threshold: Float = 0.01, silenceTimeoutMs: Int = 500, minSpeechFrames: Int = 5) {
        self.threshold = threshold
        self.silenceTimeoutMs = silenceTimeoutMs
        self.minSpeechFrames = minSpeechFrames
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
        } else if speechActive {
            if silenceStart == nil {
                silenceStart = Date()
            }
            buffer.append(contentsOf: samples)
            if let start = silenceStart,
               Date().timeIntervalSince(start) * 1000 > Double(silenceTimeoutMs) {
                let utterance = buffer
                buffer.removeAll()
                speechActive = false
                silenceStart = nil
                speechFrameCount = 0
                onUtterance?(utterance)
            }
        }
        // Non-speech with no active utterance: drop samples
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
        var sum: Float = 0
        vDSP_measqv(samples, 1, &sum, vDSP_Length(samples.count))
        return sqrt(sum / Float(samples.count))
    }
}
