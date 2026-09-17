import Foundation
import PocketCastsServer

/// Configuration for the Auris cloud server the client talks to
/// (cloud assistant + fingerprint reference data).
///
/// The effective base URL is the gateway URL when cutover is active
/// ([GatewayURLProvider.isCutoverActive]). Resolution order: UserDefaults
/// `auris_cloud_base_url` override (if key present), then build-time
/// `AurisCloudBaseURL`. An empty effective URL disables cloud alignment — the
/// client degrades to the transcript-sync mapping and `client_position_ms`.
/// Pocket Casts API-family traffic uses the same gateway via
/// [ServerConstants.Urls.api]; other Pocket Casts hosts stay direct. The kill
/// switch `auris_gateway_direct_upstream` restores direct API upstream.
final class CloudConfig {
    static let shared = CloudConfig()

    private let gateway: GatewayURLProvider

    init(defaults: UserDefaults = .standard, buildDefaultGatewayURL: String? = nil) {
        if let buildDefaultGatewayURL {
            gateway = GatewayURLProvider(defaults: defaults, buildDefaultGatewayURL: buildDefaultGatewayURL)
        } else {
            gateway = GatewayURLProvider(defaults: defaults)
        }
    }

    /// Gateway host without trailing slash when cutover is active; else empty.
    var baseUrl: String {
        guard gateway.isCutoverActive() else { return "" }
        return GatewayURLProvider.withoutTrailingSlash(gateway.configuredGatewayURL())
    }

    static let baseURLKey = GatewayURLProvider.baseURLKey
    static let directUpstreamKey = GatewayURLProvider.directUpstreamKey
}
