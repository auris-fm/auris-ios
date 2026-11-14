import CryptoKit
import XCTest
@testable import podcasts

final class WakeWordThresholdLoaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakeword-loader-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeManifest(_ json: [String: Any]) throws -> URL {
        let url = tempDir.appendingPathComponent("auris_eval.json")
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
        return url
    }

    private func writeAsset(named name: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func test_loadsDeploymentThreshold() throws {
        try writeAsset(named: "auris.ort", contents: "model-bytes")
        let hash = sha256(of: Data("model-bytes".utf8))
        let manifestURL = try writeManifest([
            "deployment_threshold": 0.8,
            "asset_hashes": ["auris.ort": hash],
        ])
        let result = WakeWordThresholdLoader.load(manifestURL: manifestURL, modelDirectory: tempDir)
        guard case .success(let threshold) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        XCTAssertEqual(threshold, 0.8, accuracy: 0.0001)
    }

    func test_verifiedDeploymentIdentityChangesWithAssetsAndRejectsUnverifiedMutation() throws {
        let asset = try writeAsset(named: "auris.ort", contents: "model-A")
        let manifest = try writeManifest([
            "deployment_threshold": 0.8,
            "asset_hashes": ["auris.ort": sha256(of: Data("model-A".utf8))],
        ])
        let first = try WakeWordThresholdLoader.loadDeployment(manifestURL: manifest, modelDirectory: tempDir).get()
        XCTAssertNotNil(first.identity)
        try Data("model-B".utf8).write(to: asset)
        if case .success = WakeWordThresholdLoader.loadDeployment(manifestURL: manifest, modelDirectory: tempDir) {
            XCTFail("unverified changed assets cannot mint a deployment identity")
        }
        _ = try writeManifest([
            "deployment_threshold": 0.8,
            "asset_hashes": ["auris.ort": sha256(of: Data("model-B".utf8))],
        ])
        let next = try WakeWordThresholdLoader.loadDeployment(manifestURL: manifest, modelDirectory: tempDir).get()
        XCTAssertNotNil(next.identity)
        XCTAssertNotEqual(first.identity, next.identity)
    }

    func test_missingManifest_fails() {
        let missing = tempDir.appendingPathComponent("does-not-exist.json")
        let result = WakeWordThresholdLoader.load(manifestURL: missing, modelDirectory: tempDir)
        if case .success = result {
            XCTFail("Expected failure for missing manifest")
        }
    }

    func test_missingDeploymentThreshold_fails() throws {
        let manifestURL = try writeManifest(["asset_hashes": [:]])
        let result = WakeWordThresholdLoader.load(manifestURL: manifestURL, modelDirectory: tempDir)
        if case .success = result {
            XCTFail("Expected failure without deployment_threshold")
        }
    }

    func test_missingAssetHashes_fails() throws {
        let manifestURL = try writeManifest(["deployment_threshold": 0.8])
        let result = WakeWordThresholdLoader.load(manifestURL: manifestURL, modelDirectory: tempDir)
        if case .success = result {
            XCTFail("Expected failure without asset_hashes")
        }
    }

    func test_hashMismatch_fails() throws {
        try writeAsset(named: "auris.ort", contents: "model-bytes")
        let manifestURL = try writeManifest([
            "deployment_threshold": 0.8,
            "asset_hashes": ["auris.ort": String(repeating: "0", count: 64)],
        ])
        let result = WakeWordThresholdLoader.load(manifestURL: manifestURL, modelDirectory: tempDir)
        if case .success = result {
            XCTFail("Expected failure on hash mismatch")
        }
    }

    func test_missingAssetFile_fails() throws {
        let manifestURL = try writeManifest([
            "deployment_threshold": 0.8,
            "asset_hashes": ["auris.ort": String(repeating: "0", count: 64)],
        ])
        let result = WakeWordThresholdLoader.load(manifestURL: manifestURL, modelDirectory: tempDir)
        if case .success = result {
            XCTFail("Expected failure when a pinned asset is missing")
        }
    }

    // MARK: - wake_only_margin_ms

    /// The margin is read only when it is a non-negative integer; everything else means "no
    /// margin", which leaves the audio wake-only rule off rather than applying a guessed one.
    func test_wakeOnlyMargin_acceptsOnlyANonNegativeInteger() {
        XCTAssertEqual(
            WakeWordThresholdLoader.wakeOnlyMarginMs(fromManifestJSON: ["wake_only_margin_ms": 80]),
            80)
        XCTAssertEqual(
            WakeWordThresholdLoader.wakeOnlyMarginMs(fromManifestJSON: ["wake_only_margin_ms": 0]),
            0,
            "zero is a VALID margin: the boundary is the completion offset itself")

        XCTAssertNil(
            WakeWordThresholdLoader.wakeOnlyMarginMs(fromManifestJSON: [:]),
            "absent: the rule is off, matching a manifest written before the margin existed")
        XCTAssertNil(
            WakeWordThresholdLoader.wakeOnlyMarginMs(fromManifestJSON: ["wake_only_margin_ms": -1]),
            "negative would invert the rule and drop ordinary commands")
        XCTAssertNil(
            WakeWordThresholdLoader.wakeOnlyMarginMs(fromManifestJSON: ["wake_only_margin_ms": "eighty"]),
            "a string is not a millisecond count")
        XCTAssertNil(
            WakeWordThresholdLoader.wakeOnlyMarginMs(fromManifestJSON: ["wake_only_margin_ms": 80.5]),
            "a fractional margin is not what the model publishes")
    }

    /// A manifest with no margin still LOADS: the margin disables the audio rule only and must
    /// not make the detector not-ready, unlike the threshold.
    func test_aManifestWithoutAMarginStillLoadsTheDeployment() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wake-margin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // One pinned asset, hashed, so the manifest is otherwise valid.
        let asset = dir.appendingPathComponent("auris.onnx")
        let bytes = Data([0x01, 0x02, 0x03])
        try bytes.write(to: asset)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = dir.appendingPathComponent("auris_eval.json")
        try JSONSerialization.data(withJSONObject: [
            "deployment_threshold": 0.5,
            "asset_hashes": ["auris.onnx": digest],
        ]).write(to: manifest)

        let deployment = try WakeWordThresholdLoader
            .loadDeployment(manifestURL: manifest, modelDirectory: dir).get()
        XCTAssertEqual(deployment.threshold, 0.5, accuracy: 1e-6)
        XCTAssertNil(deployment.wakeOnlyMarginMs, "no margin: the audio rule is off, not an error")
    }
}
