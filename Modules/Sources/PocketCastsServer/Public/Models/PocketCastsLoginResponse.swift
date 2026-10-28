import Foundation

/// Response of `POST /user/login_pocket_casts`.
///
/// Distinct from `Api_UserLoginResponse` on purpose. That type is protobuf and carries no
/// refresh token, which is why password login could never yield one. This endpoint answers JSON
/// and returns the complete token pair, so the app can hold a credential the cloud exchange can
/// renew. Field names match the server's camelCase payload exactly.
struct PocketCastsLoginRequest: Encodable {
    let email: String
    let password: String
    let scope: String
}

struct PocketCastsLoginResponse: Decodable {
    let email: String?
    let uuid: String?
    let isNew: Bool?
    let accessToken: String?
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int?
}
