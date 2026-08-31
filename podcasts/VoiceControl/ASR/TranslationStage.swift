import Foundation

/// Converts a native-language transcript to English when the source language is not
/// English and the ASR backend did not already translate.
///
/// The sole implementation is Google ML Kit (`MLKitTranslate`, on-device translation).
protocol TranslationStage {
    /// Download (if needed) the model for a source language and initialize.
    func ensureReady(sourceLanguage: String) async -> Result<Void, Error>

    /// Translate UTF-8 text from `sourceLanguage` to English.
    func translate(text: String, sourceLanguage: String) async -> String
}
