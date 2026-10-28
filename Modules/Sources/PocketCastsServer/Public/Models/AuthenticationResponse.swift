import Foundation

public struct AuthenticationResponse: Codable {
    public var localAttempt: AuthenticationAttempt? = nil
    private enum CodingKeys: String, CodingKey { case token, uuid, email, refreshToken, isNewAccount }
    public let token: String?
    public let uuid: String?
    public let email: String?
    public let refreshToken: String?
    public let isNewAccount: Bool?

    internal init(token: String?, uuid: String?, email: String?, refreshToken: String?, isNewAccount: Bool? = nil) {
        self.token = token
        self.uuid = uuid
        self.email = email
        self.refreshToken = refreshToken
        self.isNewAccount = isNewAccount
    }

    /// From the JSON `login_pocket_casts` endpoint.
    ///
    /// Unlike `Api_UserLoginResponse`, this response carries a refresh token, so a password sign-in
    /// can leave the app holding a credential it can actually renew. An empty value is treated as
    /// absent rather than stored as a blank credential.
    internal init(from apiResponse: PocketCastsLoginResponse) {
        token = apiResponse.accessToken.flatMap { $0.isEmpty ? nil : $0 }
        uuid = apiResponse.uuid.flatMap { $0.isEmpty ? nil : $0 }
        email = apiResponse.email.flatMap { $0.isEmpty ? nil : $0 }
        refreshToken = apiResponse.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
        isNewAccount = apiResponse.isNew ?? false
    }

    internal init(from apiResponse: Api_UserLoginResponse) {
        token = apiResponse.token.isEmpty ? nil : apiResponse.token
        uuid = apiResponse.uuid.isEmpty ? nil : apiResponse.uuid
        email = apiResponse.email.isEmpty ? nil : apiResponse.email
        refreshToken = nil
        isNewAccount = false
    }

    internal init(from apiResponse: Api_TokenLoginResponse) {
        token = apiResponse.accessToken.isEmpty ? nil : apiResponse.accessToken
        uuid = apiResponse.uuid.isEmpty ? nil : apiResponse.uuid
        email = apiResponse.email.isEmpty ? nil : apiResponse.email
        refreshToken = apiResponse.refreshToken
        isNewAccount = apiResponse.isNew
    }
}
