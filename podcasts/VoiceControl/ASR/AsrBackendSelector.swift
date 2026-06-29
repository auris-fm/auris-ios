import Foundation

class AsrBackendSelector {
    func select(locale: Locale, hasNPU: Bool, senseVoiceShipped: Bool) -> AsrBackend {
        if hasNPU && senseVoiceShipped {
            // Wire to WhisperNpuBackend when CoreML NPU backend is available
            return WhisperCppBackend(modelPath: defaultModelPath)
        }
        if senseVoiceShipped && ["zh", "en", "ja", "ko", "yue"].contains(locale.languageCode) {
            // Wire to SenseVoiceBackend when ONNX model is available
            return WhisperCppBackend(modelPath: defaultModelPath)
        }
        return WhisperCppBackend(modelPath: defaultModelPath)
    }

    private var defaultModelPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Auris/Models/whisper-model/ggml-small-q5_1.bin").path
    }
}
