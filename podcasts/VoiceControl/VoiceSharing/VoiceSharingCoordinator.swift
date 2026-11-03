import Foundation
import Firebase
import PocketCastsServer
import FirebaseRemoteConfig
import PocketCastsUtils
import FirebaseAnalytics

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
        lastFetchTime: @escaping () -> Date? = {
            // Freshness reads the SAME named authority the value reads (reviewer 9440ce71):
            // no mixing with the default app's fetch state; absent authority ⇒ nil.
            VoiceSharingFirebaseApp.existing().flatMap { RemoteConfig.remoteConfig(app: $0).lastFetchTime }
        },
        valueSource: (() -> RemoteValueSource)? = nil,
        enrollmentStore: VoiceSharingEnrollmentStore? = nil,
        cohortPublisher: VoiceSharingCohortPublisher? = nil
    ) {
        self.nowProvider = now
        self.monotonicClock = clock
        self.lastFetchTimeProvider = lastFetchTime
        self.valueSource = valueSource ?? Self.readSDKValue
        let store = enrollmentStore ?? VoiceSharingEnrollmentStore.shared
        self.enrollmentStore = store
        self.cohortPublisher = cohortPublisher ?? VoiceSharingCohortPublisher(store: store)
        self.applyingMembershipInvalidation = false
        self.policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: readRemoteSwitch ?? Self.defaultReadRemoteSwitch(valueSource: self.valueSource),
            // The store is the only honest source of "is this account enrolled": it requires BOTH the
            // user's own opt-in gesture AND a server projection carrying an epoch + accepted disclosure.
            // Production previously hard-coded `{ false }` because nothing fed membership yet.
            isAccountEnrolled: isAccountEnrolled ?? { store.currentEffectiveEnrolled }
        )
        // EVERY installed lease arms the expiry trigger from the install site, not from this
        // coordinator's refresh tail. Otherwise a lease installed by another route lapses with no
        // time-driven revocation: collection stops (safe) but nothing purges buffered or durable audio.
        // Fired on whatever thread installed the lease, and armed SYNCHRONOUSLY: the install and its
        // expiry schedule must be one deterministic step. Deferring to the main queue here made the
        // ordering unspecified — a control could then never distinguish an armed trigger from an
        // unarmed one, which is exactly the state this hook exists to prevent.
        self.policy.onLeaseInstalled = { [weak self] _ in
            self?.scheduleLeaseExpiryTrigger()
        }
        // Membership moves must invalidate an in-flight refresh immediately, not at lease expiry: a
        // withdrawal or account switch that lands while a fetch is running would otherwise install the
        // departed state's permission when that fetch returns. Registered for ANY store this coordinator
        // was handed — gating it on ownership left injected stores with no invalidation at all.
        membershipObserverToken = store.addObserver { [weak self] _ in
            guard let self else { return }
            self.refreshCohortAttributes()
            guard !self.applyingMembershipInvalidation else { return }
            self.applyingMembershipInvalidation = true
            defer { self.applyingMembershipInvalidation = false }
            // Membership moves inside the current session must NOT raise the identity fence: a successful
            // enrollment has to be able to install on the very next activation, or opting in does nothing.
            self.policy.invalidateForIdentityChange(kind: .membershipChange)
            self.consentGateLost()
        }
    }

    private let cohortPublisher: VoiceSharingCohortPublisher

    func refreshCohortAttributes() { cohortPublisher.refresh() }

    /// Authoritative membership shared by policy and account operations.
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
    static let defaultExpiryScheduler: (_ delay: TimeInterval, @escaping () -> Void) -> Void = { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }

    /// THE expiry trigger: fires at the LEASE DEADLINE itself, without waiting for a refresh, new
    /// frames, or any other event. At fire time the gate is re-read — if the lease lapsed (or the
    /// gate is closed for any other reason), consent is gone and the collector must purge NOW.
    /// A lease renewed in between re-reads open, so a stale schedule is harmless.
    private func scheduleLeaseExpiryTrigger() {
        // Deadline and generation are captured in ONE locked policy call: a concurrent install moves
        // both together, so they can never be paired across installs.
        guard let target = policy.leaseExpiryTarget() else { return }
        let delay = max(0, target.deadline - monotonicClock.now())
        let schedule = expiryScheduler ?? Self.defaultExpiryScheduler
        schedule(delay) { [weak self] in
            guard let self else { return }
            // The barrier is the POLICY's install-publication barrier: every install path (through
            // this coordinator or a direct policy call) publishes under it, so holding it across
            // revoke AND fan-out means a fresh lease cannot become visible mid-fan-out.
            self.policy.installPublicationBarrier.lock()
            defer { self.policy.installPublicationBarrier.unlock() }
            if self.policy.revokeIfLeaseExpired(
                generation: target.generation, deadline: target.deadline) {
                self.consentGateLost()
                // Normal lease renewal (reviewer 3154e29f): an expired lease refreshes
                // through the SAME complete exchange as launch/identity recovery. No-op
                // default; the production entry connects it to the named exchange.
                self.leaseRenewalAfterExpiry()
            }
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

    /// REENTRANCY CONTRACT, stated HERE at registration because it is a deadlock hazard, not style:
    /// a registered handler may unregister (itself or others) freely, but MUST NOT synchronously
    /// install or refresh a lease. The gate-lost fan-out runs under the policy's install-publication
    /// barrier; a synchronous refresh from a handler would deadlock on that nonrecursive lock.
    /// Anything a handler needs from a refresh must be scheduled off the fan-out stack.
    @discardableResult
    func registerGateLostHandler(_ handler: @escaping () -> Void) -> GateLostSubscription {
        let id = UUID()
        gateLostHandlersLock.lock(); gateLostHandlers[id] = handler; gateLostHandlersLock.unlock()
        return GateLostSubscription { [weak self] in self?.removeGateLostHandler(id) }
    }

    // MARK: - Test seams
    /// Number of live gate-lost handlers. Controls use this to prove the PRODUCTION registry —
    /// not a manual call — is what carries authorization invalidation to the sink.
    var gateLostHandlerCountForTesting: Int {
        gateLostHandlersLock.lock(); let n = gateLostHandlers.count; gateLostHandlersLock.unlock()
        return n
    }

    /// Fires every registered gate-lost handler exactly as production consent loss does.
    func fireGateLostHandlersForTesting() {
        gateLostHandlersLock.lock()
        let handlers = Array(gateLostHandlers.values)
        gateLostHandlersLock.unlock()
        for handler in handlers { handler() }
    }

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

    /// A newer remote fetch supersedes enrollment work from every older activation.
    struct EnrollmentLookup {
        fileprivate let generation: Int
        fileprivate let policyToken: VoiceSharingPolicy.FetchToken
        fileprivate let projectionToken: VoiceSharingEnrollmentStore.ProjectionToken?
    }

    // apply() notifies observers synchronously after releasing the store lock. A callback may
    // begin a newer lookup on this same thread; it must supersede us rather than deadlock.
    private let enrollmentLookupLock = NSRecursiveLock()
    private var enrollmentLookupGeneration = 0
    /// Holds the queued follow-up immediately before its intent check; unset in production.
    var beforeEnrollmentFollowUpForTesting: (() -> Void)?

    func beginEnrollmentLookup() -> EnrollmentLookup {
        enrollmentLookupLock.lock()
        defer { enrollmentLookupLock.unlock() }
        enrollmentLookupGeneration += 1
        return EnrollmentLookup(
            generation: enrollmentLookupGeneration,
            policyToken: policy.tokenForFetchStart(),
            projectionToken: enrollmentStore.projectionToken())
    }

    private func lookupIsCurrent(_ lookup: EnrollmentLookup) -> Bool {
        // DIAGNOSTIC (temporary): a superseded lookup is silent, and it is the difference between
        // "no identity" and "identity moved under the exchange" — two very different bugs.
        let current = enrollmentStore.projectionToken()
        if lookup.generation != enrollmentLookupGeneration || lookup.projectionToken == nil
            || lookup.projectionToken != current || lookup.policyToken != policy.tokenForFetchStart() {
            FileLog.shared.addMessage("[VoiceSharing] lookup superseded: gen=\(lookup.generation)/\(enrollmentLookupGeneration) lookupToken=\(lookup.projectionToken == nil ? "nil" : "set") currentToken=\(current == nil ? "nil" : "set") tokensEqual=\(lookup.projectionToken == current) policyTokenEqual=\(lookup.policyToken == policy.tokenForFetchStart())")
            return false
        }
        return true
    }

    /// Production activation completion: authoritative membership must be read before renewing
    /// permission. A changed projection invalidates this activation and needs one fresh exchange.
    func completeActivationWithEnrollment(
        freshActivationSucceeded: Bool,
        lookup: EnrollmentLookup,
        accountClient: VoiceSharingAccountClient? = nil
    ) async {
        guard freshActivationSucceeded else {
            FileLog.shared.addMessage("[VoiceSharing] activation settlement: no fresh activation")
            return
        }
        let mayFetch = enrollmentLookupLock.withLock { lookupIsCurrent(lookup) }
        guard mayFetch else {
            FileLog.shared.addMessage("[VoiceSharing] activation settlement: lookup superseded")
            return
        }
        let client = accountClient ?? CloudTokenProviderRouter.voiceSharingProvider().map {
            VoiceSharingAccountClient(tokenProvider: $0, membershipStore: enrollmentStore)
        }
        guard let client, let fetched = await client.fetchProjection() else {
            FileLog.shared.addMessage("[VoiceSharing] activation settlement: projection fetch failed")
            return
        }

        let changed: Bool = enrollmentLookupLock.withLock {
            guard lookupIsCurrent(lookup), fetched.issuedUnder == lookup.projectionToken else { return false }
            let membershipChanged = enrollmentStore.currentState.membership != fetched.membership
            guard enrollmentStore.apply(authoritative: fetched.membership, readUnder: fetched.issuedUnder) else {
                return false
            }
            if !membershipChanged {
                // No new token: only the original, still-current activation can renew the lease.
                guard lookupIsCurrent(lookup) else { return false }
                policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: lookup.policyToken)
            }
            return membershipChanged
        }
        guard changed else { return }
        // Dispatch outside application/observer locks. Local intent or a newer lookup can retire
        // this follow-up before it runs. The next fetch captures its own authority from scratch.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.beforeEnrollmentFollowUpForTesting?()
            let stillCurrent = self.enrollmentLookupLock.withLock {
                lookup.generation == self.enrollmentLookupGeneration
                    && fetched.issuedUnder == self.enrollmentStore.projectionToken()
                    && self.enrollmentStore.currentState.membership == fetched.membership
            }
            guard stillCurrent else { return }
            self.initiateIdentityRecoveryRefresh()
        }
    }

    /// Called from the fetch→activate completion path with the caller's evidence about that
    /// specific callback pair plus the token captured at fetch start. A cached or no-network
    /// outcome passes `freshActivationSucceeded: false` and cannot renew the lease; a token from
    /// a superseded identity cannot install at all.
    func policyRefreshAfterActivation(
        freshActivationSucceeded: Bool,
        fetchToken: VoiceSharingPolicy.FetchToken
    ) {
        FileLog.shared.addMessage("[VoiceSharing] policy refresh called: fresh=\(freshActivationSucceeded)")
        let installed = policy.refreshAfterActivation(
            freshActivationSucceeded: freshActivationSucceeded,
            fetchToken: fetchToken
        )
        FileLog.shared.addMessage("[VoiceSharing] policy refresh returned: installed=\(installed != nil)")
        // If the refresh observed the gate closed (switch off, account not enrolled, install
        // refused), any audio the collector still holds is consentless — purge now.
        if !policy.permitsCollection { consentGateLost() }
        // The NEW lease's expiry schedule is armed at the INSTALL SITE itself; arming again here
        // would double-schedule every refresh.
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
    /// Exchange-seam accessor (activation slice): the policy fetch token captured
    /// BEFORE a named fetch, for callers settling through policyRefreshAfterActivation.
    func policyTokenForFetchStart() -> VoiceSharingPolicy.FetchToken { policy.tokenForFetchStart() }
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
    private var identityCenter: NotificationRegistering?

    /// Subscribes to sign-out/identity change so permission drops synchronously instead of surviving
    /// inside a still-valid snapshot. IDEMPOTENT by construction: `setupVoiceControlIfNeeded()` runs on
    /// every activation, so a second call removes the previous subscription (from its actual center)
    /// before installing a new one. Without that, each activation leaked an observer and one sign-out
    /// notification fired N invalidations — while a single-activation test could never see it.
    ///
    /// Returns the invalidation closure so a composition site that already observes this notification
    /// can call it directly rather than registering a duplicate.
    /// The notification API the sign-out wiring needs, isolated behind a protocol (spec e3db4e30 /
    /// d718c160) because the observer's body reaches `SyncManager` and the app graph: a test cannot
    /// build that graph, but it CAN drive the REAL registration and callback path if the center is
    /// injectable. `NotificationCenter` already satisfies this, so production is unchanged — the
    /// AppDelegate still passes `.default`, and this is a conformance, not a wrapper.
    protocol NotificationRegistering {
        func addObserver(forName name: NSNotification.Name?,
                         object obj: Any?,
                         queue: OperationQueue?,
                         using block: @escaping (Notification) -> Void) -> NSObjectProtocol
        func removeObserver(_ observer: Any)
    }

    @discardableResult
    func installIdentityInvalidation(
        onNotificationCenter center: NotificationRegistering = NotificationCenter.default,
        startupAuthReadable: @escaping () -> Bool = { SyncManager.isUserLoggedIn() }
    ) -> () -> Void {
        removeAllIdentityObservers()
        let invalidate: () -> Void = { [weak self] in
            guard let self else { return }
            self.cancelRestoredSessionRetry()
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
            guard let self else { return }
            self.handleLoginStateDidChange()
        }
        // The credential OWNER's commit, which is the only completion a passive restoration has:
        // `TokenHelper.acquireToken` commits on every renewal AND on a silent refresh-token restore,
        // and it posts no notification (measured; TokenHelper.swift:95,122). Registered through the
        // package's public seam, because TokenHelper is internal to PocketCastsServer.
        //
        // It is a READINESS signal, not an identity: renewal commits and login commits look alike
        // from here, and the commit id changes on both. So the callback re-derives; it never assumes
        // a login. `credentialCommitRevision` keeps a burst of commits to one re-derivation.
        ServerSettings.credentialCommitObserver = { [weak self] in
            guard let self else { return }
            // The owner fires inside `commitAuthentication`, on whatever context committed and with
            // its lock released. Release it again immediately: the derivation hops to the main queue
            // (the same context a login notification arrives on), and must hold no owner state.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.credentialCommitRevision += 1
                self.credentialCommitDidOccur()
            }
        }
        identityObservers = [willSignOut, loginChanged]
        identityCenter = center
        // Cold start into an already-signed-in account: there is no login notification for a session that
        // predates this process, so installation itself must give the app a lifecycle to act under.
        //
        // MISSING CONNECTION (spec c3f8fcb4, 2026-11-03): this runs BEFORE the stored session is
        // readable, so `isUserLoggedIn()` is false, `ensureLifecycle()` never ran, and the launch
        // policy exchange was refused for want of a lifecycle — it then deferred to "identity
        // recovery", which only fires on a login NOTIFICATION this process never receives. Result:
        // an enrolled, consented account whose capture gate stayed closed until the next launch had
        // a readable session, with no log line explaining any of it. So: register for the transition
        // itself and settle the launch state.
        let readableAtStartup = startupAuthReadable
        if readableAtStartup() {
            // A COLD RESTORED SESSION: the stored session is readable before any login notification
            // can exist for it, and nothing posts `.userLoginDidChange` for a session that predates
            // the process. The credential owner's commit is what makes the account readable, so this
            // is the same derivation a commit uses — through the same code path, so a cold restore
            // and a later readability cannot drift apart (spec 2026-11-03, reviewer on 466576407).
            settleFromOwnerReadiness()
        } else {
            // The stored session is not readable yet. Two things finish a restoration from here and
            // either may win: the credential owner's commit (the normal case — it is what makes the
            // account readable) and this poll, which exists for the state-readability gap the README
            // of this path describes: for a short window the app can read a session the owner has not
            // yet committed inside this process, and nothing would ever derive from it. The poll
            // therefore asks the SAME derivation the commit uses, at a bounded cadence, and settles
            // nothing by itself.
            startRestoredSessionRetry()
        }
        return invalidate
    }


    // MARK: - Restored-session settlement (spec c3f8fcb4, 2026-11-03)

    /// A process that starts with a stored session has NO login event to react to: the account is
    /// restored asynchronously by the sync layer, and nothing posts `.userLoginDidChange` for it.
    /// Before this, the launch policy exchange ran while `isUserLoggedIn()` was still false, was
    /// refused for want of a lifecycle, and deferred to "identity recovery" — which also never
    /// fired. An enrolled, consented account therefore captured nothing, silently, until a later
    /// process start happened to observe a readable session. This asks the state directly.
    /// Monotonic poll generation: incrementing it invalidates every pending attempt. A
    /// DispatchWorkItem cannot capture itself for cancellation, and a generation check is the
    /// same staleness guard without the self-reference.
    private var restoredSessionPollGeneration = 0

    /// Injectable delay between restored-session attempts so controls run the real
    /// loop without real seconds. Production: 1 second.
    var restoredSessionRetryDelay: () -> TimeInterval = { 1.0 }

    /// Injectable auth-state reader so controls drive the real poll loop under a known
    /// signed-out state (the test host's defaults carry a syncing email, so the
    /// process-global `SyncManager.isUserLoggedIn()` is signed IN there). Production: the
    /// same SyncManager read, unchanged.
    var restoredSessionAuthReadable: () -> Bool = { SyncManager.isUserLoggedIn() }

    func startRestoredSessionRetry() {
        restoredSessionPollGeneration += 1
        // Polls WHILE SIGNED OUT, then settles once. A hard attempt bound leaves a session that
        // restores late (slow network, large sync) permanently unsettled: nothing ever posts
        // `.userLoginDidChange` for a session that predates the process, so stopping the poll
        // means no settlement, ever. The poll reads a defaults-backed flag and backs off to a
        // 5-second cadence after the fast restore window, which is negligible for a signed-out
        // process; any settlement (poll or notification) cancels it (reviewer 30630d31).
        attemptRestoredSessionRetry(delay: restoredSessionRetryDelay(), attempt: 0)
    }

    private func attemptRestoredSessionRetry(delay: TimeInterval, attempt: Int) {
        let generation = restoredSessionPollGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.restoredSessionPollGeneration == generation else { return }
            // The tick settles nothing on its own: every state it can read is process-global and
            // survives sign-out, so "readable" alone would mint a lifecycle for a session nobody
            // established and re-settle a departed account. It asks the OWNER whether a credential
            // for the currently readable session is committed IN THIS PROCESS, and that answer —
            // not the tick — decides. A tick that finds no answer keeps the debt (reviewer on
            // 4035a1ebf: a tick must never be able to clear its own debt).
            if self.restoredSessionAuthReadable() {
                self.settleFromOwnerReadiness()
            }
            // Back off 5x after the fast restore window (~ the old bound's coverage).
            let base = self.restoredSessionRetryDelay()
            let next = attempt < 20 ? base : base * 5
            self.attemptRestoredSessionRetry(delay: next, attempt: attempt + 1)
        }
    }

    /// Cancels any pending restored-session attempt. EVERY settlement goes through
    /// `handleLoginStateDidChange`, so this is the single choke point that stops the poll from
    /// firing after a normal login notification settled the identity - its next tick otherwise
    /// began a new lifecycle and superseded the first login's in-flight work (reviewer 30630d31).
    private func cancelRestoredSessionRetry() {
        restoredSessionPollGeneration += 1
    }

    /// The account identity the CURRENT lifecycle was settled under; nil while signed out. The
    /// idempotence key for settlement (see handleLoginStateDidChange).
    private var settledAccountIdentity: String?

    /// Read-only view of the settlement key, so a control can assert that an UNRESOLVED tick
    /// invented no identity. Reading is not an observation the predicate depends on.
    var settledAccountIdentityForTesting: String? { settledAccountIdentity }

    /// Bumped by every credential commit so a burst (a login commits, then the first renewal)
    /// re-derives once instead of twice.
    internal var credentialCommitRevision = 0

    /// The account identity the owner reports for the CURRENTLY committed credential, or nil when
    /// nothing is committed (signed out) or the owner cannot answer. Production reads the package
    /// seam; controls name accounts. This is a real account/session identity — stable across
    /// renewals of the same account, different for a different one, and nil when there is none, so
    /// "unknown owner" can never be deduped against a known one.
    var ownerAccountIdentityProvider: () -> String? = {
        ServerSettings.committedAccountIdentity()?.uuidString
    }

    /// Whether the owner holds a credential this process could PRESENT right now, independent of
    /// whether it committed one while this process was running. This is what cold start needs: the
    /// question there is not "did a commit happen in this process" (an event that may have been
    /// missed entirely, or that happened in an earlier launch) but "is there a stored credential to
    /// present". Deriving from the readable credential removes the process-lifetime problem instead
    /// of working around it, and leaves the commit hook to cover only the LATER case it is good at:
    /// a credential that became available after startup.
    var ownerCredentialIsPresent: () -> Bool = {
        ServerSettings.committedAccountIdentity() != nil || SyncManager.isUserLoggedIn()
    }

    /// Re-derives the lifecycle from authoritative auth state rather than trusting the notification that
    /// prompted it. Split out so a composition test can drive the real producer sequence and still assert
    /// the decision, and so `SignOutHelper`'s trailing post cannot be mistaken for a sign-in.
    func handleLoginStateDidChange(signedIn: Bool = SyncManager.isUserLoggedIn()) {
        // DIAGNOSTIC (temporary): silent transitions are what made "the session exists for sync but
        // voice sharing reads anonymous" unreadable for an hour.
        FileLog.shared.addMessage("[VoiceSharing] identity changed: signedIn=\(signedIn)")
        if signedIn {
            settleFromOwnerReadiness()
        } else {
            endSession()
        }
    }

    /// The ONE settlement decision. Every producer — an observed login, the credential owner's
    /// commit, a poll tick, a cold start into a readable session — asks this and nothing else, so no
    /// two of them can disagree about what an identity is (reviewer on 466576407).
    ///
    /// It settles on READINESS reported by the credential owner: an account identity for a
    /// credential committed in THIS process. That is what makes a passive restoration (no login
    /// notification exists for a session that predates the process) reach the projection/capture
    /// decision, and it is stable across renewals, so a renewal does not reset an unchanged
    /// lifecycle.
    /// Stands in for "the credential supplier" a readiness check must NOT call. The control counts
    /// invocations; production leaves it nil and nothing calls it. It exists so the cost of a
    /// predicate is observable, not so that production can acquire here.
    var credentialAcquisitionForTesting: (() -> Void)?

    func settleFromOwnerReadiness() {
        // COLD vs LATER. In this process nothing may have committed yet even though a stored session
        // is perfectly usable (reviewer on `bf335f109`: both committed-state fields start nil, so a
        // cold restore deferred forever). The fallback is therefore the READABLE credential, not a
        // remembered commit: a state you can read, not an event you may have missed. It is reached
        // only when the committed identity is absent, so a live commit always wins.
        let identity = ownerAccountIdentityProvider()
            ?? (ownerCredentialIsPresent() ? storedCredentialIdentityProvider() : nil)
        guard let identity, !identity.isEmpty else {
            // Nothing to act for: signed out, or the owner is mid-write. KEEP the current lifecycle
            // — a renewal momentarily disowning nothing must not strand a live session — and keep
            // the debt so the next tick or commit settles it.
            FileLog.shared.addMessage("[VoiceSharing] identity settlement deferred: no readable owner credential (present=\(ownerCredentialIsPresent()))")
            return
        }
        if identity == settledAccountIdentity {
            FileLog.shared.addMessage("[VoiceSharing] identity settlement: same account, no-op")
            return
        }
        FileLog.shared.addMessage("[VoiceSharing] identity settled from owner readiness")
        settledAccountIdentity = identity
        cancelRestoredSessionRetry()
        enrollmentStore.transitionToAccount(signedIn: true)
        VoiceSharingSessionGeneration.shared.beginNewLifecycle()
        identityBecameReadable()
    }

    /// The identity of the credential already STORED for this account (the cold-start answer).
    /// Injectable for the same reason as the owner identity: controls name accounts.
    var storedCredentialIdentityProvider: () -> String? = {
        VoiceSharingCoordinator.storedCredentialIdentityFallback()
    }

    /// Identity of the credential already stored for this account (a COLD start, or a credential that
    /// became present without a commit this process observed).
    ///
    /// It is the SAME value the committed path reports — the owner's account digest and nothing else
    /// (reviewer, `d23c3f613`). An earlier revision namespaced this as "stored:<digest>"; that made the
    /// same account compare unequal to itself, so the first renewal commit after a cold start read as
    /// a DIFFERENT account and reset the lifecycle, enrollment authority and in-flight work. Two ways
    /// of naming one account must produce one string, or the difference is eventually read as an event.
    static func storedCredentialIdentityFallback() -> String? {
        storedIdentity(from: ServerSettings.storedAccountIdentity())
    }

    /// The account's identity as the COLD path names it.
    static func storedIdentity(from stored: UUID?) -> String? { stored?.uuidString }

    /// The account's identity as the COMMITTED path names it. Both live here, one function apart, so
    /// any divergence between them is a one-line change that a single control can see.
    static func committedIdentity(from committed: UUID?) -> String? { committed?.uuidString }

    /// The credential owner reported a completed commit: the lock is released and the account this
    /// process can act for may have changed. Re-derives; never assumes a login.
    /// The credential owner reported a completed commit: the lock is released and the account this
    /// process can act for may have changed. Re-derives; never assumes a login.
    ///
    /// There is deliberately NO `isUserLoggedIn()` gate here (reviewer on `d23c3f613`). That check
    /// reads `ServerSettings.syncingEmail()`, which is itself nil while an incomplete credential write
    /// is in flight — so a commit observer gated on it could be silenced by the very commit it exists
    /// to observe. The decision belongs to `settleFromOwnerReadiness()`, which asks the owner for an
    /// identity: no identity, no settlement.
    func credentialCommitDidOccur() {
        settleFromOwnerReadiness()
    }

    private func endSession() {
        settledAccountIdentity = nil
        enrollmentStore.transitionToAccount(signedIn: false)
        VoiceSharingSessionGeneration.shared.clear()
        policy.invalidateForIdentityChange()
        consentGateLost()
    }

    private func removeAllIdentityObservers() {
        guard !identityObservers.isEmpty, let center = identityCenter else { return }
        for observer in identityObservers { center.removeObserver(observer) }
        identityObservers = []
    }

    /// Called by the identity provider once the new account state is readable; lifts the fence
    /// so a refresh against the CURRENT identity can install again — and then INITIATES the normal
    /// refresh, because lifting the fence alone re-arms nothing (review 15a18d5d: production's only
    /// refresh calls live in AppDelegate launch and the developer menu, so a re-login in a
    /// long-running process never fetched, never installed, and the gate stayed closed until relaunch).
    /// Injectable so tests drive the real sequence. NO-OP by default, because the production fetch
    /// entry point touches Firebase and must be wired where Firebase is configured (VoiceControlAssembly),
    /// not from a default property initializer a test can trip over.
    var initiateIdentityRecoveryRefresh: () -> Void = {}
    /// Injectable so tests drive the real sequence. NO-OP by default, because the production fetch
    /// entry point touches Firebase and must be wired where Firebase is configured (VoiceControlAssembly),
    /// not from a default property initializer a test can trip over.
    /// Normal lease-renewal entry (reviewer 3154e29f): invoked after a lease-expiry revocation so
    /// renewal uses the same complete exchange as launch/identity recovery.
    var leaseRenewalAfterExpiry: () -> Void = {}

    func identityBecameReadable() {
        policy.identityBecameReadable()
        initiateIdentityRecoveryRefresh()
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
        // FAIL CLOSED for Voice Sharing (reviewer 9440ce71): the policy scalar reads
        // ONLY the named secondary app's dedicated authority. A missing secondary
        // config is "disabled", never "fall back to another project's flag". The
        // default app's consumers elsewhere are untouched.
        guard let named = VoiceSharingFirebaseApp.existing() else {
            return RemoteValueSource(data: nil, sourceIsRemote: false)
        }
        let value = RemoteConfig.remoteConfig(app: named)
            .configValue(forKey: Constants.RemoteParams.voiceSharingEnabled)
        return RemoteValueSource(data: value.dataValue as Data, sourceIsRemote: value.source == .remote)
    }

    /// The FirebaseApp the policy reads through: the named secondary app only.
    /// Nil (never the default app) when the dedicated authority is absent — the
    /// policy flag fails closed, while default consumers keep their own app.
    static func policyFirebaseApp() -> FirebaseApp? {
        VoiceSharingFirebaseApp.existing()
    }
}


