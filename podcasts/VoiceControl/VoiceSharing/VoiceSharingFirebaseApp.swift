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

    /// Injectable fetch actor for controls: when set, replaces the named config's
    /// real network fetch (deterministic identity-pending/failed-fetch coverage).
    static var policyFetchActor: ((TimeInterval,
                                  @escaping (RemoteConfigFetchStatus, Error?) -> Void) -> Void)?

    /// Injectable activate actor for controls (paired with `policyFetchActor`).
    static var policyActivateActor: ((@escaping (Bool, Error?) -> Void) -> Void)?

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

    /// PRODUCTION ENTRY (reviewer 45479ac1 / 3154e29f): a COMPLETE coordinator-owned
    /// named-policy exchange — capture the policy fetch token BEFORE the fetch, run
    /// named fetch→activate, then settle through that same coordinator's activation
    /// path (enrollment recheck, lease install/refusal, gate-loss purge). The default
    /// app's refresh is the caller's separate concern. Identity change while pending
    /// is rejected by the lookup's token/generation guards inside the settlement.
    static func performPolicyExchange(coordinator: VoiceSharingCoordinator = .shared,
                                      expiration: TimeInterval = 0,
                                      accountClient: VoiceSharingAccountClient? = nil,
                                      completion: ((Bool) -> Void)? = nil) {
        // Settlement evidence captured BEFORE any network work.
        let lookup = coordinator.beginEnrollmentLookup()
        let policyToken = coordinator.policyTokenForFetchStart()
        let fetchStartedAt = coordinator.nowForFreshnessCheck()
        let sdkTimeBeforeFetch = coordinator.lastFetchTime()
        guard let named = existing() else {
            FileLog.shared.addMessage("[VoiceSharing] policy exchange skipped: secondary app absent")
            lastPolicyRefreshOutcome = false
            coordinator.policyRefreshAfterActivation(freshActivationSucceeded: false,
                                                     fetchToken: policyToken)
            completion?(false)
            return
        }
        let config = RemoteConfig.remoteConfig(app: named)
        let fetch: (TimeInterval, @escaping (RemoteConfigFetchStatus, Error?) -> Void) -> Void =
            policyFetchActor ?? { exp, handler in
                config.fetch(withExpirationDuration: exp, completionHandler: handler)
            }
        fetch(expiration) { status, error in
            guard status == .success, error == nil else {
                FileLog.shared.addMessage("[VoiceSharing] policy fetch failed: \(error?.localizedDescription ?? "status \(status.rawValue)")")
                lastPolicyRefreshOutcome = false
                coordinator.policyRefreshAfterActivation(freshActivationSucceeded: false,
                                                         fetchToken: policyToken)
                completion?(false)
                return
            }
            let activate: (@escaping (Bool, Error?) -> Void) -> Void =
                policyActivateActor ?? { handler in config.activate { activated, error in handler(activated, error) } }
            activate { _, activationError in
                // The only path that may install: a fresh fetch AND an activate without
                // error, with the SDK's own freshness bookkeeping having advanced.
                let didActivate = activationError == nil
                let provedFreshExchange = coordinator.lastFetchAdvancedPast(
                    fetchStartedAt, previousSDKTime: sdkTimeBeforeFetch)
                let fresh = didActivate && provedFreshExchange
                Task {
                    await coordinator.completeActivationWithEnrollment(
                        freshActivationSucceeded: fresh, lookup: lookup, accountClient: accountClient)
                    lastPolicyRefreshOutcome = fresh
                    completion?(fresh)
                }
            }
        }
    }

    /// PRODUCTION ENTRY: connects the coordinator's identity-recovery refresh to the
    /// COMPLETE named exchange above (fetch-token capture → named fetch/activate →
    /// coordinator settlement). Also arms the normal lease-renewal path: after a
    /// lease-expiry revocation the same exchange is initiated. The default-app
    /// refresh remains the caller's separate concern.
    static func connectIdentityRecoveryRefresh(coordinator: VoiceSharingCoordinator = .shared) {
        coordinator.initiateIdentityRecoveryRefresh = {
            performPolicyExchange(coordinator: coordinator) { activated in
                if !activated {
                    FileLog.shared.addMessage("[VoiceSharing] policy refresh did not install a snapshot")
                }
            }
        }
        coordinator.leaseRenewalAfterExpiry = { [weak coordinator] in
            guard let coordinator else { return }
            performPolicyExchange(coordinator: coordinator)
        }
    }
}
