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
                                  ServerConstants.Values.syncingEmailKey, ServerConstants.Values.syncingPasswordKey]

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
