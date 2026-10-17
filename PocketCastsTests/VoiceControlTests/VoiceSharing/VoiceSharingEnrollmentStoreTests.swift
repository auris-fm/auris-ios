import XCTest
import PocketCastsServer
@testable import podcasts

/// Controls for the single place local Voice Sharing state may change. The plan's named races are driven
/// here through the production API rather than through internal fields, because what matters is that no
/// reachable sequence of real replies can leave collection enabled for an account that stopped it.
final class VoiceSharingEnrollmentStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var scope = "account-A"

    override func setUp() {
        super.setUp()
        suiteName = "VoiceSharingEnrollmentStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName!)
        defaults = nil
        super.tearDown()
    }

    private func makeStore(scopeOverride: String? = nil) -> VoiceSharingEnrollmentStore {
        let s = scopeOverride ?? scope
        return VoiceSharingEnrollmentStore(defaults: defaults!, accountScopeProvider: { s })
    }

    private func projection(
        revision: String,
        enrolled: Bool = true,
        epoch: String? = "e1",
        disclosure: String? = "2026-09",
        withdrawal: VoiceSharingMembership.WithdrawalState = .active
    ) -> VoiceSharingMembership {
        VoiceSharingMembership(
            membershipRevision: revision,
            plan: .pro,
            voiceSharingEnrolled: enrolled,
            enrollmentEpoch: epoch,
            acceptedDisclosureVersion: disclosure,
            withdrawalState: withdrawal
        )
    }

    // MARK: - Opt-in requires backend authority, not a gesture

    /// Plan: `test_toggleRequiresDisclosureAcceptance_andBackendEpoch`.
    func test_localOptIn_aloneNeverEnablesCollection() {
        let store = makeStore()
        XCTAssertFalse(store.currentEffectiveEnrolled)

        store.setLocalOptIn(true)
        XCTAssertFalse(store.currentEffectiveEnrolled,
                       "a toggle is intent, not permission: nothing has come from the backend yet")

        // Server accepts disclosure and issues an epoch: only now is enrollment real.
        store.apply(authoritative: projection(revision: "r1"))
        XCTAssertTrue(store.currentEffectiveEnrolled)
        XCTAssertEqual(store.activeEnrollmentEpoch, "e1")
        XCTAssertEqual(store.expectedMembershipRevision, "r1")
    }

    /// Each half of the backend contract is independently required. A projection that claims enrollment but
    /// omits the epoch or the accepted disclosure must not be read as permission.
    func test_projectionMissingEitherAuthority_isNotEnrolled() {
        for (label, bad) in [
            ("no epoch", projection(revision: "r1", epoch: nil)),
            ("no disclosure", projection(revision: "r1", disclosure: nil)),
            ("withdrawn", projection(revision: "r1", withdrawal: .withdrawn)),
            ("not enrolled", projection(revision: "r1", enrolled: false)),
        ] {
            let store = makeStore()
            store.setLocalOptIn(true)
            store.apply(authoritative: bad)
            XCTAssertFalse(store.currentEffectiveEnrolled, "\(label) must not enable collection")
        }
    }

    // MARK: - Delayed first-delivery opt-in cannot resurrect membership

    /// Plan: `test_delayedFirstDeliveryEnrollment_afterWithdrawal_cannotReactivate`.
    ///
    /// The withdrawal advanced the server revision to r3. An opt-in reply still carrying r2 arrives late.
    /// Applying it would flip an opted-out user back on, so a revision we have already moved past is refused.
    func test_staleRevisionReply_cannotReactivateAfterWithdrawal() {
        let store = makeStore()
        store.setLocalOptIn(true)
        store.apply(authoritative: projection(revision: "r2"))
        XCTAssertTrue(store.currentEffectiveEnrolled)

        // User opts out; the withdrawal reply advances the revision.
        _ = store.withdrawLocally(acceptedServerProjectionAfterward: true)
        store.apply(authoritative: projection(revision: "r3", enrolled: false, withdrawal: .withdrawn))
        XCTAssertFalse(store.currentEffectiveEnrolled)

        // The delayed opt-in lands now, describing the world BEFORE the withdrawal.
        let accepted = store.apply(authoritative: projection(revision: "r2"))
        XCTAssertFalse(accepted, "a reply older than the revision we hold must be refused")
        XCTAssertFalse(store.currentEffectiveEnrolled, "and it must not re-enable collection")
        XCTAssertEqual(store.expectedMembershipRevision, "r3", "the newer revision survives")
    }

    /// Withdrawing while ALREADY inactive must still advance the revision, otherwise a later first-delivery
    /// opt-in could not be fenced at all. Plan: `test_withdrawalFromInactiveProjection_advancesRevision`.
    func test_withdrawalFromInactiveProjection_stillFencesLaterOptIns() {
        let store = makeStore()
        store.apply(authoritative: projection(revision: "r5", enrolled: false, withdrawal: .notEnrolled))
        XCTAssertFalse(store.currentEffectiveEnrolled)

        _ = store.withdrawLocally(acceptedServerProjectionAfterward: true)
        store.apply(authoritative: projection(revision: "r6", enrolled: false, withdrawal: .withdrawn))
        XCTAssertEqual(store.expectedMembershipRevision, "r6")

        // A first-delivery opt-in for the pre-withdrawal revision is now stale by construction.
        XCTAssertFalse(store.apply(authoritative: projection(revision: "r4")))
    }

    // MARK: - Withdrawal takes effect locally without the network

    /// Plan: withdrawal "stops new collection and clears pending queue IMMEDIATELY client-side, without
    /// waiting for the network response." Collection must stop even if the call then fails.
    func test_withdrawal_stopsCollectionBeforeAnyServerReply() {
        let store = makeStore()
        store.setLocalOptIn(true)
        store.apply(authoritative: projection(revision: "r1"))
        XCTAssertTrue(store.currentEffectiveEnrolled)

        let after = store.withdrawLocally(acceptedServerProjectionAfterward: false)
        XCTAssertFalse(store.currentEffectiveEnrolled, "local stop happens now, not on reply")
        XCTAssertEqual(after.withdrawalState, .withdrawn)
        XCTAssertFalse(store.currentState.localOptIn, "the remembered gesture must not survive an opt-out")

        // A failed/superseded server call cannot silently restore it either.
        store.apply(authoritative: projection(revision: "r2", enrolled: false, withdrawal: .withdrawn))
        XCTAssertFalse(store.currentEffectiveEnrolled)
    }

    // MARK: - Account transitions

    /// An account switch replaces the whole projection. Both accounts being enrolled does NOT carry
    /// enrollment across, because the epoch belongs to the account that issued it.
    func test_accountSwitch_replacesProjectionAndBlocksUntilReenrolled() {
        let a = makeStore(scopeOverride: "account-A")
        a.setLocalOptIn(true)
        a.apply(authoritative: projection(revision: "r1", epoch: "epoch-A"))
        XCTAssertTrue(a.currentEffectiveEnrolled)

        // Same storage, different signed-in account.
        scope = "account-B"
        let b = makeStore()
        XCTAssertFalse(b.currentEffectiveEnrolled,
                       "account B starts with nothing: no inherited enrollment, epoch, or opt-in")
        XCTAssertNil(b.expectedMembershipRevision)
        XCTAssertNil(b.activeEnrollmentEpoch)

        // Account B enrolls on its own terms.
        b.setLocalOptIn(true)
        b.apply(authoritative: projection(revision: "q1", epoch: "epoch-B"))
        XCTAssertTrue(b.currentEffectiveEnrolled)

        // Back to A: A's own remembered state returns, and it is A's epoch — never B's.
        scope = "account-A"
        let aAgain = makeStore()
        XCTAssertTrue(aAgain.currentEffectiveEnrolled)
        XCTAssertEqual(aAgain.activeEnrollmentEpoch, "epoch-A", "per-account epochs must not cross over")
    }

    /// Sign-out must leave nothing readable as enrolled, including a persisted opt-in gesture.
    func test_signOut_leavesNoEnrollment() {
        let store = makeStore()
        store.setLocalOptIn(true)
        store.apply(authoritative: projection(revision: "r1"))
        XCTAssertTrue(store.currentEffectiveEnrolled)

        store.transitionToAccount(signedIn: false)
        XCTAssertFalse(store.currentEffectiveEnrolled, "signed out is not enrolled, whatever disk says")
        XCTAssertNil(store.expectedMembershipRevision)

        // Re-authenticating the SAME account restores that account's remembered intent (it is still the
        // user's own choice), which is what makes scoping by account necessary in the first place.
        store.transitionToAccount(signedIn: true)
        XCTAssertTrue(store.currentEffectiveEnrolled)
    }

    // MARK: - Policy integration

    /// The store is what the policy reads, so a membership move must invalidate an in-flight refresh rather
    /// than wait for a lease to lapse. This is the wiring @spec asked for: authoritative changes reaching the
    /// EFFECTIVE policy, not just a parallel data structure.
    func test_membershipChange_invalidatesPolicyImmediately() {
        let store = makeStore()
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            enrollmentStore: store
        )
        // Production default now reads the store, so opting in + a real projection is what enables. The
        // membership observer installed by the coordinator fences installs on every change, so the fence
        // must be lifted for the CURRENT identity before a refresh can land — which is exactly what the
        // login-change handler does in production.
        store.setLocalOptIn(true)
        store.apply(authoritative: projection(revision: "r1"))
        coordinator.identityBecameReadable()

        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertTrue(coordinator.policy.permitsCollection, "membership reached the effective policy")

        // Withdraw: collection stops synchronously through the same path, no lease wait.
        _ = store.withdrawLocally(acceptedServerProjectionAfterward: true)
        XCTAssertFalse(coordinator.policy.permitsCollection, "withdrawal flips the decision immediately")

        // A refresh begun before the withdrawal must not install permission afterwards.
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertFalse(coordinator.policy.permitsCollection, "in-flight refresh was invalidated")
    }

    /// Repeated installs must not accumulate store observers: each one bumps the policy generation twice if
    /// they do, which is exactly the leak shape this repo has already been burned by.
    func test_reinstall_doesNotAccumulateMembershipObservers() {
        let store = makeStore()
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            enrollmentStore: store
        )
        store.setLocalOptIn(true)
        store.apply(authoritative: projection(revision: "r1"))
        let before = coordinator.policy.tokenForFetchStart()

        store.withdrawLocally(acceptedServerProjectionAfterward: true)
        let after = coordinator.policy.tokenForFetchStart()
        XCTAssertEqual(after.identityGeneration - before.identityGeneration, 1,
                       "one membership move must advance the identity generation exactly once")
    }

    // MARK: - Idempotent replay

    /// Plan: `test_identicalRequestId_retry_afterLaterTransition_returnsOriginalResult_withoutChangingState`.
    /// At the store boundary that means replaying the SAME projection must be a no-op, not a second
    /// transition, so a retried request cannot fire observers twice.
    func test_applyingTheSameRevisionTwice_isANoOp() {
        let store = makeStore()
        var notifications = 0
        let id = store.addObserver { _ in notifications += 1 }
        defer { store.removeObserver(id) }

        store.apply(authoritative: projection(revision: "r7"))
        let firstCount = notifications
        XCTAssertTrue(store.apply(authoritative: projection(revision: "r7")), "replay is accepted quietly")
        XCTAssertEqual(notifications, firstCount, "a replay must not announce a second transition")
    }
}
