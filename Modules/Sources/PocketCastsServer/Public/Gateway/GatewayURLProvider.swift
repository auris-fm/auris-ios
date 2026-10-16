import Foundation
import PocketCastsUtils

/// Resolves the Pocket Casts **API-family** base URL for Auris gateway cutover
/// (cloud-catalog.md#mobile-client-cutover).
///
/// When cutover is active, [ServerConstants.Urls.api] collapses onto the configured
/// gateway host. Other Pocket Casts hosts (static/CDN, search, refresh, lists,
/// files, shownotes) stay on their original upstreams until the gateway supports
/// multi-upstream host routing — collapsing them onto the single configured
/// upstream (`api.pocketcasts.com`) turns public CDN/discover 200s into 401s.
///
/// Auris-owned routes (`/api/v1/cloud/...`) use [CloudConfig.baseUrl] (host only)
/// plus their absolute path — not this resolver.
public final class GatewayURLProvider {
    public static var shared = GatewayURLProvider()

    /// Runtime override / configured gateway URL (same key as `CloudConfig`).
    public static let baseURLKey = "auris_cloud_base_url"
    /// Local-first kill switch: force direct upstream without reinstalling.
    public static let directUpstreamKey = "auris_gateway_direct_upstream"

    private let defaults: UserDefaults
    private let buildDefaultGatewayURL: String

    public init(
        defaults: UserDefaults = .standard,
        buildDefaultGatewayURL: String = GatewayURLProvider.buildTimeDefault()
    ) {
        self.defaults = defaults
        self.buildDefaultGatewayURL = buildDefaultGatewayURL
    }

    /// Build-time default from Info.plist (`AurisCloudBaseURL`), else empty.
    public static func buildTimeDefault() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "AurisCloudBaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Gateway URL from UserDefaults override (if key present) or build default.
    public func configuredGatewayURL() -> String {
        if defaults.object(forKey: Self.baseURLKey) != nil {
            return defaults.string(forKey: Self.baseURLKey) ?? ""
        }
        return buildDefaultGatewayURL
    }

    public func isDirectUpstreamForced() -> Bool {
        defaults.bool(forKey: Self.directUpstreamKey)
    }

    public func isCutoverActive() -> Bool {
        !configuredGatewayURL().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isDirectUpstreamForced()
    }

    /// Collapses to gateway when cutover is active; otherwise returns `upstream`.
    /// Always returns a trailing-slash URL to match existing iOS call sites.
    public func resolve(upstream: String) -> String {
        let gateway = configuredGatewayURL().trimmingCharacters(in: .whitespacesAndNewlines)
        let direct = isDirectUpstreamForced()
        let cutover = !gateway.isEmpty && !direct
        let resolved = cutover ? Self.withTrailingSlash(gateway) : upstream
        // Bounded diagnostic: the DECISION and the hosts, never a credential. Without this a
        // cutover that silently stops applying is indistinguishable from one that never applied
        // — which is exactly how API-family traffic was observed reverting from the gateway to
        // the production upstream mid-session with nothing in the log to say why.
        FileLog.shared.addMessage(
            "[Gateway] resolve: gatewayConfigured=\(!gateway.isEmpty) directUpstreamForced=\(direct)"
                + " cutoverActive=\(cutover) -> host=\(Self.hostLabel(resolved))"
        )
        return resolved
    }

    /// The host alone, for logging. Never a path or a query, so nothing credential-shaped or
    /// account-specific can reach the log through this line.
    static func hostLabel(_ url: String) -> String {
        URL(string: url)?.host ?? "(unparseable)"
    }

    public static func withTrailingSlash(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    public static func withoutTrailingSlash(_ url: String) -> String {
        url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
