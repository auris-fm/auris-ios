import Foundation
import PocketCastsServer

/// Backend-authoritative Voice Sharing membership, and the single place local state is allowed to change.
///
/// Why a store exists at all: the policy asks `isAccountEnrolled` at decision time, but that question has
/// exactly one honest answer source — the server projection. Nothing else on the device may claim
/// enrollment, including a locally flipped toggle, so this type owns the fold:
///
/// * `effectiveEnrolled` is **server state AND the user's local intent**, never either alone. A remote
/// switch or a UI gesture cannot enable collection by itself; the backend epoch must back it.
/// * NOTHING orders or compares `membership_revision`: the contract makes it opaque, so any local
/// comparison would be a guess that fails toward re-enabling a user who already withdrew. Instead every
/// read and mutation is stamped with a `ProjectionToken` captured before the request — the account/session
/// lifecycle plus a membership-operation counter — and a reply may only be applied while BOTH still match
/// the live session. The counter bumps on each local membership move, so a delayed opt-in cannot
/// resurrect membership after a withdrawal however its revision is spelled.
/// * Withdrawal takes effect LOCALLY and immediately — new collection stops without waiting for the
/// network — because "the user said stop" must not depend on a round trip. The server call still runs,
/// and its result only reconciles; it is never what stops collection.
/// * Account transitions replace the whole projection. An account switch cannot inherit the previous
/// account's enrollment, even if both are enrolled, because the epochs belong to different accounts.
///
/// Storage: app-private `UserDefaults`, opaque values only (revision/epoch/disclosure version as received).
/// It deliberately does not store audio, transcripts, or credentials, and it is not the durable contribution
/// queue — purging queued audio is Task 6's job and must run through `transitionToAccount` / `withdraw` here
/// so both use one production transition rather than two divergent notions of "stopped".
final class VoiceSharingEnrollmentStore {
    static let shared = VoiceSharingEnrollmentStore()

    /// What the policy reads at decision time.
    /// ONE state change, WITH the account moment it belongs to.
    ///
    /// The state, the account scope and the session identity are read under a single hold, so a
    /// handler can never pair one account's membership with another account's identity. `sequence`
    /// is the transition's position in the stream: handlers use it to discard a stale delivery
    /// instead of letting it overwrite newer knowledge.
    struct Transition {
        let sequence: Int
        let state: State
        let accountScope: String
        let sessionIdentity: String?
    }

    struct State: Equatable {
        var membership: VoiceSharingMembership = .unavailable
        /// The user's own opt-in gesture, persisted so a launch does not silently re-enable something they
        /// turned off. Never sufficient on its own — see `effectiveEnrolled`.
        var localOptIn = false
        /// True only once a projection has been ACCEPTED from the server in this session. Loading disk can
        /// never set it: a remembered active epoch plus a remembered opt-in is not permission, because the
        /// account may have withdrawn on another device, been disabled server-side, or the process may simply
        /// have restarted into a state the server no longer recognises. Until a current-session reply lands,
        /// `effectiveEnrolled` is false and collection stays off.
        var hasAuthoritativeProjection = false
        /// True only when the USER turned sharing off. A fresh or default-wiped store is false:
        /// unknown consent retains recordings.
        var explicitOptOut = false

        /// Enrollment requires BOTH halves. This is the property the plan states as
        /// `test_toggleRequiresDisclosureAcceptance_andBackendEpoch`: flipping a switch locally yields
        /// enrolled=false until the server publishes acceptance plus an epoch.
        var effectiveEnrolled: Bool {
            guard localOptIn, hasAuthoritativeProjection else { return false }
            let m = membership
            return m.voiceSharingEnrolled
                && m.withdrawalState == .active
                && m.enrollmentEpoch != nil
                && m.acceptedDisclosureVersion != nil
        }
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var state = State()
    private var authoritativeLifecycle: String?
    /// Each subscriber records the sequence of ITS own baseline; anything at or below it is
    /// pre-subscription history and is never delivered to that subscriber.
    private var observers: [UUID: (Transition) -> Void] = [:]
    private var observerBaselines: [UUID: Int] = [:]
    /// Monotonic position in the state's history. Every mutation bumps it under the state lock, so
    /// two transitions can never claim the same position or be delivered out of order.
    private var transitionSequence: Int = 0
    /// TRANSITIONS awaiting delivery, captured at the mutation and drained in sequence order.
    private var pendingDeliveries: [Delivery] = []
    /// The single-drainer gate, owned by the SAME lock as the queue and the state.
    private var draining = false

