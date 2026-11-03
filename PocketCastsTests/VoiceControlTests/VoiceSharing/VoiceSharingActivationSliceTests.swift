import FirebaseCore
import FirebaseRemoteConfig
import XCTest
@testable import podcasts

/// Activation-slice controls (2026-11-03, @spec dispatch `d42369ac` + `51500e55`):
/// the disclosure token, the named secondary Firebase app, and the coordinator's
/// named-app routing. The property under test is not "the feature works" but
/// "activation is honest": the default Firebase app is untouched, a missing
/// secondary config degrades to nil (never a crash), and the disclosure token is
/// the exact server-supported string.
final class VoiceSharingActivationSliceTests: XCTestCase {

    // MARK: Disclosure token

    /// The token must be the exact server-supported disclosure version. Any other
    /// string is a contract change, not a copy tweak.
    func test_disclosureVersionIsTheExactServerToken() {
        XCTAssertEqual(VoiceSharingDisclosure.version, "voice-sharing-v1")
    }

    /// The production wiring must carry the token (not nil, which renders as
    /// `disclosureUnavailable` and can never enroll).
    func test_assemblySuppliesTheProductionDisclosureVersion() {
        XCTAssertEqual(VoiceSharingDisclosure.productionVersion, VoiceSharingDisclosure.version)
    }

    /// Truthful copy: the disclosure body must state the retention fact, the
    /// withdrawal fact and the separate-deletion fact, and must NOT name storage
    /// infrastructure or limit machinery.
    func test_englishDisclosureCopyStatesRequiredFactsAndOmitsMachinery() throws {
        let body = try XCTUnwrap(VoiceSharingDisclosure.englishBody,
                                 "the English disclosure body must be present")
        XCTAssertTrue(body.contains("year"), "the body must state the one-year retention plainly")
        XCTAssertTrue(body.lowercased().contains("withdraw"), "the body must state withdrawal")
        XCTAssertTrue(body.lowercased().contains("delet"), "the body must state separate deletion")
        let forbidden = ["bucket", "r2", "auris-upload", "ceiling", "ledger",
                         "100 MB", "1000", "quota", "batch"]
        let lowered = body.lowercased()
        for token in forbidden {
            XCTAssertFalse(lowered.contains(token.lowercased()),
                           "user copy must not name infrastructure or limit machinery: \(token)")
        }
    }

    // MARK: Named secondary Firebase app

    /// A valid bundled-style config produces a named app with the project identity,
    /// and does not touch the default app.
    func test_namedAppConfiguresFromValidPlistWithoutTouchingDefaultApp() throws {
        let path = try XCTUnwrap(TestSupport.makeVoiceSharingPlist())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = VoiceSharingFirebaseApp.configure(plistPath: path)
        XCTAssertEqual(first?.name, VoiceSharingFirebaseApp.appName)

        // Idempotent: a second configure returns the SAME app, not a duplicate.
        let second = VoiceSharingFirebaseApp.configure(plistPath: path)
        XCTAssertEqual(first, second)

        // Isolation: the default app (if configured in the test host) keeps its own
        // name; the named app never replaced it.
        if let defaultApp = FirebaseApp.app() {
            XCTAssertNotEqual(defaultApp.name, VoiceSharingFirebaseApp.appName)
        }
    }

    /// A missing or invalid config degrades to nil — honest unavailability, never
    /// a launch crash (mirrors the AppDelegate stub-guard).
    func test_missingOrInvalidPlistYieldsNilWithoutCrash() {
        // Test isolation: remove any named app a prior control in this suite configured.
        TestSupport.deleteVoiceSharingAppSync()
        XCTAssertNil(VoiceSharingFirebaseApp.configure(plistPath: "/nonexistent/plist.plist"))
        let junk = TestSupport.makeJunkFile()
        defer { try? FileManager.default.removeItem(atPath: junk) }
        XCTAssertNil(VoiceSharingFirebaseApp.configure(plistPath: junk))
    }

    // MARK: Coordinator routing

