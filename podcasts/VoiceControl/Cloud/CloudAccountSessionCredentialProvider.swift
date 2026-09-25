import Foundation
import PocketCastsServer

/// Task #33 client half — supplies the credential the app *already holds* at
/// login (owner-ruled shape (a)): the account session the client obtained from
/// the existing account path.
///
/// The account verifier exchanges this at `POST /user/token` with
/// `grant_type=refresh_token` (`ModeRefreshExchange`), so the **account refresh
/// token is preferred**. Both values come from the app's existing session
/// (`ServerSettings.refreshToken()` / `ServerSettings.syncingV2Token`), and
/// nothing is stored or logged here — this type only reads the session the app
/// already holds.
struct CloudAccountSessionCredentialProvider {
    private let refreshTokenReader: () -> String?
    private let accessTokenReader: () -> String?

    init(
        refreshTokenReader: @escaping () -> String? = { try? ServerSettings.refreshToken() },
        accessTokenReader: @escaping () -> String? = { ServerSettings.syncingV2Token }
    ) {
        self.refreshTokenReader = refreshTokenReader
        self.accessTokenReader = accessTokenReader
    }

    /// The credential to present, or nil when the user is not signed in — in
    /// which case the caller fails closed and dials nothing.
    ///
    /// Order matters and is driven by what the app actually stores: an
    /// **email + password login** returns only an access token
    /// (`Api_UserLoginResponse` carries no refresh token, so
    /// `refreshToken()` stays empty), while a refresh/SSO exchange stores both.
    /// So the refresh token is preferred when present — it is the value the
    /// account verifier's refresh-exchange mode consumes — and the access token
    /// is the fallback that makes a password login usable at all.
    func credential() -> String? {
        if let refresh = refreshTokenReader(), !refresh.isEmpty { return refresh }
        if let access = accessTokenReader(), !access.isEmpty { return access }
        return nil
    }
}
