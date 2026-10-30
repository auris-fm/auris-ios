import Foundation
import PocketCastsServer

/// Supplies only the account refresh token for the Auris verifier exchange. A legacy
/// password session with no refresh token first renews through the normal account path.
struct CloudAccountSessionCredentialProvider {
    private let refreshTokenReader: () -> String?
    private let migrate: () -> Void

    init(
        refreshTokenReader: (() -> String?)? = nil,
        migrate: (() -> Void)? = nil
    ) {
        self.refreshTokenReader = refreshTokenReader ?? { try? ServerSettings.refreshToken() }
        self.migrate = migrate ?? (refreshTokenReader == nil ? { ServerSettings.refreshPasswordSessionIfNeeded() } : {})
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
        if let refresh = refreshTokenReader(), !refresh.isEmpty { return refresh }
        migrate()
        guard let refresh = refreshTokenReader(), !refresh.isEmpty else { return nil }
        return refresh
    }
}
