import FirebaseCore
import FirebaseRemoteConfig
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

    /// Fetch + activate the policy scalar on the NAMED app's RemoteConfig — the same
    /// instance the value/freshness reads use (reviewer 9440ce71: value, fetch,
    /// activation, status and time bind to one authority). Never touches the default
    /// app's RemoteConfig. Completion fires exactly once with activate-outcome.
    static func refreshPolicy(expiration: TimeInterval = 3600,
                              completion: ((Bool) -> Void)? = nil) {
        guard let named = existing() else {
            FileLog.shared.addMessage("[VoiceSharing] policy refresh skipped: secondary app absent")
            lastPolicyRefreshOutcome = false
            completion?(false)
            return
        }
        let config = RemoteConfig.remoteConfig(app: named)
        config.fetch(withExpirationDuration: expiration) { status, error in
            if let error {
                FileLog.shared.addMessage("[VoiceSharing] policy fetch failed: \(error.localizedDescription)")
                lastPolicyRefreshOutcome = false
                completion?(false)
                return
            }
            config.activate { activated, error in
                if let error {
                    FileLog.shared.addMessage("[VoiceSharing] policy activate failed: \(error.localizedDescription)")
                }
                lastPolicyRefreshOutcome = activated
                completion?(activated)
            }
        }
    }

    /// Observable outcome of the last completed named fetch→activate (test seam).
    static var lastPolicyRefreshOutcome: Bool?

    /// PRODUCTION ENTRY (reviewer 45479ac1): connects the coordinator's identity-
    /// recovery refresh to the NAMED fetch→activate→value path. The default-app
    /// refresh remains the caller's separate concern. Called from the assembly
    /// where Firebase is configured; the recorded outcome makes the connection
    /// observable end to end.
    static func connectIdentityRecoveryRefresh(coordinator: VoiceSharingCoordinator = .shared) {
        coordinator.initiateIdentityRecoveryRefresh = {
            refreshPolicy(expiration: 0) { activated in
                if !activated {
                    FileLog.shared.addMessage("[VoiceSharing] policy refresh did not install a snapshot")
                }
            }
        }
    }
}