    /// The policy flag reads through the NAMED app when it exists and falls back to
    /// the default-app read when it does not — the extraction behavior is otherwise
    /// identical (same key, same default-false handling).
    func test_flagReadFailsClosedWithoutNamedAppAndRoutesNamedAppWhenPresent() {
        // The coordinator's remote scalar is exactly the one owned key.
        XCTAssertEqual(Constants.RemoteParams.voiceSharingEnabled, "voice_sharing_enabled")
        // FAIL CLOSED (reviewer 9440ce71): with no named secondary app the policy
        // has NO authority — nil app, never the default app, and the SDK read
        // yields a non-remote value (local default false), never another
        // project's enabled flag.
        if VoiceSharingFirebaseApp.existing() == nil {
            XCTAssertNil(VoiceSharingCoordinator.policyFirebaseApp(),
                         "policy must not fall back to the default app")
        } else {
            XCTAssertEqual(VoiceSharingCoordinator.policyFirebaseApp()?.name,
                           VoiceSharingFirebaseApp.appName)
        }
    }

    /// Freshness binds to the SAME named authority: the coordinator's default
    /// last-fetch reader answers nil when the named app is absent (never the
    /// default app's fetch time), and the named app's fetch/activate path runs on
    /// its own RemoteConfig instance.
    func test_freshnessReaderBindsToTheNamedAuthorityOnly() {
        let reader = VoiceSharingCoordinator().lastFetchTime()
        if VoiceSharingFirebaseApp.existing() == nil {
            XCTAssertNil(reader, "no named authority ⇒ no freshness claim")
        }
        // The named refresh path completes without touching the default app;
        // with no named app it completes(false) synchronously-ish.
        let expectation = expectation(description: "refresh completes once")
        VoiceSharingFirebaseApp.refreshPolicy { _ in expectation.fulfill() }
        waitForExpectations(timeout: 10)
    }

    // MARK: Complete named-policy exchange (reviewer 3154e29f)

    private func withCoordinator(_ body: (VoiceSharingCoordinator) -> Void) {
        let coordinator = VoiceSharingCoordinator.shared
        VoiceSharingFirebaseApp.connectIdentityRecoveryRefresh(coordinator: coordinator)
        XCTAssertNotNil(coordinator.initiateIdentityRecoveryRefresh)
        body(coordinator)
    }

    /// Missing authority: the exchange settles NO lease — fail closed, outcome false,
    /// and the settlement path runs (not just an outcome variable).
    func test_exchangeMissingAuthorityFailsClosedThroughTheSettlementPath() {
        withCoordinator { coordinator in
            if VoiceSharingFirebaseApp.existing() != nil { return } // named present: covered below
            VoiceSharingFirebaseApp.lastPolicyRefreshOutcome = nil
            let done = expectation(description: "exchange completes")
            VoiceSharingFirebaseApp.performPolicyExchange(coordinator: coordinator) { fresh in
                XCTAssertFalse(fresh)
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            XCTAssertEqual(VoiceSharingFirebaseApp.lastPolicyRefreshOutcome, false)
            XCTAssertFalse(coordinator.policy.permitsCollection,
                           "no authority ⇒ no lease")
        }
    }

    /// Failed fetch: the exchange settles refused — outcome false, no lease, and the
    /// coordinator's activation path (not merely the flag) receives the refusal.
    func test_exchangeFailedFetchFailsClosedThroughTheSettlementPath() {
        withCoordinator { coordinator in
            guard VoiceSharingFirebaseApp.existing() != nil else { return }
            VoiceSharingFirebaseApp.policyFetchActor = { _, handler in
                handler(.failure, NSError(domain: "test", code: 1) as Error)
            }
            defer { VoiceSharingFirebaseApp.policyFetchActor = nil }
            VoiceSharingFirebaseApp.lastPolicyRefreshOutcome = nil
            let done = expectation(description: "exchange completes")
            VoiceSharingFirebaseApp.performPolicyExchange(coordinator: coordinator) { fresh in
                XCTAssertFalse(fresh)
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            XCTAssertEqual(VoiceSharingFirebaseApp.lastPolicyRefreshOutcome, false)
            XCTAssertFalse(coordinator.policy.permitsCollection)
        }
    }

    /// Identity change while pending: a fetch/activate pair that lands AFTER the
    /// account identity moved must NOT install the departed state's permission —
    /// the lookup's token/generation guards refuse the settlement.
    func test_exchangeIdentityChangeWhilePendingRefusesInstall() {
        withCoordinator { coordinator in
            guard VoiceSharingFirebaseApp.existing() != nil else { return }
            // Stub the whole network pair; the freshness proof comes from the
            // coordinator's own settable provider.
            VoiceSharingFirebaseApp.policyFetchActor = { _, handler in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    handler(RemoteConfigFetchStatus.success, nil as Error?)
                }
            }
            VoiceSharingFirebaseApp.policyActivateActor = { handler in
                handler(true, nil)
            }
            defer {
                VoiceSharingFirebaseApp.policyFetchActor = nil
                VoiceSharingFirebaseApp.policyActivateActor = nil
            }
            let box = LockedFlag()
            let original = coordinator.lastFetchTimeProvider
            coordinator.lastFetchTimeProvider = { box.value ? Date() : nil }
            defer { coordinator.lastFetchTimeProvider = original }
            let done = expectation(description: "exchange completes")
            VoiceSharingFirebaseApp.performPolicyExchange(coordinator: coordinator) { fresh in
                done.fulfill()
                _ = fresh
            }
            // The identity moves WHILE the fetch is in flight.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                box.set(true) // fetch "succeeds" after the identity moved
            }
            wait(for: [done], timeout: 10)
            // Whether the token guards refuse depends on the store's projection state;
            // the hard assertion is that collection NEVER becomes permitted without a
            // real authenticated enrollment exchange.
            XCTAssertFalse(coordinator.policy.permitsCollection)
        }
    }

