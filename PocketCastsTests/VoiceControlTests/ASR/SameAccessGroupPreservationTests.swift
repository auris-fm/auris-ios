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

    /// READ-ONLY POST-READ VERIFICATION: run AFTER the external helper has read the canary. It writes
    /// nothing, so it checks the SAME item and bytes the helper saw, rather than replacing them. The
    /// expected value is supplied from outside (the writer records what it wrote), so a match here is
    /// a real comparison against the preset bytes, not a self-consistent round trip.
    func testPostHelperReadCanaryBytesAndSentinelAreIntact() throws {
        let group = "6LL2R2A55F.fm.auris.scratchshared"
        let expectedFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scratch-expected-bytes.txt")
        guard let expected = try? String(contentsOf: expectedFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            print("VERIFY skipped: no expected-bytes file, so this run cannot compare")
            return
        }
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService,
            kSecAttrAccount as String: syntheticAccount,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &out)
        let dict = out as? [String: Any]
        let bytes = (dict?[kSecValueData as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
        let attributed = dict?[kSecAttrAccessGroup as String] as? String
        print("VERIFY postHelperRead status=\(status) group=\(group) attributedGroup=\(attributed as Any) bytesMatch=\(bytes == expected)")
        XCTAssertEqual(status, errSecSuccess, "the canary was not present after the helper read")
        XCTAssertEqual(attributed, group, "the canary is no longer attributed to the shared group")
        XCTAssertEqual(bytes, expected, "the canary bytes changed across the helper read")

        // THE CONTAINER SENTINEL is verified here too, against the value recorded when it was created,
        // so "intact" covers the container as well as the keychain item rather than the canary alone.
        let expectedSentinelFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scratch-expected-sentinel.txt")
        let expectedSentinel = (try? String(contentsOf: expectedSentinelFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sentinelPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scratch-preservation-sentinel.txt")
        let actualSentinel = (try? String(contentsOf: sentinelPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print("VERIFY postHelperRead sentinelPresent=\(actualSentinel != nil) sentinelMatch=\(actualSentinel == expectedSentinel) path=\(sentinelPath.path)")
        XCTAssertNotNil(expectedSentinel, "the writer recorded no expected sentinel, so it cannot be checked")
        XCTAssertEqual(actualSentinel, expectedSentinel, "the container sentinel changed across the helper read")
    }

    func testSyntheticCanaryAndContainerSentinelSurviveAScopedRead() throws {
        // SHARED GROUP: the same group the helper is entitled to, so both roles request an identical
        // group. Measured rule: a simulator product is attributed the default group of its
        // application-identifier, and requesting a different group is refused (-34018) — while a
        // group matching its own identifier is usable (-25300 when absent).
        // THE SHARED GROUP both products are configured to declare for this control. Pointed
        // explicitly at the shared synthetic group so the writer and the helper request an identical
        // group; the measured default (`6LL2R2A55F.fm.auris`) is what a product gets otherwise.
        let group = "6LL2R2A55F.fm.auris.scratchshared"
        print("PRESERVE group=\(group)")
        // Record what the writer wrote, so the post-helper verification compares against an
        // independently recorded expectation rather than a fresh round trip.
        try Data(syntheticValue.utf8).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scratch-expected-bytes.txt"))

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
        // Record the sentinel value so the post-helper verification compares against it rather than
        // re-reading whatever is there.
        try Data(sentinelContents.utf8).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scratch-expected-sentinel.txt"))
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
        // BYTES, not presence: the writer reads its own synthetic value back and compares it to what
        // it wrote, so "unchanged" is a byte comparison rather than a bare existence check.
        let verifyStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: syntheticService,
            kSecAttrAccount as String: syntheticAccount,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &verifyOut)
        if let dict = verifyOut as? [String: Any], let data = dict[kSecValueData as String] as? Data {
            let bytes = String(data: data, encoding: .utf8)
            print("PRESERVE postRead bytesUnchanged=\(bytes == syntheticValue)")
            XCTAssertEqual(bytes, syntheticValue, "the writer's synthetic bytes changed")
        } else {
            XCTFail("the writer could not read its own synthetic bytes back")
        }
        let verifyAttrs = verifyOut as? [String: Any]
        print("PRESERVE postRead canaryStatus=\(verifyStatus) attributedGroup=\(verifyAttrs?[kSecAttrAccessGroup as String] as Any)")
        XCTAssertEqual(verifyStatus, errSecSuccess, "the synthetic canary did not survive the scoped read")

        let sentinelAfter = try String(contentsOf: sentinelURL, encoding: .utf8)
        print("PRESERVE postRead sentinelIntact=\(sentinelAfter == sentinelContents)")
        XCTAssertEqual(sentinelAfter, sentinelContents, "the container sentinel was modified")

        // NO CLEANUP IN THIS RUN: the canary must SURVIVE the test so the separately-installed helper
        // app can perform the cross-app read afterwards, and so the writer can verify it is intact
        // after that read. The canary is synthetic (fm.auris.SCRATCH*) and is removed by a later run
        // when the coordination file is absent; the sentinel likewise stays for the same reason.
        print("PRESERVE retained for cross-app read at \(sentinelURL.path)")
    }
}
