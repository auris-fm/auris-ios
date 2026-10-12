import XCTest
@testable import podcasts

/// A READ-ONLY credential-store recovery check for an installed build.
///
/// Purpose: answer "is a credential present in the owner's access group?" without reading any
/// value, without writing, and without launching or modifying the owner's install. It exists
/// because every earlier negative I reported was taken with a reader that could not reach the
/// group — a wrong service name once, and the wrong signing scope twice — so "not found" told us
/// nothing. This makes the reader's own scope part of the result.
///
/// **It writes nothing.** Every call is `SecItemCopyMatching` with `kSecReturnAttributes` only;
/// `kSecReturnData` appears nowhere, so no credential value can be returned or logged even by
/// accident.
///
/// **It must run under the OWNER'S signing scope** (a StagingDebug test action), because the
/// production host refuses that group with `errSecMissingEntitlement` (-34018) — a refusal that
/// says nothing about the owner's build.
///
/// Enable with `TEST_RUNNER_AURIS_RECOVERY_CHECK=1`; skipped otherwise so it never runs in the
/// shared suite.
final class ReadOnlyCredentialRecoveryCheck: XCTestCase {
    /// The group the installed app's entries carry, and the service names it stores.
    private static let ownerGroup = "6LL2R2A55F.fm.auris.debug"
    private static let serviceKeys = [
        "SJSyncV2Token",        // access credential
        "SJRefreshToken",       // refresh credential
        "SJSyncingEmail",       // password-path material
        "SJSyncingPwd",
    ]

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["AURIS_RECOVERY_CHECK"] == "1"
    }

    override func setUp() {
        super.setUp()
        // No writes and no cleanup: this check never creates anything to remove.
    }

    /// Reports, for each service key: whether an item exists in the owner's group, and the group
    /// the store answered with. Presence and group only — never a value.
    func testReportCredentialPresenceInTheOwnerGroup() throws {
        try XCTSkipUnless(
            enabled,
            "read-only recovery check runs only when explicitly enabled under the owner's scope"
        )

        var lines: [String] = []
        lines.append("RECOVERY-CHECK group=\(Self.ownerGroup)")
        for key in Self.serviceKeys {
            let service = "fm.auris." + key
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccessGroup as String: Self.ownerGroup,
                kSecReturnAttributes as String: true,   // attributes ONLY
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            // `kSecReturnData` is deliberately never added.
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            switch status {
            case errSecSuccess:
                let attrs = result as? [String: Any] ?? [:]
                let group = attrs[kSecAttrAccessGroup as String] as? String ?? "(none)"
                lines.append("  \(key): PRESENT group=\(group)")
            case errSecItemNotFound:
                lines.append("  \(key): absent (and the group was ADDRESSABLE — not a refusal)")
            default:
                // A refusal is NOT absence, and must never be reported as one.
                lines.append("  \(key): UNREADABLE status=\(status) — the reader cannot address "
                             + "this group, so this says nothing about presence")
            }
            query.removeAll()
        }
        print(lines.joined(separator: "\n"))
    }
}
