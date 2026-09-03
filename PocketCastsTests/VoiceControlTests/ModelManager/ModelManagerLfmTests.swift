import XCTest
@testable import podcasts

final class ModelManagerLfmTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm-model-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_parseLfmManifest_requiresExactlyGgufClassifierAndLabelMap() throws {
        let manifest = """
        {
          "version": "2026-06-21-143005",
          "source_commit": "abc123",
          "assets": {
            "model.gguf": {
              "bytes": 5,
              "sha256": "gguf-sha",
              "url": "https://download.auris.fm/function-call/2026-06-21-143005/model.gguf"
            },
            "classifier.bin": {
              "bytes": 5,
              "sha256": "cls-sha",
              "url": "https://download.auris.fm/function-call/2026-06-21-143005/classifier.bin"
            },
            "label_map.json": {
              "bytes": 5,
              "sha256": "map-sha",
              "url": "https://download.auris.fm/function-call/2026-06-21-143005/label_map.json"
            }
          }
        }
        """
        let release = try parseLfmManifest(manifest)
        XCTAssertEqual(release.version, "2026-06-21-143005")
        XCTAssertEqual(
            release.requiredAssets.map(\.name),
            ["model.gguf", "classifier.bin", "label_map.json"]
        )
    }

    func test_parseLfmManifest_rejectsFunctionGemmaManifest() {
        XCTAssertThrowsError(
            try parseLfmManifest(
                """
                {
                  "version": "2026-06-21-143005",
                  "assets": {
                    "model.litertlm": {
                      "bytes": 5,
                      "sha256": "model-sha",
                      "url": "https://download.auris.fm/function-call/model.litertlm"
                    }
                  }
                }
                """
            )
        ) { error in
            XCTAssertEqual(error as? LfmManifestError, .missingAsset("model.gguf"))
        }
    }

    func test_lfmIsNotReadyWhenDownloadedAssetIsPartial() {
        seed(
            gguf: "gguf",
            classifier: "cls",
            labelMap: "bad",
            ggufBytes: 4,
            classifierBytes: 3,
            labelMapBytes: 5
        )
        let manager = ModelManager(storageDir: tempDir)
        XCTAssertFalse(manager.isLfmModelReady())
    }

    func test_lfmIsReadyWhenRequiredDownloadedAssetsMatchManifest() {
        let labelMap = #"{"labels":["playback:pause"]}"#
        seed(
            gguf: "gguf",
            classifier: "LFMC",
            labelMap: labelMap,
            ggufBytes: 4,
            classifierBytes: 4,
            labelMapBytes: labelMap.utf8.count
        )
        let manager = ModelManager(storageDir: tempDir)
        XCTAssertTrue(manager.isLfmModelReady())
        XCTAssertTrue(manager.lfmDir.path.hasSuffix("/function-call"))
    }

    func test_lfmIsNotReadyWhenClassifierMagicIsWrong() {
        let labelMap = #"{"labels":["playback:pause"]}"#
        seed(
            gguf: "gguf",
            classifier: "XXXX",
            labelMap: labelMap,
            ggufBytes: 4,
            classifierBytes: 4,
            labelMapBytes: labelMap.utf8.count
        )
        let manager = ModelManager(storageDir: tempDir)
        XCTAssertFalse(manager.isLfmModelReady())
    }

    func test_lfmReleaseVersionIsReadFromInstalledManifest() {
        let labelMap = #"{"labels":["playback:pause"]}"#
        seed(
            gguf: "gguf",
            classifier: "LFMC",
            labelMap: labelMap,
            ggufBytes: 4,
            classifierBytes: 4,
            labelMapBytes: labelMap.utf8.count
        )
        let manager = ModelManager(storageDir: tempDir)
        XCTAssertEqual(manager.lfmReleaseVersion(), "2026-06-21-143005")
    }

    private func seed(
        gguf: String,
        classifier: String,
        labelMap: String,
        ggufBytes: Int,
        classifierBytes: Int,
        labelMapBytes: Int
    ) {
        let modelDir = tempDir.appendingPathComponent("function-call", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try? gguf.write(to: modelDir.appendingPathComponent("model.gguf"), atomically: true, encoding: .utf8)
        try? classifier.write(to: modelDir.appendingPathComponent("classifier.bin"), atomically: true, encoding: .utf8)
        try? labelMap.write(to: modelDir.appendingPathComponent("label_map.json"), atomically: true, encoding: .utf8)
        let manifest = """
        {
          "version": "2026-06-21-143005",
          "assets": {
            "model.gguf": {
              "bytes": \(ggufBytes),
              "sha256": "gguf-sha",
              "url": "https://example.test/model.gguf"
            },
            "classifier.bin": {
              "bytes": \(classifierBytes),
              "sha256": "cls-sha",
              "url": "https://example.test/classifier.bin"
            },
            "label_map.json": {
              "bytes": \(labelMapBytes),
              "sha256": "map-sha",
              "url": "https://example.test/label_map.json"
            }
          }
        }
        """
        try? manifest.write(
            to: modelDir.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}
