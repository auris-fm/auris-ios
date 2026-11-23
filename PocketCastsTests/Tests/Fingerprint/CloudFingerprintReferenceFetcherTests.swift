import XCTest

@testable import podcasts

final class CloudFingerprintReferenceFetcherTests: XCTestCase {

    /// Builds a payload whose checkpoints carry the parity hashes (delta 0 for the
    /// first window, then 1 per 1s stride). The format is a parameter so a case can
    /// present the reference as either source; the strings are written out rather
    /// than read from the constants, so a case cannot pass by comparing a value
    /// with itself.
    private func compactData(format: String) -> Data {
        let windows = CloudFingerprintParityData.signal16kMonoWindows
        var checkpoints: [String] = []
        for (index, hashes) in windows.enumerated() {
            let delta = index == 0 ? 0 : 1
            var bytes = Data()
            for hash in hashes {
                var littleEndian = hash.littleEndian
                withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
            }
            let base64 = bytes.base64EncodedString()
            checkpoints.append("[\(delta), \"\(base64)\"]")
        }
        let json = """
        {
          "format": "\(format)",
          "total_duration": 10.0,
          "checkpoint_interval": 1,
          "checkpoint_duration": 8,
          "timestamp_quantum": 1,
          "checkpoints": [\(checkpoints.joined(separator: ","))]
        }
        """
        return Data(json.utf8)
    }

    /// The endpoint's references load straight into the library matcher: the payload
    /// carries the library's own hash values, so no scoring adapter sits between them.
    func testBuildMatcherLoadsAnAurisReferenceIntoTheLibraryMatcher() throws {
        let matcher = try XCTUnwrap(
            CloudFingerprintReferenceFetcher.shared.buildMatcher(from: compactData(format: "fingerprint-compact-v3"))
        )
        XCTAssertEqual(matcher.count, 3)

        let matches = matcher.findTopMatches(
            queryHashes: CloudFingerprintParityData.signal16kMonoWindows[1],
            maxResults: 3
        )
        XCTAssertEqual(matches.count, 3)
        XCTAssertTrue(matches.allSatisfy { $0.score == 1.0 }, "the hashes must match the loaded checkpoints")
        XCTAssertTrue(matches.contains { $0.timestamp == 1 })
    }

    /// A v2 reference is refused, so alignment fails closed rather than matching a
    /// reference whose hashes are not the ones this endpoint's matcher is ranked
    /// against. Literal format, deliberately: deriving it would test v3 against v3.
    func testBuildMatcherRefusesAV2Reference() {
        XCTAssertNil(
            CloudFingerprintReferenceFetcher.shared.buildMatcher(from: compactData(format: "fingerprint-compact-v2"))
        )
    }

    func testBuildMatcherReturnsNilForInvalidPayload() {
        XCTAssertNil(CloudFingerprintReferenceFetcher.shared.buildMatcher(from: Data("not json".utf8)))
    }
}

final class CloudIdentityTests: XCTestCase {

    func testGeneratedUserIdHasUserPrefix() {
        let id = CloudIdentity.generateUserId()
        XCTAssertTrue(id.hasPrefix("user_"))
        XCTAssertEqual(id.count, 5 + 36) // "user_" + UUID v4
    }

    func testUserIdIsStableAcrossInstances() {
        let suiteName = "test_cloud_identity_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = CloudIdentity(defaults: defaults)
        let second = CloudIdentity(defaults: defaults)

        XCTAssertEqual(first.userId, second.userId)
        XCTAssertTrue(first.userId.hasPrefix("user_"))
    }
}

final class CloudConfigTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "cloud_config_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testBaseUrlEmptyWhenCutoverInactive() {
        let config = CloudConfig(defaults: defaults, buildDefaultGatewayURL: "")
        XCTAssertEqual(config.baseUrl, "")
    }

    func testBaseUrlUsesGatewayWhenCutoverActive() {
        defaults.set("https://gateway.staging.example.com/", forKey: CloudConfig.baseURLKey)
        let config = CloudConfig(defaults: defaults, buildDefaultGatewayURL: "")
        XCTAssertEqual(config.baseUrl, "https://gateway.staging.example.com")
    }

    func testKillSwitchClearsCloudBaseUrl() {
        defaults.set("https://gateway.staging.example.com", forKey: CloudConfig.baseURLKey)
        defaults.set(true, forKey: CloudConfig.directUpstreamKey)
        let config = CloudConfig(defaults: defaults, buildDefaultGatewayURL: "")
        XCTAssertEqual(config.baseUrl, "")
    }

    func testBuildDefaultUsedWhenNoOverrideKey() {
        let config = CloudConfig(
            defaults: defaults,
            buildDefaultGatewayURL: "https://build.example.com"
        )
        XCTAssertEqual(config.baseUrl, "https://build.example.com")
    }
}
