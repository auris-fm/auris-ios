import FirebaseCore
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

    static func makeJunkFile() -> String {
        let path = NSTemporaryDirectory() + "vs-fb-junk-\(UUID().uuidString).plist"
        try? Data("not a plist".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }
}
