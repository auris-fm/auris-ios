import XCTest
import Security

/// DISPOSABLE SAME-ACCESS-GROUP PRESERVATION CONTROL (synthetic only).
///
/// Two roles, both in the supported test-host context, both using the SAME measured effective group
/// (`6LL2R2A55F.fm.auris`):
///   * a WRITER establishes a synthetic canary in that group plus a container sentinel file;
///   * a READER (the helper's scoped read shape: presence + access-group attribution, no value
///     returned) confirms the canary is present under that group;
///   * afterwards the canary and the sentinel are verified INTACT.
///
/// No production credential service or account is queried, no secret value is exported: the service
/// is a synthetic constant, the value is a synthetic token, and the reader returns ATTRIBUTES only.
final class SameAccessGroupPreservationTests: XCTestCase {

    private let syntheticService = "fm.auris.SCRATCHPRESERVATION"
    private let syntheticAccount = "scratch-preservation"
    private let syntheticValue = "synthetic-canary-token"

    private var sentinelURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scratch-preservation-sentinel.txt")
    }

    func testSyntheticCanaryAndContainerSentinelSurviveAScopedRead() throws {
        // The measured effective group for this context (from ScratchKeychainContextProbe).
        let group = "6LL2R2A55F.fm.auris"

        // --- WRITER: synthetic canary in the named group, plus a container sentinel ---
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService,
            kSecAttrAccount as String: syntheticAccount,
            kSecAttrAccessGroup as String: group
        ] as CFDictionary)

        let writeStatus = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService,
            kSecAttrAccount as String: syntheticAccount,
            kSecAttrAccessGroup as String: group,
            kSecValueData as String: Data(syntheticValue.utf8)
        ] as CFDictionary, nil)
        print("PRESERVE write group=\(group) status=\(writeStatus)")
        XCTAssertEqual(writeStatus, errSecSuccess, "the synthetic canary was not written into the measured group")

        let sentinelContents = "sentinel-\(UUID().uuidString)"
        try Data(sentinelContents.utf8).write(to: sentinelURL)
        print("PRESERVE sentinel written at \(sentinelURL.path)")

        // --- READER: the helper's scoped shape — presence + group attribution, NO value returned ---
        var out: CFTypeRef?
        let readStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService,
            kSecAttrAccount as String: syntheticAccount,
            kSecAttrAccessGroup as String: group,
            kSecReturnAttributes as String: true,        // attributes only: kSecReturnData is absent
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &out)
        let attrs = out as? [String: Any]
        let attributedGroup = attrs?[kSecAttrAccessGroup as String] as? String
        print("PRESERVE read status=\(readStatus) attributedGroup=\(attributedGroup as Any)")
        XCTAssertEqual(readStatus, errSecSuccess, "the scoped read did not find the synthetic canary")
        XCTAssertEqual(attributedGroup, group, "the canary was not attributed to the requested group")

        // --- AFTERWARDS: canary and container sentinel must be INTACT ---
        var verifyOut: CFTypeRef?
        let verifyStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService,
            kSecAttrAccount as String: syntheticAccount,
            kSecAttrAccessGroup as String: group,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &verifyOut)
        let verifyAttrs = verifyOut as? [String: Any]
        print("PRESERVE postRead canaryStatus=\(verifyStatus) attributedGroup=\(verifyAttrs?[kSecAttrAccessGroup as String] as Any)")
        XCTAssertEqual(verifyStatus, errSecSuccess, "the synthetic canary did not survive the scoped read")

        let sentinelAfter = try String(contentsOf: sentinelURL, encoding: .utf8)
        print("PRESERVE postRead sentinelIntact=\(sentinelAfter == sentinelContents)")
        XCTAssertEqual(sentinelAfter, sentinelContents, "the container sentinel was modified")

        // CLEANUP: remove only our synthetic items.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService,
            kSecAttrAccount as String: syntheticAccount,
            kSecAttrAccessGroup as String: group
        ] as CFDictionary)
        try? FileManager.default.removeItem(at: sentinelURL)
    }
}
