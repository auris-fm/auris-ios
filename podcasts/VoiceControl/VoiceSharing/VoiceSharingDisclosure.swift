import Foundation

/// Activation-slice disclosure facts (2026-11-03, @spec dispatch `d42369ac`).
///
/// The version is the exact server-supported disclosure token; the body is the
/// user-facing copy surfaced by the enroll confirmation dialog. The copy states
/// WHAT is shared, the PURPOSE, the one-year retention, withdrawal, and separate
/// deletion — plainly, with no storage-infrastructure or limit-machinery names.
enum VoiceSharingDisclosure {
    /// Exact server-supported disclosure token (`accepted_disclosure_version`).
    static let version = "voice-sharing-v1"

    /// The production wiring's disclosure version (kept as a named indirection so
    /// the assembly site reads as a decision, not a literal).
    static let productionVersion: String? = version

    /// English disclosure body (single source for the settings dialog and the
    /// copy controls). Format slot: the plain-language retention duration. Reads
    /// the localized table when the key exists; otherwise the fallback literal
    /// keeps the copy truthful even before localization ships.
    static let englishBody: String? = {
        let fallback = "With your permission, auris shares voice recordings, your spoken text and the actions you take with our team so we can improve speech recognition. Background speech captured during a voice conversation may be included. Recordings are kept for one year and then deleted. You can withdraw at any time in Settings, and you can delete your recordings separately at any time."
        let key = "voice_sharing_disclosure_body"
        let localized = NSLocalizedString(key, comment: "Voice Sharing disclosure")
        return localized == key || localized.isEmpty ? fallback : localized
    }()
}
