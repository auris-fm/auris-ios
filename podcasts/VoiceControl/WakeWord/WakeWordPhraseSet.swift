import Foundation

/// The configured wake word, as data.
///
/// The exclusion rule — a transcript that is the wake phrase and nothing else is
/// not a question — has to read the **same** source the detector uses. A phrase set
/// that drifts from the detector's is worse than a hardcoded one: it would
/// recognise a wake and then treat that same wake as a question, spending the
/// window's only dispatch on `hey aris`.
///
/// This is the **conservative** half of the rule. Phonetic renderings ASR invents
/// (`Oace.`, `aris`) are deliberately not enumerated here — no spelling tolerance
/// separates them from short real words — and are handled instead by the trimmer's
/// timing test, which asks when the wake fired rather than how it was spelled.
///
/// Until now the wake word was only implicit in the trained classifier
/// (`WakeWordDetector`: "Auris" ONNX model), so this constant is the first place it
/// is nameable as data. If the detector ever learns its word from the deployment
/// manifest, load it here rather than adding a second list.
enum WakeWordPhraseSet {
    /// The configured wake word(s).
    static let configured: [String] = ["auris"]

    /// Words people put in front of a wake phrase.
    static let toleratedLeadingWords: [String] = ["hey", "hi", "ok", "okay"]

    /// Every spelling that counts as the wake phrase and nothing else.
    ///
    /// Compared as complete normalised variants rather than by prefix: `ok` is a
    /// prefix of `okay`, so a `starts-with` match removes the wrong number of
    /// characters and fails the very case it exists for.
    static let wakeOnlyVariants: Set<String> = {
        var variants = Set<String>()
        for phrase in configured {
            let normalized = normalize(phrase)
            variants.insert(normalized)
            for leading in toleratedLeadingWords {
                variants.insert(normalize(leading) + normalized)
            }
        }
        return variants
    }()

    /// True when the transcript is the wake phrase and nothing else.
    ///
    /// Equality after normalisation, deliberately **not** `starts-with`: a wake
    /// phrase followed by a real question must still route and escalate.
    static func isWakeOnly(_ transcript: String) -> Bool {
        wakeOnlyVariants.contains(normalize(transcript))
    }

    /// Lowercased, with punctuation and whitespace removed — the renderings that
    /// carry no meaning for this decision.
    static func normalize(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
