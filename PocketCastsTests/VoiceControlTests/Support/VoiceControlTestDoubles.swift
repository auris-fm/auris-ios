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

    func load(modelPath: String, classifierPath: String, labelMapPath: String, nCtx: Int) -> Bool {
        loadResult
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
