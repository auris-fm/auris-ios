import XCTest
import PocketCastsUtils
@testable import PocketCastsServer

final class SessionAuthenticationTests: XCTestCase {
    private var values: [String: String] = [:]
    private var storedEmail: String?
    private var storedUserId: String?
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let accessKey = ServerConstants.Values.syncingV2TokenKey
    private let refreshKey = ServerConstants.Values.refreshTokenKey
    private let marker = "AurisIncompleteCredentialWrite"

    override func setUp() {
        super.setUp()
        suiteName = "session-auth-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        ServerSettings.invalidateAuthentication(defaults: defaults) {}
        defaults.set(false, forKey: marker)
        values = [accessKey: "old-access", refreshKey: "old-refresh"]
    }

    override func tearDown() {
        ServerSettings.invalidateAuthentication(defaults: defaults) {}
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func response(_ access: String = "new-access", refresh: String? = "new-refresh", email: String = "b@example.com", uuid: String = "account-b") -> AuthenticationResponse {
        AuthenticationResponse(token: access, uuid: uuid, email: email, refreshToken: refresh)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The account identity hashes the SAME stored fields a real commit writes (email + user id),
        // so these controls must write through the same storages or they would hash a different
        // account than the one they committed.
        storedEmail = ServerSettings.syncingEmail()
        storedUserId = ServerSettings.userId
        ServerSettings.setSyncingEmail(email: "b@example.com")
        ServerSettings.userId = "account-b"
    }

    override func tearDownWithError() throws {
        ServerSettings.setSyncingEmail(email: storedEmail)
        ServerSettings.userId = storedUserId
        try super.tearDownWithError()
    }

    private func commit(_ response: AuthenticationResponse, _ attempt: AuthenticationAttempt, failAt: Int? = nil, alwaysFail: Bool = false) -> Bool {
        var writes = 0
        return ServerSettings.commitAuthentication(response, for: attempt, password: "new-password", read: { self.values[$0] }, write: { value, key in
            writes += 1
            if alwaysFail || writes == failAt { return false }
            self.values[key] = value
            return true
        }, defaults: defaults)
    }

    /// The owner-side connection voice sharing depends on (spec): a credential commit
    /// REPORTS itself once it has completed and released the lock, and the account identity it
    /// reports is STABLE across renewals of the same account while a genuine login changes it.
    ///
    /// Red shapes this control must reject: no completion at all (a passive restoration then has no
    /// way in), a completion that fires while the lock is still held (the observer deadlocks or reads
    /// a half-committed state), and an identity derived from the authentication id (which is
    /// re-minted on every renewal, so a renewal would read as a different account).
    func testCredentialCommitReportsCompletion_andItsAccountIdentitySurvivesRenewal() throws {
        var completions = 0
        ServerSettings.credentialCommitObserver = { completions += 1 }
        defer { ServerSettings.credentialCommitObserver = nil }

        let first = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        XCTAssertEqual(completions, 0, "nothing is reported before a commit")
        XCTAssertTrue(commit(response(), first))
        XCTAssertEqual(completions, 1, "a commit reports exactly one completion")
        // The completion happens with the owner's lock released, which is what makes reading the
        // committed state from the callback safe.
        XCTAssertTrue(ServerSettings.authenticationLockAvailableForTesting(),
                      "the completion must not run while the caller still holds the authentication lock")
        let identity = try XCTUnwrap(ServerSettings.committedAccountIdentity(),
                                     "a committed credential has an account identity")

        XCTAssertEqual(ServerSettings.committedAccountIdentity(), identity, "and it is stable to read")

        // A RENEWAL of the same account commits again — a new completion, the SAME account identity.
        let renewal = try XCTUnwrap(ServerSettings.beginAuthentication(explicit: false))
        XCTAssertTrue(commit(response("renewed-access", refresh: "rotated-refresh"), renewal))
        XCTAssertEqual(completions, 2, "a renewal reports completion too: it is a readiness signal")
        XCTAssertEqual(ServerSettings.committedAccountIdentity(), identity,
                       "but a renewal must NOT read as a different account")

        // Signing OUT drops it (nothing is committed), which is what lets the SAME account settle
        // again as a new session after a real sign-out/sign-in rather than dedupe away.
        ServerSettings.invalidateAuthentication(defaults: defaults) {}
        XCTAssertNil(ServerSettings.committedAccountIdentity(),
                     "a signed-out owner has no account identity to report")

        // A failed commit reports nothing: the owner is not ready, so nothing may act on it.
        let failing = try XCTUnwrap(ServerSettings.beginAuthentication(email: "c@example.com"))
        XCTAssertFalse(commit(response(uuid: "account-c"), failing, alwaysFail: true))
        XCTAssertEqual(completions, 2, "a rejected write is not a completion")
    }

    /// REVIEWER (`d23c3f613`): the cold-readiness control injected a stored identity into the
    /// coordinator, which proves the coordinator's wiring but not the seam it reads in production.
    /// This one exercises the real `ServerSettings` reader against actually-stored credentials, and
    /// asserts the distinction the whole cold path exists for:
    ///
    /// * a credential that is STORED but was never committed in this process must report a stored
    /// identity and NO committed identity — the cold-start answer is readable state, not an event;
    /// * the committed form and the stored form must be THE same string for the same account, because
    /// the first renewal commit after a cold start is otherwise read as a different account;
    /// * with no stored credential there is nothing to present.
    func testStoredCredentialIdentityIsReadableWithoutACommit_andMatchesTheCommittedForm() throws {
        // Start from a device with NOTHING to present. The test host's Keychain is shared and dirty
        // from other suites, so this needs an explicit clear, not an assumption about its contents.
        ServerSettings.clearAuthentication(defaults: defaults)
        XCTAssertNil(ServerSettings.committedAccountIdentity(),
                     "premise: a cold start has no committed identity to report")
        XCTAssertNil(ServerSettings.storedAccountIdentity(),
                     "premise: with nothing stored there is nothing to present")

        // A credential that IS stored: the exact state a cold start resumes from a readable
        // refresh token AND the email it belongs to, with still no commit in this process. Both must
        // be present, because they are the two halves the identity hashes; with either one missing the
        // device genuinely cannot say which account it could act for, and must not guess.
        ServerSettings.setSyncingEmail(email: "b@example.com")
        try KeychainHelper.save(string: "restored-refresh",
                                key: ServerConstants.Values.refreshTokenKey,
                                accessibility: kSecAttrAccessibleAfterFirstUnlock)
        XCTAssertNil(ServerSettings.committedAccountIdentity(),
                     "premise: storing a credential is not a commit")
        let cold = try XCTUnwrap(ServerSettings.storedAccountIdentity(),
                                 "a stored credential is readable state, so cold readiness can settle on it")

        // Now the process commits the SAME account (a restoration's first token exchange).
        let attempt = try XCTUnwrap(ServerSettings.beginAuthentication(explicit: false))
        XCTAssertTrue(commit(response(), attempt))
        let committed = try XCTUnwrap(ServerSettings.committedAccountIdentity())

        XCTAssertEqual(committed, cold,
                       "the stored and committed namings of one account must be one string, or the "
                       + "commit looks like an account transition and resets the session lifecycle")

        // Signing out leaves nothing to present.
        ServerSettings.clearAuthentication(defaults: defaults)
        XCTAssertNil(ServerSettings.storedAccountIdentity(),
                     "a signed-out device has nothing to present, whatever the defaults once said")
    }

    func testLatestRegisteredLoginWinsEvenWhenFirstResponseArrivesLast() throws {
        let first = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        let second = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        XCTAssertTrue(commit(response(), second))
        XCTAssertFalse(commit(response("late-access"), first))
        XCTAssertEqual(values[accessKey], "new-access")
    }

    func testSignoutDuringRequestRejectsLateSuccessAndEffects() throws {
        let attempt = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        ServerSettings.invalidateAuthentication(defaults: defaults) {}
        XCTAssertFalse(commit(response(), attempt))
        var effects = 0
        XCTAssertFalse(ServerSettings.withCommittedAuthentication(attempt) { effects += 1 })
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(values[accessKey], "old-access")
    }

    func testIncompleteOrWrongAccountLoginPreservesOldPair() throws {
        let attempt = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        XCTAssertFalse(commit(response(refresh: nil), attempt))
        XCTAssertFalse(commit(response(email: "c@example.com"), attempt))
        XCTAssertEqual(values[accessKey], "old-access")
        XCTAssertEqual(values[refreshKey], "old-refresh")
    }

    func testFailedSecondWriteRollsBackBothTokensAndDoesNotReportSuccess() throws {
        let attempt = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        XCTAssertFalse(commit(response(), attempt, failAt: 2))
        XCTAssertEqual(values[accessKey], "old-access")
        XCTAssertEqual(values[refreshKey], "old-refresh")
        XCTAssertFalse(defaults.bool(forKey: marker))
        XCTAssertFalse(ServerSettings.withCommittedAuthentication(attempt) { XCTFail("failed write reported success") })
    }

    func testCheckedClearReleasesUnavailableMarkerOnlyAfterEveryRemovalSucceeds() {
        ServerSettings.clearAuthentication(defaults: defaults, remove: { key in
            self.values[key] = nil
            return true
        })
        XCTAssertFalse(defaults.bool(forKey: marker))
        XCTAssertNil(values[accessKey])
        XCTAssertNil(values[refreshKey])
    }

    func testFailedClearRemainsUnavailableInANewDefaultsInstance() throws {
        var removals = 0
        ServerSettings.clearAuthentication(defaults: defaults, remove: { key in
            removals += 1
            return key != self.refreshKey
        })
        XCTAssertEqual(removals, 5, "attempt every removal even when one fails")
        XCTAssertTrue(defaults.bool(forKey: marker))
        XCTAssertTrue(try XCTUnwrap(UserDefaults(suiteName: suiteName)).bool(forKey: marker))
    }

    func testFailedLoginAfterSignoutDoesNotMakeOldCredentialsReadableAgain() throws {
        ServerSettings.invalidateAuthentication(defaults: defaults) {}
        let attempt = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        XCTAssertFalse(commit(response(), attempt, failAt: 2))
        XCTAssertTrue(defaults.bool(forKey: marker), "rollback must preserve the prior signed-out state")
    }

    func testFailedRollbackLeavesPersistentUnavailableMarker() throws {
        let attempt = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        XCTAssertFalse(commit(response(), attempt, alwaysFail: true))
        XCTAssertTrue(defaults.bool(forKey: marker))
        XCTAssertTrue(try XCTUnwrap(UserDefaults(suiteName: suiteName)).bool(forKey: marker))
    }

    func testMigrationWithValidAccessButNoRefreshCannotCommitAnotherAccessOnlyResponse() throws {
        values[refreshKey] = nil
        let attempt = try XCTUnwrap(ServerSettings.beginAuthentication(explicit: false))
        let email = ServerSettings.syncingEmail() ?? "existing@example.com"
        let uuid = ServerSettings.userId ?? "existing-account"
        XCTAssertFalse(commit(response(refresh: nil, email: email, uuid: uuid), attempt))
        XCTAssertEqual(values[accessKey], "old-access")
        XCTAssertNil(values[refreshKey])
        XCTAssertFalse(ServerSettings.withCommittedAuthentication(attempt) { XCTFail("incomplete migration reported success") })
    }

    func testRenewalWithoutRefreshPreservesSameAccountsStoredCredential() throws {
        let attempt = try XCTUnwrap(ServerSettings.beginAuthentication(explicit: false))
        let email = ServerSettings.syncingEmail() ?? "existing@example.com"
        let uuid = ServerSettings.userId ?? "existing-account"
        XCTAssertTrue(commit(response(refresh: nil, email: email, uuid: uuid), attempt))
        XCTAssertEqual(values[refreshKey], "old-refresh")
        XCTAssertEqual(values[accessKey], "new-access")
    }

    func testRenewalCannotSupersedeExplicitLoginAndStaleErrorCannotSignOut() throws {
        let renewal = try XCTUnwrap(ServerSettings.beginAuthentication(explicit: false))
        let login = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        XCTAssertNil(ServerSettings.beginAuthentication(explicit: false))
        XCTAssertTrue(commit(response(), login))
        var signouts = 0
        ServerSettings.ifAuthenticationIsCurrent(renewal) { signouts += 1 }
        XCTAssertEqual(signouts, 0)
    }

    func testCommittedEffectsAreRejectedAfterSameAccountRelogin() throws {
        let first = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        XCTAssertTrue(commit(response(), first))
        var effects = 0
        XCTAssertTrue(ServerSettings.withCommittedAuthentication(first) { effects += 1 })
        let second = try XCTUnwrap(ServerSettings.beginAuthentication(email: "b@example.com"))
        XCTAssertTrue(commit(response(), second))
        XCTAssertFalse(ServerSettings.withCommittedAuthentication(first) { effects += 1 })
        XCTAssertEqual(effects, 1)
    }
}
