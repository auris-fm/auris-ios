import Foundation

/// Resolves spoken response templates from VoiceTemplates.strings.
///
/// Each template key maps to a format string with `%@` placeholders.
/// Call `resolve(_:_:)` with the key and positional arguments to produce
/// a localized spoken string.
class SpokenTemplateResolver {
    private let tableName = "VoiceTemplates"

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
