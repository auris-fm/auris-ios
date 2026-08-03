import Foundation

/// Removes at most one supported leading wake phrase from a transcript per
/// recognition-pipeline.md "Leading wake-phrase removal": "Hey Auris",
/// "Hi Auris", "Auris", matched longest first. Matching is case-insensitive
/// after Unicode normalization; leading/trailing punctuation and whitespace are
/// ignored; token boundaries are mandatory; unsupported prefixes and later
/// occurrences are never removed.
enum WakePhraseNormalizer {
    static let supportedPhrases = ["Hey Auris", "Hi Auris", "Auris"]

    static func normalize(_ transcript: String) -> String {
        let folded = transcript.precomposedStringWithCanonicalMapping
        let tokens = folded.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }

        for phrase in supportedPhrases {
            let phraseTokens = phrase.split(separator: " ")
            guard tokens.count >= phraseTokens.count else { continue }
            let leading = tokens.prefix(phraseTokens.count)
            let matches = zip(leading, phraseTokens).allSatisfy { lhs, rhs in
                lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    == rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            }
            if matches {
                return tokens.dropFirst(phraseTokens.count).joined(separator: " ")
            }
        }

        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
