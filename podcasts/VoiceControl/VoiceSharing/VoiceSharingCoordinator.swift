import Foundation
import PocketCastsUtils
import FirebaseCore
import FirebaseAnalytics
import PocketCastsServer

/// Observes consent authority changes and fans out gate-loss.
///
/// SIMPLIFIED contract: there is no policy snapshot, no lease, no exchange,
/// no retry machinery and no second identity lifecycle. The coordinator is now exactly two
/// things:
///
/// 1. THE gate-LOSS fan-OUT — one registration point for the pipeline (sink, collector,
/// trigger, queue purge predicate). Loss of consent or a transient gate move reaches every
/// registered handler through one snapshot-and-invoke; whether recordings are PURGED is
/// decided by the consent predicate in the handler (: explicit withdrawal
/// clears, temporary loss retains).
/// 2. PROJECTION refresh — on sign-in/launch it fetches the account's sharing view and applies
/// it to the enrollment store. This is how a withdrawal made on another device reaches the
/// consent authority (store observer → gate-lost fan-out → purge predicate), and how the
/// settings surface shows the account's enrolled truth. The server re-checks enrollment at
/// accept; nothing here is an upload-readiness gate.
final class VoiceSharingCoordinator {
    static let shared = VoiceSharingCoordinator()

    /// Authoritative membership shared by account operations and the settings surface.
    let enrollmentStore: VoiceSharingEnrollmentStore
    private var membershipObserverToken: UUID?
    private let cohortPublisher: VoiceSharingCohortPublisher

    func refreshCohortAttributes() { cohortPublisher.refresh() }

    init(enrollmentStore: VoiceSharingEnrollmentStore = .shared,
         cohortPublisher: VoiceSharingCohortPublisher? = nil,
         scheduledWorkObserver: ScheduledWorkObserver? = nil) {
        self.scheduledWorkObserver = scheduledWorkObserver
        let store = enrollmentStore ?? .shared
        self.enrollmentStore = store
        self.cohortPublisher = cohortPublisher ?? VoiceSharingCohortPublisher(store: store)
        // THE baseline arrives from the store, ATOMICALLY with the subscription.
        // Seeding here from separate reads left a window: a withdrawal landing between the read
        // and the registration was already inside the baseline, so the first comparison found
        // "no change" and the loss was never reported. The observer below is therefore called by
        // the store with its registration snapshot, and every later change follows it by sequence.
        // Membership moves reach the fan-out immediately: a withdrawal applied by a projection
        // refresh must stop collection at once (spec (a) "immediate local stop"). Whether
        // recordings are purged is the handler's consent predicate, not this event.
        membershipObserverToken = store.addObserver { [weak self] transition in
            guard let self else { return }
            self.refreshCohortAttributes()
            // THE fan-OUT is for A CONSENT loss, not for "SOMETHING changed". This
            // observer used to fire `consentGateLost` on every store notification — including a
            // first authoritative projection and the ordinary sign-in transition. The foreground
            // path refreshes the projection, the refresh applies the membership, `notify` fires,
            // and the handler called `uploadTrigger?.stop` — cancelling the very drain the same
            // foreground event had just started, ~1 ms later. Measured on a live build: 32 retained
            // recordings could never drain because the routine refresh stopped them first.
            //
            // TWO triggers, both real losses: consent truth going permitted →
            // not, OR the account itself changing — an ACCOUNT replacement must cancel even when
            // both accounts are opted in, because in-flight work belongs to the old owner. A
            // same-account projection refresh is neither, so it stops nothing.
            //
            // ORDER, not just mutual exclusion. `notify` invokes callbacks on
            // the mutating thread outside the store lock, so two notifications can be delivered
            // out of order: an OLDER snapshot arriving after a newer one. A lock alone makes each
            // comparison safe and still lets that stale callback overwrite the newer baseline —
            // regressing `lastConsentTruth` to `true` and swallowing the withdrawal that the newer
            // snapshot had already reported. Each notification therefore carries the store's
            // monotonically increasing sequence, taken under the state lock with the snapshot, and
            // anything not strictly newer than the last one processed is DISCARDED. The baseline
            // registered by the store has that same sequence, so the first delivered notification
            // is compared against a real predecessor rather than a guess.
            let state = transition.state
            let scopeNow = transition.accountScope
            let userIDNow = transition.sessionIdentity
            let sequence = transition.sequence
            let consentNow = Self.consentTruth(state)
            var fire = false
            self.consentTruthLock.lock()
            if sequence > self.lastObservedSequence {
                let userIDChanged = self.lastConsentUserID.map { $0 != userIDNow } ?? false
                if self.lastConsentTruth && !consentNow { fire = true }
                if let previousScope = self.lastConsentScope, previousScope != scopeNow { fire = true }
                if userIDChanged { fire = true }
                self.lastConsentTruth = consentNow
                self.lastConsentScope = scopeNow
                self.lastConsentUserID = userIDNow
                self.lastObservedSequence = sequence
            }
            self.consentTruthLock.unlock()
            if fire { self.consentGateLost() }
        }
    }

