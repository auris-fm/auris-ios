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
    // ONE Auris provider for every caller. Its cache, rotating refresh chain and single-flight handle
    // are instance state, so a second instance would rotate the same refresh token and revoke the
    // other's chain (`refresh_reused`). It dials the CONFIGURED origin, not the cutover-gated one: the
    // two differ only when the assistant's direct-upstream kill switch is set, and in that state the
    // assistant's own selection gate picks the static provider anyway — so this changes no assistant
    // behaviour while making the origin consistent for sharing (reviewer on f37893cd0).
    private static let sharedAurisProvider = CloudAuthTokenProvider(
        authBaseURLProvider: { CloudConfig.shared.configuredOrigin },
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

    /// The credential for Voice Sharing, on EVERY build where sharing is enabled (spec ruling
    /// 2026-11-03). Deliberately not `provider()`: the assistant's routing flag and the gateway-cutover
    /// gate both exist for their own migrations, and inheriting either would let a shipped build quietly
    /// fall back to `CloudStaticIdentityTokenProvider` — whose `token()` is a bare `user_<uuid>`, not a
    /// JWS, which the account route cannot verify under any configuration.
    ///
    /// Fail-closed on a missing origin: with no sharing origin there is no credential to present, and
    /// returning the static provider would send an identity the route must refuse. The caller treats a
    /// nil token as "sharing unavailable", which is the honest state.
    static func voiceSharingProvider(aurisBaseURL: String? = nil) -> (any CloudTokenProviding)? {
        let resolved = aurisBaseURL ?? CloudConfig.shared.configuredOrigin
        guard nonEmpty(resolved) != nil else { return nil }
        return sharedAurisProvider
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