    private enum Key {
        static func scoped(_ base: String, _ accountScope: String) -> String { "\(base).\(accountScope)" }
        static let optIn = "VoiceSharing.localOptIn"
        static let optOut = "VoiceSharing.explicitOptOut"
        static let revision = "VoiceSharing.membershipRevision"
        static let enrolled = "VoiceSharing.serverEnrolled"
        static let epoch = "VoiceSharing.enrollmentEpoch"
        static let disclosure = "VoiceSharing.acceptedDisclosureVersion"
        static let withdrawal = "VoiceSharing.withdrawalState"
        static let plan = "VoiceSharing.plan"
    }

    /// Reads the CURRENT account/session lifecycle generation. A projection is applicable only while the
    /// lifecycle it was read under is still live — the half no local revision comparison can supply, because
    /// an opaque revision says nothing about which session produced it.
    private let sessionIdentityProvider: () -> String?

    init(
        defaults: UserDefaults = .standard,
        accountScopeProvider: @escaping () -> String = VoiceSharingEnrollmentStore.currentAccountScope,
        sessionIdentityProvider: @escaping () -> String? = VoiceSharingEnrollmentStore.currentSessionOwner
    ) {
        self.defaults = defaults
        self.accountScopeProvider = accountScopeProvider
        self.sessionIdentityProvider = sessionIdentityProvider
        loadForCurrentAccount()
    }

    /// Membership is per-account. Keying storage by the signed-in account means signing into a different
    /// account cannot read the previous account's enrollment out of disk, and signing back in restores the
    /// user's own prior intent rather than resetting it.
    /// ORDINARY account ownership: the lifecycle a projection was read under is the
    /// signed-in account itself, read from the same place every other authenticated request reads it. The
    /// retired sharing lifecycle registry used to supply this and no longer exists, so leaving the default
    /// pointed at it would refuse every signed-in operation before a request was made.
    static func currentSessionOwner() -> String? {
        guard SyncManager.isUserLoggedIn() else { return nil }
        return ServerSettings.userId
    }

    private let accountScopeProvider: () -> String
    private static func currentAccountScope() -> String {
        // Fail closed to an unscoped-but-stable label when nothing is authenticated.
        ServerSettings.userId ?? "signed-out"
    }

    private var scope: String { accountScopeProvider() }

    /// The account scope the CURRENT snapshot belongs to, read under the same hold as the state.
    var currentScopeForObservers: String {
        lock.lock(); defer { lock.unlock() }
        return accountScopeProvider()
    }

    // MARK: - Reading

    ///: true when CONSENT is gone — the user opted out locally, the account
    /// withdrew, or there is no session. Only this may authorize purging durable recordings;
    /// temporary gate loss (policy flap, network, listening) must retain them.
    var consentGoneForPurge: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.explicitOptOut
            || state.membership.withdrawalState == .withdrawn
    }

