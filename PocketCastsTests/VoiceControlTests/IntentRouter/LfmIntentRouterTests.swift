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
        // Fail-fast session for both manifest fetch and asset downloads.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.1
        config.timeoutIntervalForResource = 0.1
        let session = URLSession(configuration: config)
        let manager = ModelManager(
            storageDir: tempDir,
            downloader: ModelDownloader(),
            session: session
        )
        seedLfmAssets(manager: manager)
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
        XCTAssertEqual(metrics?.finalOutcome, RouterStageDiagnostic.outcomeIntent)
        XCTAssertEqual(metrics?.inputFormat, "english_v1")
        XCTAssertEqual(metrics?.translationKind, "none")
        XCTAssertNil(metrics?.failedStage)
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
        XCTAssertEqual(metrics?.finalOutcome, RouterStageDiagnostic.outcomeNoIntent)
        XCTAssertEqual(metrics?.failedStage, RouterStageDiagnostic.stageNotReady)
        XCTAssertEqual(metrics?.reason, RouterStageDiagnostic.reasonModelNotLoaded)
    }

    func test_noMatch_emitsBoundedDiagnostic() async {
        let inference = FakeLfmInference()
        inference.classifyLabel = "no_match:"
        let router = createRouter(inference: inference)
        _ = await router.ensureReady()
        var metrics: RouterStageDiagnostic?
        router.onMetrics = { metrics = $0 }

        let input = IntentRoutingInput(
            sourceTranscript: "倒回去3分钟。",
            sourceLanguage: "zh",
            routerTranscript: "Go back to 3 minutes.",
            translationKind: .platform
        )
        _ = router.classify(input: input)

        XCTAssertEqual(metrics?.finalOutcome, RouterStageDiagnostic.outcomeNoIntent)
        XCTAssertEqual(metrics?.failedStage, RouterStageDiagnostic.stageNoMatch)
        XCTAssertEqual(metrics?.reason, RouterStageDiagnostic.reasonNoMatch)
        XCTAssertEqual(metrics?.sourceLanguage, "zh")
        XCTAssertEqual(metrics?.translationKind, "platform")
        XCTAssertEqual(metrics?.classifierLabel, "no_match:")
        XCTAssertEqual(metrics?.inputFormat, "english_v1")
        // Privacy: diagnostic must not echo transcripts.
        let mirror = String(describing: metrics!)
        XCTAssertFalse(mirror.contains("倒回去"))
        XCTAssertFalse(mirror.contains("Go back"))
    }

    func test_spanFailure_emitsTokenizeStage() async {
        let inference = FakeLfmInference()
        inference.tokenizeThrows = LfmInferenceError.userSpanNotFound
        let router = createRouter(inference: inference)
        _ = await router.ensureReady()
        var metrics: RouterStageDiagnostic?
        router.onMetrics = { metrics = $0 }
        _ = router.classify(transcript: "pause")
        XCTAssertEqual(metrics?.failedStage, RouterStageDiagnostic.stageTokenize)
        XCTAssertEqual(metrics?.reason, RouterStageDiagnostic.reasonTokenizeFailed)
        XCTAssertEqual(inference.classifyCount, 0)
    }

    func test_generateFailure_emitsGenerateStage() async {
        let inference = FakeLfmInference()
        inference.classifyLabel = "playback:pause"
        inference.generateResult = nil
        let router = createRouter(inference: inference)
        _ = await router.ensureReady()
        var metrics: RouterStageDiagnostic?
        router.onMetrics = { metrics = $0 }
        _ = router.classify(transcript: "pause")
        XCTAssertEqual(metrics?.failedStage, RouterStageDiagnostic.stageGenerate)
        XCTAssertEqual(metrics?.reason, RouterStageDiagnostic.reasonGenerateFailed)
        XCTAssertEqual(metrics?.classifierLabel, "playback:pause")
    }

    func test_blankTranscript_emitsBlankStage() async {
        let inference = FakeLfmInference()
        let router = createRouter(inference: inference)
        _ = await router.ensureReady()
        var metrics: RouterStageDiagnostic?
        router.onMetrics = { metrics = $0 }
        _ = router.classify(transcript: "   ")
        XCTAssertEqual(metrics?.failedStage, RouterStageDiagnostic.stageBlank)
        XCTAssertEqual(metrics?.reason, RouterStageDiagnostic.reasonBlankTranscript)
    }

    func test_unknownInputFormat_bundleNotReady() {
        let labelMap = #"{"labels":["playback:pause"]}"#
        seedLfmAssets(manager: ModelManager(storageDir: tempDir), format: "source_v1", labelMap: labelMap)
        let manager = ModelManager(storageDir: tempDir)
        XCTAssertEqual(manager.lfmRouterInputFormat(), .sourceV1)
        XCTAssertFalse(manager.isLfmModelReady())
    }

    func test_explicitEnglishV1_reachesDiagnostics() async {
        let inference = FakeLfmInference()
        inference.classifyLabel = "playback:pause"
        inference.generateResult =
            "<|tool_call_start|>[playback(action='pause')]<|tool_call_end|>"
        let manager = ModelManager(storageDir: tempDir)
        seedLfmAssets(manager: manager, format: "english_v1")
        let router = LfmIntentRouter(modelManager: manager, inference: inference)
        _ = await router.ensureReady()
        var metrics: RouterStageDiagnostic?
        router.onMetrics = { metrics = $0 }
        _ = router.classify(transcript: "pause")
        XCTAssertEqual(metrics?.inputFormat, "english_v1")
        XCTAssertEqual(metrics?.finalOutcome, RouterStageDiagnostic.outcomeIntent)
    }

    private func createRouter(inference: FakeLfmInference) -> LfmIntentRouter {
        let manager = ModelManager(storageDir: tempDir)
        seedLfmAssets(manager: manager)
        return LfmIntentRouter(modelManager: manager, inference: inference)
    }

    private func seedLfmAssets(manager: ModelManager, format: String? = nil, labelMap: String? = nil) {
        let modelDir = manager.lfmDir
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try? "gguf".write(to: manager.lfmModelFile, atomically: true, encoding: .utf8)
        try? "LFMC".write(to: manager.lfmClassifierFile, atomically: true, encoding: .utf8)
        let map = labelMap ?? #"{"labels":["playback:pause"]}"#
        try? map.write(to: manager.lfmLabelMapFile, atomically: true, encoding: .utf8)
        let formatLine = format.map { "\"router_input_format\": \"\($0)\"," } ?? ""
        let manifest = """
        {
          "version": "2026-06-21-143005",
          \(formatLine)
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
              "bytes": \(map.utf8.count),
              "sha256": "\(sha256(map))",
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
