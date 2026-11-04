import FirebaseCore
import FirebaseRemoteConfig
import XCTest
@testable import podcasts

/// OWNERSHIP + TRANSIENT RECOVERY controls (spec 50d8807d / reviewer 6b6fc0c8).
///
/// Pinned incident: the settlement rejected its install because the lookup's POLICY token no
/// longer equaled the current one — policy identity had moved under THIS lookup with no newer
/// exchange — leaving the only in-flight install with NO owner. The ownership fix re-derives
/// the install token for the current policy identity when only the token moved. The recovery
/// driver is exchange-owned (retry claimed by the owning lookup generation), serialized by a
/// single state lock (no queue reentrancy), and floors its delay at the SDK throttle boundary.
final class VoiceSharingPolicyOwnershipRecoveryTests: XCTestCase {

    private enum TestSupport {
        static func makeVoiceSharingPlist() throws -> String {
            let path = NSTemporaryDirectory() + "vs-fb-\(UUID().uuidString).plist"
            let dict: [String: Any] = [
                "API_KEY": "AIzaSyDijrCBGM8Jx2U1Pj5C8YWQsE4-TLVpIcQ",
                "GCM_SENDER_ID": "1083869833786",
                "GOOGLE_APP_ID": "1:1083869833786:ios:6348e7f8ce326ad4caa303",
                "PROJECT_ID": "auris-fm",
                "BUNDLE_ID": Bundle.main.bundleIdentifier ?? "fm.auris",
                "BUNDLE_URL_SCHEME_SUFFIX": "",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: path))
            return path
        }
    }

    /// Minimal thread-safe flag (mirror of the canonical suite's LockedFlag).
    private final class AdvancedFlag {
        private let lock = NSLock()
        private var value = false
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Crash-free polling wait for async tests (XCTest expectation machinery has crashed
    /// under the async test runner here).
    private func pollUntil(_ condition: @escaping () -> Bool, timeoutSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline && !condition() {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

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

    private final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private struct Delivery {
        let delay: Double
        let item: DispatchWorkItem
    }

    /// Controls deliver the REAL work item (real fire closure, generation checks included)
    /// immediately instead of after the wall-clock delay. Returns the delivery log.
    private func deliverImmediately(_ coordinator: VoiceSharingCoordinator) -> Box<[Delivery]> {
        let log = Box<[Delivery]>([])
        coordinator.deliverPolicyRetryForTesting = { delay, item in
            log.value.append(Delivery(delay: delay, item: item))
        }
        coordinator.observePolicyRetryDelayForTesting = { _ in }
        return log
    }

    /// OWNERSHIP (red→green): the lookup's policy token is STALE (policy identity moved under
    /// this lookup — the incident's fence lift AFTER capture — with NO newer lookup taken),
    /// generation and projection still current. The settlement must STILL apply membership and
    /// install, using a re-derived token. Rejecting on the token alone stranded the install.
    func test_policyTokenMovedUnderTheLookupWithNoNewerOwnerStillInstalls() async throws {
        let (coordinator, store) = makeEnrolledStack()
        VoiceSharingSessionGeneration.shared.ensureLifecycle()
        defer { VoiceSharingSessionGeneration.shared.clear() }

        // Capture FIRST, then move policy identity under the lookup (the incident's ordering).
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

        // THE OWNERSHIP DELTA: the token moved UNDER this lookup, yet the authoritative
        // membership must still APPLY (old behavior refused the whole settlement).
        XCTAssertTrue(store.currentEffectiveEnrolled,
                      "a moved policy token under the current lookup must not refuse the membership apply")

        // Changed membership installs the lease on the UNCHANGED-membership pass (settlement
        // contract, same as the two-exchange exchange control).
        let freshLookup = coordinator.beginEnrollmentLookup()
        await coordinator.completeActivationWithEnrollment(
            freshActivationSucceeded: true, lookup: freshLookup, accountClient: client)
        XCTAssertNotNil(coordinator.policy.installedLeaseExpiry,
                        "the only in-flight install must not be stranded by a moved policy token")
    }

    /// TRANSIENT RECOVERY, exchange-owned: a transiently refused exchange (its OWN generation)
    /// schedules a retry whose REAL fire closure re-drives the ordinary exchange; a later
    /// install cancels and resets the backoff.
    func test_transientRefusalRecoversThroughScheduledRetryWithoutRestart() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let gen = coordinator.currentEnrollmentLookupGenerationForTesting
        coordinator.initiateOwnedRetryRefresh = { _ in }

        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: gen)
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: gen)
        XCTAssertEqual(delivered.value.count, 1, "a transient refusal must schedule recovery")
        XCTAssertEqual(delivered.value[0].delay, 30, "base backoff is 30 s")

        // REAL fire closure runs (delivered item performed inline — no queue reentrancy):
        // it routes through the production-owned retry entry, which hands off atomically.
        var refreshRuns = 0
        coordinator.initiateOwnedRetryRefresh = { claimed in
            if coordinator.beginRetryExchangeIfCurrent(claimedGeneration: claimed) != nil { refreshRuns += 1 }
        }
        delivered.value[0].item.perform()
        XCTAssertEqual(refreshRuns, 1, "the retry re-drives the ordinary exchange")

        // A later SUCCESS (actual install) cancels and resets: next transient refusal starts
        // back at base. (fresh + refused install would itself be transient per the new
        // semantics — covered by test_freshFetchWithRefusedInstallRecoversTransiently.)
        coordinator.setPolicyInstallOutcomeForTesting(.installed, generation: gen)
        coordinator.policyExchangeCompleted(fresh: true, exchangeGeneration: gen)
        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: gen)
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: gen)
        XCTAssertEqual(delivered.value.count, 2)
        XCTAssertEqual(delivered.value[1].delay, 30, "backoff RESET after a successful install")
    }

    /// Backoff DOUBLES and is CAPPED: consecutive transient refusals schedule 30 → 60 → … ≤ 900 s.
    func test_transientBackoffDoublesAndCaps() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let gen = coordinator.currentEnrollmentLookupGenerationForTesting
        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: gen)
        coordinator.initiateOwnedRetryRefresh = { _ in }
        for expected in [30.0, 60.0, 120.0, 240.0, 480.0, 900.0, 900.0] {
            coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: gen)
            XCTAssertEqual(delivered.value.last?.delay, expected, "backoff must double up to the 900 s cap")
            delivered.value.last?.item.perform()
        }
    }

    /// AUTHORITATIVE answer: a strict decoded false cancels recovery — retrying cannot change it.
    func test_authoritativeDisabledDoesNotScheduleRetry() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let gen = coordinator.currentEnrollmentLookupGenerationForTesting
        coordinator.setPolicyInstallOutcomeForTesting(.authoritativeDisabled, generation: gen)
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: gen)
        XCTAssertTrue(delivered.value.isEmpty, "an authoritative disabled answer must not schedule recovery")
    }

    /// LATE OLD FAILURE AFTER A NEWER DISABLE (reviewer blocker 2): an older exchange's
    /// completion arriving after a newer authoritative-disabled answer must neither schedule
    /// a retry nor revive recovery.
    func test_lateOldFailureAfterNewerAuthoritativeDisableSchedulesNothing() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let genOld = coordinator.currentEnrollmentLookupGenerationForTesting
        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: genOld)
        // A newer exchange takes the next generation and settles authoritative-disabled.
        _ = coordinator.beginEnrollmentLookup()
        let genNew = coordinator.currentEnrollmentLookupGenerationForTesting
        coordinator.setPolicyInstallOutcomeForTesting(.authoritativeDisabled, generation: genNew)
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: genNew)
        XCTAssertTrue(delivered.value.isEmpty)
        // The OLD exchange's completion lands late: stale generation → dropped entirely.
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: genOld)
        XCTAssertTrue(delivered.value.isEmpty, "a stale completion must not schedule or revive recovery")
    }

    /// SUPERSESSION (reviewer blocker 2 / spec 2ffd8026): a retry claimed by an older
    /// generation, whose callback is delivered AFTER a newer exchange took the gate, must be
    /// dropped ATOMICALLY — the owned handoff validates the claimed generation and takes the
    /// exchange lookup in ONE enrollmentLookupLock step, so the retry can neither start after
    /// a newer authoritative answer nor supersede a newer in-flight refresh.
    func test_retryCallbackDeliveredAfterSupersessionIsDropped() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let gen = coordinator.currentEnrollmentLookupGenerationForTesting
        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: gen)
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: gen)
        XCTAssertEqual(delivered.value.count, 1)
        // A newer exchange begins (generation bumps); THEN the old callback is delivered.
        _ = coordinator.beginEnrollmentLookup()
        var attempts = 0
        coordinator.initiateOwnedRetryRefresh = { claimed in
            if coordinator.beginRetryExchangeIfCurrent(claimedGeneration: claimed) != nil { attempts += 1 }
        }
        delivered.value[0].item.perform()
        XCTAssertEqual(attempts, 0, "a superseded retry must not take a lookup or start an exchange")
    }

    /// ATOMIC HANDOFF, happy path: a retry whose claim is STILL current takes its exchange
    /// lookup in the same lock step — the exchange starts with that lookup (its completion
    /// carries the newly taken generation), not with a re-derived one.
    func test_retryWithCurrentClaimHandsOffAtomically() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let gen = coordinator.currentEnrollmentLookupGenerationForTesting
        coordinator.initiateOwnedRetryRefresh = { claimed in
            guard let lookup = coordinator.beginRetryExchangeIfCurrent(claimedGeneration: claimed) else {
                XCTFail("a still-current claim must hand off atomically")
                return
            }
            XCTAssertEqual(lookup.generation, gen + 1,
                           "the exchange must run on the lookup taken IN the handoff")
        }
        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: gen)
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: gen)
        XCTAssertEqual(delivered.value.count, 1)
        delivered.value[0].item.perform()
    }

    /// FRESH FETCH, REFUSED INSTALL (reviewer blocker 2): a fresh fetch whose settlement
    /// installs nothing — no newer owner, no follow-up — is the stranded-install shape and
    /// MUST schedule transient recovery, not count as success.
    func test_freshFetchWithRefusedInstallRecoversTransiently() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let gen = coordinator.currentEnrollmentLookupGenerationForTesting
        // Completion reports fresh, but no install outcome and no follow-up were recorded:
        // exactly the completion `performPolicyExchange` emits for a refused settlement.
        coordinator.initiateOwnedRetryRefresh = { _ in }
        coordinator.policyExchangeCompleted(fresh: true, exchangeGeneration: gen)
        XCTAssertEqual(delivered.value.count, 1,
                       "fresh-but-uninstalled must recover transiently, not reset")
    }

    /// FOLLOW-UP OWNERSHIP: a completion whose settlement deferred the install to its
    /// follow-up exchange counts as neither success-install nor transient — no duplicate
    /// retry; the follow-up drives the install.
    func test_deferredFollowUpCompletionSchedulesNoDuplicateRetry() async throws {
        let (coordinator, store) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        VoiceSharingSessionGeneration.shared.ensureLifecycle()
        defer { VoiceSharingSessionGeneration.shared.clear() }
        let lookup = coordinator.beginEnrollmentLookup()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSharingStubProtocol.self]
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubBearerTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" },
            membershipStore: store)
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] = .init(
            status: 200,
            body: ["schema_version": 1, "membership_revision": "r1", "plan": "pro",
                   "voice_sharing_enrolled": true, "withdrawal_state": "active",
                   "enrollment_epoch": "e1" as Any, "accepted_disclosure_version": "voice-sharing-v1" as Any])
        defer { VoiceSharingStubProtocol.replies.removeAll() }
        await coordinator.completeActivationWithEnrollment(
            freshActivationSucceeded: true, lookup: lookup, accountClient: client)
        // Membership CHANGED here, so this generation deferred its install to the follow-up.
        XCTAssertTrue(store.currentEffectiveEnrolled)
        coordinator.policyExchangeCompleted(fresh: true, exchangeGeneration: lookup.generation)
        XCTAssertTrue(delivered.value.isEmpty,
                      "a follow-up-owned completion must not schedule a duplicate retry")
    }

    /// ENTRY SUPERSESSION PRESERVES BACKOFF (reviewer 722bcc74 gap 3): a new exchange entry
    /// cancels a pending delivery but must NOT reset outage backoff — consecutive transient
    /// failures keep growing 30 → 60 → 120 even across intervening exchange entries.
    func test_exchangeEntriesBetweenFailuresPreserveBackoffGrowth() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let gen = coordinator.currentEnrollmentLookupGenerationForTesting
        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: gen)
        coordinator.initiateOwnedRetryRefresh = { _ in }
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: gen)
        XCTAssertEqual(delivered.value.last?.delay, 30)
        delivered.value.last?.item.perform()
        // A new exchange entry happens (what every real retry does):
        coordinator.cancelPendingRetryDeliveryForNewExchange()
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: gen)
        XCTAssertEqual(delivered.value.last?.delay, 60,
                       "an exchange entry must cancel delivery, not reset outage backoff")
        delivered.value.last?.item.perform()
        coordinator.cancelPendingRetryDeliveryForNewExchange()
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: gen)
        XCTAssertEqual(delivered.value.last?.delay, 120)
    }

    /// STALE COMPLETION CANNOT CLAIM (reviewer 722bcc74 gap 2): a completion for a superseded
    /// generation cannot schedule a retry even when the retry state looks free — the claim is
    /// currency-checked in the lookup owner's serialization.
    func test_staleCompletionCannotClaimRetryThroughSchedulePath() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let genOld = coordinator.currentEnrollmentLookupGenerationForTesting
        _ = coordinator.beginEnrollmentLookup() // newer exchange owns the gate
        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: genOld)
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: genOld)
        XCTAssertTrue(delivered.value.isEmpty, "a stale completion must not claim a retry")
    }

    /// GATED OLD COMPLETION VS NEWER PENDING RETRY (reviewer 19acaa23): a stale completion
    /// arriving while a NEWER generation's retry is pending must touch NOTHING — the newer
    /// retry stays deliverable and the newer outage's backoff stays intact.
    func test_oldCompletionLeavesNewerPendingRetryUntouched() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let genOld = coordinator.currentEnrollmentLookupGenerationForTesting
        // Newer exchange gen1 claims a pending retry (transient refusal at gen1).
        _ = coordinator.beginEnrollmentLookup()
        let genNew = coordinator.currentEnrollmentLookupGenerationForTesting
        coordinator.initiateOwnedRetryRefresh = { _ in }
        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: genNew)
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: genNew)
        XCTAssertEqual(delivered.value.count, 1)
        // Now the OLD generation's completion lands (claimed installed, gated fresh=true):
        // currency-refused inside the owner transaction → nothing touched.
        coordinator.setPolicyInstallOutcomeForTesting(.installed, generation: genOld)
        coordinator.policyExchangeCompleted(fresh: true, exchangeGeneration: genOld)
        XCTAssertEqual(delivered.value.count, 1, "the newer retry's delivery must survive a stale completion")
        // The newer retry still fires and the backoff schedule is NOT reset (next is 60).
        var retryExchangeGeneration = 0
        coordinator.initiateOwnedRetryRefresh = { claimed in
            if let lookup = coordinator.beginRetryExchangeIfCurrent(claimedGeneration: claimed) {
                retryExchangeGeneration = lookup.generation
            }
        }
        delivered.value[0].item.perform()
        XCTAssertEqual(retryExchangeGeneration, genNew + 1,
                       "the newer retry must still be deliverable after the stale completion")
        // The retry's OWN exchange continues the outage: its transient completion must
        // schedule at 60 — proof the stale completion reset nothing.
        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: retryExchangeGeneration)
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: retryExchangeGeneration)
        XCTAssertEqual(delivered.value.last?.delay, 60,
                       "a stale completion must not reset the newer outage's backoff")
    }

    /// LEASE EXPIRY → FAILED FETCH → DELIVERED RETRY → FRESH INSTALLED POLICY
    /// (spec f734c75c / e42d2959 / reviewers 974f4958 + aa503d56): install an initial
    /// enabled lease, advance the injected clock past its deadline, invoke the captured
    /// REAL expiry schedule, watch collection close, then let the renewal fetch fail
    /// transiently and DELIVER the scheduled retry through the real owned handoff and
    /// exchange — ending in a fresh installed lease with collection permitted again.
    func test_leaseExpiryWithFailedFetchRecoversToAFreshInstalledPolicy() async throws {
        let store = VoiceSharingEnrollmentStore(sessionIdentityProvider: { "gen-A" })
        store.setLocalOptIn(true)
        let clock = StubMonotonicClock(time: 1_000)
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            lastFetchTime: { nil },
            valueSource: { VoiceSharingCoordinator.RemoteValueSource(
                data: Data("true".utf8), sourceIsRemote: true) },
            enrollmentStore: store)
        VoiceSharingSessionGeneration.shared.ensureLifecycle()
        defer { VoiceSharingSessionGeneration.shared.clear() }
        let firApp = try XCTUnwrap(
            VoiceSharingFirebaseApp.configure(plistPath: TestSupport.makeVoiceSharingPlist()))
        XCTAssertNotNil(firApp)
        let delivered = deliverImmediately(coordinator)
        VoiceSharingFirebaseApp.connectIdentityRecoveryRefresh(coordinator: coordinator)

        // Phase 0: the settlement passes must settle SUCCESSFULLY (no pending retry left
        // behind for a later generation to trip over): immediate successful fetch.
        VoiceSharingFirebaseApp.policyFetchActor = { _, handler in handler(.success, nil as Error?) }
        defer { VoiceSharingFirebaseApp.policyFetchActor = nil }
        let config0 = URLSessionConfiguration.ephemeral
        config0.protocolClasses = [VoiceSharingStubProtocol.self]
        let client0 = VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubBearerTokens(),
            session: URLSession(configuration: config0),
            sessionIdentity: { "gen-A" },
            membershipStore: store)
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] = .init(
            status: 200,
            body: ["schema_version": 1, "membership_revision": "r1", "plan": "pro",
                   "voice_sharing_enrolled": true, "withdrawal_state": "active",
                   "enrollment_epoch": "e1" as Any, "accepted_disclosure_version": "voice-sharing-v1" as Any])
        var expiryCallback: (() -> Void)?
        coordinator.expiryScheduler = { _, body in expiryCallback = body }
        var lookup0 = coordinator.beginEnrollmentLookup()
        await coordinator.completeActivationWithEnrollment(
            freshActivationSucceeded: true, lookup: lookup0, accountClient: client0)
        lookup0 = coordinator.beginEnrollmentLookup()
        await coordinator.completeActivationWithEnrollment(
            freshActivationSucceeded: true, lookup: lookup0, accountClient: client0)
        XCTAssertNotNil(coordinator.policy.installedLeaseExpiry,
                        "phase 0: an initial lease must install")
        XCTAssertTrue(coordinator.policy.permitsCollection,
                      "phase 0: the initial lease permits collection")
        let initialExpiry = coordinator.policy.installedLeaseExpiry

        // Phase 1: advance the injected clock PAST the lease deadline so the captured REAL
        // expiry schedule's revoke check fires; collection must CLOSE; the renewal fetch
        // FAILS transiently → recovery scheduled.
        try XCTUnwrap(expiryCallback != nil, "the initial install must arm the real expiry schedule")
        clock.advance(1_000_000)
        XCTAssertFalse(coordinator.policy.permitsCollection,
                       "after the clock passes the deadline the lease must close collection")
        VoiceSharingFirebaseApp.policyFetchActor = { _, handler in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                handler(.failure, NSError(domain: "test", code: 1))
            }
        }
        expiryCallback?()
        await pollUntil({ !delivered.value.isEmpty }, timeoutSeconds: 10)
        guard !delivered.value.isEmpty else {
            XCTFail("no recovery was scheduled after the real expiry callback"); return
        }
        XCTAssertEqual(delivered.value.count, 1,
                       "an expiry renewal with a failed fetch must schedule recovery")

        // Phase 2: the delivered retry runs the REAL owned handoff + exchange; the stub
        // now answers fresh, remote, activated, and enrolled — the lease must INSTALL.
        let advanced = AdvancedFlag()
        coordinator.lastFetchTimeProvider = { advanced.get() ? Date() : nil }
        VoiceSharingFirebaseApp.policyFetchActor = { _, handler in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                advanced.set(true)
                handler(.success, nil as Error?)
            }
        }
        VoiceSharingFirebaseApp.policyActivateActor = { handler in handler(true, nil) }
        VoiceSharingFirebaseApp.policyValueProvenanceActor = { true }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSharingStubProtocol.self]
        VoiceSharingFirebaseApp.defaultAccountClientOverride = { coordinator in
            VoiceSharingAccountClient(
                baseURLProvider: { "https://api.example.test" },
                tokenProvider: StubBearerTokens(),
                session: URLSession(configuration: config),
                sessionIdentity: { "gen-A" },
                membershipStore: store)
        }
        defer {
            VoiceSharingFirebaseApp.policyFetchActor = nil
            VoiceSharingFirebaseApp.policyActivateActor = nil
            VoiceSharingFirebaseApp.policyValueProvenanceActor = nil
            VoiceSharingFirebaseApp.defaultAccountClientOverride = nil
            VoiceSharingStubProtocol.replies.removeAll()
        }
        delivered.value[0].item.perform()
        // First settlement applies the CHANGED membership (deferred follow-up drives the
        // install); wait for the lease to appear via the auto-driven follow-up.
        await pollUntil({ coordinator.policy.installedLeaseExpiry != nil }, timeoutSeconds: 10)
        XCTAssertNotNil(coordinator.policy.installedLeaseExpiry,
                        "the delivered retry must end in a fresh installed policy")
        XCTAssertTrue(coordinator.policy.permitsCollection,
                      "the recovered lease must be usable: collection permitted")
        if let initialExpiry, let fresh = coordinator.policy.installedLeaseExpiry {
            XCTAssertNotEqual(fresh, initialExpiry,
                              "the recovered lease must be a LATER deadline than the expired one")
        }
    }

    /// SDK THROTTLE BOUNDARY (reviewer blocker 3): a fetch error carrying
    /// `RemoteConfigThrottledEndTimeInSecondsKey` floors the retry delay at the later of the
    /// boundary and local backoff — INCLUDING a boundary beyond the 900 s backoff cap.
    func test_throttleBoundaryFloorsRetryDelayBeyondBackoffCap() {
        let (coordinator, _) = makeEnrolledStack()
        let delivered = deliverImmediately(coordinator)
        let gen = coordinator.currentEnrollmentLookupGenerationForTesting
        let boundary = Date().addingTimeInterval(3600)
        let error = NSError(domain: "test", code: 1, userInfo: [
            RemoteConfigThrottledEndTimeInSecondsKey: NSNumber(value: boundary.timeIntervalSince1970),
        ])
        coordinator.recordPolicyFetchThrottleFloor(from: error)
        coordinator.initiateOwnedRetryRefresh = { _ in }
        coordinator.setPolicyInstallOutcomeForTesting(.transientRefused, generation: gen)
        coordinator.policyExchangeCompleted(fresh: false, exchangeGeneration: gen)
        XCTAssertEqual(delivered.value.count, 1)
        // Boundary read just before recording: allow sub-second clock skew.
        XCTAssertGreaterThanOrEqual(delivered.value[0].delay, 3599,
                                    "retry delay must respect the SDK throttle boundary, uncapped")
    }
}
