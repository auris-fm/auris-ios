import Foundation
import CoreML

class FunctionGemmaSessionPool {
    private var currentSession: CoreMLSession?
    private var tokenCount: Int = 0
    private let maxTokens = 32_768
    private var baselineTokenCount: Int = 0
    private let prewarmQueue = DispatchQueue(label: "com.auris.functiongemma.session-pool")

    func prepare() async {
        let systemPrompt = PromptBuilder().buildSystemPrompt(tools: ToolSchema.tools())
        do {
            let session = try await CoreMLSession.create()
            let tokens = try await session.prefill(systemPrompt)
            self.currentSession = session
            self.baselineTokenCount = tokens
            self.tokenCount = 0
        } catch {
            self.currentSession = nil
        }
    }

    func acquire() -> CoreMLSession? { currentSession }

    func scheduleReplacement() {
        tokenCount += 1
        let usableTokens = maxTokens - baselineTokenCount
        let limit = Int(Double(usableTokens) * 0.8)
        if tokenCount > limit, limit > 0 {
            prewarmQueue.async {
                Task { await self.rotate() }
            }
        }
    }

    private func rotate() async {
        let oldSession = currentSession
        await prepare()
        oldSession?.close()
    }
}

// MARK: - CoreMLSession

class CoreMLSession {
    private let model: MLModel
    private var requestCount: Int = 0

    private init(model: MLModel) {
        self.model = model
    }

    static func create() async throws -> CoreMLSession {
        let modelDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Auris/Models/functiongemma-model")

        let compiledURL = modelDir.appendingPathComponent("model.mlmodelc")
        guard FileManager.default.fileExists(atPath: compiledURL.path) else {
            throw SessionError.modelNotFound
        }

        let model = try await MLModel.load(contentsOf: compiledURL, configuration: {
            let config = MLModelConfiguration()
            #if targetEnvironment(simulator)
            config.computeUnits = .cpuOnly
            #else
            config.computeUnits = .cpuAndNeuralEngine
            #endif
            return config
        }())
        return CoreMLSession(model: model)
    }

    /// Prefills the system prompt and returns the token count consumed.
    func prefill(_ prompt: String) async throws -> Int {
        _ = try await generate(prompt)
        // Token count estimated from the prompt — a tokenizer integration
        // would provide an exact count; roughly 1 token per 4 characters
        return prompt.count / 4
    }

    /// Runs generation on the Core ML model and returns the output text.
    /// Each call appends to the model's KV cache, so token budget tracking is critical.
    func generate(_ prompt: String) throws -> String {
        requestCount += 1
        // The model expects tokenized input; tokenization + generation are
        // handled by the Core ML model's built-in preprocessor when available.
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
            "input_text": MLFeatureValue(string: prompt)
        ]) else {
            return ""
        }
        let prediction = try model.prediction(from: input)
        guard let output = prediction.featureValue(for: "output_text")?.stringValue else {
            return ""
        }
        return output
    }

    func close() {
        // Core ML automatically manages resources; no explicit deallocation needed
    }

    enum SessionError: Error {
        case modelNotFound
    }
}
