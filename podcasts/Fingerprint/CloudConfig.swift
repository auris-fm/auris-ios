import Foundation

/// Configuration for the Auris cloud server the client talks to
/// (cloud assistant + fingerprint reference data).
///
/// The base URL is stored in UserDefaults under the documented key
/// `auris_cloud_base_url`. An empty base URL disables cloud alignment — the
/// client degrades to the transcript-sync mapping and `client_position_ms`.
/// (A debug-settings entry to set this key is a follow-up.)
final class CloudConfig {
    static let shared = CloudConfig()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var baseUrl: String {
        defaults.string(forKey: Self.baseURLKey) ?? ""
    }

    static let baseURLKey = "auris_cloud_base_url"
}
