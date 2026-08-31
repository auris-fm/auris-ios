import Foundation
import PocketCastsUtils
#if canImport(whisper)
import whisper
#endif

class WhisperCppBackend: AsrBackend {
    private let modelPath: String
    private var whisperContext: OpaquePointer?
    private let transcribeQueue = DispatchQueue(label: "com.auris.whisper", qos: .userInitiated)

    let capabilities = AsrCapabilities(
        languages: ["en", "zh", "ja", "ko", "fr", "de", "es", "it", "pt", "nl", "ru", "ar", "tr", "pl", "sv", "da", "fi", "no", "hu", "cs", "ro", "uk", "el", "th", "vi", "hi", "bn", "ur", "fa", "he", "id", "ms", "ta", "te", "ml", "mr", "kn", "gu", "pa", "si", "ne", "my", "km", "lo", "bo", "ug", "kk", "ky", "tg", "uz", "az", "hy", "ka", "mn", "ja", "ko", "yue", "ca", "eu", "gl", "oc", "br", "cy", "ga", "gd", "gv", "kw"],
        canTranslateToEnglish: true,
        requiresHardwareAccel: false
    )

    var requiredModel: ModelSpec {
        ModelSpec(
            id: "whisper",
            files: [
                ModelFile(
                    url: URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
                    filename: "ggml-small-q5_1.bin",
                    sha256: nil
                ),
            ],
            targetDir: "whisper-model"
        )
    }

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    func ensureReady() async -> Result<Void, Error> {
        #if canImport(whisper)
        // Already loaded
        if whisperContext != nil {
            return .success(())
        }

        // Ensure model file exists — download if needed
        let modelURL = URL(fileURLWithPath: modelPath)
        if !FileManager.default.fileExists(atPath: modelPath) {
            do {
                try await downloadModel(to: modelURL)
            } catch {
                return .failure(error)
            }
        }

        var cparams = whisper_context_default_params()
        #if targetEnvironment(simulator)
        cparams.use_gpu = false  // CoreML encoder crashes on simulator
        #else
        cparams.use_gpu = true
        #endif

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            return .failure(BackendError.modelLoadFailed)
        }

        self.whisperContext = ctx
        return .success(())
        #else
        return .failure(BackendError.whisperNotLinked)
        #endif
    }

    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        #if canImport(whisper)
        // Serialize whisper access — whisper is NOT thread-safe.
        // `async` bridging to serial queue: continuation + dispatch_async.
        return await withCheckedContinuation { continuation in
            transcribeQueue.async { [weak self] in
                guard let self, let ctx = self.whisperContext else {
                    continuation.resume(returning: AsrResult(text: "", detectedLanguage: nil))
                    return
                }
                let result = samples.withUnsafeBufferPointer { ptr -> AsrResult in
                    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                    params.print_progress = false
                    params.print_realtime = false
                    params.print_special = false
                    params.translate = false
                    params.language = nil
                    params.n_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
                    params.suppress_non_speech_tokens = true
                    params.no_timestamps = true
                    params.single_segment = true
                    params.audio_ctx = 0

                    let ret = whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
                    guard ret == 0 else {
                        return AsrResult(text: "", detectedLanguage: nil)
                    }

                    let nSegments = whisper_full_n_segments(ctx)
                    var text = ""
                    for i in 0..<nSegments {
                        if let cStr = whisper_full_get_segment_text(ctx, i) {
                            text += String(cString: cStr)
                        }
                    }

                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isAnnotationOnly(trimmed) {
                        return AsrResult(text: "", detectedLanguage: nil)
                    }

                    return AsrResult(text: trimmed, detectedLanguage: nil)
                }
                continuation.resume(returning: result)
            }
        }
        #else
        return AsrResult(text: "", detectedLanguage: nil)
        #endif
    }

    func release() {
        #if canImport(whisper)
        if let ctx = whisperContext {
            whisper_free(ctx)
            whisperContext = nil
        }
        #endif
    }

    deinit { release() }

    // MARK: - Model download

    private func downloadModel(to url: URL) async throws {
        let modelURL = requiredModel.files[0].url
        let parentDir = url.deletingLastPathComponent()

        // Create directory if needed
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        FileLog.shared.addMessage("[WhisperCpp] Downloading model from \(modelURL)...")
        let (tmpURL, _) = try await URLSession.shared.download(from: modelURL)
        try FileManager.default.moveItem(at: tmpURL, to: url)
        FileLog.shared.addMessage("[WhisperCpp] Model downloaded to \(url.path)")
    }

    enum BackendError: Error, LocalizedError {
        case modelNotFound(String)
        case modelLoadFailed
        case whisperNotLinked

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let path):
                return "Whisper model not found at \(path)"
            case .modelLoadFailed:
                return "Failed to load whisper model"
            case .whisperNotLinked:
                return "whisper.cpp is not linked (canImport(whisper) is false)"
            }
        }
    }
}

private func isAnnotationOnly(_ text: String) -> Bool {
    let annotations = ["[Music]", "[Applause]", "[Laughter]", "[typing]", "[Silence]", "[BLANK_AUDIO]", "[Noise]"]
    return annotations.contains(text) || text.isEmpty
}
