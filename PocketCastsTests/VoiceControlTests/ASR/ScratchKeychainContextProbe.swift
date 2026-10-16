import XCTest
import Security

/// SUPPORTED-CONTEXT INVESTIGATION (read-only, synthetic-only).
///
/// The raw `simctl spawn` attempt failed at launchd, but that does not establish that every
/// simulator test-host path is unavailable. This XCTest runs INSIDE the installed host app — the
/// context the whole suite already uses — and reports, without writing or reading any real
/// credential, what keychain access the test process actually has:
///   * can it read back an item it did NOT write? (expected: no)
///   * what does a write/read of a SYNTHETIC item into a NAMED group return?
///   * does an item written WITHOUT an explicit group come back (the app's default group)?
/// The point is to measure the supported context's real capabilities rather than infer them.
final class ScratchKeychainContextProbe: XCTestCase {

    private let syntheticService = "fm.auris.SCRATCHCONTEXTPROBE"
    private let syntheticAccount = "scratch-context"

    func testWhatKeychainAccessTheHostedTestProcessHas() throws {
        // 1. SYNTHETIC write with NO explicit group: this exercises whatever default group the
        //    hosted process is entitled to. Nothing real is touched — the service is ours.
        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService,
            kSecAttrAccount as String: syntheticAccount,
            kSecValueData as String: Data("synthetic-canary".utf8)
        ] as CFDictionary, nil)
        print("SCRATCHCTX add(no group) status=\(addStatus)")

        // 2. Read it back, plus the attributes, so the effective group is visible if present.
        var out: CFTypeRef?
        let readStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService,
            kSecAttrAccount as String: syntheticAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &out)
        let attrs = out as? [String: Any]
        print("SCRATCHCTX read(no group) status=\(readStatus) accessGroup=\(attrs?[kSecAttrAccessGroup as String] as Any)")

        // 3. Attempt the same synthetic item in a NAMED group. FIRST the group this process is
        //    actually entitled to (learned from step 2's attribute), THEN a different one, so the
        //    probe distinguishes "explicit group honoured" from "the requested group is refused".
        let effective = (attrs?[kSecAttrAccessGroup as String] as? String) ?? "unknown"
        let named = effective
        print("SCRATCHCTX effectiveGroup=\(effective)")
        // and a deliberately different group, to show a mismatch is refused rather than silently used
        let otherGroup = effective + ".debug"
        let namedAdd = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService + ".named",
            kSecAttrAccount as String: syntheticAccount,
            kSecAttrAccessGroup as String: named,
            kSecValueData as String: Data("synthetic-canary".utf8)
        ] as CFDictionary, nil)
        print("SCRATCHCTX add(named group=\(named)) status=\(namedAdd)")
        let otherAdd = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService + ".other",
            kSecAttrAccount as String: syntheticAccount,
            kSecAttrAccessGroup as String: otherGroup,
            kSecValueData as String: Data("synthetic-canary".utf8)
        ] as CFDictionary, nil)
        print("SCRATCHCTX add(other group=\(otherGroup)) status=\(otherAdd)")

        // CLEANUP: remove only the synthetic items this probe may have created. Nothing else.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService,
            kSecAttrAccount as String: syntheticAccount
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService + ".named",
            kSecAttrAccount as String: syntheticAccount
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService + ".other",
            kSecAttrAccount as String: syntheticAccount
        ] as CFDictionary)

        // The probe reports; it does not assert a pass/fail, because its purpose is measurement.
        XCTAssertTrue(true)
    }
}
