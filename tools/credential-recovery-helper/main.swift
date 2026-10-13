import Foundation
import Security

/// Read-only credential-store check for an installed Auris build.
///
/// Runs as a SEPARATE SIGNED BINARY, never as an XCTest: an XCTest is hosted by the app, so
/// running it installs and launches the app on whatever simulator it is pointed at. This helper is
/// installed on a SCRATCH simulator only and never touches an owner's installed app or its store.
///
/// **It writes nothing.** Every call is `SecItemCopyMatching` with `kSecReturnAttributes` only;
/// `kSecReturnData` appears nowhere, so no credential value can be returned or printed.
///
/// Usage: credential-recovery-helper <accessGroup> [service-key ...]
enum Helper {
    static let assignedKeys = ["SJSyncV2Token", "SJRefreshToken"]

    static func run() -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let group = args.first, !group.isEmpty else {
            print("usage: credential-recovery-helper <accessGroup> [service-key ...]")
            return 2
        }
        let keys = args.count > 1 ? Array(args.dropFirst()) : assignedKeys

        print("RECOVERY-CHECK group=\(group)")
        for key in keys {
            let service = "fm.auris." + key
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccessGroup as String: group,
                kSecReturnAttributes as String: true,   // attributes ONLY
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
        // kSecReturnData is deliberately never added.
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                let attrs = result as? [String: Any] ?? [:]
                let returned = attrs[kSecAttrAccessGroup as String] as? String ?? "(none)"
                let match = returned == group ? "EQUAL" : "DIFFERENT(\(returned))"
                print("  \(key): PRESENT group=\(match)")
            case errSecItemNotFound:
                print("  \(key): not found — INCONCLUSIVE. This reader's access to the group is not "
                      + "established, so not-found cannot be read as absence.")
            default:
                print("  \(key): UNREADABLE osstatus=\(status) — a refusal is NOT absence")
            }
            query.removeAll()
        }
        return 0
    }
}
exit(Helper.run())
