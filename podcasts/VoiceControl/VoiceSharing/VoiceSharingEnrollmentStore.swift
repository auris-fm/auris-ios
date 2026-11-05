import Foundation
import PocketCastsServer

/// Backend-authoritative Voice Sharing membership, and the single place local state is allowed to change.
///
/// Why a store exists at all: the policy asks `isAccountEnrolled()` at decision time, but that question has
/// exactly one honest answer source — the server projection. Nothing else on the device may claim
/// enrollment, including a locally flipped toggle, so this type owns the fold:
///
///   * `effectiveEnrolled` is **server state AND the user's local intent**, never either alone. A remote
///     switch or a UI gesture cannot enable collection by itself; the backend epoch must back it.
///   * NOTHING orders or compares `membership_revision`: the contract makes it opaque, so any local
///     comparison would be a guess that fails toward re-enabling a user who already withdrew. Instead every
///     read and mutation is stamped with a `ProjectionToken` captured BEFORE the request — the account/session
///     lifecycle plus a membership-operation counter — and a reply may only be applied while BOTH still match
///     the live session. The counter bumps on each local membership move, so a delayed opt-in cannot
///     resurrect membership after a withdrawal however its revision is spelled.
///   * Withdrawal takes effect LOCALLY and immediately — new collection stops without waiting for the
///     network — because "the user said stop" must not depend on a round trip. The server call still runs,
///     and its result only reconciles; it is never what stops collection.
///   * Account transitions replace the whole projection. An account switch cannot inherit the previous
///     account's enrollment, even if both are enrolled, because the epochs belong to different accounts.
///
/// Storage: app-private `UserDefaults`, opaque values only (revision/epoch/disclosure version as received).
/// It deliberately does NOT store audio, transcripts, or credentials, and it is not the durable contribution
/// queue — purging queued audio is Task 6's job and must run through `transitionToAccount` / `withdraw` here
/// so both use one production transition rather than two divergent notions of "stopped".
final class VoiceSharingEnrollmentStore {
    static let shared = VoiceSharingEnrollmentStore()

    /// What the policy reads at decision time.
    /// ONE STATE CHANGE, WITH THE ACCOUNT MOMENT IT BELONGS TO (spec 8a9c057f).
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
        /// True only once a projection has been ACCEPTED FROM THE SERVER IN THIS SESSION. Loading disk can
        /// never set it: a remembered active epoch plus a remembered opt-in is not permission, because the
        /// account may have withdrawn on another device, been disabled server-side, or the process may simply
        /// have restarted into a state the server no longer recognises. Until a current-session reply lands,
        /// `effectiveEnrolled` is false and collection stays off.
        var hasAuthoritativeProjection = false
        /// True only when the USER turned sharing off. A fresh or default-wiped store is false:
        /// unknown consent retains recordings (spec e1529db9).
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
    private var observers: [UUID: (Transition) -> Void] = [:]
    /// Monotonic position in the state's history. Every mutation bumps it under the state lock, so
    /// two transitions can never claim the same position or be delivered out of order.
    private var transitionSequence: Int = 0
    /// TRANSITIONS AWAITING DELIVERY, captured at the mutation and drained in sequence order.
    /// Held by `lock`; drained by whichever thread currently owns `draining`.
    private var pendingTransitions: [Transition] = []
    /// The single-drainer gate. An observer that mutates the store re-enters a mutator, which
    /// enqueues and then tries to drain; it must NOT take the drainer (it is on the draining
    /// thread) and must NOT wait for it — the outer drain picks its transition up. Nothing is ever
    /// delivered while either `lock` or this lock is held.
    private let drainStateLock = NSLock()
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
    /// ORDINARY ACCOUNT OWNERSHIP (spec 4afc6e43): the lifecycle a projection was read under is the
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

