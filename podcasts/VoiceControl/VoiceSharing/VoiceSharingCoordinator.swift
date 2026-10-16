import Foundation
import Firebase
import PocketCastsServer

/// Composition point for the Voice Sharing feature on iOS.
///
/// Owns the policy snapshot and exposes the single decision every other component
/// asks: may collection run right now? Keeping construction here (rather than a
/// singleton maze) means tests can build a coordinator with stubbed providers,
/// exactly like the rest of the voice pipeline injects clocks and sources.
final class VoiceSharingCoordinator {
    static let shared = VoiceSharingCoordinator()

    let policy: VoiceSharingPolicy
    private var identityObserver: NSObjectProtocol?

    /// `isAccountEnrolled` must be re-readable at decision time, not sampled once: the policy
    /// consults it on every `permitsCollection`, so withdrawal or an account switch flips the
    /// answer without waiting for a lease to lapse. Production fails closed until the enrollment
    /// API lands in the cloud lane.
    init(
        clock: MonotonicClock = SystemMonotonicClock(),
        readRemoteSwitch: (() -> VoiceSharingPolicy.RemoteSwitchValue)? = nil,
        isAccountEnrolled: (() -> Bool)? = nil
    ) {
        self.policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: readRemoteSwitch ?? Self.readActivatedSwitch,
            isAccountEnrolled: isAccountEnrolled ?? { false }
        )
    }

    /// Called from the fetch→activate completion path with the caller's evidence about that
    /// specific callback pair. A cached or no-network outcome passes `false` and therefore
    /// cannot renew the lease.
    func policyRefreshAfterActivation(freshActivationSucceeded: Bool) {
        policy.refreshAfterActivation(freshActivationSucceeded: freshActivationSucceeded)
    }

    /// Subscribes to sign-out/identity change so permission drops synchronously instead of
    /// surviving inside a still-valid snapshot. Returns the invalidation closure as well, so a
    /// composition site that already observes this notification can call it directly rather
    /// than registering a duplicate observer.
    @discardableResult
    func installIdentityInvalidation(onNotificationCenter center: NotificationCenter = .default) -> () -> Void {
        let invalidate: () -> Void = { [weak self] in
            guard let self else { return }
            self.policy.invalidateForIdentityChange()
        }
        identityObserver = center.addObserver(
            forName: .serverUserWillBeSignedOut,
            object: nil,
            queue: .main
        ) { _ in invalidate() }
        return invalidate
    }

    /// Called by the identity provider once the new account state is readable; lifts the fence
    /// so a refresh against the CURRENT identity can install again.
    func identityBecameReadable() {
        policy.identityBecameReadable()
    }

    deinit {
        if let identityObserver { NotificationCenter.default.removeObserver(identityObserver) }
    }

    private static func readActivatedSwitch() -> VoiceSharingPolicy.RemoteSwitchValue {
        guard FirebaseApp.app() != nil else { return .unavailable }
        let config = RemoteConfig.remoteConfig()
        // The VALUE SOURCE is the gate: only `.remote` (a genuinely published server value)
        // counts. `.default` is OUR compiled fallback and `.static` means the key does not
        // exist — neither may satisfy the policy. That is the fail-closed asymmetry the spec
        // requires. (`RemoteConfigValue` has no `status` property; `source` is the only
        // existence signal it offers.)
        let value = config.configValue(forKey: Constants.RemoteParams.voiceSharingEnabled)
        guard value.source == .remote else { return .unavailable }
        // The decision is made by the production decoder, which refuses anything that is not a
        // genuine boolean literal: `intValue` would coerce 1.5 → 1 and enable, and `boolValue`
        // would accept "yes".
        return VoiceSharingPolicy.decodeRemoteSwitch(value.numberValue)
    }
}
