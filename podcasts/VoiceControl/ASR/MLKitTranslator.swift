import Foundation
import PocketCastsUtils
#if canImport(MLKitTranslate)
import MLKitTranslate
#endif

/// Google ML Kit on-device translation (source language -> English).
///
/// ML Kit downloads a per-language model on first use; `ensureReady` triggers that
/// download for a given source language. Translation is bridged over ML Kit's
/// callback API to a suspend function.
///
/// Language codes follow ML Kit's ISO-639-1 set. Cantonese (`yue`) is not a distinct
/// ML Kit language, so it routes through Mandarin Chinese (`zh`) as a pragmatic
/// fallback (same script, closest supported model).
///
/// When `MLKitTranslate` is not linked (e.g. the pod has not been configured in the
/// project), the translator fails closed: translation returns the input unchanged and
/// `ensureReady` reports a failure, so the pipeline degrades to the native transcript
/// rather than crashing.
final class MLKitTranslator: TranslationStage {

    #if canImport(MLKitTranslate)
    private var translators: [String: Translator] = [:]
    #endif

    func ensureReady(sourceLanguage: String) async -> Result<Void, Error> {
        #if canImport(MLKitTranslate)
        guard let mlKitLang = mapLanguage(sourceLanguage) else {
            return .failure(TranslationError.unsupportedSource(sourceLanguage))
        }
        let translator = translatorFor(mlKitLang)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                translator.downloadModelIfNeeded { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
            FileLog.shared.addMessage("[MLKitTranslate] model ready for \(sourceLanguage)")
            return .success(())
        } catch {
            FileLog.shared.addMessage("[MLKitTranslate] model download failed for \(sourceLanguage): \(error)")
            return .failure(error)
        }
        #else
        return .failure(TranslationError.mlKitNotLinked)
        #endif
    }

    func translate(text: String, sourceLanguage: String) async -> String {
        #if canImport(MLKitTranslate)
        guard let mlKitLang = mapLanguage(sourceLanguage) else {
            return text
        }
        let translator = translatorFor(mlKitLang)
        do {
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                translator.translate(text) { translated, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: translated)
                    }
                }
            }
        } catch {
            FileLog.shared.addMessage("[MLKitTranslate] translation failed for \(sourceLanguage): \(error)")
            return text
        }
        #else
        return text
        #endif
    }

    #if canImport(MLKitTranslate)
    private func translatorFor(_ mlKitLang: String) -> Translator {
        if let existing = translators[mlKitLang] {
            return existing
        }
        let options = TranslatorOptions(
            sourceLanguage: TranslateLanguage(rawValue: mlKitLang),
            targetLanguage: TranslateLanguage(rawValue: "en")
        )
        let translator = Translator.translator(options: options)
        translators[mlKitLang] = translator
        return translator
    }

    /// Maps an ISO-639-1 language code to the ML Kit translate language constant.
    /// Returns nil if there is no ML Kit equivalent.
    private func mapLanguage(_ language: String) -> String? {
        switch language.lowercased() {
        case "zh", "yue": return "zh" // Cantonese -> Mandarin Chinese (closest supported model)
        case "ja": return "ja"
        case "ko": return "ko"
        case "de": return "de"
        case "es": return "es"
        case "fr": return "fr"
        case "it": return "it"
        case "pt": return "pt"
        case "ru": return "ru"
        case "ar": return "ar"
        case "nl": return "nl"
        case "sv": return "sv"
        default: return nil
        }
    }
    #endif

    enum TranslationError: Error, LocalizedError {
        case unsupportedSource(String)
        case mlKitNotLinked

        var errorDescription: String? {
            switch self {
            case .unsupportedSource(let lang):
                return "Unsupported ML Kit source language: \(lang)"
            case .mlKitNotLinked:
                return "MLKitTranslate is not linked (canImport(MLKitTranslate) is false)"
            }
        }
    }
}