    /// SPEC e1529db9: true when CONSENT IS GONE — the user opted out locally, the account
    /// withdrew, or there is no session. Only this may authorize purging durable recordings;
    /// temporary gate loss (policy flap, network, listening) must retain them.
    var consentGoneForPurge: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.explicitOptOut
            || state.membership.withdrawalState == .withdrawn
    }

    /// ONE CONSENT DECISION for capture AND upload (reviewer ee48cdfe): the ordinary session,
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

    /// Called after every state change, on the thread that made it. The coordinator uses this to invalidate
    /// an in-flight refresh the moment membership moves.
    @discardableResult
    func addObserver(_ body: @escaping (Transition) -> Void) -> UUID {
        lock.lock()
        let id = UUID()
        // THE BASELINE AND THE SUBSCRIPTION ARE TAKEN UNDER ONE LOCK (spec 8a9c057f). Reading the
        // state and the scope, releasing, then registering left a window in which a withdrawal
        // could land: it was already inside the baseline, so the coordinator's first comparison
        // found "no change" and the loss was never reported. Here the caller's baseline IS the
        // snapshot the store is currently on, and every later change is queued to it by sequence.
        let baseline = Transition(
            sequence: transitionSequence,
            state: state,
            accountScope: accountScopeProvider(),
            sessionIdentity: sessionIdentityProvider())
        // THE BASELINE JOINS THE SAME ORDERING AS EVERY LATER TRANSITION. It is appended to the
        // pending queue at its own position while the state lock is held, and the subscriber is
        // registered before it can be delivered — so the first transition the handler sees is the
        // state at subscription, and no later change can overtake it.
        transitionSequence += 1
        pendingTransitions.append(Transition(
            sequence: transitionSequence,
            state: baseline.state,
            accountScope: baseline.accountScope,
            sessionIdentity: baseline.sessionIdentity))
        observers[id] = body
        lock.unlock()
        drainTransitions()
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock(); observers.removeValue(forKey: id); lock.unlock()
    }

    /// Publishes one state change to every observer, IN MUTATION ORDER.
    ///
    /// A transition is captured UNDER THE STATE LOCK, at the moment of the mutation, together with
    /// the account scope and session it belongs to — so the snapshot, its owner and its position
    /// cannot disagree (spec 8a9c057f). Delivery then happens outside the lock, so a reentrant
    /// handler cannot deadlock the store.
    ///
    /// ORDER IS PRESERVED, not merely protected: delivery is serialised by `deliveryLock`, and an
    /// observer that is handed an older sequence than one it already held DISCARDS it. Without
    /// this, an opt-out and a later opt-in racing on two threads could both be captured as
    /// "permitted" (each taking its snapshot after the other's mutation), and the loss would never
    /// be reported — a lost withdrawal is the failure direction that matters here.
    /// Captures the current state as the next transition and drains the queue.
    ///
    /// TWO SEPARATE GUARANTEES, both required (spec 8a9c057f, reviewer 33a2a287):
    ///
    /// 1. CAPTURE HAPPENS UNDER THE MUTATION'S OWN LOCK. An opt-out that released the lock before
    ///    capturing could be overtaken by a later opt-in, and both snapshots would then read
    ///    "permitted" — the loss would never be announced. Callers therefore capture INSIDE their
    ///    mutation's hold (`captureTransitionLocked()`), never after releasing it.
    /// 2. DELIVERY HAPPENS OUTSIDE EVERY LOCK, IN ORDER, ON ONE DRAINER. A handler may mutate the
    ///    store; if delivery held a lock across the call, that re-entry would deadlock. Instead
    ///    transitions queue up and a single owner drains them; a re-entrant mutator only enqueues.
    private func captureTransitionLocked() {
        transitionSequence += 1
        pendingTransitions.append(Transition(
            sequence: transitionSequence,
            state: state,
            accountScope: accountScopeProvider(),
            sessionIdentity: sessionIdentityProvider()))
    }

    /// Drains queued transitions to every observer, in sequence order, holding nothing.
    private func drainTransitions() {
        drainStateLock.lock()
        if draining {
            // Someone is already delivering on another thread: it will pick ours up, in order.
            drainStateLock.unlock()
            return
        }
        draining = true
        drainStateLock.unlock()
        while true {
            lock.lock()
            let next = pendingTransitions.isEmpty ? nil : pendingTransitions.removeFirst()
            let list = Array(observers.values)
            lock.unlock()
            guard let transition = next else { break }
            for body in list { body(transition) }
        }
        drainStateLock.lock()
        draining = false
        drainStateLock.unlock()
    }

    /// Convenience for the mutators: notify after their state change, having already captured.
    private func notify() {
        drainTransitions()
    }

    // MARK: - Local intent

    /// The user's opt-in gesture. Recording it does NOT enroll anyone: `effectiveEnrolled` also demands a
    /// server projection carrying an epoch and accepted disclosure. Callers must not read `true` back as
    /// permission to collect.
    func setLocalOptIn(_ value: Bool) {
        lock.lock()
        bumpOperationGenerationLocked()
        state.localOptIn = value
        defaults.set(value, forKey: Key.scoped(Key.optIn, scope))
        // EXPLICIT OPT-OUT is consent loss (spec e1529db9); a never-opted-in or default-wiped
        // store is NOT — unknown consent must retain recordings, never authorize deleting them.
        state.explicitOptOut = !value
        defaults.set(!value, forKey: Key.scoped(Key.optOut, scope))
        captureTransitionLocked()
        lock.unlock()
        notify()
    }

    // MARK: - Authoritative projection

    /// Applies a server projection issued under `token`.
    ///
    /// NO REVISION ORDERING. `membership_revision` is opaque by contract, so any local comparison would be a
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
            lock.unlock()
            return false
        }
        let changed = state.membership != projection || !state.hasAuthoritativeProjection
        state.membership = projection
        state.hasAuthoritativeProjection = true
        authoritativeLifecycle = token.lifecycleGeneration
        persist(projection)
        // IDENTICAL REPLAYS ANNOUNCE NOTHING; a first authority in this session must publish.
        if changed { captureTransitionLocked() }
        lock.unlock()
        if changed { notify() }
        return true
    }

    /// Identifies the exact instant a projection or mutation was issued. Carried by every request made on
    /// this feature's behalf and checked when its reply lands.
    struct ProjectionToken: Equatable {
        let lifecycleGeneration: String
        let operationGeneration: Int
    }

    /// Current fence value. Call this BEFORE issuing a request, never after the reply.
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
    /// with "not enrolled" (reviewer 05aaaedc). `nil` means there is no authoritative projection in
    /// this session — the answer is unknown, not negative.
    var currentEnrollmentAnswer: Bool? {
        lock.lock(); defer { lock.unlock() }
        guard state.hasAuthoritativeProjection else { return nil }
        return state.effectiveEnrolled
    }

    /// The current membership-operation generation. Consumers that must prove several reads belong
    /// to ONE moment (the settings surface) stamp with this: a mutation between their reads bumps it
    /// and the combination is rejected as incoherent (reviewer e40508a1).
    var currentEnrollmentGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return operationGeneration
    }

    private func bumpOperationGenerationLocked() { operationGeneration += 1 }

    /// Replaces the projection from a 409 conflict payload. Surfacing the real state is required; the caller
    /// must NOT auto-replay the opt-in against the newer revision.
    /// A 409 carries the server's current projection. Surfacing it is required; auto-replaying the opt-in
    /// against the newer revision is forbidden, and reconciling happens through a NEW GET under a NEW token.
    func applyConflict(current projection: VoiceSharingMembership?, readUnder token: ProjectionToken) {
        guard let projection else { return }
        apply(authoritative: projection, readUnder: token)
    }

    // MARK: - Withdrawal

    /// Stops collection IMMEDIATELY and locally, before any network result, and returns the operation the
    /// caller should send. The returned projection is what the local state now claims; the server reply only
    /// reconciles it.
    ///
    /// This is deliberately not "wait for POST .../withdrawal then clear": a user who opts out must not keep
    /// contributing while a request is in flight or fails.
    func withdrawLocally(acceptedServerProjectionAfterward: Bool) -> VoiceSharingMembership {
        lock.lock()
        // FENCE FIRST: everything issued before this instant becomes inapplicable the moment the user opts
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

    /// Cold start restores the user's OWN INTENT and the last known display state, and nothing more.
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
