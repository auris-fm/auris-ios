import XCTest
@testable import PocketCastsServer

/// The sign-in response must carry a refresh token.
///
/// The defect this guards: password sign-in decoded a protobuf type with no refresh-token field,
/// so the app held only an access token, could not renew, and anything requiring a session had
/// no credential to present. These tests assert the pairing, not the string values.
final class PocketCastsLoginResponseTests: XCTestCase {
    private func decode(_ json: String) throws -> AuthenticationResponse {
        let response = try JSONDecoder().decode(PocketCastsLoginResponse.self, from: Data(json.utf8))
        return AuthenticationResponse(from: response)
    }

    func testPasswordLoginCarriesBothTokens() throws {
        let authentication = try decode("""
        {"email":"a@b.c","uuid":"U1","isNew":false,"accessToken":"access-1",
         "refreshToken":"refresh-1","tokenType":"Bearer","expiresIn":3600}
        """)

        XCTAssertEqual(authentication.token, "access-1")
        XCTAssertEqual(
            authentication.refreshToken, "refresh-1",
            "the refresh token was dropped, so the session cannot be renewed"
        )
        XCTAssertEqual(authentication.uuid, "U1")
    }

    /// An empty refresh token must be treated as absent, not stored as "".
    ///
    /// Storing an empty string would look like a credential to every reader that checks for
    /// non-nil and would then fail the exchange with an unhelpful rejection.
    func testEmptyRefreshTokenIsTreatedAsAbsent() throws {
        let authentication = try decode("""
        {"email":"a@b.c","uuid":"U1","isNew":false,"accessToken":"access-1",
         "refreshToken":"","tokenType":"Bearer","expiresIn":3600}
        """)

        XCTAssertNil(authentication.refreshToken, "an empty refresh token must not be stored as a credential")
        XCTAssertEqual(authentication.token, "access-1")
    }

    /// A response with no refresh token at all must not crash or fabricate one.
    func testMissingRefreshTokenIsNil() throws {
        let authentication = try decode(#"{"email":"a@b.c","uuid":"U1","accessToken":"access-1"}"#)

        XCTAssertNil(authentication.refreshToken)
        XCTAssertEqual(authentication.token, "access-1")
    }
}