extension NotificationCenter: VoiceSharingCoordinator.NotificationRegistering {}

/// Advisory targeting attributes only. SDK calls do not acknowledge targeting or authorize collection.
final class VoiceSharingCohortPublisher {
    private let store: VoiceSharingEnrollmentStore
    private let configured: () -> Bool
    private let privacyAllows: () -> Bool
    private let schedule: (@escaping () -> Void) -> Void
    private let setProperty: (String?, String) -> Void

    init(store: VoiceSharingEnrollmentStore,
         configured: @escaping () -> Bool = { FirebaseApp.app() != nil },
         privacyAllows: @escaping () -> Bool = { !Settings.analyticsOptOut() },
         schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         setProperty: @escaping (String?, String) -> Void = { FirebaseAnalytics.Analytics.setUserProperty($0, forName: $1) }) {
        self.store = store
        self.configured = configured
        self.privacyAllows = privacyAllows
        self.schedule = schedule
        self.setProperty = setProperty
    }

    func refresh() {
        schedule { [weak self] in
            guard let self, self.configured() else { return } // No SDK call, no clearing claim.
            guard self.privacyAllows() else {
                self.setProperty(nil, "plan")
                self.setProperty(nil, "voice_sharing_enrolled")
                return
            }
            self.store.publishCurrentCohortAttributes { plan, enrolled in
                self.setProperty(plan, "plan")
                self.setProperty(enrolled, "voice_sharing_enrolled")
            }
        }
    }
}
