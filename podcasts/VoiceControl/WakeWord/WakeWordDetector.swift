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
    /// Returns the maximum confidence score across all windows.
    func detect(samples: [Float], sampleRate: Int) -> Float {
        guard let handle = nativeHandle, !samples.isEmpty else { return 0.0 }
        var scores: [Float] = []
        let windowSize = sampleRate * 2   // 2 seconds
        let stride = sampleRate / 2       // 0.5 second stride
        var offset = 0
        while offset + windowSize <= samples.count {
            let window = Array(samples[offset..<offset + windowSize])
            let score = wakeword_detect(handle, window, Int32(sampleRate))
            scores.append(score)
            offset += stride
        }
        return scores.max() ?? 0.0
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
