import Foundation
import PocketCastsUtils
#if canImport(Translation)
import Translation
#endif

/// Apple's on-device Translation framework for source language -> English.
///
/// `Locale.Language`/`LanguageAvailability` are available from iOS 17.4, the
/// `TranslationSession` API from iOS 18, and the `TranslationSession(installedSource:target:)`
/// convenience initializer from **iOS 26**. On iOS 17.4–25.x a `TranslationSession` is normally
/// provided by a SwiftUI `translationTask` host, which is not yet wired here. Until a session
/// can be obtained, the translator fails closed: `ensureReady` reports a failure and `translate`
/// returns the input unchanged, so the pipeline degrades to the native transcript (per the
/// spec's missing-model fallback contract) rather than crashing.
final class AppleTranslationTranslator: TranslationStage {

    func ensureReady(sourceLanguage: String) async -> Result<Void, Error> {
        #if canImport(Translation)
        guard #available(iOS 26, *) else {
            return .failure(TranslationError.sessionUnavailable)
        }
        guard let source = makeLanguage(sourceLanguage) else {
            return .failure(TranslationError.unsupportedSource(sourceLanguage))
        }
        do {
            let availability = LanguageAvailability()
            let status = await availability.status(from: source, to: Locale.Language(identifier: "en"))
            guard status == .installed else {
                return .failure(TranslationError.unavailable(sourceLanguage))
            }
            let session = TranslationSession(
                installedSource: source,
                target: Locale.Language(identifier: "en")
            )
            try await session.prepareTranslation()
            FileLog.shared.addMessage("[AppleTranslation] model ready for \(sourceLanguage)")
            return .success(())
        } catch {
            FileLog.shared.addMessage("[AppleTranslation] model prepare failed for \(sourceLanguage): \(error)")
            return .failure(error)
        }
        #else
        return .failure(TranslationError.translationUnavailable)
        #endif
    }

    func translate(text: String, sourceLanguage: String) async -> String {
        #if canImport(Translation)
        guard #available(iOS 26, *) else {
            return text
        }
        guard let source = makeLanguage(sourceLanguage) else {
            return text
        }
        do {
            let session = TranslationSession(
                installedSource: source,
                target: Locale.Language(identifier: "en")
            )
            let response = try await session.translate(text)
            let translated = response.targetText
            return translated.isEmpty ? text : translated
        } catch {
            FileLog.shared.addMessage("[AppleTranslation] translation failed for \(sourceLanguage): \(error)")
            return text
        }
        #else
        return text
        #endif
    }

    #if canImport(Translation)
    /// Maps an ISO-639-1 language code to a `Locale.Language`. Cantonese (`yue`) is not a
    /// distinct Apple Translation language, so it routes through Mandarin Chinese (`zh`).
    /// Also accepts SenseVoice tags (`<|zh|>`) if a caller skipped normalize.
    private func makeLanguage(_ language: String) -> Locale.Language? {
        var code = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if code.hasPrefix("<|"), code.hasSuffix("|>"), code.count > 4 {
            let inner = String(code.dropFirst(2).dropLast(2))
            code = inner.split(separator: "/").first.map(String.init) ?? code
        }
        if code == "yue" { code = "zh" }
        guard code.range(of: #"^[a-z]{2,8}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Locale.Language(identifier: code)
    }
    #endif

    enum TranslationError: Error, LocalizedError {
        case unsupportedSource(String)
        case unavailable(String)
        case sessionUnavailable
        case translationUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedSource(let lang):
                return "Unsupported translation source language: \(lang)"
            case .unavailable(let lang):
                return "Translation model unavailable for: \(lang)"
            case .sessionUnavailable:
                return "Translation not available on this OS — requires a SwiftUI translationTask host or iOS 26+"
            case .translationUnavailable:
                return "Apple Translation framework is not available (pre-iOS 17.4 or not linked)"
            }
        }
    }
}