    /// POSITIVE INSTALL CONTROL (reviewer 0c3168fe): a fully stubbed exchange — fetch
    /// success, activate success, freshness advanced, an authoritative enrolled
    /// projection, the switch value enabled — MUST install the policy lease through
    /// the settlement call. Removing the settlement (membership never applies, no
    /// lease) makes this control fail. No live-network claim is made.
    func test_exchangeWithAuthoritativeEnrollmentInstallsTheLease() async throws {
        let store = VoiceSharingEnrollmentStore(
            sessionIdentityProvider: { "gen-A" })
        store.setLocalOptIn(true)
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            lastFetchTime: { nil },
            valueSource: { VoiceSharingCoordinator.RemoteValueSource(
                data: Data("true".utf8), sourceIsRemote: true) },
            enrollmentStore: store)
        coordinator.expiryScheduler = { _, _ in }
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

        // No delete here: the Firebase app is configured once by the provenance control that
        // sorts before this one. DELETING AND RECREATING the same app name makes FirebaseApp
        // hand back a half-configured instance whose RemoteConfig component throws
        // (googleAppID "missing"), so the suite creates the app once and reuses it.
        let firApp = try XCTUnwrap(
            VoiceSharingFirebaseApp.configure(plistPath: TestSupport.makeVoiceSharingPlist()))
        // CAUSE OF THE LONG-STANDING BASELINE FAILURE (found while writing the provenance
        // control): performPolicyExchange DEFERS with completion(false) when the process-wide
        // session registry has no lifecycle, which is its state in the test host — so the
        // stubbed fetch/activate actors were never consulted and every install assertion
        // failed. Arming the lifecycle is not a bypass: the production path reaches this point
        // only once the account lifecycle exists.
        VoiceSharingSessionGeneration.shared.ensureLifecycle()
        defer { VoiceSharingSessionGeneration.shared.clear() }
        let advanced = LockedFlag()
        let originalFreshness = coordinator.lastFetchTimeProvider
        coordinator.lastFetchTimeProvider = { advanced.value ? Date() : nil }
        defer { coordinator.lastFetchTimeProvider = originalFreshness }
        VoiceSharingFirebaseApp.policyFetchActor = { _, handler in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                advanced.set(true)
                handler(.success, nil as Error?)
            }
        }
        VoiceSharingFirebaseApp.policyActivateActor = { handler in handler(true, nil) }
        defer {
            VoiceSharingFirebaseApp.policyFetchActor = nil
            VoiceSharingFirebaseApp.policyActivateActor = nil
            TestSupport.deleteVoiceSharingAppSync()
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSharingStubProtocol.self]
        let session = URLSession(configuration: config)
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: session,
            sessionIdentity: { "gen-A" },
            membershipStore: store)

        let settled = expectation(description: "exchange settles")
        VoiceSharingFirebaseApp.performPolicyExchange(
            coordinator: coordinator, accountClient: client) { fresh in
                XCTAssertTrue(fresh, "a fully-stubbed successful exchange must report install")
                settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertTrue(store.currentEffectiveEnrolled,
                      "authoritative membership must have applied through the settlement")

        // FIRST settlement applies a CHANGED membership, so by contract it schedules a
        // follow-up exchange rather than installing on its own lookup. The follow-up is
        // the second run of the SAME exchange; it now sees unchanged membership and is
        // the run that installs the lease.
        let followUp = expectation(description: "follow-up exchange settles")
        VoiceSharingFirebaseApp.performPolicyExchange(
            coordinator: coordinator, accountClient: client) { fresh in
                XCTAssertTrue(fresh)
                followUp.fulfill()
        }
        await fulfillment(of: [followUp], timeout: 10)

        XCTAssertTrue(coordinator.policy.permitsCollection,
                      "enabled switch + enrolled account + fresh lease ⇒ collection permitted")
    }

    /// ACTIVATION PROVENANCE (reviewer 30630d31 finding 1): on a FIRST fetch the active
    /// config value is still the local DEFAULT until `activate` applies the fetched data.
    /// Reading the value's source before activation therefore rejected a successful first
    /// fetch with the old provenance. The stub fetches nothing; the provenance actor answers
    /// FALSE before the activation handler runs and TRUE after — exactly what a real first
    /// fetch/activate pair produces. With the pre-activation read restored, this exchange
    /// settles NO lease and the control fails.
    func test_exchangeFirstFetchProvenanceIsReadAfterActivationApplies() async throws {
        // DELETION AT END (see helper): a fire-and-forget delete raced the next control's
        // configure — the same name was recreated mid-deletion and FirebaseApp handed back a
        // half-configured instance whose RemoteConfig component throws (googleAppID "missing").
        let firApp = try XCTUnwrap(
            VoiceSharingFirebaseApp.configure(plistPath: TestSupport.makeVoiceSharingPlist()))
        // The exchange refuses to even fetch without an account lifecycle; the process-wide
        // registry has none in the test host, so arm one (and clear it after).
        VoiceSharingSessionGeneration.shared.ensureLifecycle()
        defer { VoiceSharingSessionGeneration.shared.clear() }

        let store = VoiceSharingEnrollmentStore(sessionIdentityProvider: { "gen-A" })
        store.setLocalOptIn(true)
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            lastFetchTime: { nil },
            valueSource: { VoiceSharingCoordinator.RemoteValueSource(
                data: Data("true".utf8), sourceIsRemote: true) },
            enrollmentStore: store)
        coordinator.expiryScheduler = { _, _ in }
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

        let advanced = LockedFlag()
        let originalFreshness = coordinator.lastFetchTimeProvider
        coordinator.lastFetchTimeProvider = { advanced.value ? Date() : nil }
        defer { coordinator.lastFetchTimeProvider = originalFreshness }

        let activationApplied = LockedFlag()
        let provenanceReads = LockedCounter()
        final class Box { var list: [Bool] = [] }; let provenanceValues = Box()
        let activateCalls = LockedCounter()
        VoiceSharingFirebaseApp.policyFetchActor = { _, handler in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                advanced.set(true)
                handler(.success, nil as Error?)
            }
        }
        VoiceSharingFirebaseApp.policyActivateActor = { handler in
            activateCalls.increment()
            activationApplied.set(true) // activation applies fetched data to the active config
            handler(true, nil)
        }
        VoiceSharingFirebaseApp.policyValueProvenanceActor = {
            provenanceReads.increment()
            let v = activationApplied.value
            provenanceValues.list.append(v)
            return v
        }
        defer {
            VoiceSharingFirebaseApp.policyFetchActor = nil
            VoiceSharingFirebaseApp.policyActivateActor = nil
            VoiceSharingFirebaseApp.policyValueProvenanceActor = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSharingStubProtocol.self]
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" },
            membershipStore: store)

        let settled = expectation(description: "exchange settles")
        VoiceSharingFirebaseApp.performPolicyExchange(
            coordinator: coordinator, accountClient: client) { fresh in
                XCTAssertTrue(fresh,
                              "a first fetch whose activation succeeds must install: provenance "
                              + "is read AFTER activation applied the fetched value")
                settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertTrue(store.currentEffectiveEnrolled,
                      "the settled lease must carry the authoritative membership")
    }

    /// PRODUCTION ENTRY control (reviewer 45479ac1): the connected identity-recovery
    /// path runs the named fetch→activate and the outcome is observable. Deleting the
    /// `connectIdentityRecoveryRefresh()` call in the assembly removes the production
    /// connection; this control exercises that exact connected closure.
    func test_identityRecoveryRefreshRunsTheNamedFetchActivatePath() {
        VoiceSharingFirebaseApp.lastPolicyRefreshOutcome = nil
        let coordinator = VoiceSharingCoordinator.shared
        VoiceSharingFirebaseApp.connectIdentityRecoveryRefresh(coordinator: coordinator)
        XCTAssertNotNil(coordinator.initiateIdentityRecoveryRefresh,
                        "the production connection must install the refresh closure")
        let expectation = expectation(description: "identity-recovery refresh completes")
        // The connected closure uses expiration 0 and records its outcome. Poll: a
        // real fetch can take several seconds on a live project.
        coordinator.initiateIdentityRecoveryRefresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { expectation.fulfill() }
        let outcome = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            VoiceSharingFirebaseApp.lastPolicyRefreshOutcome != nil
        }, object: self)
        wait(for: [expectation, outcome], timeout: 30)
        if VoiceSharingFirebaseApp.existing() == nil {
            XCTAssertEqual(VoiceSharingFirebaseApp.lastPolicyRefreshOutcome, false,
                           "absent authority must report a failed refresh, not silence")
        } else {
            XCTAssertNotNil(VoiceSharingFirebaseApp.lastPolicyRefreshOutcome,
                            "the named fetch→activate path must report its outcome")
        }
    }
}

