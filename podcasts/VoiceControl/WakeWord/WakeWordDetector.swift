import Foundation
import PocketCastsUtils

class WakeWordDetector: WakeWordDetectorProtocol {
    private var nativeHandle: UnsafeMutableRawPointer?
    private let threshold: Float

    /// - Parameters:
    ///   - melModel: Path to melspectrogram ONNX model
    ///   - embedModel: Path to embedding ONNX model
    ///   - classifierModel: Path to "Auris" classifier ONNX model
    ///   - threshold: Deployment threshold loaded from the eval manifest
    init(melModel: URL, embedModel: URL, classifierModel: URL, threshold: Float) {
        self.threshold = threshold
        fflush(stderr)
        self.nativeHandle = melModel.path.withCString { melPath in
            embedModel.path.withCString { embedPath in
                classifierModel.path.withCString { clsPath in
                    wakeword_init(melPath, embedPath, clsPath, threshold)
                }
            }
        }
        if nativeHandle == nil {
            let errorDetail: String
            if let cError = wakeword_last_error() {
                errorDetail = " — \(String(cString: cError))"
            } else {
                errorDetail = ""
            }
            FileLog.shared.addMessage("[VoiceControl/WakeWord] Failed to initialize ONNX pipeline\(errorDetail)")
        } else {
            FileLog.shared.addMessage("[VoiceControl/WakeWord] ONNX pipeline initialized OK")
        }
        fflush(stderr)
    }

    /// Scores the utterance and returns the tagged result. An initialization or
    /// scoring failure is never converted into a zero-confidence `notDetected`.
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        guard let handle = nativeHandle else {
            return .error(code: "init_failed")
        }
        guard !samples.isEmpty else {
            return .error(code: "no_samples")
        }

        // Native entry points clear the thread-local last-error, so a non-null
        // pointer after the call means this segment failed to score.
        var completionSample: Int32 = -1
        let maxScore = samples.withUnsafeBufferPointer { ptr in
            wakeword_detect_segment(handle, ptr.baseAddress, Int32(samples.count), Int32(sampleRate), &completionSample)
        }

        if let errorPtr = wakeword_last_error() {
            let errorDetail = String(cString: errorPtr)
            FileLog.shared.addMessage("[VoicePipeline] wake scoring failed: \(errorDetail)")
            return .error(code: "detect_failed")
        }

        // Score + decision are logged once by VoiceAsrEngine as [VoicePipeline].
        return maxScore >= threshold
            ? .detected(confidence: maxScore, completionSample: max(0, Int(completionSample)))
            : .notDetected(confidence: maxScore)
    }

    func release() {
        if let handle = nativeHandle {
            wakeword_release(handle)
            nativeHandle = nil
        }
    }

    deinit { release() }
}

// MARK: - C Bridge

/// These C functions are implemented in WakeWordDetector.cpp and linked
/// via the bridging header. They wrap the ONNX Runtime 3-stage pipeline
/// (mel spectrogram → embedding → classifier).

/// Initializes the 3-stage ONNX Runtime pipeline.
/// Returns an opaque handle, or nil if ONNX Runtime is not linked or
/// any model fails to load.
@_silgen_name("wakeword_init")
private func wakeword_init(
    _ melModelPath: UnsafePointer<CChar>,
    _ embedModelPath: UnsafePointer<CChar>,
    _ classifierModelPath: UnsafePointer<CChar>,
    _ threshold: Float
) -> UnsafeMutableRawPointer?

/// Runs detection on a single window of 16kHz mono float PCM.
/// Returns a confidence score in [0, 1].
@_silgen_name("wakeword_detect")
private func wakeword_detect(
    _ handle: UnsafeMutableRawPointer,
    _ samples: UnsafePointer<Float>?,
    _ sampleCount: Int32,
    _ sampleRate: Int32
) -> Float

/// Runs detection on a complete VAD segment per the recognition-pipeline
/// detection-window policy (virtual 2s context, single preprocessing pass,
/// stride-1 classifier windows). Returns the maximum score in [0, 1].
@_silgen_name("wakeword_detect_segment")
private func wakeword_detect_segment(
    _ handle: UnsafeMutableRawPointer,
    _ samples: UnsafePointer<Float>?,
    _ sampleCount: Int32,
    _ sampleRate: Int32,
    _ outCompletionSample: UnsafeMutablePointer<Int32>?
) -> Float

/// Releases all ONNX Runtime resources.
@_silgen_name("wakeword_release")
private func wakeword_release(_ handle: UnsafeMutableRawPointer)

/// Returns the last C++ error message, or nil.
@_silgen_name("wakeword_last_error")
private func wakeword_last_error() -> UnsafePointer<CChar>?