    /// ONE consent decision for capture AND upload: the ordinary session,
    /// an affirmative local sharing choice, and no explicit consent loss. Unknown projection is
    /// transient and permits; the server re-checks enrollment at accept. Never a readiness gate.
    var consentAllowsCollection: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.localOptIn
            && state.membership.withdrawalState != .withdrawn
    }

    var currentEffectiveEnrolled: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.effectiveEnrolled
    }

    var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Last server-observed revision, sent as `expected_membership_revision` on every mutation.
    var expectedMembershipRevision: String? {
        lock.lock(); defer { lock.unlock() }
        return state.hasAuthoritativeProjection && !state.membership.membershipRevision.isEmpty
            ? state.membership.membershipRevision : nil
    }

    var activeEnrollmentEpoch: String? {
        lock.lock(); defer { lock.unlock() }
        guard state.effectiveEnrolled else { return nil }
        return state.membership.enrollmentEpoch
    }

    /// The PERSISTED enrollment epoch, for use as upload PROVENANCE only.
    ///
    /// Deliberately not gated on `effectiveEnrolled`: that gate needs
    /// `hasAuthoritativeProjection`, which is false after every cold start until a projection round
    /// trip lands in THIS process. Requiring it here made a leftover readiness dependency — a
    /// restarted app with consent already given could not admit a single upload, and a failed or
    /// unavailable fetch would refuse indefinitely.
    ///
    /// This is provenance, not permission: the epoch is stamped on the record so the server can
    /// attribute it. Upload permission is the authenticated account plus the user's own choice
    /// (opt-in and not opted-out/withdrawn), enforced by the queue's account fence and re-checked
    /// server-side. Nothing here may be used to authorise collection.
    var persistedEnrollmentEpochForProvenance: String? {
        lock.lock(); defer { lock.unlock() }
        // Explicit withdrawal turns collection off locally and immediately; an opt-out is the
        // user's own instruction and must stop the upload path without a round trip.
        guard !state.explicitOptOut, state.membership.withdrawalState != .withdrawn else {
            return nil
        }
        return state.membership.enrollmentEpoch
    }

    /// Executes a bounded synchronous publication against one lock-held state/session snapshot.
    /// The callback must not reenter the store. No captured observer payload may publish later.
    func publishCurrentCohortAttributes(_ publish: (String?, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let lifecycle = sessionIdentityProvider()
        let operation = operationGeneration
        let snapshot = state
        guard lifecycle != nil, lifecycle == authoritativeLifecycle, snapshot.hasAuthoritativeProjection,
              lifecycle == sessionIdentityProvider(), operation == operationGeneration else {
            publish(nil, nil)
            return
        }
        publish(snapshot.membership.plan.rawValue, snapshot.effectiveEnrolled ? "true" : "false")
    }

    /// Account-facing display data is authoritative only for the lifecycle that accepted it.
    var currentAuthoritativeState: State? {
        lock.lock(); defer { lock.unlock() }
        guard state.hasAuthoritativeProjection, let lifecycle = sessionIdentityProvider(),
              lifecycle == authoritativeLifecycle else { return nil }
        return state
    }

    // MARK: - Observing

    /// A queued delivery: the transition and the exact subscribers that must receive it.
    ///
    /// THE recipients are frozen when the transition is captured. A subscriber
    /// records the position it registered at, and only transitions strictly after that position are
    /// addressed to it — so pre-subscription history can never be replayed to a newcomer, and a
    /// baseline goes to the new subscriber alone.
    private struct Delivery {
        let transition: Transition
        let recipients: [(Transition) -> Void]
    }

    /// Called after every state change, on the thread that made it. The coordinator uses this to invalidate
    /// an in-flight refresh the moment membership moves.
    ///
    /// BASELINE and subscription are one step: the newcomer's first delivery is a baseline addressed
    /// to itself, queued at its own position. Nothing can precede it, and nothing older can follow it.
    @discardableResult
    func addObserver(_ body: @escaping (Transition) -> Void) -> UUID {
        lock.lock()
        transitionSequence += 1
        let baseline = Transition(
            sequence: transitionSequence,
            state: state,
            accountScope: accountScopeProvider(),
            sessionIdentity: sessionIdentityProvider())
        let id = UUID()
        observers[id] = body
        observerBaselines[id] = transitionSequence
        // ADDRESSED to the new subscriber only, so nobody else sees a duplicate of their own past.
        pendingDeliveries.append(Delivery(transition: baseline, recipients: [body]))
        lock.unlock()
        drain()
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        observerBaselines.removeValue(forKey: id)
        lock.unlock()
    }

    /// Captures the current state as the next transition. The CALLER must already hold `lock`.
    ///
    /// CAPTURE happens inside the mutation'S OWN hold, which is what stops an opt-out being
    /// overtaken: it releases nothing until its snapshot — with its owning account scope — is on
    /// the queue. Recipients are frozen here too, so delivery choices cannot disagree with the
    /// state they belong to.
    private func captureTransitionLocked() {
        transitionSequence += 1
        let transition = Transition(
            sequence: transitionSequence,
            state: state,
            accountScope: accountScopeProvider(),
            sessionIdentity: sessionIdentityProvider())
        var recipients: [(Transition) -> Void] = []
        for (id, body) in observers {
            guard let baseline = observerBaselines[id], transition.sequence > baseline
            else { continue }
            recipients.append(body)
        }
        pendingDeliveries.append(Delivery(transition: transition, recipients: recipients))
    }

    /// Delivers queued transitions in order, holding NO lock while invoking a handler.
    ///
    /// ONE lock for the queue and the ownership flag. Ownership is taken once per
    /// pass and released under that same lock only after the queue is observed empty — so an
    /// enqueue either finds a live drainer (which will see it) or finds the queue itself. A
    /// re-entrant mutation from inside a handler only appends; this loop picks it up. Handlers are
    /// never called with a lock held, so re-entry cannot deadlock.
    private func notify() {
        drain()
    }

    private func drain() {
        lock.lock()
        if draining {
            // The current drainer owns the queue and will deliver ours, in order.
            lock.unlock()
            return
        }
        draining = true
        while true {
            guard !pendingDeliveries.isEmpty else {
                draining = false          // clear ownership before unlocking: no window remains
                lock.unlock()
                return
            }
            let delivery = pendingDeliveries.removeFirst()
            lock.unlock()
            for body in delivery.recipients { body(delivery.transition) }
            lock.lock()
        }
    }

    // MARK: - Local intent

    /// The user's opt-in gesture. Recording it does not enroll anyone: `effectiveEnrolled` also demands a
    /// server projection carrying an epoch and accepted disclosure. Callers must not read `true` back as
    /// permission to collect.
    func setLocalOptIn(_ value: Bool) {
        lock.lock()
        bumpOperationGenerationLocked()
        state.localOptIn = value
        defaults.set(value, forKey: Key.scoped(Key.optIn, scope))
        // EXPLICIT opt-OUT is consent loss; a never-opted-in or default-wiped
        // store is not — unknown consent must retain recordings, never authorize deleting them.
        state.explicitOptOut = !value
        defaults.set(!value, forKey: Key.scoped(Key.optOut, scope))
        captureTransitionLocked()
        lock.unlock()
        notify()
    }

    // MARK: - Authoritative projection

    /// Applies a server projection issued under `token`.
    ///
    /// NO REVISION ordering. `membership_revision` is opaque by contract, so any local comparison would be a
    /// guess — and this guess fails in the dangerous direction: treating a late reply as "not older" and
    /// accepting it can restore permission a user already withdrew. A projection is applied only if the
    /// account/session lifecycle AND the membership-operation generation it was read under are both still
    /// current, so anything fenced since is refused regardless of how its revision is spelled.
    ///
    /// Returns false when refused so callers reconcile with a fresh GET rather than show stale state.
    @discardableResult
    func apply(authoritative projection: VoiceSharingMembership, readUnder token: ProjectionToken) -> Bool {
        lock.lock()
        guard token.lifecycleGeneration == sessionIdentityProvider(),
              token.operationGeneration == operationGeneration else {
            // NO TRANSITION, SO NO NOTIFY — but the lock must still be released, or every later
            // mutation blocks behind a refusal that never took anything.
            lock.unlock()
            return false
        }
        let changed = state.membership != projection || !state.hasAuthoritativeProjection
        state.membership = projection
        state.hasAuthoritativeProjection = true
        authoritativeLifecycle = token.lifecycleGeneration
        persist(projection)
        // IDENTICAL replays announce nothing; a first authority in this session must publish.
        if changed {
            captureTransitionLocked()
            lock.unlock()
            notify()
        } else {
            lock.unlock()
        }
        return true
    }

    /// Identifies the exact instant a projection or mutation was issued. Carried by every request made on
    /// this feature's behalf and checked when its reply lands.
    struct ProjectionToken: Equatable {
        let lifecycleGeneration: String
        let operationGeneration: Int
    }

    /// Current fence value. Call this before issuing a request, never after the reply.
    func projectionToken() -> ProjectionToken? {
        lock.lock()
        let operation = operationGeneration
        lock.unlock()
        guard let lifecycle = sessionIdentityProvider() else { return nil }
        return ProjectionToken(lifecycleGeneration: lifecycle, operationGeneration: operation)
    }

    /// Bumped by every LOCAL membership change (opt-in, withdrawal, account transition), so a reply to a
    /// request issued before the bump is refused even if the server has advanced nothing yet. That is what
    /// makes "user opts out, then a slow old GET arrives" impossible to honour.
    private var operationGeneration: Int = 0

    /// Enrollment as a TRI-STATE for consumers that must not conflate "the server has not told us"
    /// with "not enrolled". `nil` means there is no authoritative projection in
    /// this session — the answer is unknown, not negative.
    var currentEnrollmentAnswer: Bool? {
        lock.lock(); defer { lock.unlock() }
        guard state.hasAuthoritativeProjection else { return nil }
        return state.effectiveEnrolled
    }

    /// The current membership-operation generation. Consumers that must prove several reads belong
    /// to ONE moment (the settings surface) stamp with this: a mutation between their reads bumps it
    /// and the combination is rejected as incoherent.
    var currentEnrollmentGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return operationGeneration
    }

    private func bumpOperationGenerationLocked() { operationGeneration += 1 }

    /// Replaces the projection from a 409 conflict payload. Surfacing the real state is required; the caller
    /// must not auto-replay the opt-in against the newer revision.
    /// A 409 carries the server's current projection. Surfacing it is required; auto-replaying the opt-in
    /// against the newer revision is forbidden, and reconciling happens through a NEW get under a NEW token.
    func applyConflict(current projection: VoiceSharingMembership?, readUnder token: ProjectionToken) {
        guard let projection else { return }
        apply(authoritative: projection, readUnder: token)
    }

    // MARK: - Withdrawal

    /// Stops collection IMMEDIATELY and locally, before any network result, and returns the operation the
    /// caller should send. The returned projection is what the local state now claims; the server reply only
    /// reconciles it.
    ///
    /// This is deliberately not "wait for POST.../withdrawal then clear": a user who opts out must not keep
    /// contributing while a request is in flight or fails.
    func withdrawLocally(acceptedServerProjectionAfterward: Bool) -> VoiceSharingMembership {
        lock.lock()
        // FENCE first: everything issued before this instant becomes inapplicable the moment the user opts
        // out. Ordering matters — bumping after the change would leave a window where a late old reply still
        // matches the old fence value.
        bumpOperationGenerationLocked()
        state.localOptIn = false
        var projected = state.membership
        projected = VoiceSharingMembership(
            membershipRevision: projected.membershipRevision,
            plan: projected.plan,
            voiceSharingEnrolled: false,
            enrollmentEpoch: projected.enrollmentEpoch,
            acceptedDisclosureVersion: projected.acceptedDisclosureVersion,
            withdrawalState: .withdrawn
        )
        state.membership = projected
        defaults.set(false, forKey: Key.scoped(Key.optIn, scope))
        persist(projected)
        captureTransitionLocked()
        lock.unlock()
        notify()
        _ = acceptedServerProjectionAfterward
        return projected
    }

    // MARK: - Account transitions

    /// Sign-out, account switch, or any lifecycle change: forget everything about the departed account.
    /// Collection is impossible afterwards until this account's projection says otherwise AND the user opts in
    /// again — a different account's enrollment never carries over, and neither does its epoch.
    func transitionToAccount(signedIn: Bool) {
        lock.lock()
        bumpOperationGenerationLocked()
        state = State()
        if signedIn {
            // Restore THIS account's remembered intent from disk (never another account's).
            loadForCurrentAccountLocked()
        } else {
            // Signed out: no local intent can matter, and nothing may read as enrolled.
            state.localOptIn = false
        }
        captureTransitionLocked()
        lock.unlock()
        notify()
    }

    // MARK: - Persistence

    private func loadForCurrentAccount() {
        lock.lock(); defer { lock.unlock() }
        loadForCurrentAccountLocked()
    }

    /// Cold start restores the user's OWN intent and the last known display state, and nothing more.
    /// `hasAuthoritativeProjection` stays false, so permission cannot come from disk — only from a reply
    /// received in this session. Keeping the fields loaded (rather than resetting them) means the settings UI
    /// can still show what the server last said while collection remains off until a GET confirms it.
    private func loadForCurrentAccountLocked() {
        let s = scope
        state.localOptIn = defaults.bool(forKey: Key.scoped(Key.optIn, s))
        state.explicitOptOut = defaults.bool(forKey: Key.scoped(Key.optOut, s))
        state.hasAuthoritativeProjection = false
        guard let revision = defaults.string(forKey: Key.scoped(Key.revision, s)), !revision.isEmpty else {
            state.membership = .unavailable
            return
        }
        let withdrawal = VoiceSharingMembership.WithdrawalState(
            rawValue: defaults.string(forKey: Key.scoped(Key.withdrawal, s)) ?? ""
        ) ?? .notEnrolled
        let plan = VoiceSharingMembership.Plan(
            rawValue: defaults.string(forKey: Key.scoped(Key.plan, s)) ?? ""
        ) ?? .free
        state.membership = VoiceSharingMembership(
            membershipRevision: revision,
            plan: plan,
            voiceSharingEnrolled: defaults.bool(forKey: Key.scoped(Key.enrolled, s)),
            enrollmentEpoch: defaults.string(forKey: Key.scoped(Key.epoch, s)),
            acceptedDisclosureVersion: defaults.string(forKey: Key.scoped(Key.disclosure, s)),
            withdrawalState: withdrawal
        )
    }

    private func persist(_ m: VoiceSharingMembership) {
        let s = scope
        defaults.set(m.membershipRevision, forKey: Key.scoped(Key.revision, s))
        defaults.set(m.voiceSharingEnrolled, forKey: Key.scoped(Key.enrolled, s))
        defaults.set(m.plan.rawValue, forKey: Key.scoped(Key.plan, s))
        defaults.set(m.withdrawalState.rawValue, forKey: Key.scoped(Key.withdrawal, s))
        if let epoch = m.enrollmentEpoch { defaults.set(epoch, forKey: Key.scoped(Key.epoch, s)) }
        else { defaults.removeObject(forKey: Key.scoped(Key.epoch, s)) }
        if let d = m.acceptedDisclosureVersion { defaults.set(d, forKey: Key.scoped(Key.disclosure, s)) }
        else { defaults.removeObject(forKey: Key.scoped(Key.disclosure, s)) }
    }
}
