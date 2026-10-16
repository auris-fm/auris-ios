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
    /// The credential to present, or nil when the app holds no refresh token.
    ///
    /// **The refresh token only.** The verifier's refresh-exchange mode puts whatever it is
    /// given into a `refresh_token` field and asks the upstream to refresh it, so presenting an
    /// ACCESS token there relabels it: the server cannot tell the two apart, has one field, and
    /// asks the upstream to refresh something that is not a refresh token. The upstream answers
    /// `invalid_grant`, which is the client's fault for putting the wrong value in the field,
    /// not evidence about the session.
    ///
    /// An earlier version fell back to the access token "so a password login stays usable". That
    /// fallback is exactly the defect: it trades a clear, local "no refresh token" — which the
    /// caller handles by failing closed and dialling nothing — for a server round trip that
    /// reports a self-inflicted `invalid_grant` as though the session were bad.
    func credential() -> String? {
        guard let refresh = refreshTokenReader(), !refresh.isEmpty else { return nil }
        return refresh
    }
}
