import FirebaseCore
import Foundation
import PocketCastsUtils

/// The named secondary Firebase app for Voice Sharing (2026-11-03 activation slice).
///
/// The DEFAULT Firebase app and all its existing consumers are untouched: this app
/// exists only so the Voice Sharing policy reads its own remote scalar
/// (`voice_sharing_enabled`) from the dedicated `auris-fm` project registration.
/// A missing or invalid bundled config degrades to nil — honest unavailability,
/// never a launch crash (mirrors the AppDelegate stub-guard discipline).
enum VoiceSharingFirebaseApp {
    /// The secondary app's registered name.
    static let appName = "voiceSharing"

    /// The bundled client-config resource name (no extension).
    private static let configResourceName = "VoiceSharingFirebase"

    /// The currently configured secondary app, if any.
    static func existing() -> FirebaseApp? {
        FirebaseApp.app(name: appName)
    }

    /// Configures the secondary app from the bundled plist. Idempotent: returns the
    /// existing named app on repeat calls. Returns nil when the plist is absent or
    /// unparseable; the default app is never modified.
    @discardableResult
    static func configure(plistPath: String? = nil) -> FirebaseApp? {
        if let existing = existing() { return existing }
        let path = plistPath ?? Bundle.main.path(forResource: configResourceName, ofType: "plist")
        guard let path,
              let options = FirebaseOptions(contentsOfFile: path) else {
            FileLog.shared.addMessage("[VoiceSharing] secondary Firebase config missing or invalid; Voice Sharing stays on the default-app read")
            return nil
        }
        FirebaseApp.configure(name: appName, options: options)
        FileLog.shared.addMessage("[VoiceSharing] secondary Firebase app configured")
        return existing() ?? FirebaseApp.app(name: appName)
    }
}
