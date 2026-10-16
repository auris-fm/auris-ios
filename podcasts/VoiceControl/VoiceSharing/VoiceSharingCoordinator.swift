import Foundation
import Firebase
import PocketCastsServer
import FirebaseRemoteConfig

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
        isAccountEnrolled: (() -> Bool)? = nil,
        now: @escaping () -> Date = Date.init,
        lastFetchTime: @escaping () -> Date? = { RemoteConfig.remoteConfig().lastFetchTime },
        valueSource: (() -> RemoteValueSource)? = nil
    ) {
        self.nowProvider = now
        self.lastFetchTimeProvider = lastFetchTime
        self.valueSource = valueSource ?? Self.readSDKValue
        self.policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: readRemoteSwitch ?? Self.defaultReadRemoteSwitch(valueSource: self.valueSource),
            isAccountEnrolled: isAccountEnrolled ?? { false }
        )
    }

    /// Called from the fetch→activate completion path with the caller's evidence about that
    /// specific callback pair plus the token captured at fetch start. A cached or no-network
    /// outcome passes `freshActivationSucceeded: false` and cannot renew the lease; a token from
    /// a superseded identity cannot install at all.
    func policyRefreshAfterActivation(
        freshActivationSucceeded: Bool,
        fetchToken: VoiceSharingPolicy.FetchToken
    ) {
        policy.refreshAfterActivation(
            freshActivationSucceeded: freshActivationSucceeded,
            fetchToken: fetchToken
        )
    }

    /// Freshness plumbing reads the SDK's own bookkeeping rather than trusting `.success`, which
    /// the SDK also reports for cached returns. Injectable so tests drive the real decision
    /// function without a live Firebase instance.
    private let nowProvider: () -> Date
    var lastFetchTimeProvider: () -> Date?   // settable so tests drive the real decision function

    /// The SDK-facing seam: exactly the two fields production reads off a config value. Isolated so
    /// tests drive the SAME extraction path with a faithful fixture — a real `FIRRemoteConfigValue`, or
    /// an equivalent data/source pair — without live Firebase credentials or configuration.
    struct RemoteValueSource {
        let data: Data?
        let sourceIsRemote: Bool
    }

    var valueSource: () -> RemoteValueSource

    /// SDK bookkeeping accessors, exposed as functions so call sites read as intent.
    func nowForFreshnessCheck() -> Date { nowProvider() }
    func lastFetchTime() -> Date? { lastFetchTimeProvider() }

    /// Freshness predicate used by the production bridge. Requires BOTH:
    ///  - the SDK timestamp advanced from its own prior value (`previousSDKTime`), and
    ///  - the new value is past our wall-clock fetch start.
    ///
    /// A cached short-circuit leaves the SDK timestamp unchanged, so the first test fails. A backward
    /// clock jump can leave an OLD cached timestamp still greater than our start, so the second test
    /// alone is insufficient — that case fails closed here because the timestamp did not move.
    ///
    /// This is NOT a monotonic guarantee: it is the strongest statement the SDK's public bookkeeping
    /// supports, and equal/absent/unmoved timestamps are all treated as "not proven".
    func lastFetchAdvancedPast(_ startedAt: Date, previousSDKTime: Date?) -> Bool {
        guard let now = lastFetchTimeProvider() else { return false }
        if let previousSDKTime, now <= previousSDKTime { return false }   // SDK time did not move
        return now > startedAt
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

    /// Default reader: routes the seam's raw fields through the production extraction function.
    /// Instance wiring passes `Self.defaultReadRemoteSwitch(valueSource:)` so an injected seam is
    /// actually consulted instead of bypassed by a second static SDK read.
    static func defaultReadRemoteSwitch(valueSource: @escaping () -> RemoteValueSource) -> () -> VoiceSharingPolicy.RemoteSwitchValue {
        return {
            let source = valueSource()
            return VoiceSharingPolicy.extractRemoteSwitch(
                data: source.data,
                sourceIsRemote: source.sourceIsRemote
            )
        }
    }

    /// Reads the live SDK value into the seam's representation. `dataValue` is the UTF-8 payload the
    /// server published; `.source` distinguishes a genuine remote publication from our compiled
    /// default (`.default`) or an absent key (`.static`) — neither of which may satisfy the policy.
    ///
    /// NOTE: this deliberately does NOT use `numberValue`. FIRRemoteConfigValue implements it as
    /// `[NSNumber numberWithDouble:self.stringValue.doubleValue]` (vendored Sources/FIRConfigValue.m),
    /// so it always returns a boxed DOUBLE derived from text and never an ObjC boolean literal. A
    /// decoder that demanded a boolean literal would reject every real publication — including
    /// "true" — and the switch could never turn on at all. The faithful signals are the payload bytes
    /// plus the source.
    private static func readSDKValue() -> RemoteValueSource {
        guard FirebaseApp.app() != nil else { return RemoteValueSource(data: nil, sourceIsRemote: false) }
        let value = RemoteConfig.remoteConfig().configValue(forKey: Constants.RemoteParams.voiceSharingEnabled)
        return RemoteValueSource(data: value.dataValue as Data, sourceIsRemote: value.source == .remote)
    }
}
