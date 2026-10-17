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
    /// Stands in for the account/session lifecycle generation the real store reads from
    /// VoiceSharingSessionGeneration, so a control can move sessions explicitly.
    private var lifecycle: String? = "gen-1"

    override func setUp() {
        super.setUp()
        suiteName = "VoiceSharingEnrollmentStoreTests-\(UUID().uuidString)"
        lifecycle = "gen-1"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName!)
        defaults = nil
        super.tearDown()
    }

    private func makeStore(scopeOverride: String? = nil) -> VoiceSharingEnrollmentStore {
        let s = scopeOverride ?? scope
        return VoiceSharingEnrollmentStore(
            defaults: defaults!,
            accountScopeProvider: { [weak self] in self?.scope ?? s },
            sessionIdentityProvider: { [weak self] in self?.lifecycle }
        )
    }

    /// Captures the fence value the way a caller MUST: before issuing the request, never after the reply.
    private func token(_ store: VoiceSharingEnrollmentStore) -> VoiceSharingEnrollmentStore.ProjectionToken {
        guard let t = store.projectionToken() else {
            XCTFail("no lifecycle, so no token can be issued")
            return .init(lifecycleGeneration: "", operationGeneration: -1)
        }
        return t
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

        // Server accepts disclosure and issues an epoch: only now is enrollment real. The GET is issued
        // AFTER the opt-in gesture, so its token is taken at that point.
        let getIssuedAfterOptIn = token(store)
        store.apply(authoritative: projection(revision: "r1"), readUnder: getIssuedAfterOptIn)
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
            store.apply(authoritative: bad, readUnder: token(store))
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
        store.apply(authoritative: projection(revision: "r2"), readUnder: token(store))
        XCTAssertTrue(store.currentEffectiveEnrolled)

        // Capture the fence BEFORE opting out: this is the token the delayed opt-in was issued under.
        let stale = token(store)

        // User opts out; the withdrawal reply advances the revision.
        _ = store.withdrawLocally(acceptedServerProjectionAfterward: true)
        store.apply(authoritative: projection(revision: "r3", enrolled: false, withdrawal: .withdrawn), readUnder: token(store))
        XCTAssertFalse(store.currentEffectiveEnrolled)

        // The delayed opt-in lands now. It was issued BEFORE the withdrawal, so it carries the pre-withdrawal
        // token — and that alone refuses it. No comparison of "r2" against "r3" is involved, which matters
        // because the contract makes revisions opaque and nothing here may assume they are orderable.
        let accepted = store.apply(authoritative: projection(revision: "r2"), readUnder: stale)
        XCTAssertFalse(accepted, "a projection issued before the withdrawal must be refused")
        XCTAssertFalse(store.currentEffectiveEnrolled, "and it must not re-enable collection")
        XCTAssertEqual(store.expectedMembershipRevision, "r3", "the newer revision survives")
    }

    /// Withdrawing while ALREADY inactive must still advance the revision, otherwise a later first-delivery
    /// opt-in could not be fenced at all. Plan: `test_withdrawalFromInactiveProjection_advancesRevision`.
    func test_withdrawalFromInactiveProjection_stillFencesLaterOptIns() {
        let store = makeStore()
        let preWithdrawal = token(store)
        store.apply(authoritative: projection(revision: "r5", enrolled: false, withdrawal: .notEnrolled), readUnder: token(store))
        XCTAssertFalse(store.currentEffectiveEnrolled)

        _ = store.withdrawLocally(acceptedServerProjectionAfterward: true)
        store.apply(authoritative: projection(revision: "r6", enrolled: false, withdrawal: .withdrawn), readUnder: token(store))
        XCTAssertEqual(store.expectedMembershipRevision, "r6")

        // A first-delivery opt-in for the pre-withdrawal revision is now stale by construction.
        XCTAssertFalse(store.apply(authoritative: projection(revision: "r4"), readUnder: preWithdrawal))
    }

    // MARK: - Withdrawal takes effect locally without the network

    /// Plan: withdrawal "stops new collection and clears pending queue IMMEDIATELY client-side, without
    /// waiting for the network response." Collection must stop even if the call then fails.
    func test_withdrawal_stopsCollectionBeforeAnyServerReply() {
        let store = makeStore()
        store.setLocalOptIn(true)
        let getIssuedAfterOptIn = token(store)
        store.apply(authoritative: projection(revision: "r1"), readUnder: getIssuedAfterOptIn)
        XCTAssertTrue(store.currentEffectiveEnrolled)

        let after = store.withdrawLocally(acceptedServerProjectionAfterward: false)
        XCTAssertFalse(store.currentEffectiveEnrolled, "local stop happens now, not on reply")
        XCTAssertEqual(after.withdrawalState, .withdrawn)
        XCTAssertFalse(store.currentState.localOptIn, "the remembered gesture must not survive an opt-out")

        // A failed/superseded server call cannot silently restore it either.
        store.apply(authoritative: projection(revision: "r2", enrolled: false, withdrawal: .withdrawn), readUnder: token(store))
        XCTAssertFalse(store.currentEffectiveEnrolled)
    }

    // MARK: - Account transitions

    /// An account switch replaces the whole projection. Both accounts being enrolled does NOT carry
    /// enrollment across, because the epoch belongs to the account that issued it.
    func test_accountSwitch_replacesProjectionAndBlocksUntilReenrolled() {
        let a = makeStore(scopeOverride: "account-A")
        a.setLocalOptIn(true)
        a.apply(authoritative: projection(revision: "r1", epoch: "epoch-A"), readUnder: token(a))
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
        b.apply(authoritative: projection(revision: "q1", epoch: "epoch-B"), readUnder: token(b))
        XCTAssertTrue(b.currentEffectiveEnrolled)

        // Back to A. Cold start restores A's INTENT and last known display state, but permission needs a
        // reply received in THIS session, so enrollment is still off until the GET lands.
        scope = "account-A"
        lifecycle = "gen-2"          // returning to an account is a new session for this feature
        let aAgain = makeStore()
        XCTAssertTrue(aAgain.currentState.localOptIn, "A's own opt-in gesture is remembered")
        XCTAssertFalse(aAgain.currentEffectiveEnrolled, "but a remembered projection is not current-session authority")

        aAgain.apply(authoritative: projection(revision: "r9", epoch: "epoch-A"), readUnder: token(aAgain))
        XCTAssertTrue(aAgain.currentEffectiveEnrolled)
        XCTAssertEqual(aAgain.activeEnrollmentEpoch, "epoch-A", "per-account epochs must not cross over")
    }

    /// Sign-out must leave nothing readable as enrolled, including a persisted opt-in gesture.
    func test_signOut_leavesNoEnrollment() {
        let store = makeStore()
        store.setLocalOptIn(true)
        let getIssuedAfterOptIn = token(store)
        store.apply(authoritative: projection(revision: "r1"), readUnder: getIssuedAfterOptIn)
        XCTAssertTrue(store.currentEffectiveEnrolled)

        store.transitionToAccount(signedIn: false)
        XCTAssertFalse(store.currentEffectiveEnrolled, "signed out is not enrolled, whatever disk says")
        XCTAssertNil(store.expectedMembershipRevision)

        // Re-authenticating the SAME account restores that account's remembered INTENT — the gesture is still
        // the user's own — but not permission: that needs a fresh server reply in the new session.
        store.transitionToAccount(signedIn: true)
        XCTAssertTrue(store.currentState.localOptIn, "the remembered gesture belongs to this account")
        XCTAssertFalse(store.currentEffectiveEnrolled, "intent alone is not authority")
        store.apply(authoritative: projection(revision: "r2"), readUnder: token(store))
        XCTAssertTrue(store.currentEffectiveEnrolled, "and a current-session reply re-enables it")
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
        let getIssuedAfterOptIn = token(store)
        store.apply(authoritative: projection(revision: "r1"), readUnder: getIssuedAfterOptIn)
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
        let getIssuedAfterOptIn = token(store)
        store.apply(authoritative: projection(revision: "r1"), readUnder: getIssuedAfterOptIn)
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

        store.apply(authoritative: projection(revision: "r7"), readUnder: token(store))
        let firstCount = notifications
        // Same revision, same fence: an identical replay must be accepted WITHOUT announcing a transition.
        XCTAssertTrue(store.apply(authoritative: projection(revision: "r7"), readUnder: token(store)),
                      "replay under the current fence is accepted quietly")
        XCTAssertEqual(notifications, firstCount, "a replay must not announce a second transition")
    }

    // MARK: - Opaque revisions (reviewer 4599fb63 / 7897cd94)

    /// The contract makes `membership_revision` OPAQUE. Nothing in the store may compare or order it, so a
    /// reply whose revision looks "older", "newer", or completely unrelated must be judged ONLY by the fence
    /// it was issued under. This drives arbitrary opaque tokens through the real apply path.
    func test_opaqueRevisions_neverDecideAcceptance_theyAreJustData() {
        let store = makeStore()
        store.setLocalOptIn(true)
        let issuedBefore = token(store)

        // Any spelling is accepted when its fence is still current — including one that a numeric heuristic
        // would have called "older".
        XCTAssertTrue(store.apply(authoritative: projection(revision: "01HQZK9F7Q"), readUnder: issuedBefore))
        XCTAssertTrue(store.apply(authoritative: projection(revision: "aaa"), readUnder: token(store)))
        XCTAssertTrue(store.apply(authoritative: projection(revision: "2"), readUnder: token(store)))
        XCTAssertTrue(store.apply(authoritative: projection(revision: "r1"), readUnder: token(store)),
                      "a numerically-smaller token after a larger one is NOT judged by its spelling")

        // And NONE of them survives a local membership move: the fence decides, not the string.
        _ = store.withdrawLocally(acceptedServerProjectionAfterward: false)
        for revision in ["r1", "9999", "zzz-later", "01HQZK9F7Q-NEWER", "", "  "] {
            XCTAssertFalse(store.apply(authoritative: projection(revision: revision), readUnder: issuedBefore),
                           "pre-withdrawal projection \(revision.debugDescription) must be refused")
            XCTAssertFalse(store.currentEffectiveEnrolled,
                           "and none of them may re-enable collection")
        }
    }

    /// Cold start with a remembered ACTIVE projection plus a remembered opt-in, and the session's GET is
    /// delayed (or refused). Collection must stay OFF the whole time; then a current-session reply turns it on.
    func test_coldStart_rememberedActiveProjection_doesNotEnableUntilThisSessionsGET() {
        let sharedSuite = "VoiceSharingColdStart-\(UUID().uuidString)"
        guard let persistent = UserDefaults(suiteName: sharedSuite) else {
            return XCTFail("UserDefaults suite unavailable")
        }
        defer { persistent.removePersistentDomain(forName: sharedSuite) }

        // Session 1: user opts in and the server confirms. Both are persisted.
        let first = VoiceSharingEnrollmentStore(
            defaults: persistent,
            accountScopeProvider: { "account-cold" },
            sessionIdentityProvider: { "session-1" }
        )
        first.setLocalOptIn(true)
        // The confirming GET is issued AFTER the opt-in gesture, so it carries the fence value as of then.
        let firstToken = VoiceSharingEnrollmentStore.ProjectionToken(
            lifecycleGeneration: "session-1",
            operationGeneration: first.projectionToken()?.operationGeneration ?? 0
        )
        XCTAssertTrue(first.apply(authoritative: projection(revision: "r1", epoch: "epoch-1"),
                                  readUnder: firstToken))
        XCTAssertTrue(first.currentEffectiveEnrolled)

        // Session 2: relaunch. Same account, same remembered gesture, nothing fetched yet. Built the same
        // way session 1 was — a fresh instance over the same defaults suite is exactly what a cold start is.
        let relaunched = VoiceSharingEnrollmentStore(
            defaults: persistent,
            accountScopeProvider: { "account-cold" },
            sessionIdentityProvider: { "session-2" }
        )
        XCTAssertTrue(relaunched.currentState.localOptIn, "the user's own gesture is remembered")
        // The remembered projection stays readable for the settings UI, while `expectedMembershipRevision`
        // (which feeds outbound mutations) and permission both stay gated until this session confirms.
        XCTAssertEqual(relaunched.currentState.membership.membershipRevision, "r1",
                       "last known state is still displayable")
        XCTAssertNil(relaunched.expectedMembershipRevision, "not usable as an expected revision for mutations")
        XCTAssertFalse(relaunched.currentEffectiveEnrolled,
                       "but a previous session's projection is NOT this session's permission")

        // While the GET is in flight the feature stays off.
        do {
            let clock = StubMonotonicClock(time: 1_000)
            let coordinator = VoiceSharingCoordinator(
                clock: clock,
                readRemoteSwitch: { .valid(true) },
                enrollmentStore: relaunched
            )
            XCTAssertFalse(coordinator.policy.permitsCollection,
                           "cold start + delayed GET must not collect on remembered state")

            // The GET finally lands for THIS session, under a token taken after the opt-in gesture.
            let issued = token(relaunched)
            relaunched.apply(authoritative: projection(revision: "r2", epoch: "epoch-1"), readUnder: issued)
            XCTAssertTrue(relaunched.currentEffectiveEnrolled)
            // Activation makes the identity readable and a FRESH fetch must actually move the SDK's own
            // timestamp, or the install is refused as cached.
            coordinator.identityBecameReadable()
            let installed = coordinator.policy.refreshAfterActivation(
                freshActivationSucceeded: true,
                fetchToken: coordinator.policy.tokenForFetchStart()
            )
            XCTAssertNotNil(installed)
            XCTAssertTrue(coordinator.policy.permitsCollection, "only now does collection become permitted")
        }

        // A refused GET keeps it off.
        let thirdSession = VoiceSharingEnrollmentStore(
            defaults: persistent,
            accountScopeProvider: { "account-cold" },
            sessionIdentityProvider: { "session-3" }
        )
        XCTAssertFalse(thirdSession.currentEffectiveEnrolled, "relaunch into a session where GET fails stays off")
    }

    /// A projection issued under a DIFFERENT account/session lifecycle is refused even if the store otherwise
    /// agrees — the half a revision comparison could never supply.
    func test_projectionFromAnotherSession_isRefused() {
        let store = makeStore()
        store.setLocalOptIn(true)
        let otherSession = VoiceSharingEnrollmentStore.ProjectionToken(
            lifecycleGeneration: "some-other-session",
            operationGeneration: store.projectionToken()?.operationGeneration ?? 0
        )
        XCTAssertFalse(store.apply(authoritative: projection(revision: "r1"), readUnder: otherSession),
                       "a projection read under another lifecycle cannot authorize this session")
        XCTAssertFalse(store.currentEffectiveEnrolled)

        // Sign-out mid-flight: the outstanding token stops matching because the lifecycle disappears.
        let outstanding = token(store)
        lifecycle = nil
        XCTAssertFalse(store.apply(authoritative: projection(revision: "r1", enrolled: true), readUnder: outstanding),
                       "a reply to a request issued before sign-out must not land after it")
    }

    // MARK: - Enroll → fresh activation → permitted (reviewer 7897cd94)

    /// The defect this closes: every membership notification used to raise the policy's identity fence, and
    /// only a later login cleared it — so after a SUCCESSFUL enroll nothing could install until the user
    /// signed out and back in. Opt-in would have looked like a no-op forever. Drives the production switch
    /// decoder plus the real store, with no test-local permission stub.
    func test_successfulEnrollment_freshActivationInstallsAndPermits() {
        let store = makeStore()
        let clock = StubMonotonicClock(time: 1_000)
        // Production's own extraction path: raw published bytes + source, never a test-supplied bool.
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            valueSource: { VoiceSharingCoordinator.RemoteValueSource(data: Data("true".utf8), sourceIsRemote: true) },
            enrollmentStore: store
        )

        // Before any gesture: off.
        XCTAssertFalse(coordinator.policy.permitsCollection)

        // User opts in; the confirming GET is issued after that gesture.
        store.setLocalOptIn(true)
        let issued = token(store)
        XCTAssertTrue(store.apply(authoritative: projection(revision: "opaque-1"), readUnder: issued))
        XCTAssertTrue(store.currentEffectiveEnrolled, "membership authority exists")

        // Fresh activation for the CURRENT session installs against it — the point the old fence blocked.
        coordinator.identityBecameReadable()
        let installed = coordinator.policy.refreshAfterActivation(
            freshActivationSucceeded: true,
            fetchToken: coordinator.policy.tokenForFetchStart()
        )
        XCTAssertNotNil(installed, "a successful enrollment must be able to activate")
        XCTAssertTrue(coordinator.policy.permitsCollection, "and activation must actually permit collection")
    }

    /// The other half of the split: WITHDRAWAL disables immediately, and stays disabled even if a refresh
    /// succeeds afterwards under the departed membership.
    func test_withdrawal_disablesImmediatelyAndSurvivesALaterRefresh() {
        let store = makeStore()
        let clock = StubMonotonicClock(time: 1_000)
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            valueSource: { VoiceSharingCoordinator.RemoteValueSource(data: Data("true".utf8), sourceIsRemote: true) },
            enrollmentStore: store
        )
        store.setLocalOptIn(true)
        store.apply(authoritative: projection(revision: "opaque-1"), readUnder: token(store))
        coordinator.identityBecameReadable()
        _ = coordinator.policy.refreshAfterActivation(
            freshActivationSucceeded: true,
            fetchToken: coordinator.policy.tokenForFetchStart()
        )
        XCTAssertTrue(coordinator.policy.permitsCollection, "enabled before opting out")

        _ = store.withdrawLocally(acceptedServerProjectionAfterward: false)
        XCTAssertFalse(coordinator.policy.permitsCollection, "opting out stops collection right now")

        // A refresh that lands afterwards cannot resurrect it. The remote switch is genuinely ON, so a
        // snapshot does install — what keeps collection off is that `permitsCollection` RE-READS membership at
        // decision time instead of trusting the value folded in at install. Asserting nil here would have
        // encoded the wrong rule; asserting this pins the actual mechanism.
        _ = coordinator.policy.refreshAfterActivation(
            freshActivationSucceeded: true,
            fetchToken: coordinator.policy.tokenForFetchStart()
        )
        XCTAssertFalse(coordinator.policy.permitsCollection,
                       "a remote-only permission must not collect for an account that withdrew")
    }

    /// Sign-out is the ONE transition that does fence: without it, a stale fetch could install permission for
    /// an account that is no longer readable.
    func test_signOut_fencesInstallsUntilANewLogin() {
        let store = makeStore()
        let clock = StubMonotonicClock(time: 1_000)
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            valueSource: { VoiceSharingCoordinator.RemoteValueSource(data: Data("true".utf8), sourceIsRemote: true) },
            enrollmentStore: store
        )
        store.setLocalOptIn(true)
        store.apply(authoritative: projection(revision: "opaque-1"), readUnder: token(store))
        coordinator.identityBecameReadable()
        _ = coordinator.policy.refreshAfterActivation(
            freshActivationSucceeded: true,
            fetchToken: coordinator.policy.tokenForFetchStart()
        )
        XCTAssertTrue(coordinator.policy.permitsCollection)

        lifecycle = nil
        store.transitionToAccount(signedIn: false)
        coordinator.policy.raiseIdentityFence()
        XCTAssertFalse(coordinator.policy.permitsCollection, "signed out collects nothing")

        // A refresh attempted while the fence is up is refused...
        let fenced = coordinator.policy.refreshAfterActivation(
            freshActivationSucceeded: true,
            fetchToken: coordinator.policy.tokenForFetchStart()
        )
        XCTAssertNil(fenced, "an unresolved identity transition must not install")

        // ...and only a new login plus re-enrollment restores it.
        lifecycle = "gen-2"
        coordinator.identityBecameReadable()
        store.setLocalOptIn(true)
        store.apply(authoritative: projection(revision: "opaque-2"), readUnder: token(store))
        XCTAssertNotNil(coordinator.policy.refreshAfterActivation(
            freshActivationSucceeded: true,
            fetchToken: coordinator.policy.tokenForFetchStart()
        ), "a new session can activate once membership is re-established")
        XCTAssertTrue(coordinator.policy.permitsCollection)
    }

    /// Direct control on the split itself, with no coordinator involved: a MEMBERSHIP change must not fence,
    /// an IDENTITY transition must. The coordinator routes these two kinds through different call sites, so
    /// an end-to-end test alone cannot tell "membership wrongly fenced" apart from "sign-out correctly
    /// fenced" — this can.
    func test_invalidationKinds_membershipDoesNotFence_identityDoes() {
        let policy = VoiceSharingPolicy(clock: StubMonotonicClock(time: 1_000), readRemoteSwitch: { .valid(true) }) { false }

        // Membership move inside the current session: snapshot drops, installs stay available.
        policy.invalidateForIdentityChange(kind: .membershipChange)
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()),
                        "a membership change must leave the feature able to activate")

        // Identity transition with no readable account yet: installs are refused until one appears.
        policy.invalidateForIdentityChange(kind: .identityTransition)
        XCTAssertNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()),
                     "an unresolved identity transition must fence installs")

        // And the fence is lifted by exactly one thing: the new account state becoming readable.
        policy.identityBecameReadable()
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()),
                        "login clears the fence")
    }
}
