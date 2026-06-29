import Foundation

class WhisperCppBackend: AsrBackend {
    private let modelPath: String
    private var whisperContext: UnsafeMutableRawPointer?

    let capabilities = AsrCapabilities(
        languages: [],
        canTranslateToEnglish: true,
        requiresHardwareAccel: false
    )

    var requiredModel: ModelSpec {
        ModelSpec(
            id: "whisper",
            files: [
                ModelFile(
                    url: URL(string: "https://download.auris.fm/whisper/ggml-small-q5_1.bin")!,
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
        guard let cPath = modelPath.cString(using: .utf8) else {
            return .failure(BackendError.invalidModelPath)
        }
        let ctx = whisper_init_from_file(cPath)
        guard ctx != nil else {
            return .failure(BackendError.modelLoadFailed)
        }
        // Configure for low-latency ASR: reduced audio_ctx, greedy sampling, suppress non-speech tokens
        whisper_set_max_threads(ctx, 4)
        self.whisperContext = ctx
        return .success(())
        #else
        // whisper.cpp not linked — stub returns success but transcribe will be no-op
        return .success(())
        #endif
    }

    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        #if canImport(whisper)
        guard let ctx = whisperContext else {
            return AsrResult(text: "", detectedLanguage: nil)
        }
        return samples.withUnsafeBufferPointer { ptr in
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_progress = false
            params.print_realtime = false
            params.translate = true
            params.language = nil // auto-detect
            params.suppress_non_speech_tokens = true
            params.audio_ctx = 384
            params.single_segment = true

            let result = whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
            guard result == 0 else {
                return AsrResult(text: "", detectedLanguage: nil)
            }

            let nSegments = whisper_full_n_segments(ctx)
            var text = ""
            for i in 0..<nSegments {
                if let cStr = whisper_full_get_segment_text(ctx, i) {
                    text += String(cString: cStr)
                }
            }

            // Reject annotation-only output
            if isAnnotationOnly(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return AsrResult(text: "", detectedLanguage: nil)
            }

            return AsrResult(text: text, detectedLanguage: nil)
        }
        #else
        // Stub — whisper.cpp not linked
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

    enum BackendError: Error {
        case invalidModelPath
        case modelLoadFailed
    }
}

private func isAnnotationOnly(_ text: String) -> Bool {
    let annotations = ["[Music]", "[Applause]", "[Laughter]", "[typing]", "[Silence]", "[BLANK_AUDIO]", "[Noise]"]
    return annotations.contains(text) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
