import Foundation
import PocketCastsUtils
import FirebaseCore
import FirebaseAnalytics
import PocketCastsServer

/// Observes consent authority changes and fans out gate-loss.
///
/// SIMPLIFIED CONTRACT (spec `4afc6e43`): there is no policy snapshot, no lease, no exchange,
/// no retry machinery and no second identity lifecycle. The coordinator is now exactly two
/// things:
///
///   1. THE GATE-LOSS FAN-OUT — one registration point for the pipeline (sink, collector,
///      trigger, queue purge predicate). Loss of consent or a transient gate move reaches every
///      registered handler through one snapshot-and-invoke; whether recordings are PURGED is
///      decided by the consent predicate in the handler (spec e1529db9: explicit withdrawal
///      clears, temporary loss retains).
///   2. PROJECTION REFRESH — on sign-in/launch it fetches the account's sharing view and applies
///      it to the enrollment store. This is how a withdrawal made on another device reaches the
///      consent authority (store observer → gate-lost fan-out → purge predicate), and how the
///      settings surface shows the account's enrolled truth. The server re-checks enrollment at
///      accept; nothing here is an upload-readiness gate.
final class VoiceSharingCoordinator {
    static let shared = VoiceSharingCoordinator()

    /// Authoritative membership shared by account operations and the settings surface.
    let enrollmentStore: VoiceSharingEnrollmentStore
    private var membershipObserverToken: UUID?
    private let cohortPublisher: VoiceSharingCohortPublisher

    func refreshCohortAttributes() { cohortPublisher.refresh() }

    init(enrollmentStore: VoiceSharingEnrollmentStore = .shared,
         cohortPublisher: VoiceSharingCohortPublisher? = nil) {
        let store = enrollmentStore ?? .shared
        self.enrollmentStore = store
        self.cohortPublisher = cohortPublisher ?? VoiceSharingCohortPublisher(store: store)
        // Membership moves reach the fan-out immediately: a withdrawal applied by a projection
        // refresh must stop collection at once (spec (a) "immediate local stop"). Whether
        // recordings are purged is the handler's consent predicate, not this event.
        membershipObserverToken = store.addObserver { [weak self] _ in
            guard let self else { return }
            self.refreshCohortAttributes()
            self.consentGateLost()
        }
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
        startupAuthReadable: @escaping () -> Bool = { SyncManager.isUserLoggedIn() }
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
            if SyncManager.isUserLoggedIn() {
                self.enrollmentStore.transitionToAccount(signedIn: true)
                Task { await self.refreshProjectionFromServer() }
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
            Task { await self.refreshProjectionFromServer() }
        }
        return { [weak self] in
            guard let self else { return }
            for o in self.identityObservers { center.removeObserver(o) }
            self.identityObservers.removeAll()
        }
    }

    // MARK: - Projection refresh

    /// Fetches the account's sharing view and applies it to the store. Called on sign-in, at
    /// launch (from the ordinary remote-config refresh entry) and by account operations that need
    /// a follow-up read. This is the ONLY remaining coordinator-driven server interaction, and it
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
