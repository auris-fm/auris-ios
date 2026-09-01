import Foundation

class AsrBackendSelector {

    /// Gates the SenseVoice/Canary locale matrix. Per the agreed safety posture, the
    /// primary backends stay off until their ASR is validated on-device; while this is
    /// false (default) every locale routes to the Whisper fallback. Flip it on once the
    /// on-device ASR pass for SenseVoice + Canary is confirmed.
    var useSenseVoiceCanary = false

    /// Selects the ASR backend by the device's OS locale, per the spec's matrix:
    /// zh/ja/ko/yue + en -> SenseVoice (native text, translated downstream);
    /// de/es/fr -> Canary Flash (native translate to English);
    /// otherwise -> Whisper fallback (translate to English).
    /// When [useSenseVoiceCanary] is false, always returns WhisperCppBackend.
    func select(locale: Locale) -> AsrBackend {
        guard useSenseVoiceCanary else {
            return WhisperCppBackend(modelPath: whisperModelPath)
        }

        let lang = locale.language.languageCode?.identifier ?? "en"
        let modelsRoot = modelsRootURL.path
        switch lang {
        case "zh", "ja", "ko", "yue":
            return SenseVoiceBackend(modelDir: (modelsRoot as NSString).appendingPathComponent("sensevoice-model"))
        case "de", "es", "fr":
            return CanaryFlashBackend(
                modelDir: (modelsRoot as NSString).appendingPathComponent("canary-flash-model"),
                srcLang: lang
            )
        case "en":
            return SenseVoiceBackend(modelDir: (modelsRoot as NSString).appendingPathComponent("sensevoice-model"))
        default:
            return WhisperCppBackend(modelPath: whisperModelPath)
        }
    }

    // MARK: - Paths

    private var modelsRootURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Auris/Models", isDirectory: true)
    }

    private var whisperModelPath: String {
        (modelsRootURL.path as NSString).appendingPathComponent("whisper-model/ggml-small-q5_1.bin")
    }
}