    /// The consent predicate the gate-loss fan-out exists to detect. `state` is the store's snapshot,
    /// read under its own lock, so this needs no extra synchronization.
    static func consentTruth(_ state: VoiceSharingEnrollmentStore.State) -> Bool {
        state.localOptIn && !state.explicitOptOut
            && state.membership.withdrawalState != .withdrawn
    }

    // MARK: - Gate-loss fan-out

    /// One gate-loss registration. Destroying it UNREGISTERS its handler: a pipeline rebuild can
    /// neither leave the previous collector un-notified nor notify a collector the new pipeline
    /// already replaced. Each service build registers its own collector; handlers fan out together.
    public final class GateLostSubscription {
        private let unregister: () -> Void
        fileprivate init(unregister: @escaping () -> Void) { self.unregister = unregister }
        func unregisterNow() { unregister() }
    }

    /// Last observed consent truth, so the membership observer can tell a LOSS from any other
    /// notification. Seeded on first notification rather than assumed, so a cold start that already
    /// holds consent does not manufacture a spurious loss.
    private var consentTruthLock = NSLock()
    /// Newest transition position this coordinator has processed. Anything older is stale.
    private var lastObservedSequence = -1
    /// The account the baseline belongs to, when the store had one. A change here is an account
    /// replacement even if the injected scope string stays identical.
    private var lastConsentUserID: String?
    private var lastConsentTruth = false
    /// The account scope the last notification described, so an ACCOUNT replacement is told apart
    /// from a same-account membership update even when both accounts hold consent.
    private var lastConsentScope: String?
    private var gateLostHandlers: [UUID: () -> Void] = [:]
    private let gateLostHandlersLock = NSLock()

    func registerGateLostHandler(_ handler: @escaping () -> Void) -> GateLostSubscription {
        let id = UUID()
        gateLostHandlersLock.lock()
        gateLostHandlers[id] = handler
        gateLostHandlersLock.unlock()
        return GateLostSubscription { [weak self] in self?.removeGateLostHandler(id) }
    }

    var gateLostHandlerCountForTesting: Int {
        gateLostHandlersLock.lock(); let n = gateLostHandlers.count; gateLostHandlersLock.unlock()
        return n
    }

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

    /// SNAPSHOT under the lock, INVOKE outside it: a handler may tear itself (or another
    /// registration) down reentrantly, which re-enters this registry; invoking under the lock
    /// would deadlock that. Snapshot semantics are the contract: a fan-out reaches every
    /// registration alive at the moment the loss was observed.
    private func consentGateLost() {
        gateLostHandlersLock.lock(); let snapshot = Array(gateLostHandlers.values); gateLostHandlersLock.unlock()
        for handler in snapshot { handler() }
    }

    // MARK: - Identity transitions

    private var identityObservers: [NSObjectProtocol] = []
    private var identityCenter: NotificationRegistering?

    /// Signs-in/out reach the consent authority here: sign-out transitions the store (consent
    /// gone), login changes and cold-start sign-in refresh the projection from the server. This
    /// is how a withdrawal made anywhere becomes an immediate local stop + purge decision.
    /// The two center calls the installer makes. `NotificationCenter` satisfies it as-is; controls
    /// substitute a center whose deliveries they can count.
    protocol NotificationRegistering {
        func addObserver(forName name: NSNotification.Name?, object obj: Any?,
                         queue: OperationQueue?, using block: @escaping (Notification) -> Void) -> NSObjectProtocol
        func removeObserver(_ observer: Any)
    }

