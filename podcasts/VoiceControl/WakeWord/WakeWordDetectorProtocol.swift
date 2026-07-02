import Foundation

struct WakeWordResult {
    let detected: Bool
    let confidence: Float
    /// Audio after the wake word, or nil if detection couldn't localize the cut point.
    /// When non-nil, this should be passed to ASR instead of the full utterance.
    let remainderSamples: [Float]?
}

protocol WakeWordDetectorProtocol: AnyObject {
    /// Runs wake word detection on the full VAD utterance.
    /// Returns detection result including stripped remainder audio.
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult
    func release()
}
