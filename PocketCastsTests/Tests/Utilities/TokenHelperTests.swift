import Foundation
import Security
import XCTest
@testable import PocketCastsServer
import PocketCastsUtils

fileprivate extension URL {
    static var userLogin: URL {
        return ServerHelper.asUrl(ServerConstants.Urls.api() + "user/login_pocket_casts")
    }
    static var userUpdate: URL {
        return ServerHelper.asUrl(ServerConstants.Urls.main() + "user/update")
    }
}

class TokenHelperTests: XCTestCase {
    private var previous: [String: String] = [:]
    private var previousUserID: String?
    private var previousIncompleteWrite = false
    private let credentialKeys = [ServerConstants.Values.syncingV2TokenKey, ServerConstants.Values.refreshTokenKey,
                                  ServerConstants.Values.syncingEmailKey, ServerConstants.Values.syncingPasswordKey, ServerConstants.Values.appleAuthUserIDKey]

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousUserID = ServerSettings.userId
        previousIncompleteWrite = UserDefaults.standard.bool(forKey: "AurisIncompleteCredentialWrite")
        for key in credentialKeys {
            previous[key] = try KeychainHelper.string(for: key)
            XCTAssertTrue(KeychainHelper.removeKey(key))
        }
        UserDefaults.standard.set(false, forKey: "AurisIncompleteCredentialWrite")
    }

    override func tearDownWithError() throws {
        for key in credentialKeys {
            XCTAssertTrue(KeychainHelper.save(string: previous[key], key: key, accessibility: kSecAttrAccessibleAfterFirstUnlock))
        }
        ServerSettings.userId = previousUserID
        UserDefaults.standard.set(previousIncompleteWrite, forKey: "AurisIncompleteCredentialWrite")
        try super.tearDownWithError()
    }


    func testFirstLaunchClearAllowsPlainAccountRegistration() {
        SyncManager.clearTokensFromKeyChain()
        ServerSettings.setSyncingEmail(email: "registered@example.com")
        ServerSettings.saveSyncingPassword("registered-password")
        XCTAssertEqual(ServerSettings.syncingEmail(), "registered@example.com")
        XCTAssertEqual(ServerSettings.syncingPassword(), "registered-password")
        XCTAssertTrue(SyncManager.isUserLoggedIn())
    }

    func testRejectedStoredPasswordSignsOutForDefinitiveAccountErrors() {
        for error in [APIError.INCORRECT_PASSWORD, .EMAIL_NOT_FOUND] {
            ServerSettings.setSyncingEmail(email: "test@test.com")
            ServerSettings.saveSyncingPassword("rejected-password")
            UserDefaults.standard.set(false, forKey: "AurisIncompleteCredentialWrite")
            XCTAssertTrue(SyncManager.isUserLoggedIn(), "test premise: an existing password session")
            let helper = TokenHelper(urlConnection: URLConnection { request in
                let data = try JSONSerialization.data(withJSONObject: ["errorMessageId": error.rawValue])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil))
            }, backgroundState: { false })
            XCTAssertNil(helper.acquireToken())
            XCTAssertFalse(SyncManager.isUserLoggedIn())
            XCTAssertNil(ServerSettings.syncingPassword())
        }
    }

    func testRejectedPasswordResponseCannotSignOutASupersedingLogin() throws {
        ServerSettings.setSyncingEmail(email: "test@test.com")
        ServerSettings.saveSyncingPassword("old-password")
        let helper = TokenHelper(urlConnection: URLConnection { request in
            let login = try XCTUnwrap(ServerSettings.beginAuthentication(email: "new@example.com"))
            let response = AuthenticationResponse(token: "new-access", uuid: "new-account", email: "new@example.com", refreshToken: "new-refresh")
            XCTAssertTrue(ServerSettings.commitAuthentication(response, for: login, password: "new-password"))
            let data = try JSONSerialization.data(withJSONObject: ["errorMessageId": APIError.INCORRECT_PASSWORD.rawValue])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil))
        }, backgroundState: { false })
        XCTAssertNil(helper.acquireToken())
        XCTAssertEqual(ServerSettings.syncingEmail(), "new@example.com")
        XCTAssertEqual(ServerSettings.syncingV2Token, "new-access")
        XCTAssertEqual(try ServerSettings.refreshToken(), "new-refresh")
    }

    @MainActor
    func testMainThreadMigrationDoesNotWaitOnRenewalsMainThreadStateQuery() {
        ServerSettings.setSyncingEmail(email: "test@test.com")
        ServerSettings.saveSyncingPassword("1234")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "background renewal finished")
        let stateLock = NSLock()
        var queryTimedOut = false
        let helper = TokenHelper(urlConnection: URLConnection { request in
            (nil, HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil))
        }, backgroundState: {
            if Thread.isMainThread { return true }
            entered.signal()
            let timedOut = release.wait(timeout: .now() + 2) == .timedOut
            stateLock.withLock { queryTimedOut = timedOut }
            return true
        })
        DispatchQueue.global().async {
            _ = helper.acquireToken()
            finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        // The background caller is deliberately parked in its main-state query. This
        // main-thread migration must acquire/release the renewal lock before we unpark it.
        XCTAssertNil(helper.acquireToken(onlyIfMissingRefresh: true))
        release.signal()
        wait(for: [finished], timeout: 3)
        XCTAssertFalse(stateLock.withLock { queryTimedOut }, "renewal held its lock while waiting on main")
    }

    func testSSORenewalUsesRefreshGrantAndPreservesAnOmittedRefreshToken() throws {
        // The watch restores credentials through these plain setters after signout.
        SyncManager.clearTokensFromKeyChain()
        ServerSettings.setSyncingEmail(email: "test@test.com")
        ServerSettings.userId = "uuid-test"
        ServerSettings.setRefreshToken("refresh-existing")
        ServerSettings.syncingV2Token = "access-existing"
        XCTAssertTrue(SyncManager.isUserLoggedIn())
        XCTAssertEqual(try ServerSettings.refreshToken(), "refresh-existing")
        var requests = 0
        let helper = TokenHelper(urlConnection: URLConnection { request in
            requests += 1
            XCTAssertEqual(request.url, ServerHelper.asUrl(ServerConstants.Urls.api() + "user/token"))
            let body = try Api_UserTokenRequest(serializedBytes: XCTUnwrap(request.httpBody))
            XCTAssertEqual(body.refreshToken, "refresh-existing")
            XCTAssertEqual(body.grantType, "refresh_token")
            var response = Api_TokenLoginResponse()
            response.accessToken = "access-renewed"
            response.uuid = "uuid-test"
            response.email = "test@test.com"
            return (try response.serializedData(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
        }, backgroundState: { true })
        XCTAssertEqual(helper.acquireToken(), "access-renewed")
        XCTAssertEqual(try ServerSettings.refreshToken(), "refresh-existing")
        XCTAssertEqual(ServerSettings.syncingV2Token, "access-renewed")
        XCTAssertEqual(requests, 1)
    }

    /// Tests the acquirePasswordToken function
    func testAcquirePasswordToken() {
        ServerSettings.setSyncingEmail(email: "test@test.com")
        ServerSettings.saveSyncingPassword("1234")

        let tokenHelper = TokenHelper(urlConnection: URLConnection { request in
            let url = ServerHelper.asUrl(ServerConstants.Urls.api() + "user/login_pocket_casts")
            if request.url == url {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF8")
                let body = try XCTUnwrap(request.httpBody)
                let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
                XCTAssertEqual(decoded?["email"], "test@test.com")
                XCTAssertEqual(decoded?["password"], "1234")
                let data = try JSONSerialization.data(withJSONObject: ["accessToken": "1234", "refreshToken": "refresh-1234", "uuid": "uuid-test", "email": "test@test.com"])
                return (data, response)
            } else {
                throw NSError()
            }
        })
        do {
            let response = try tokenHelper.acquirePasswordToken()
            XCTAssertEqual(response?.token, "1234")
            XCTAssertEqual(response?.email, "test@test.com")
            XCTAssertEqual(response?.refreshToken, "refresh-1234")
            XCTAssertNotNil(response?.uuid, "Should receive UUID")
        } catch {
            XCTFail("Acquire Password Token shouldn't fail: \(error)")
        }
    }

    /// Tests the acquireAsyncToken function with
    func testAcquireAsyncToken() {
        ServerSettings.setSyncingEmail(email: "test@test.com")
        ServerSettings.saveSyncingPassword("1234")

        let tokenHelper = TokenHelper(urlConnection: URLConnection { request in
            let url = ServerHelper.asUrl(ServerConstants.Urls.api() + "user/login_pocket_casts")
            if request.url == url {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF8")
                let body = try XCTUnwrap(request.httpBody)
                let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
                XCTAssertEqual(decoded?["email"], "test@test.com")
                XCTAssertEqual(decoded?["password"], "1234")
                let data = try JSONSerialization.data(withJSONObject: ["accessToken": "1234", "refreshToken": "refresh-1234", "uuid": "uuid-test", "email": "test@test.com"])
                return (data, response)
            } else {
                throw NSError()
            }
        })

        let expectation = XCTestExpectation(description: "Waiting on asyncAcquireToken to complete")
        tokenHelper.asyncAcquireToken { result in
            switch result {
            case .success(let response):
                XCTAssertEqual(response?.token, "1234")
                XCTAssertEqual(response?.email, "test@test.com")
            XCTAssertEqual(response?.refreshToken, "refresh-1234")
                XCTAssertNotNil(response?.uuid, "Should receive UUID")
            case .failure(let error):
                XCTFail("Failed async acquire with error: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation])
    }

    func testCallSecureURL() {

        ServerSettings.setSyncingEmail(email: "test@test.com")
        ServerSettings.saveSyncingPassword("1234")

        let tokenHelper = TokenHelper(urlConnection: URLConnection { request in
            switch request.url {
            case URL.userLogin:
                let response = HTTPURLResponse(url: .userLogin, statusCode: 200, httpVersion: nil, headerFields: nil)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF8")
                let body = try XCTUnwrap(request.httpBody)
                let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
                XCTAssertEqual(decoded?["email"], "test@test.com")
                XCTAssertEqual(decoded?["password"], "1234")
                let data = try JSONSerialization.data(withJSONObject: ["accessToken": "1234", "refreshToken": "refresh-1234", "uuid": "uuid-test", "email": "test@test.com"])
                return (data, response)
            case URL.userUpdate:
                let response = HTTPURLResponse(url: .userUpdate, statusCode: 200, httpVersion: nil, headerFields: nil)
                // Any data will do here, just to see if it makes it through
                let data = "Test".data(using: .utf8)
                return (data, response)
            default:
                throw NSError()
            }
        })

        let expectation = XCTestExpectation(description: "Waiting on asyncAcquireToken to complete")
        tokenHelper.callSecureUrl(request: URLRequest(url: .userUpdate)) { response, data, error in
            if let error {
                XCTFail("Failed async acquire with error: \(error)")
            } else {
                XCTAssertNotNil(response, "Should have received response")
                XCTAssertNotNil(data, "Should have received data")
            }
            expectation.fulfill()
        }
        wait(for: [expectation])
    }
}
