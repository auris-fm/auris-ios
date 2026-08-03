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
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(threshold, 0.8, accuracy: 0.0001)
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
}
