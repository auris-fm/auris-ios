import Foundation

/// Tagged wake-word result per recognition-pipeline.md. `Error(code:)` carries
/// neither a detection decision nor a confidence value, so callers cannot branch
/// on a default boolean. `Detected` iff the maximum score >= deployment threshold.
enum WakeWordResult: Equatable {
    case detected(confidence: Float, completionSample: Int)
    case notDetected(confidence: Float)
    case error(code: String)
}

protocol WakeWordDetectorProtocol: AnyObject {
    /// Runs wake-word detection on the full VAD utterance and returns the tagged
    /// result. The complete original segment is always forwarded to ASR on a
    /// positive result; the detector never cuts audio.
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult
    func release()
}