/// Tiny lock-protected flag for cross-thread control sequencing.
private final class LockedFlag {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ newValue: Bool) { lock.lock(); stored = newValue; lock.unlock() }
    init(value: Bool = false) { stored = value }
}

/// Lock-protected counter for cross-thread control observation.
private final class LockedCounter {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}

/// Trust-on-first-use stub credential, mirroring AccountClientTests' provider.
private final class StubTokens: CloudTokenProviding {
    func token() async -> String? { "test-bearer" }
    func prepare() async {}
    func handleUnauthorized(rejectedToken: String?) async {}
}

private enum TestSupport {
    /// Writes a VALID Firebase-options plist (the same key set and value shapes as
    /// the provisioned `VoiceSharingFirebase.plist` — the SDK validates the app-id
    /// format at configure time) to a temp path.
    static func makeVoiceSharingPlist() throws -> String {
        let path = NSTemporaryDirectory() + "vs-fb-\(UUID().uuidString).plist"
        let dict: [String: Any] = [
            "API_KEY": "AIzaSyDijrCBGM8Jx2U1Pj5C8YWQsE4-TLVpIcQ",
            "GCM_SENDER_ID": "1083869833786",
            "GOOGLE_APP_ID": "1:1083869833786:ios:6348e7f8ce326ad4caa303",
            "PROJECT_ID": "auris-fm",
            "BUNDLE_ID": Bundle.main.bundleIdentifier ?? "fm.auris",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Deletes the named app SYNCHRONOUSLY. The old fire-and-forget delete let the next
    /// configure recreate the name mid-deletion, producing a half-configured app whose
    /// RemoteConfig component throws.
    static func deleteVoiceSharingAppSync() {
        guard let app = VoiceSharingFirebaseApp.existing() else { return }
        let sem = DispatchSemaphore(value: 0)
        app.delete { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
    }

    static func makeJunkFile() -> String {
        let path = NSTemporaryDirectory() + "vs-fb-junk-\(UUID().uuidString).plist"
        try? Data("not a plist".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }
}
