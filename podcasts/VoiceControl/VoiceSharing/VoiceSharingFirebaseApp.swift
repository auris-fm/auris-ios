import FirebaseCore
import FirebaseRemoteConfig
import Foundation
import PocketCastsServer
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

    /// Injectable provenance actor for controls (paired with `policyActivateActor`):
    /// when set, replaces the active-config value-source read. Nil (production)
    /// reads the named config live - INSIDE the activation completion (reviewer
    /// 30630d31: activation is the step that applies fetched data to the active
    /// config, so a first fetch's value reads `.default` until activate runs).
    static var policyValueProvenanceActor: (() -> Bool)?

    /// Fetch + activate the policy scalar on the NAMED app's RemoteConfig — the same
    /// instance the value/freshness reads use (reviewer 9440ce71: value, fetch,
    /// activation, status and time bind to one authority). Never touches the default
    /// app's RemoteConfig. Completion fires exactly once with activate-outcome.
    static func refreshPolicy(expiration: TimeInterval = 3600,
                              completion: ((Bool, Int) -> Void)? = nil) {
        guard let named = existing() else {
            FileLog.shared.addMessage("[VoiceSharing] policy refresh skipped: secondary app absent")
            lastPolicyRefreshOutcome = false
            completion?(false, 0)
            return
        }
        let config = RemoteConfig.remoteConfig(app: named)
        config.fetch(withExpirationDuration: expiration) { status, error in
            if let error {
                FileLog.shared.addMessage("[VoiceSharing] policy fetch failed: \(error.localizedDescription)")
                lastPolicyRefreshOutcome = false
                completion?(false, 0)
                return
            }
            config.activate { activated, error in
                if let error {
                    FileLog.shared.addMessage("[VoiceSharing] policy activate failed: \(error.localizedDescription)")
                }
                lastPolicyRefreshOutcome = activated
                completion?(activated, 0)
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
                                      pretakenLookup: VoiceSharingCoordinator.EnrollmentLookup? = nil,
                                      completion: ((Bool, Int) -> Void)? = nil) {
        // A new exchange supersedes any pending transient retry (a newer real refresh drives
        // its own outcome), and the outcome classification starts clean for THIS exchange.
        coordinator.cancelTransientPolicyRetryForTesting()
        // Settlement evidence captured BEFORE any network work (see the lifecycle note below).
        guard let named = existing() else {
            FileLog.shared.addMessage("[VoiceSharing] policy exchange skipped: secondary app absent")
            lastPolicyRefreshOutcome = false
            coordinator.policyRefreshAfterActivation(freshActivationSucceeded: false,
                                                     fetchToken: coordinator.policyTokenForFetchStart())
            completion?(false, 0)
            return
        }
        // At LAUNCH the account is not yet readable — the app restores its session a moment after
        // the exchange begins — so no lifecycle can exist yet, and a lookup taken now is refused by
        // the settle path's own guard (`lookupIsCurrent` requires a projection token), before any
        // network work. That guard exists so an account transition cannot install the departed
        // account's permission; at launch there is nothing yet to be stale against. So the settle
        // step runs when the lookup itself is validity-checked: no lifecycle → the fetch is deferred
        // to the identity-recovery path, which runs once the account becomes readable. This is the
        // honest reading of the guard, not a bypass of it.
        if VoiceSharingSessionGeneration.shared.currentGeneration() == nil {
            FileLog.shared.addMessage("[VoiceSharing] policy exchange deferred: no account lifecycle yet")
            completion?(false, 0)
            return
        }
        let lookup = pretakenLookup ?? coordinator.beginEnrollmentLookup()
        let exchangeGeneration = lookup.generation
        let policyToken = coordinator.policyTokenForFetchStart()
        let fetchStartedAt = coordinator.nowForFreshnessCheck()
        let sdkTimeBeforeFetch = coordinator.lastFetchTime()
        let config = RemoteConfig.remoteConfig(app: named)
        // DIAGNOSTIC (temporary): the named exchange returned without ever settling, so watch the
        // raw SDK status and the freshness bookkeeping the settle path judges it by.
        FileLog.shared.addMessage("[VoiceSharing] policy exchange starting: expiration=\(Int(expiration))s sdkLastFetch=\(String(describing: sdkTimeBeforeFetch))")
        let fetch: (TimeInterval, @escaping (RemoteConfigFetchStatus, Error?) -> Void) -> Void =
            policyFetchActor ?? { exp, handler in
                config.fetch(withExpirationDuration: exp, completionHandler: handler)
            }
        fetch(expiration) { status, error in
            guard status == .success, error == nil else {
                FileLog.shared.addMessage("[VoiceSharing] policy fetch failed: \(error?.localizedDescription ?? "status \(status.rawValue)")")
                lastPolicyRefreshOutcome = false
                coordinator.recordPolicyFetchThrottleFloor(from: error)
                // OWNERSHIP FENCE (reviewer 632cce79): a LATE fetch failure of an OLD exchange
                // must not clear a policy a newer successor already installed. Only the
                // generation that still owns the gate may run the failure settlement.
                guard coordinator.currentEnrollmentLookupGenerationForTesting == exchangeGeneration else {
                    FileLog.shared.addMessage("[VoiceSharing] stale fetch failure dropped (gen \(exchangeGeneration) superseded); installed policy untouched")
                    completion?(false, exchangeGeneration)
                    return
                }
                coordinator.policyRefreshAfterActivation(freshActivationSucceeded: false,
                                                         fetchToken: policyToken,
                                                         settlementGeneration: exchangeGeneration)
                completion?(false, exchangeGeneration)
                return
            }
            let activate: (@escaping (Bool, Error?) -> Void) -> Void =
                policyActivateActor ?? { handler in config.activate { activated, error in handler(activated, error) } }
            FileLog.shared.addMessage("[VoiceSharing] policy fetch settled: status=\(status.rawValue) error=\(error.map { String(describing: type(of: $0)) } ?? "none")")
            let readProvenance = { () -> Bool in
                Self.policyValueProvenanceActor?()
                    ?? (config.configValue(forKey: Constants.RemoteParams.voiceSharingEnabled).source == .remote)
            }
            activate { sdkActivated, activationError in
                // Read the value's own provenance INSIDE the activation completion: activation
                // is the step that applies fetched data to the active config, so on a FIRST
                // fetch the active value is still the local default until activate runs.
                // Reading it before activation rejected a successful first fetch with the old
                // provenance (reviewer 30630d31). A local, non-remote value remains exactly
                // the stale read the freshness rule rejects - the point is to read AFTER apply.
                let valueIsRemote = readProvenance()
                // The only path that may install: an activate without error, a REMOTE-sourced
                // value, and the SDK's own freshness bookkeeping having advanced past this
                // exchange's start.
                //
                // `sdkActivated == false` with no error is Firebase saying "nothing to APPLY", and
                // with expiration 0 that is the normal result of a fetch served from its cache —
                // the config was already current, so no change is applied and the SDK reports that
                // honestly. Judging install on it therefore turned a successful exchange into
                // "no fresh activation", and the lease never installed: a consented capture was
                // refused by a gate with no user-visible cause. Freshness below is the real proof
                // that a live fetch→activate happened; the value's own `.remote` source is the
                // second guard against a stale local read.
                let didActivate = activationError == nil && valueIsRemote
                let provedFreshExchange = coordinator.lastFetchAdvancedPast(
                    fetchStartedAt, previousSDKTime: sdkTimeBeforeFetch)
                let fresh = didActivate && provedFreshExchange
                FileLog.shared.addMessage("[VoiceSharing] policy exchange settled: sdkActivated=\(sdkActivated) error=\(activationError == nil ? "none" : String(describing: type(of: activationError!))) fetchAdvanced=\(provedFreshExchange) valueRemote=\(valueIsRemote) installing=\(fresh)")
                Task {
                    await coordinator.completeActivationWithEnrollment(
                        freshActivationSucceeded: fresh, lookup: lookup, accountClient: accountClient)
                    lastPolicyRefreshOutcome = fresh
                    completion?(fresh, exchangeGeneration)
                    if fresh { Self.allowanceRefresh?() }
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
        coordinator.initiateIdentityRecoveryRefresh = { [weak coordinator] in
            guard let coordinator else { return }
            performPolicyExchange(coordinator: coordinator) { fresh, generation in
                if !fresh {
                    FileLog.shared.addMessage("[VoiceSharing] policy refresh did not install a snapshot")
                }
                coordinator.policyExchangeCompleted(fresh: fresh, exchangeGeneration: generation)
            }
        }
        // OWNED RETRY ENTRY (spec 2ffd8026): the retry's claimed generation is validated and
        // the exchange's lookup taken in ONE enrollmentLookupLock step — a retry owned by an
        // older exchange cannot start after a newer authoritative answer or supersede a newer
        // in-flight refresh.
        coordinator.initiateOwnedRetryRefresh = { [weak coordinator] claimedGeneration in
            guard let coordinator else { return }
            guard let lookup = coordinator.beginRetryExchangeIfCurrent(claimedGeneration: claimedGeneration) else {
                FileLog.shared.addMessage("[VoiceSharing] retry dropped: claimed generation \(claimedGeneration) no longer owns the gate")
                return
            }
            performPolicyExchange(coordinator: coordinator, pretakenLookup: lookup) { fresh, generation in
                if !fresh {
                    FileLog.shared.addMessage("[VoiceSharing] policy refresh did not install a snapshot")
                }
                coordinator.policyExchangeCompleted(fresh: fresh, exchangeGeneration: generation)
            }
        }
        coordinator.leaseRenewalAfterExpiry = { [weak coordinator] in
            guard let coordinator else { return }
            performPolicyExchange(coordinator: coordinator)
        }
    }

    /// PRODUCTION DRIVER: connects the capture-allowance refresh to every settled policy exchange, so a
    /// renewed lease also settles the allowance. Without this the allowance was only ever fetched at
    /// launch, and a batch the client had proved exhausted could not advance without a relaunch.
    static func connectAllowanceRefresh(_ refresh: @escaping () -> Void) {
        allowanceRefresh = refresh
    }

    /// Called after every exchange that installs a snapshot. Optional: an unset hook (tests, the
    /// secondary app) leaves the provider path exactly as it was.
    private static var allowanceRefresh: (() -> Void)?
}