    func installIdentityInvalidation(
        onNotificationCenter center: NotificationRegistering = NotificationCenter.default,
        startupAuthReadable: @escaping () -> Bool = { SyncManager.isUserLoggedIn() },
        // The refresh the identity notifications SCHEDULE must be driveable by a control at the
        // exact boundary where it happens, instead of being replaced afterwards by a separate call
        // that never awaits those tasks.
        scheduledRefreshClient: VoiceSharingAccountClient? = nil,
        loginStateReadable: @escaping () -> Bool = { SyncManager.isUserLoggedIn() }
    ) -> () -> Void {
        // Unregister from the center the PREVIOUS installation used — removing on the NEW center would
        // leave the old center with a live observer pointing at this coordinator.
        for o in identityObservers { identityCenter?.removeObserver(o) }
        identityObservers.removeAll()
        identityCenter = center
        let willSignOut = center.addObserver(
            forName: .serverUserWillBeSignedOut, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.enrollmentStore.transitionToAccount(signedIn: false)
            self.consentGateLost()
        }
        let loginChanged = center.addObserver(
            forName: .userLoginDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if loginStateReadable() {
                self.enrollmentStore.transitionToAccount(signedIn: true)
                let task = Task { await self.refreshProjectionFromServer(accountClient: scheduledRefreshClient) }
                self.scheduleRefresh(task)
            } else {
                self.enrollmentStore.transitionToAccount(signedIn: false)
                self.consentGateLost()
            }
        }
        identityObservers = [willSignOut, loginChanged]
        // Cold start into an already-signed-in account: no login notification will arrive for a
        // session that predates this process — settle the launch state now.
        if startupAuthReadable() {
            enrollmentStore.transitionToAccount(signedIn: true)
            let task = Task { await refreshProjectionFromServer(accountClient: scheduledRefreshClient) }
            scheduleRefresh(task)
        }
        return { [weak self] in
            guard let self else { return }
            for o in self.identityObservers { center.removeObserver(o) }
            self.identityObservers.removeAll()
        }
    }

    /// Scheduled-work OBSERVER: the coordinator keeps NO registry of its refresh
    /// tasks. Production passes nothing, so a notification's refresh is an ordinary fire-and-forget
    /// `Task` that the runtime owns and releases — there is no list to grow, no cap to enforce and
    /// no handle to leak. A control passes an observer to be handed each task as it is created, so
    /// it can settle exactly the work the notification started.
    ///
    /// Why not a registry: an earlier version kept one and capped it. Capping discards handles for
    /// work that is still running, so `awaitScheduledRefreshes` could no longer await it
    /// — a test convenience that silently changes what is observable.
    struct ScheduledWorkObserver {
        let didSchedule: (Task<Void, Never>) -> Void
        init(didSchedule: @escaping (Task<Void, Never>) -> Void) { self.didSchedule = didSchedule }
    }

    private let scheduledWorkObserver: ScheduledWorkObserver?

    /// Awaits the work a control's observer captured. Only meaningful when an observer was
    /// injected; in production there is nothing to await and this returns immediately.
    private var capturedWork: [Task<Void, Never>] = []
    private let capturedWorkLock = NSLock()

    func settleObservedWork() async {
        while true {
            capturedWorkLock.lock()
            let tasks = capturedWork
            capturedWorkLock.unlock()
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
            capturedWorkLock.lock()
            capturedWork.removeAll { tasks.contains($0) }
            capturedWorkLock.unlock()
        }
    }

    private func scheduleRefresh(_ task: Task<Void, Never>) {
        guard let scheduledWorkObserver else { return }
        capturedWorkLock.lock()
        capturedWork.append(task)
        capturedWorkLock.unlock()
        scheduledWorkObserver.didSchedule(task)
    }

    // MARK: - Projection refresh

    /// Fetches the account's sharing view and applies it to the store. Called on sign-in, at
    /// launch (from the ordinary remote-config refresh entry) and by account operations that need
    /// a follow-up read. This is the only remaining coordinator-driven server interaction, and it
    /// is not a readiness gate: unknown/stale projections keep consent as the user left it.
    func refreshProjectionFromServer(accountClient: VoiceSharingAccountClient? = nil) async {
        let client = accountClient ?? CloudTokenProviderRouter.voiceSharingProvider().map {
            VoiceSharingAccountClient(tokenProvider: $0, membershipStore: enrollmentStore)
        }
        guard let client, let fetched = await client.fetchProjection() else {
            FileLog.shared.addMessage("[VoiceSharing] projection refresh: fetch failed or unavailable")
            return
        }
        _ = enrollmentStore.apply(authoritative: fetched.membership, readUnder: fetched.issuedUnder)
    }
}

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

extension NotificationCenter: VoiceSharingCoordinator.NotificationRegistering {}
