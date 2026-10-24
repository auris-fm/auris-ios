import CryptoKit
import Foundation
@testable import podcasts

/// Controllable monotonic clock for timing tests.
final class FakeMonotonicClock: MonotonicClock {
    private var nowValue: CFTimeInterval = 0

    func setNow(_ value: CFTimeInterval) {
        nowValue = value
    }

    func now() -> CFTimeInterval {
        nowValue
    }
}

/// Fake LFM inference used by `LfmIntentRouterTests`.
final class FakeLfmInference: LfmInference {
    var loadResult = true
    var lastErrorMessage = ""
    var classifyLabel: String? = "playback:pause"
    var generateResult: String? = "<|tool_call_start|>[playback(action='pause')]<|tool_call_end|>"
    var tokenizeThrows: Error?
    var classifyCount = 0
    var resetCount = 0
    /// Ordered event log: "reset" entries; tests pair with diagnostic sink order.
    private(set) var eventLog: [String] = []

    var lastError: String { lastErrorMessage }

    /// LIFECYCLE OBSERVER (spec 6b45a5d2): counts real `inference.load` calls so a control can
    /// pin WHEN the router load happens (first arm, not construction).
    private(set) var loadCount = 0

    func load(modelPath: String, classifierPath: String, labelMapPath: String, nCtx: Int) -> Bool {
        loadCount += 1
        return loadResult
    }

    func tokenize(_ text: String, addBos: Bool) throws -> [Int] {
        if let tokenizeThrows { throw tokenizeThrows }
        if text == "pause" {
            return [10]
        }
        return [1, 10, 2]
    }

    func classify(promptTokenIds: [Int], poolStart: Int, poolEnd: Int) throws -> String {
        classifyCount += 1
        guard let classifyLabel else {
            throw LfmInferenceError.notReady
        }
        return classifyLabel
    }

    func generate(prefill: String, nPredict: Int) throws -> String {
        guard let generateResult else {
            throw LfmInferenceError.notReady
        }
        return generateResult
    }

    func reset() {
        resetCount += 1
        eventLog.append("reset")
    }

    func release() {}
}


/// A DETERMINISTIC ASR backend: ready immediately, no model download, no ONNX load. Substituted at
/// the ENGINE's backend so `preloadBackend()`/`ensureReady()` never touches real model assets.
final class FakeAsrBackend: AsrBackend {
    var ensureReadyCount = 0
    private(set) var released = false
    var requiredModel: ModelSpec { ModelSpec(id: "fake", files: [], targetDir: "fake") }
    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
    }
    func ensureReady() async -> Result<Void, Error> {
        ensureReadyCount += 1
        return .success(())
    }
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        AsrResult(text: "", detectedLanguage: nil, tokens: nil)
    }
    func release() { released = true }
}


/// Seeds a `ModelManager`'s LFM assets so `LfmIntentRouter.ensureReady()` succeeds without the real
/// model. Readiness goes through the manager, so injecting an inference alone is not enough.
func seedLfmAssetsForTestingForPositive(manager: ModelManager, labelMap: String = #"{"labels":["cloud_route:"]}"#) {
    func sha256(_ v: String) -> String {
        SHA256.hash(data: Data(v.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }
    let dir = manager.lfmDir
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? "gguf".write(to: manager.lfmModelFile, atomically: true, encoding: .utf8)
    try? "LFMC".write(to: manager.lfmClassifierFile, atomically: true, encoding: .utf8)
    try? labelMap.write(to: manager.lfmLabelMapFile, atomically: true, encoding: .utf8)
    let manifest = """
    {
      "version": "2026-06-21-143005",
      "assets": {
        "model.gguf": { "bytes": 4, "sha256": "\(sha256("gguf"))", "url": "https://example.test/model.gguf" },
        "classifier.bin": { "bytes": 4, "sha256": "\(sha256("LFMC"))", "url": "https://example.test/classifier.bin" },
        "label_map.json": { "bytes": \(labelMap.utf8.count), "sha256": "\(sha256(labelMap))", "url": "https://example.test/label_map.json" }
      }
    }
    """
    try? manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
}
