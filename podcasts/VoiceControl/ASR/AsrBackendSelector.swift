import Foundation

class AsrBackendSelector {

    /// Selects the ASR backend by the device's OS locale, per the spec's matrix
    /// (matches Android's `AsrBackendSelector` — no enable gate; the matrix is always live):
    /// zh/ja/ko/yue + en -> SenseVoice (native text, translated downstream);
    /// de/es/fr -> Canary Flash (native translate to English);
    /// otherwise -> nil (unsupported locale; Whisper remains in-tree but unselected).
    ///
    /// On-device validation of SenseVoice/Canary happens on this branch before it is merged
    /// (per @merlinran); there is no separate activation flag because the branch is held
    /// unmerged until that pass is done.
    func select(locale: Locale) -> AsrBackend? {
        guard let lang = locale.language.languageCode?.identifier else {
            return nil
        }
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
            return nil
        }
    }

    // MARK: - Paths

    private var modelsRootURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Auris/Models", isDirectory: true)
    }
}
