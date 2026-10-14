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

        // ESTABLISH / VERIFY MODES for the disposable no-reinstall container control. One installed
        // binary, launched twice; the sentinel lives INSIDE this app's container, so the same
        // container ID can be asserted across the two launches and the helper read in between.
        // usage: credential-recovery-helper --scratch-establish <group> <service> <account> <sentinel>
        //        credential-recovery-helper --scratch-verify    <group> <service> <account> <sentinel>
        if args.first == "--scratch-establish" || args.first == "--scratch-verify" {
            let verifying = args.first == "--scratch-verify"
            let rest = Array(args.dropFirst())
            guard rest.count == 4 else {
                print("usage: credential-recovery-helper --scratch-establish|--scratch-verify <group> <service> <account> <sentinelPath>")
                return 2
            }
            let (group, service, account, sentinelPath) = (rest[0], rest[1], rest[2], rest[3])
            guard service.hasPrefix("fm.auris.SCRATCH") else {
                print("refused: scratch modes accept only synthetic services (fm.auris.SCRATCH*)")
                return 2
            }
            let container = NSHomeDirectory()
            // The sentinel path is resolved RELATIVE TO THIS APP'S CONTAINER, so both launches touch
            // the same file even though launchd may start each with a different working directory.
            // A bare relative path made both reads return nil, which compared equal and passed
            // vacuously.
            // A BARE FILENAME is relative to this container; only a path with a directory prefix is
            // treated as absolute. `URL(fileURLWithPath: "sentinel.txt").path` is "/sentinel.txt",
            // so testing hasPrefix("/") wrongly classified a bare name as absolute and wrote to the
            // filesystem root.
            let sentinelURL = sentinelPath.contains("/")
                ? URL(fileURLWithPath: sentinelPath)
                : URL(fileURLWithPath: container).appendingPathComponent(sentinelPath)
            if !verifying {
                // ESTABLISH: write the canary and a sentinel INSIDE this container, recording the
                // expected sentinel value beside it so the verify launch compares against it.
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrAccessGroup as String: group,
                ] as CFDictionary)
                let value = "canary-\(UUID().uuidString)"
                let status = SecItemAdd([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrAccessGroup as String: group,
                    kSecValueData as String: Data(value.utf8),
                ] as CFDictionary, nil)
                let sentinel = "sentinel-\(UUID().uuidString)"
                try? Data(sentinel.utf8).write(to: sentinelURL)
                try? Data(sentinel.utf8).write(to: sentinelURL.appendingPathExtension("expected"))
                print("SCRATCH-ESTABLISH container=\(container) write=\(status) canary=\(value)")
                print("SCRATCH-ESTABLISH sentinelPath=\(sentinelURL.path) sentinel=\(sentinel)")
                return status == errSecSuccess ? 0 : 4
            } else {
                // VERIFY: read the canary back and compare the sentinel, both against the recorded
                // expectations. Nothing is written on this path.
                var out: CFTypeRef?
                let status = SecItemCopyMatching([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecAttrAccessGroup as String: group,
                    kSecReturnData as String: true,
                    kSecReturnAttributes as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ] as CFDictionary, &out)
                let dict = out as? [String: Any]
                let bytes = (dict?[kSecValueData as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
                let attributed = dict?[kSecAttrAccessGroup as String] as? String
                let sentinel = try? String(contentsOf: sentinelURL, encoding: .utf8)
                let expected = try? String(contentsOf: sentinelURL.appendingPathExtension("expected"), encoding: .utf8)
                // A missing sentinel must FAIL, not compare nil == nil and pass.
                let sentinelOK = (sentinel != nil && sentinel == expected)
                print("SCRATCH-VERIFY container=\(container) read=\(status) attributedGroup=\(attributed as Any)")
                print("SCRATCH-VERIFY sentinelPath=\(sentinelURL.path) sentinelPresent=\(sentinel != nil) sentinelMatch=\(sentinelOK)")
                print("SCRATCH-VERIFY canaryPresent=\(bytes != nil)")
                return (status == errSecSuccess && sentinelOK && bytes != nil) ? 0 : 6
            }
        }

        // SYNTHETIC-CANARY MODE: a narrowly scoped read of ONE caller-supplied synthetic service,
        // used by the disposable same-access-group control. It is deliberately separate from the
        // assigned production keys below, so this mode can never be pointed at a production service:
        // the service must carry the synthetic marker, and it returns ATTRIBUTES ONLY.
        // usage: credential-recovery-helper --synthetic <group> <service> <account>
        if args.first == "--synthetic" {
            let rest = Array(args.dropFirst())
            guard rest.count == 3 else {
                print("usage: credential-recovery-helper --synthetic <accessGroup> <service> <account>")
                return 2
            }
            let (group, service, account) = (rest[0], rest[1], rest[2])
            guard service.hasPrefix("fm.auris.SCRATCH") else {
                print("refused: synthetic mode accepts only synthetic services (fm.auris.SCRATCH*)")
                return 2
            }
            print("RECOVERY-CHECK synthetic group=\(group) service=\(service) account=\(account)")
            var result: AnyObject?
            let status = SecItemCopyMatching([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: group,
                kSecReturnAttributes as String: true,   // attributes ONLY; no kSecReturnData
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, &result)
            let attrs = result as? [String: Any]
            let attributed = attrs?[kSecAttrAccessGroup as String] as? String
            print("  synthetic: status=\(status) attributedGroup=\(attributed as Any)")
            return status == errSecSuccess ? 0 : 4
        }

        guard let group = args.first, !group.isEmpty else {
            print("usage: credential-recovery-helper <accessGroup> [service-key ...]")
            return 2
        }
        // Only the two ASSIGNED service keys are accepted. An arbitrary caller-supplied key would
        // turn a narrow, reviewable probe into a general keychain reader, which is a wider
        // authority than this helper was authorised to hold.
        let requested = args.count > 1 ? Array(args.dropFirst()) : assignedKeys
        let rejected = requested.filter { !assignedKeys.contains($0) }
        guard rejected.isEmpty else {
            print("refused: key(s) not assigned to this helper: \(rejected.joined(separator: ", "))")
            print("assigned keys: \(assignedKeys.joined(separator: ", "))")
            return 2
        }
        let keys = requested

        print("RECOVERY-CHECK group=\(group)")
        var outcomes: [VerdictKind] = []
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
            let verdict = Helper.verdict(for: status, result: result, key: key, group: group)
            print("  " + verdict.message)
            outcomes.append(verdict.kind)
            query.removeAll()
        }
        return Helper.exitCode(for: outcomes)
    }

    /// What one key's read meant. **Pure and separately drivable**, so the mapping from an
    /// OSStatus to an outcome can be exercised with SIMULATED statuses — no keychain, no real
    /// credential, and no forced signing failure are needed to prove the mapping.
    enum VerdictKind {
        case present
        /// The store answered "no such item". Inconclusive about ACCESS: an empty store and an
        /// unaddressable group are indistinguishable here, so this must never be read as absence.
        case notFound
        /// The store refused the read (e.g. `errSecMissingEntitlement`). Distinct from not-found
        /// and never folded into success.
        case refused
        /// A bare success whose item is attributed to a DIFFERENT access group. The read worked, but
        /// it did not read what was asked for, so it must not certify success.
        case wrongGroup
        /// A bare success carrying no usable access-group attribute, so the group cannot be
        /// confirmed. Unverifiable is not matched.
        case malformedSuccess
    }

    struct Verdict {
        let kind: VerdictKind
        let message: String
    }

    static func verdict(for status: OSStatus, result: AnyObject?, key: String, group: String) -> Verdict {
        switch status {
        case errSecSuccess:
            // Success ALSO requires a MATCHING, WELL-FORMED group attribute. The exit-code contract
            // promises "0 = PRESENT and the group matched"; returning .present on a bare success let
            // an item attributed to a DIFFERENT group exit 0, which certifies a condition we did not
            // check. A missing or non-string attribute is not "matched" either — it is unverifiable.
            let attrs = result as? [String: Any] ?? [:]
            guard let returned = attrs[kSecAttrAccessGroup as String] as? String,
                  !returned.isEmpty else {
                return Verdict(kind: .malformedSuccess,
                               message: "\(key): matched a status but carried NO usable access-group "
                                      + "attribute — cannot confirm the group, so NOT a success")
            }
            guard returned == group else {
                return Verdict(kind: .wrongGroup,
                               message: "\(key): PRESENT but attributed to group=\(returned), "
                                      + "NOT the requested \(group) — a different group is not this group")
            }
            return Verdict(kind: .present, message: "\(key): PRESENT group=EQUAL")
        case errSecItemNotFound:
            return Verdict(kind: .notFound,
                           message: "\(key): not found — INCONCLUSIVE. This reader's access to the group is not "
                                  + "established, so not-found cannot be read as absence.")
        default:
            return Verdict(kind: .refused,
                           message: "\(key): UNREADABLE osstatus=\(status) — a refusal is NOT absence")
        }
    }

    /// Exit code states WHAT HAPPENED, so a caller cannot read a refusal as success:
    ///   0 = every assigned key was PRESENT **and attributed to the requested group**
    ///   3 = a key was NOT PRESENT (inconclusive about access, but a distinct outcome)
    ///   4 = the store REFUSED the read. Never conflated with absence.
    ///   5 = present but attributed to a DIFFERENT group — read worked, wrong thing read
    ///   6 = present with no usable group attribute — the group cannot be confirmed
    /// A refusal outranks a not-found: the sharper signal wins.
    static func exitCode(for kinds: [VerdictKind]) -> Int32 {
        // Ordered sharpest-first. Success is now the NARROWEST outcome: it requires every key
        // present AND attributed to the requested group.
        if kinds.contains(.refused) { return 4 }
        if kinds.contains(.wrongGroup) { return 5 }
        if kinds.contains(.malformedSuccess) { return 6 }
        if kinds.contains(.notFound) { return 3 }
        return 0
    }
}
exit(Helper.run())
