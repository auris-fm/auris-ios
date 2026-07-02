import Foundation

class WakeWordDetector: WakeWordDetectorProtocol {
    private var nativeHandle: UnsafeMutableRawPointer?
    private let threshold: Float

    /// - Parameters:
    ///   - melModel: Path to melspectrogram ONNX model
    ///   - embedModel: Path to embedding ONNX model
    ///   - classifierModel: Path to "Auris" classifier ONNX model
    ///   - threshold: Confidence threshold above which a detection is triggered
    init(melModel: URL, embedModel: URL, classifierModel: URL, threshold: Float) {
        self.threshold = threshold
        self.nativeHandle = wakeword_init(
            melModel.path,
            embedModel.path,
            classifierModel.path,
            threshold
        )
    }

    /// Processes audio samples through the 3-stage openWakeWord pipeline.
    /// Uses sliding windows of ~2 seconds with 0.5 second stride to match the Python ring-buffer.
    /// When the wake word is detected, computes the remainder audio after the wake word
    /// so ASR receives only the command, not "Auris" noise.
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        guard let handle = nativeHandle, !samples.isEmpty else {
            return WakeWordResult(detected: false, confidence: 0, remainderSamples: nil)
        }
        let windowSize = sampleRate * 2   // 2 seconds
        let stride = sampleRate / 2       // 0.5 second stride

        var maxScore: Float = 0
        var maxOffset: Int = 0
        var offset = 0

        while offset + windowSize <= samples.count {
            let window = Array(samples[offset..<offset + windowSize])
            let score = wakeword_detect(handle, window, Int32(sampleRate))
            if score > maxScore {
                maxScore = score
                maxOffset = offset
            }
            offset += stride
        }

        let detected = maxScore >= threshold
        guard detected else {
            return WakeWordResult(detected: false, confidence: maxScore, remainderSamples: nil)
        }

        // The wake word occupies roughly the first 600ms of the segment.
        // The detection window that fired tells us where the wake word starts;
        // we cut after ~600ms from that window's start.
        let wakeWordDurationMs = 600
        let wakeWordEndSample = maxOffset + (wakeWordDurationMs * sampleRate / 1000)

        // Safety: if the cut point is too close to the start or end, or if the
        // segment is too short, return nil so the caller falls back to full audio.
        let minRemainderSamples = sampleRate / 5  // 200ms minimum remainder
        guard wakeWordEndSample > 0,
              wakeWordEndSample < samples.count - minRemainderSamples
        else {
            return WakeWordResult(detected: true, confidence: maxScore, remainderSamples: nil)
        }

        let remainder = Array(samples[wakeWordEndSample..<samples.count])
        return WakeWordResult(detected: true, confidence: maxScore, remainderSamples: remainder)
    }

    func release() {
        if let handle = nativeHandle {
            wakeword_release(handle)
            nativeHandle = nil
        }
    }

    deinit { release() }
}

// MARK: - C Bridge to openWakeWord ONNX Runtime pipeline

/// Initializes the 3-stage ONNX Runtime pipeline:
/// - Mel spectrogram feature extractor
/// - Audio embedding model
/// - "Auris" wake-word classifier
///
/// Linked from WakeWordDetector.cpp via the bridging header.
/// Returns an opaque handle to the initialized pipeline, or nil on failure.
private func wakeword_init(
    _ melModelPath: String,
    _ embedModelPath: String,
    _ classifierModelPath: String,
    _ threshold: Float
) -> UnsafeMutableRawPointer? {
    #if canImport(onnxruntime)
    guard let melPath = melModelPath.cString(using: .utf8),
          let embedPath = embedModelPath.cString(using: .utf8),
          let clsPath = classifierModelPath.cString(using: .utf8)
    else { return nil }
    return wakeword_init_c(melPath, embedPath, clsPath, threshold)
    #else
    // ONNX Runtime not linked — wake word will be unavailable
    return nil
    #endif
}

/// Runs detection on a single ~2-second window of 16kHz mono float PCM.
/// Returns a confidence score in [0, 1].
private func wakeword_detect(
    _ handle: UnsafeMutableRawPointer,
    _ samples: [Float],
    _ sampleRate: Int32
) -> Float {
    #if canImport(onnxruntime)
    return samples.withUnsafeBufferPointer { ptr in
        wakeword_detect_c(handle, ptr.baseAddress, Int32(samples.count), sampleRate)
    }
    #else
    return 0.0
    #endif
}

/// Releases all ONNX Runtime resources held by the pipeline.
private func wakeword_release(_ handle: UnsafeMutableRawPointer) {
    #if canImport(onnxruntime)
    wakeword_release_c(handle)
    #endif
}

// These declarations match the C symbols exported from WakeWordDetector.cpp.
// The actual implementations live in the C++ file linked via the bridging header.

#if canImport(onnxruntime)
@_silgen_name("wakeword_init")
private func wakeword_init_c(
    _ mel: UnsafePointer<CChar>,
    _ embed: UnsafePointer<CChar>,
    _ cls: UnsafePointer<CChar>,
    _ threshold: Float
) -> UnsafeMutableRawPointer?

@_silgen_name("wakeword_detect")
private func wakeword_detect_c(
    _ handle: UnsafeMutableRawPointer,
    _ samples: UnsafePointer<Float>?,
    _ count: Int32,
    _ sampleRate: Int32
) -> Float

@_silgen_name("wakeword_release")
private func wakeword_release_c(_ handle: UnsafeMutableRawPointer)
#endif
