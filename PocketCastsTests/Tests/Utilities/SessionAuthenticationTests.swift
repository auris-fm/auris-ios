import XCTest
@testable import PocketCastsServer

final class SessionAuthenticationTests: XCTestCase {
    private var values: [String: String] = [:]
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

    private func commit(_ response: AuthenticationResponse, _ attempt: AuthenticationAttempt, failAt: Int? = nil, alwaysFail: Bool = false) -> Bool {
        var writes = 0
        return ServerSettings.commitAuthentication(response, for: attempt, password: "new-password", read: { self.values[$0] }, write: { value, key in
            writes += 1
            if alwaysFail || writes == failAt { return false }
            self.values[key] = value
            return true
        }, defaults: defaults)
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
