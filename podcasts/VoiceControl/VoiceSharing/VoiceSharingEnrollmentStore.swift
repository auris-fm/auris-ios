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
///   * Transitions are ordered by the server's `membership_revision`. A reply from an older revision than
///     what we already hold is dropped rather than applied, which is what makes a delayed first-delivery
///     opt-in unable to resurrect membership after a withdrawal.
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
    struct State: Equatable {
        var membership: VoiceSharingMembership = .unavailable
        /// The user's own opt-in gesture, persisted so a launch does not silently re-enable something they
        /// turned off. Never sufficient on its own — see `effectiveEnrolled`.
        var localOptIn = false
        /// True once a projection has actually been read from the server this session. Before that,
        /// `membership` is `.unavailable`, which must not be confused with "confirmed not enrolled".
        var hasAuthoritativeProjection = false

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
    private var observers: [UUID: (State) -> Void] = [:]

    private enum Key {
        static func scoped(_ base: String, _ accountScope: String) -> String { "\(base).\(accountScope)" }
        static let optIn = "VoiceSharing.localOptIn"
        static let revision = "VoiceSharing.membershipRevision"
        static let enrolled = "VoiceSharing.serverEnrolled"
        static let epoch = "VoiceSharing.enrollmentEpoch"
        static let disclosure = "VoiceSharing.acceptedDisclosureVersion"
        static let withdrawal = "VoiceSharing.withdrawalState"
        static let plan = "VoiceSharing.plan"
    }

    init(
        defaults: UserDefaults = .standard,
        accountScopeProvider: @escaping () -> String = VoiceSharingEnrollmentStore.currentAccountScope
    ) {
        self.defaults = defaults
        self.accountScopeProvider = accountScopeProvider
        loadForCurrentAccount()
    }

    /// Membership is per-account. Keying storage by the signed-in account means signing into a different
    /// account cannot read the previous account's enrollment out of disk, and signing back in restores the
    /// user's own prior intent rather than resetting it.
    private let accountScopeProvider: () -> String
    private static func currentAccountScope() -> String {
        // Fail closed to an unscoped-but-stable label when nothing is authenticated.
        ServerSettings.userId ?? "signed-out"
    }

    private var scope: String { accountScopeProvider() }

    // MARK: - Reading

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

    // MARK: - Observing

    /// Called after every state change, on the thread that made it. The coordinator uses this to invalidate
    /// an in-flight refresh the moment membership moves.
    @discardableResult
    func addObserver(_ body: @escaping (State) -> Void) -> UUID {
        lock.lock()
        let id = UUID()
        observers[id] = body
        lock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock(); observers.removeValue(forKey: id); lock.unlock()
    }

    private func notify() {
        lock.lock()
        let snapshot = state
        let list = Array(observers.values)
        lock.unlock()
        for body in list { body(snapshot) }
    }

    // MARK: - Local intent

    /// The user's opt-in gesture. Recording it does NOT enroll anyone: `effectiveEnrolled` also demands a
    /// server projection carrying an epoch and accepted disclosure. Callers must not read `true` back as
    /// permission to collect.
    func setLocalOptIn(_ value: Bool) {
        lock.lock()
        state.localOptIn = value
        defaults.set(value, forKey: Key.scoped(Key.optIn, scope))
        lock.unlock()
        notify()
    }

    // MARK: - Authoritative projection

    /// Applies a server projection, honouring revision ordering.
    ///
    /// Rejects a projection whose revision is one we have already applied: replaying an older revision would
    /// let a delayed first-delivery opt-in land AFTER a withdrawal and flip membership back on. Returns false
    /// when the update was refused so callers can surface a conflict instead of showing stale state.
    @discardableResult
    func apply(authoritative projection: VoiceSharingMembership) -> Bool {
        lock.lock()
        guard shouldAccept(projection) else {
            lock.unlock()
            return false
        }
        let changed = state.membership != projection
        state.membership = projection
        state.hasAuthoritativeProjection = true
        persist(projection)
        lock.unlock()
        // An identical replay announces nothing: a retried request must not look like a second transition.
        if changed { notify() }
        return true
    }

    /// Revision ordering, enforced locally because the server's revision is the only sequence available.
    /// `membership_revision` is opaque, but it advances monotonically per applied mutation, so any reply we
    /// have already moved past is stale by construction — that is precisely what makes a delayed
    /// first-delivery opt-in unable to reactivate a user who withdrew in the meantime.
    private func shouldAccept(_ incoming: VoiceSharingMembership) -> Bool {
        guard state.hasAuthoritativeProjection else { return true }
        let held = state.membership.membershipRevision
        guard !held.isEmpty, !incoming.membershipRevision.isEmpty else { return true }
        if held == incoming.membershipRevision { return true }   // idempotent replay of the same state
        guard let incomingOrder = Self.revisionOrder(incoming.membershipRevision),
              let heldOrder = Self.revisionOrder(held) else {
            return true   // unorderable tokens: accept rather than silently dropping a real projection
        }
        return incomingOrder >= heldOrder
    }

    /// Numeric ordering over an opaque revision string. The contract publishes revisions as short tokens
    /// whose trailing integer increases (`r1`, `r2`, …); anything without a trailing number cannot be
    /// ordered, and is accepted rather than guessed at — refusing unorderable revisions would drop valid
    /// projections, which fails worse than accepting one extra update.
    static func revisionOrder(_ revision: String) -> Int? {
        guard let split = revision.split(whereSeparator: { !$0.isNumber }).last,
              let value = Int(split) else { return nil }
        return value
    }

    /// Replaces the projection from a 409 conflict payload. Surfacing the real state is required; the caller
    /// must NOT auto-replay the opt-in against the newer revision.
    func applyConflict(current projection: VoiceSharingMembership?) {
        guard let projection else { return }
        apply(authoritative: projection)
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
        state = State()
        if signedIn {
            // Restore THIS account's remembered intent from disk (never another account's).
            loadForCurrentAccountLocked()
        } else {
            // Signed out: no local intent can matter, and nothing may read as enrolled.
            state.localOptIn = false
        }
        lock.unlock()
        notify()
    }

    // MARK: - Persistence

    private func loadForCurrentAccount() {
        lock.lock(); defer { lock.unlock() }
        loadForCurrentAccountLocked()
    }

    private func loadForCurrentAccountLocked() {
        let s = scope
        state.localOptIn = defaults.bool(forKey: Key.scoped(Key.optIn, s))
        guard let revision = defaults.string(forKey: Key.scoped(Key.revision, s)), !revision.isEmpty else {
            state.membership = .unavailable
            state.hasAuthoritativeProjection = false
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
        state.hasAuthoritativeProjection = true
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
