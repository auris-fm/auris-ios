import Foundation

/// Lightweight cloud identity (cloud-identity.md). The client generates a
/// stable random user ID on first launch, persists it locally, and sends the
/// full `user_<uuid>` string verbatim in `Authorization: Bearer <user_id>`.
/// The server treats the raw bearer value as `users.id` (trust-on-first-use).
final class CloudIdentity {
    static let shared = CloudIdentity()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the stable user ID, creating and persisting it on first call.
    var userId: String {
        if let existing = defaults.string(forKey: Self.userIDKey) {
            return existing
        }
        let id = Self.generateUserId()
        defaults.set(id, forKey: Self.userIDKey)
        return id
    }

    /// User IDs are client-generated UUIDv4 with a `user_` prefix (cloud-identity.md).
    static func generateUserId() -> String {
        "user_" + UUID().uuidString.lowercased()
    }

    private static let userIDKey = "auris_cloud_user_id"
}
