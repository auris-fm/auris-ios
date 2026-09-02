import Foundation

protocol LfmInference: AnyObject {
    var lastError: String { get }
    func load(modelPath: String, classifierPath: String, labelMapPath: String, nCtx: Int) -> Bool
    func tokenize(_ text: String, addBos: Bool) throws -> [Int]
    func classify(promptTokenIds: [Int], poolStart: Int, poolEnd: Int) throws -> String
    func generate(prefill: String, nPredict: Int) throws -> String
    func reset()
    func release()
}

final class LfmNativeInference: LfmInference {
    private let bridge = LfmRuntimeBridge()

    var lastError: String { bridge.lastError }

    func load(modelPath: String, classifierPath: String, labelMapPath: String, nCtx: Int) -> Bool {
        do {
            try bridge.load(
                withModelPath: modelPath,
                classifierPath: classifierPath,
                labelMapPath: labelMapPath,
                nCtx: nCtx
            )
            return true
        } catch {
            return false
        }
    }

    func tokenize(_ text: String, addBos: Bool) throws -> [Int] {
        let tokens = try bridge.tokenize(text, addBos: addBos)
        return tokens.map { $0.intValue }
    }

    func classify(promptTokenIds: [Int], poolStart: Int, poolEnd: Int) throws -> String {
        let numbers = promptTokenIds.map { NSNumber(value: $0) }
        return try bridge.classifyPromptTokenIds(numbers, poolStart: poolStart, poolEnd: poolEnd)
    }

    func generate(prefill: String, nPredict: Int) throws -> String {
        try bridge.generate(withPrefill: prefill, nPredict: nPredict)
    }

    func reset() {
        bridge.reset()
    }

    func release() {
        bridge.releaseRuntime()
    }
}
