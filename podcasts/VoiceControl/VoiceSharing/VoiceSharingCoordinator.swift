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
    static var shared = VoiceSharingCoordinator()

    /// Test-only seam so the app's own composition path can be exercised against an injected
    /// coordinator. Production never calls these; they exist because `shared` is what
    /// `AppDelegate.setupVoiceSharingIdentityInvalidation` reads by default, and a subscription test has
    /// to observe the same object the transition will later invalidate.
    static func setSharedForTesting(_ replacement: VoiceSharingCoordinator) { shared = replacement }
    static func resetSharedForTesting() { shared = VoiceSharingCoordinator() }

    let policy: VoiceSharingPolicy
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
        valueSource: (() -> RemoteValueSource)? = nil,
        enrollmentStore: VoiceSharingEnrollmentStore? = nil
    ) {
        self.nowProvider = now
        self.monotonicClock = clock
        self.lastFetchTimeProvider = lastFetchTime
        self.valueSource = valueSource ?? Self.readSDKValue
        let store = enrollmentStore ?? VoiceSharingEnrollmentStore.shared
        self.enrollmentStore = store
        self.applyingMembershipInvalidation = false
        self.policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: readRemoteSwitch ?? Self.defaultReadRemoteSwitch(valueSource: self.valueSource),
            // The store is the only honest source of "is this account enrolled": it requires BOTH the
            // user's own opt-in gesture AND a server projection carrying an epoch + accepted disclosure.
            // Production previously hard-coded `{ false }` because nothing fed membership yet.
            isAccountEnrolled: isAccountEnrolled ?? { store.currentEffectiveEnrolled }
        )
        // Membership moves must invalidate an in-flight refresh immediately, not at lease expiry: a
        // withdrawal or account switch that lands while a fetch is running would otherwise install the
        // departed state's permission when that fetch returns. Registered for ANY store this coordinator
        // was handed — gating it on ownership left injected stores with no invalidation at all.
        membershipObserverToken = store.addObserver { [weak self] _ in
            guard let self, !self.applyingMembershipInvalidation else { return }
            self.applyingMembershipInvalidation = true
            defer { self.applyingMembershipInvalidation = false }
            // Membership moves inside the current session must NOT raise the identity fence: a successful
            // enrollment has to be able to install on the very next activation, or opting in does nothing.
            self.policy.invalidateForIdentityChange(kind: .membershipChange)
            self.consentGateLost()
        }
    }

    /// The authoritative membership state, read by the settings UI and the mutation caller alike so no
    /// component keeps its own idea of enrollment.
    let enrollmentStore: VoiceSharingEnrollmentStore
    private var membershipObserverToken: UUID?
    /// Re-entrancy latch: the coordinator's lifecycle handlers call the store, whose observer calls back
    /// here. Without it one sign-out bumps the policy generation twice — the double-transition shape already
    /// caught once in this feature.
    private var applyingMembershipInvalidation: Bool

    /// Schedules the lease-expiry purge. Injectable so tests drive the exact deadline; production
    /// uses `defaultExpiryScheduler` (wall-clock delay computed from the monotonic deadline).
    /// Each refresh REPLACES the pending schedule (newest token wins), so a renewed lease never
    /// fires the previous deadline's purge.
    var expiryScheduler: ((_ delay: TimeInterval, _ body: @escaping () -> Void) -> Void)?
    private var expiryScheduleToken = UUID()

    static let defaultExpiryScheduler: (_ delay: TimeInterval, @escaping () -> Void) -> Void = { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }

    /// THE expiry trigger: fires at the LEASE DEADLINE itself, without waiting for a refresh, new
    /// frames, or any other event. At fire time the gate is re-read — if the lease lapsed (or the
    /// gate is closed for any other reason), consent is gone and the collector must purge NOW.
    /// A lease renewed in between re-reads open, so a stale schedule is harmless.
    private func scheduleLeaseExpiryTrigger() {
        guard let deadline = policy.installedLeaseExpiry else { return }
        let delay = max(0, deadline - monotonicClock.now())
        let token = UUID()
        expiryScheduleToken = token
        let schedule = expiryScheduler ?? Self.defaultExpiryScheduler
        schedule(delay) { [weak self] in
            guard let self, self.expiryScheduleToken == token else { return }
            if !self.policy.permitsCollection { self.consentGateLost() }
        }
    }

    /// One gate-loss registration. Destroying it UNREGISTERS its handler: a pipeline rebuild can
    /// neither leave the previous collector un-notified nor notify a collector the new pipeline
    /// already replaced. Each service build registers its own collector; handlers fan out together.
    public final class GateLostSubscription {
        private let unregister: () -> Void
        fileprivate init(unregister: @escaping () -> Void) { self.unregister = unregister }
        /// Explicit teardown, for a handler that must remove ITSELF during fan-out (reentrant
        /// teardown): same path as deinit, safe to call from inside a handler invocation.
        func unregisterNow() { unregister() }
        deinit { unregister() }
    }

    /// Production gate-loss fan-out. Every pipeline build registers its own collector (via
    /// `registerGateLostHandler`) so consent loss — membership withdrawal, sign-out, refresh
    /// observing the gate closed, or the scheduled lease-expiry trigger — purges EVERY collector
    /// that is still alive and holding audio, and only those. Purging an already-purged collector
    /// is a no-op.
    /// Registry state is mutated from MANY threads: registration on pipeline builds, token deinit
    /// teardown on whatever thread drops the last reference (a drain queue, a sink holder), and the
    /// expiry trigger on the main queue. Every access is therefore lock-guarded.
    private var gateLostHandlers: [UUID: () -> Void] = [:]
    private let gateLostHandlersLock = NSLock()

    @discardableResult
    func registerGateLostHandler(_ handler: @escaping () -> Void) -> GateLostSubscription {
        let id = UUID()
        gateLostHandlersLock.lock(); gateLostHandlers[id] = handler; gateLostHandlersLock.unlock()
        return GateLostSubscription { [weak self] in self?.removeGateLostHandler(id) }
    }

    // MARK: - Test seams
    var registerGateLostHandlerForTestingCount: Int {
        gateLostHandlersLock.lock(); let n = gateLostHandlers.count; gateLostHandlersLock.unlock()
        return n
    }
    func consentGateLostForTesting() { consentGateLost() }

    private func removeGateLostHandler(_ id: UUID) {
        gateLostHandlersLock.lock(); gateLostHandlers.removeValue(forKey: id); gateLostHandlersLock.unlock()
    }

    private func consentGateLost() {
        // SNAPSHOT under the lock, INVOKE outside it: a handler may tear itself (or another
        // registration) down reentrantly, which re-enters this registry; invoking under the lock
        // would deadlock that. Snapshot semantics are the contract: a fan-out reaches every
        // registration alive at the moment the loss was observed.
        gateLostHandlersLock.lock(); let snapshot = Array(gateLostHandlers.values); gateLostHandlersLock.unlock()
        for handler in snapshot { handler() }
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
        // If the refresh observed the gate closed (switch off, account not enrolled, install
        // refused), any audio the collector still holds is consentless — purge now.
        if !policy.permitsCollection { consentGateLost() }
        // And schedule the purge at the NEW lease's deadline, so expiry is triggered by time itself.
        scheduleLeaseExpiryTrigger()
    }

    /// Freshness plumbing reads the SDK's own bookkeeping rather than trusting `.success`, which
    /// the SDK also reports for cached returns. Injectable so tests drive the real decision
    /// function without a live Firebase instance.
    private let nowProvider: () -> Date
    private let monotonicClock: MonotonicClock
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

    /// Observers registered by the last install (sign-out + login-changed), so a repeat install removes
    /// BOTH rather than leaking one of them.
    private var identityObservers: [NSObjectProtocol] = []

    /// The center an installed observer was registered on. Removing an observer must be done through
    /// the SAME center that added it — `removeObserver(_:)` alone would not reach a non-default center.
    private var identityCenter: NotificationCenter?

    /// Subscribes to sign-out/identity change so permission drops synchronously instead of surviving
    /// inside a still-valid snapshot. IDEMPOTENT by construction: `setupVoiceControlIfNeeded()` runs on
    /// every activation, so a second call removes the previous subscription (from its actual center)
    /// before installing a new one. Without that, each activation leaked an observer and one sign-out
    /// notification fired N invalidations — while a single-activation test could never see it.
    ///
    /// Returns the invalidation closure so a composition site that already observes this notification
    /// can call it directly rather than registering a duplicate.
    @discardableResult
    func installIdentityInvalidation(onNotificationCenter center: NotificationCenter = .default) -> () -> Void {
        removeAllIdentityObservers()
        let invalidate: () -> Void = { [weak self] in
            guard let self else { return }
            self.policy.invalidateForIdentityChange()
        }
        // Sign-out: end the lifecycle so nothing begun under it can run, and fence policy installs until the
        // new account state is readable.
        let willSignOut = center.addObserver(
            forName: .serverUserWillBeSignedOut,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            VoiceSharingSessionGeneration.shared.clear()
            guard let self else { return }
            // Sign-out is an IDENTITY transition, not merely a membership change: the new account state is
            // unreadable, so installs are fenced until a login re-establishes them. The store call also
            // bumps the generation once through its own observer, so no second invalidate here.
            self.enrollmentStore.transitionToAccount(signedIn: false)
            self.policy.raiseIdentityFence()
            self.consentGateLost()
        }
        // Login changed is a STATE CHANGE, not proof of a login. Audited producers:
        //   AuthenticationHelper.handleSuccessfulSignIn, SyncSigninViewController, SyncSigninView,
        //   NewEmailViewController  -> all set ServerSettings.setSyncingEmail(...) FIRST, so the app is
        //                               genuinely signed in by the time this fires: new lifecycle.
        //   AppDelegate+Analytics   -> repairs a missing ServerSettings.userId; signed in: new lifecycle.
        //   SignOutHelper.signout   -> posts this AFTER SyncManager.signout() cleared email + userId, i.e.
        //                              while SIGNED OUT. Treating it as a login would mint a fresh lifecycle
        //                              and lift the fence with nobody authenticated, letting work begin under
        //                              a session that does not exist.
        // So the notification only says "re-derive": establish when auth state says signed in, otherwise end
        // the lifecycle and KEEP the fence raised.
        let loginChanged = center.addObserver(
            forName: .userLoginDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleLoginStateDidChange()
        }
        identityObservers = [willSignOut, loginChanged]
        identityCenter = center
        // Cold start into an already-signed-in account: there is no login notification for a session that
        // predates this process, so installation itself must give the app a lifecycle to act under.
        if SyncManager.isUserLoggedIn() {
            VoiceSharingSessionGeneration.shared.ensureLifecycle()
        }
        return invalidate
    }


    /// Re-derives the lifecycle from authoritative auth state rather than trusting the notification that
    /// prompted it. Split out so a composition test can drive the real producer sequence and still assert
    /// the decision, and so `SignOutHelper`'s trailing post cannot be mistaken for a sign-in.
    func handleLoginStateDidChange(signedIn: Bool = SyncManager.isUserLoggedIn()) {
        enrollmentStore.transitionToAccount(signedIn: signedIn)
        if signedIn {
            VoiceSharingSessionGeneration.shared.beginNewLifecycle()
            identityBecameReadable()
        } else {
            VoiceSharingSessionGeneration.shared.clear()
            policy.invalidateForIdentityChange()
            consentGateLost()
        }
    }

    private func removeAllIdentityObservers() {
        guard !identityObservers.isEmpty, let center = identityCenter else { return }
        for observer in identityObservers { center.removeObserver(observer) }
        identityObservers = []
    }

    /// Called by the identity provider once the new account state is readable; lifts the fence
    /// so a refresh against the CURRENT identity can install again.
    func identityBecameReadable() {
        policy.identityBecameReadable()
    }

    deinit {
        removeAllIdentityObservers()
        if let membershipObserverToken {
            enrollmentStore.removeObserver(membershipObserverToken)
        }
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
