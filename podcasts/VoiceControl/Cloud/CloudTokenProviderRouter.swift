import Foundation

/// Chooses the credential source for an edge call, per call.
///
/// A configured Auris origin means the deployment is on the Auris-issued token
/// path, so the Auris provider is used; with no origin configured the app keeps
/// today's trust-on-first-use static provider. Reading the configuration on each
/// call means enabling the gateway switches the credential source without a
/// restart, and the legacy `user_<uuid>` bearer can never reach the edge once an
/// origin exists (Android parity: the same predicate its router uses).
enum CloudTokenProviderRouter {
    static func provider(
        aurisBaseURL: String = CloudConfig.shared.baseUrl,
        identity: CloudIdentity = .shared
    ) -> any CloudTokenProviding {
        guard !aurisBaseURL.isEmpty else {
            return CloudStaticIdentityTokenProvider(identity: identity)
        }
        return CloudAuthTokenProvider(
            authBaseURLProvider: { CloudConfig.shared.baseUrl },
            credentialProvider: { CloudAccountSessionCredentialProvider().credential() }
        )
    }
}
