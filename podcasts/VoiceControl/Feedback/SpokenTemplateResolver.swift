import Foundation

/// Resolves spoken response templates from VoiceTemplates.strings.
///
/// Each template key maps to a format string with `%@` placeholders.
/// Call `resolve(_:_:)` with the key and positional arguments to produce
/// a localized spoken string.
class SpokenTemplateResolver {
    private let tableName = "VoiceTemplates"
    private let mainBundle: Bundle
    /// The bundle holding the **user's own** locale, or nil when the app has no
    /// resources for it.
    private let localeBundle: Bundle?

    /// - Parameter localeBundle: injectable for tests; defaults to the bundle for
    ///   the current language, discovered explicitly so a missing translation can
    ///   be *detected* rather than silently falling back to the base language.
    init(mainBundle: Bundle = .main, localeBundle: Bundle? = nil) {
        self.mainBundle = mainBundle
        if let localeBundle {
            self.localeBundle = localeBundle
        } else {
            let code = Locale.current.language.languageCode?.identifier
            let path = code.flatMap { mainBundle.path(forResource: $0, ofType: "lproj") }
            self.localeBundle = path.flatMap { Bundle(path: $0) }
        }
    }

    /// Resolves a template **only when the user's own locale has a translation**.
    ///
    /// Returns "" when that locale has no entry — including when the base
    /// language does — because the channel here is speech and has no affordance
    /// for a language the user doesn't read: an English sentence spoken to a
    /// Korean user conveys nothing while occupying the channel that should be
    /// signalling failure. Callers fall back to the error earcon, which reads as
    /// "that didn't work" in every language (spec ruling, 2026-09-24).
    ///
    /// Revisit when translations are added: the moment a user's locale carries
    /// the key, this returns it and the earcon stops being used.
    func resolveForUserLocale(_ key: String) -> String {
        guard let localeBundle else { return "" }
        let sentinel = "\u{0}missing"
        let format = localeBundle.localizedString(forKey: key, value: sentinel, table: tableName)
        guard format != sentinel, format != key, !format.isEmpty else { return "" }
        return format
    }

    /// Resolve a template key with the given format arguments.
    /// - Parameters:
    ///   - key: The template key (e.g. "effects.set_speed")
    ///   - args: Positional format arguments interpolated into the template
    /// - Returns: The resolved string, or "" if the key is not found
    func resolve(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, tableName: tableName, bundle: .main, value: "", comment: "")
        guard !format.isEmpty, format != key else { return "" }
        return String(format: format, arguments: args)
    }

    /// Convenience: resolve a template without arguments.
    func resolve(_ key: String) -> String {
        let format = NSLocalizedString(key, tableName: tableName, bundle: .main, value: "", comment: "")
        guard !format.isEmpty, format != key else { return "" }
        return format
    }
}
