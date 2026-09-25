import Foundation
import PocketCastsUtils

/// Chooses the credential source for an edge call, per call, while keeping **one
/// shared Auris provider**.
///
/// A configured Auris origin means the deployment is on the Auris-issued token
/// path, so the Auris provider is used; with no origin configured the app keeps
/// today's trust-on-first-use static provider. The decision is made per call, so
/// enabling the gateway switches the credential source without a restart and the
/// legacy `user_<uuid>` bearer cannot reach the edge once an origin exists.
///
/// The Auris provider is shared rather than constructed per client: its token
/// cache, rotating refresh chain and single-flight handle are instance state, so
/// building one per client would start cold on every turn, exchange again each
/// time, and stop the route and prefetch paths sharing a refresh lock (PR #20
/// review). The provider keys its cache to the origin as well as the account, so
/// sharing it across an origin change cannot replay a token minted elsewhere.
enum CloudTokenProviderRouter {
    private static let sharedAurisProvider = CloudAuthTokenProvider(
        authBaseURLProvider: { CloudConfig.shared.baseUrl },
        credentialProvider: { CloudAccountSessionCredentialProvider().credential() }
    )
    private static let sharedStaticProvider = CloudStaticIdentityTokenProvider()

    /// - Parameters:
    ///   - aurisBaseURL: predicate only — *whether* the Auris provider is chosen.
    ///     The shared provider reads `CloudConfig` itself for the origin it dials.
    ///   - edgeTokensEnabled: the explicit switch that makes the credential change
    ///     deferrable; a configured origin alone is not enough, since that is also
    ///     what makes the assistant work (see `FeatureFlag.cloudEdgeTokens`).
    static func provider(
        aurisBaseURL: String = CloudConfig.shared.baseUrl,
        edgeTokensEnabled: Bool = FeatureFlag.cloudEdgeTokens.enabled
    ) -> any CloudTokenProviding {
        guard edgeTokensEnabled, !aurisBaseURL.isEmpty else { return sharedStaticProvider }
        return sharedAurisProvider
    }
}
