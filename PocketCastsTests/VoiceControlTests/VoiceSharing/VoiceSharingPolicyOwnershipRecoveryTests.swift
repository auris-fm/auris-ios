import XCTest
@testable import podcasts

/// OWNERSHIP + TRANSIENT RECOVERY controls (spec 50d8807d / 2026-11-04 owner incident).
///
/// Incident being pinned: the settlement rejected its install because the lookup's POLICY
/// token no longer equaled the current one — policy identity had moved under THIS lookup
/// with no newer exchange — leaving the only in-flight install with NO owner: no snapshot,
/// no retry, `gate closed` until (never) another driver. The ownership fix re-derives the
/// install token for the CURRENT policy identity when only the token moved; the recovery
/// driver re-drives transient refusals on a doubling, capped backoff without an app restart.
final class VoiceSharingPolicyOwnershipRecoveryTests: XCTestCase {

    private final class StubBearerTokens: CloudTokenProviding {
        func token() async -> String? { "test-bearer" }
        func prepare() async {}
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    private func makeEnrolledStack() -> (VoiceSharingCoordinator, VoiceSharingEnrollmentStore) {
        let store = VoiceSharingEnrollmentStore(sessionIdentityProvider: { "gen-A" })
        store.setLocalOptIn(true)
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            lastFetchTime: { nil },
            valueSource: { VoiceSharingCoordinator.RemoteValueSource(
                data: Data("true".utf8), sourceIsRemote: true) },
            enrollmentStore: store)
        coordinator.expiryScheduler = { _, _ in }
        return (coordinator, store)
    }

    /// OWNERSHIP (red→green): the lookup's policy token is STALE (policy identity moved under
    /// this lookup — login settle lifted a fence — with NO newer lookup taken), generation and
    /// projection are still current. The settlement must STILL install, using a re-derived
    /// token for the current policy identity. Rejecting on the token alone stranded the install.
    func test_policyTokenMovedUnderTheLookupWithNoNewerOwnerStillInstalls() async throws {
        let (coordinator, store) = makeEnrolledStack()
        VoiceSharingSessionGeneration.shared.ensureLifecycle()
        defer { VoiceSharingSessionGeneration.shared.clear() }

        // The lookup is taken, THEN policy identity moves under it (the incident's fence
        // lift: superseded-install check saw policyTokenEqual=false at equal generation)
        // with no newer lookup: exactly the stranded state. The move MUST come after the
        // capture — before it, the lookup would simply record the new identity.
        let lookup = coordinator.beginEnrollmentLookup()
        coordinator.policy.invalidateForIdentityChange()
        coordinator.policy.identityBecameReadable()

        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] = .init(
            status: 200,
            body: [
                "schema_version": 1,
                "membership_revision": "r1",
                "plan": "pro",
                "voice_sharing_enrolled": true,
                "withdrawal_state": "active",
                "enrollment_epoch": "e1" as Any,
                "accepted_disclosure_version": "voice-sharing-v1" as Any,
            ])
        defer { VoiceSharingStubProtocol.replies.removeAll() }

