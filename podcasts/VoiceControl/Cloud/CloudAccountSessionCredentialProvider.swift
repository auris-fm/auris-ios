import Foundation
import PocketCastsServer

/// Task #33 client half — supplies the credential the app *already holds* at
/// login (owner-ruled shape (a)): the account session the client obtained from
/// the existing account path.
///
/// The account verifier exchanges this at `POST /user/token` with
/// `grant_type=refresh_token` (nightshift's `ModeRefreshExchange`), so the
/// **account refresh token is the credential**. That's also the value the app
/// already maintains for both password and SSO sign-in
/// (`ServerSettings.refreshToken()`, public), and the only session value the
/// server module exposes — the stored access token lives in module-internal
/// Keychain access, and widening that API isn't justified for a fallback the
/// primary exchange mode doesn't use. Nothing is stored or logged here; this
/// type only reads the session the app already holds.
struct CloudAccountSessionCredentialProvider {
    private let refreshTokenReader: () -> String?

    init(refreshTokenReader: @escaping () -> String? = { try? ServerSettings.refreshToken() }) {
        self.refreshTokenReader = refreshTokenReader
    }

    /// The credential to present, or nil when the user is not signed in — in
    /// which case the caller fails closed and dials nothing.
    func credential() -> String? {
        guard let refresh = refreshTokenReader(), !refresh.isEmpty else { return nil }
        return refresh
    }
}
