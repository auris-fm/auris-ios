import XCTest
import CryptoKit
@testable import podcasts

final class LfmIntentRouterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm-router-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_noMatch_returnsNoneAndResets() async {
        let inference = FakeLfmInference()
        inference.classifyLabel = "no_match:"
        let router = createRouter(inference: inference)

        let ready = await router.ensureReady()
        XCTAssertTrue(ready.isSuccess)

        let result = router.classify(transcript: "hello")
        if case .none = result {
            // expected
        } else {
            XCTFail("expected .none, got \(result)")
        }
        XCTAssertEqual(inference.resetCount, 1)
    }

    func test_dialogControl_returnsDialogAction() async {
        let inference = FakeLfmInference()
        inference.classifyLabel = "dialog_control:begin"
        inference.generateResult =
            "<|tool_call_start|>[dialog_control(action='begin', target_tool='bookmark', target_action='rename')]<|tool_call_end|>"
        let router = createRouter(inference: inference)
        _ = await router.ensureReady()

        let result = router.classify(transcript: "rename my bookmark")
        if case .dialogControl(let action) = result {
            if case .begin(let tool, let actionName) = action {
                XCTAssertEqual(tool, "bookmark")
                XCTAssertEqual(actionName, "rename")
            } else {
                XCTFail("expected begin, got \(action)")
            }
        } else {
            XCTFail("expected dialogControl, got \(result)")
        }
    }

    func test_spanFailure_returnsNoneWithoutClassifying() async {
        let inference = FakeLfmInference()
        inference.tokenizeThrows = LfmInferenceError.userSpanNotFound
        let router = createRouter(inference: inference)
        _ = await router.ensureReady()

        let result = router.classify(transcript: "pause")
        if case .none = result {
            // expected
        } else {
            XCTFail("expected .none, got \(result)")
        }
        XCTAssertEqual(inference.classifyCount, 0)
    }

    func test_decodeFailure_returnsNoneWithoutGuessingTool() async {
        let inference = FakeLfmInference()
        inference.classifyLabel = "playback:pause"
        inference.generateResult = nil
        let router = createRouter(inference: inference)
        _ = await router.ensureReady()

        let result = router.classify(transcript: "pause")
        if case .none = result {
            // expected
        } else {
            XCTFail("expected .none, got \(result)")
        }
    }

    func test_ensureReady_failsWhenNativeLoadFails() async {
        let inference = FakeLfmInference()
        inference.loadResult = false
        inference.lastErrorMessage = "invalid classifier.bin magic"
        // Fail-fast session so invalidate→redownload does not hit the real CDN.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.1
        config.timeoutIntervalForResource = 0.1
        let manager = ModelManager(storageDir: tempDir, session: URLSession(configuration: config))
        seedLfmAssets(manager)
        let router = LfmIntentRouter(modelManager: manager, inference: inference)

        let result = await router.ensureReady()
        XCTAssertTrue(result.isFailure)
        XCTAssertFalse(router.isReady)
    }

    func test_pauseCommand_mapsToPlaybackPause() async {
        let inference = FakeLfmInference()
        inference.classifyLabel = "playback:pause"
        inference.generateResult =
            "<|tool_call_start|>[playback(action='pause')]<|tool_call_end|>"
        let router = createRouter(inference: inference)
        _ = await router.ensureReady()

        var metrics: RouterClassificationMetrics?
        router.onMetrics = { metrics = $0 }

        let result = router.classify(transcript: "pause")
        if case .intent(let intent) = result, let playback = intent as? PlaybackIntent {
            XCTAssertEqual(playback, .pause)
        } else {
            XCTFail("expected PlaybackIntent.pause, got \(result)")
        }
        XCTAssertEqual(metrics?.outcome, "intent")
        XCTAssertEqual(inference.resetCount, 1)
    }

    func test_classify_withoutEnsureReady_reportsRouterNotReady() {
        let inference = FakeLfmInference()
        let router = LfmIntentRouter(
            modelManager: ModelManager(storageDir: tempDir),
            inference: inference
        )
        var metrics: RouterClassificationMetrics?
        router.onMetrics = { metrics = $0 }
        let result = router.classify(transcript: "pause")
        if case .none = result {
            // expected
        } else {
            XCTFail("expected .none, got \(result)")
        }
        XCTAssertEqual(metrics?.outcome, "router_not_ready")
    }

    private func createRouter(inference: FakeLfmInference) -> LfmIntentRouter {
        let manager = ModelManager(storageDir: tempDir)
        seedLfmAssets(manager)
        return LfmIntentRouter(modelManager: manager, inference: inference)
    }

    private func seedLfmAssets(_ manager: ModelManager) {
        let modelDir = manager.lfmDir
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try? "gguf".write(to: manager.lfmModelFile, atomically: true, encoding: .utf8)
        try? "LFMC".write(to: manager.lfmClassifierFile, atomically: true, encoding: .utf8)
        let labelMap = #"{"labels":["playback:pause"]}"#
        try? labelMap.write(to: manager.lfmLabelMapFile, atomically: true, encoding: .utf8)
        let manifest = """
        {
          "version": "2026-06-21-143005",
          "assets": {
            "model.gguf": {
              "bytes": 4,
              "sha256": "\(sha256("gguf"))",
              "url": "https://example.test/model.gguf"
            },
            "classifier.bin": {
              "bytes": 4,
              "sha256": "\(sha256("LFMC"))",
              "url": "https://example.test/classifier.bin"
            },
            "label_map.json": {
              "bytes": \(labelMap.utf8.count),
              "sha256": "\(sha256(labelMap))",
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

    private func sha256(_ value: String) -> String {
        let data = Data(value.utf8)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailure: Bool { !isSuccess }
}
