import XCTest
@testable import podcasts
import PocketCastsUtils

/// Scope probe for the credential-recovery investigation.
///
/// This does NOT recover anything and reads no real credential. It writes a SYNTHETIC entry
/// through the app's own `KeychainHelper` and reads it back with `SecItemCopyMatching` using
/// class + service + access-group and `kSecReturnAttributes` ONLY — never `kSecReturnData`.
///
/// The purpose is to establish the query SHAPE the helper can actually satisfy on a given
/// signing scope, so a later read-only check against a real group can be judged safe or not.
/// It must be run on a scratch simulator: nothing here belongs in the shared suite, and it is
/// skipped unless explicitly enabled.
final class KeychainScopeProbeTests: XCTestCase {
    private let probeKey = "__scope_probe__"

    /// Explicit enablement, read by EVERY hook that can touch the store.
    ///
    /// `setUp` and `tearDown` run even when the test body skips, so an ungated remove here means
    /// a disabled shared-suite run still WRITES to the keychain of whatever device it runs on.
    /// The gate therefore has to cover the hooks, not just the body — skip semantics do not
    /// protect the store.
    private var probeEnabled: Bool {
        ProcessInfo.processInfo.environment["AURIS_KEYCHAIN_SCOPE_PROBE"] == "1"
    }

    override func setUp() {
        super.setUp()
        guard probeEnabled else { return }
        _ = KeychainHelper.removeKey(probeKey)
    }

    override func tearDown() {
        guard probeEnabled else {
            super.tearDown()
            return
        }
        _ = KeychainHelper.removeKey(probeKey)
        super.tearDown()
    }

    func testSyntheticEntryIsReadableByAttributesOnly() throws {
        try XCTSkipUnless(
            probeEnabled,
            "scope probe runs only when explicitly enabled on a scratch simulator"
        )

        // 1. Write a SYNTHETIC value through the app's own helper — no real credential.
        let saved = KeychainHelper.save(
            string: "synthetic-probe-value",
            key: probeKey,
            accessibility: kSecAttrAccessibleAfterFirstUnlock
        )
        XCTAssertTrue(saved, "the helper could not write a synthetic entry")

        // 2. Read back with ATTRIBUTES ONLY. `kSecReturnData` is deliberately absent.
        let service = "fm.auris." + probeKey
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        XCTAssertEqual(status, errSecSuccess, "attributes-only read failed with status \(status)")

        let attributes = try XCTUnwrap(result as? [String: Any])
        // Report what the store DISCLOSES, never the value.
        let disclosed = attributes.keys.sorted().joined(separator: ",")
        print("SCOPE-PROBE status=\(status) service=\(service) attributes=[\(disclosed)]")
        XCTAssertNotNil(attributes[kSecAttrAccessGroup as String], "no access group disclosed")
    }
}
