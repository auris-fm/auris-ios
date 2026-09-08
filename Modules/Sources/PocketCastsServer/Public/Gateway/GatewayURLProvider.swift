import Foundation

/// Resolves Pocket Casts-compatible API base URLs for Auris gateway cutover
/// (cloud-catalog.md#mobile-client-cutover).
///
/// When cutover is active, proxied Pocket Casts hosts collapse to the configured
/// gateway base URL. When the gateway URL is empty or the local kill switch is
/// on, upstream hosts are used unchanged.
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
        guard isCutoverActive() else { return upstream }
        return Self.withTrailingSlash(configuredGatewayURL())
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