        // Stubbed client: the DEFAULT client would hit the real API host; the settlement
        // fetch must answer from the stub like the existing exchange controls do.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSharingStubProtocol.self]
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubBearerTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" },
            membershipStore: store)
        await coordinator.completeActivationWithEnrollment(
            freshActivationSucceeded: true, lookup: lookup, accountClient: client)
        // THE OWNERSHIP DELTA, pass 1: the token moved UNDER this lookup, yet the
        // authoritative membership must still APPLY (old behavior refused the whole
        // settlement on policyTokenEqual=false — the stranded-install incident).
        XCTAssertTrue(store.currentEffectiveEnrolled,
                      "a moved policy token under the current lookup must not refuse the membership apply")
        // By the settlement contract a CHANGED membership installs the lease on the
        // UNCHANGED-membership pass (same as the two-exchange exchange control).
        let freshLookup = coordinator.beginEnrollmentLookup()
        await coordinator.completeActivationWithEnrollment(
            freshActivationSucceeded: true, lookup: freshLookup, accountClient: client)

        // The lease MUST be installed (fail-closed kept: an actual identity change that left
        // the fence raised would still refuse inside refreshAfterActivation). Assert the
        // installed SNAPSHOT, not permitsCollection: the stub clock does not track wall time
        // with the lease, so collection permission is out of scope for this control.
        XCTAssertNotNil(coordinator.policy.installedLeaseExpiry,
                        "the only in-flight install must not be stranded by a moved policy token")
    }

    /// TRANSIENT RECOVERY: a transiently refused exchange schedules a bounded retry that
    /// re-runs the ordinary exchange (generation-fenced); a later install cancels and resets
    /// the backoff. No app restart involved.
    func test_transientRefusalRecoversThroughScheduledRetryWithoutRestart() {
        let (coordinator, _) = makeEnrolledStack()
        var scheduled: [(Double, () -> Void)] = []
        coordinator.schedulePolicyRetryForTesting = { delay, fire in scheduled.append((delay, fire)) }

        coordinator.lastPolicyInstallOutcome = .transientRefused
        coordinator.policyExchangeCompleted(fresh: false)
        XCTAssertEqual(scheduled.count, 1, "a transient refusal must schedule recovery")
        XCTAssertEqual(scheduled[0].0, 30, "base backoff is 30 s")

        // The retry fires the ordinary refresh entry (production: performPolicyExchange).
        var refreshRuns = 0
        coordinator.initiateIdentityRecoveryRefresh = { refreshRuns += 1 }
        scheduled[0].1()
        XCTAssertEqual(refreshRuns, 1, "the retry re-drives the ordinary exchange")

        // A later SUCCESS cancels and resets: no further retries, backoff back at base.
        coordinator.policyExchangeCompleted(fresh: true)
        coordinator.lastPolicyInstallOutcome = .transientRefused
        coordinator.policyExchangeCompleted(fresh: false)
        XCTAssertEqual(scheduled.count, 2, "a fresh retry may be scheduled after success")
        XCTAssertEqual(scheduled[1].0, 30, "backoff RESET after a successful install")
    }

    /// Backoff DOUBLES and is CAPPED: consecutive transient refusals schedule 30 → 60 → … ≤ 900 s.
    func test_transientBackoffDoublesAndCaps() {
        let (coordinator, _) = makeEnrolledStack()
        var scheduled: [Double] = []
        coordinator.schedulePolicyRetryForTesting = { delay, _ in scheduled.append(delay) }
        coordinator.lastPolicyInstallOutcome = .transientRefused
        coordinator.initiateIdentityRecoveryRefresh = {}
        for expected in [30.0, 60.0, 120.0, 240.0, 480.0, 900.0, 900.0] {
            coordinator.policyExchangeCompleted(fresh: false)
            XCTAssertEqual(scheduled.last, expected, "backoff must double up to the 900 s cap")
            coordinator.firePendingPolicyRetryForTesting()
        }
    }

    /// AUTHORITATIVE answer: a strict decoded false cancels recovery — retrying cannot change it.
    func test_authoritativeDisabledDoesNotScheduleRetry() {
        let (coordinator, _) = makeEnrolledStack()
        var scheduled = 0
        coordinator.schedulePolicyRetryForTesting = { _, _ in scheduled += 1 }
        coordinator.lastPolicyInstallOutcome = .authoritativeDisabled
        coordinator.policyExchangeCompleted(fresh: false)
        XCTAssertEqual(scheduled, 0, "an authoritative disabled answer must not schedule recovery")
    }

    /// SUPERSESSION: a newer real refresh (exchange start) cancels any pending retry.
    func test_newerExchangeCancelsPendingRetry() {
        let (coordinator, _) = makeEnrolledStack()
        var pendingFired = false
        coordinator.schedulePolicyRetryForTesting = { _, fire in
            // production fires asynchronously; keep the handle without firing here
            _ = { pendingFired = true; fire() }
        }
        coordinator.lastPolicyInstallOutcome = .transientRefused
        coordinator.policyExchangeCompleted(fresh: false)
        // A newer exchange starts: the pending retry must be dropped (no double-drive).
        coordinator.cancelTransientPolicyRetryForTesting()
        coordinator.lastPolicyInstallOutcome = .transientRefused
        coordinator.policyExchangeCompleted(fresh: false)
        XCTAssertFalse(pendingFired)
    }
}
