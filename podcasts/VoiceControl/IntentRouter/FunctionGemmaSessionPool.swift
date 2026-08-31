import Foundation
import CoreML
import PocketCastsUtils
#if canImport(LiteRTLM)
import LiteRTLM
#endif

/// Manifest entry for a single asset in the release JSON.
struct ModelAsset: Decodable {
    let url: String
    let bytes: Int
    let sha256: String
}

/// Top-level manifest returned by `latest.json`.
struct ModelManifest: Decodable {
    let version: String
    let assets: [String: ModelAsset]
}

/// Inference backends available for FunctionGemma.
enum InferenceBackend {
    /// LiteRT-LM — cross-platform, uses `.litertlm` from R2.
    /// Primary path for the initial release; shares the Android model.
    case litert
    /// Core ML — compiled `.mlmodelc`, best latency on ANE.
    /// Requires a generation-capable export matching the client contract.
    case coreml
}

/// A prepared session plus the backend that produced it.
struct MadeSession {
    let session: any InferenceSession
    let backend: InferenceBackend
}

/// Creates inference sessions for the session pool. Injectable so the pool's
/// prepare/rotation behavior is unit-testable without real model files.
protocol FunctionGemmaSessionFactory {
    func makeSession() async throws -> MadeSession
}

class FunctionGemmaSessionPool {
    private let sessionFactory: FunctionGemmaSessionFactory
    private var currentSession: (any InferenceSession)?
    private var tokenCount: Int = 0
    private let maxTokens = 32_768
    private var baselineTokenCount: Int = 0
    private var hasTokenCounts = false
    private let prewarmQueue = DispatchQueue(label: "com.auris.functiongemma.session-pool")

    /// URL to fetch the latest model manifest.
    private static let manifestURL = URL(string: "https://download.auris.fm/function-call/latest.json")!

    /// Which backend produced the current session.
    private(set) var backend: InferenceBackend = .litert

    /// Test seam: overrides the model-file availability check so `prepare()` can
    /// run against a fake session without downloading a release.
    var modelFilesReady: () -> Bool = { FunctionGemmaPaths.hasUsableModel() }

    init(factory: FunctionGemmaSessionFactory? = nil) {
        self.sessionFactory = factory ?? DefaultFunctionGemmaSessionFactory()
    }

    func prepare() async {
        do {
            try await ensureModelDownloaded()
        } catch {
            FileLog.shared.addMessage("[FunctionGemma] Model download failed: \(error)")
            self.currentSession = nil
            return
        }

        let systemPrompt = PromptBuilder.buildSystemPrompt(tools: ToolSchema.tools())
        do {
            let made = try await sessionFactory.makeSession()
            let tokens = try await made.session.prefill(systemPrompt)
            self.currentSession = made.session
            self.backend = made.backend
            self.hasTokenCounts = tokens != nil
            self.baselineTokenCount = tokens ?? 0
            self.tokenCount = 0
            FileLog.shared.addMessage("[FunctionGemma] Session ready (backend: \(made.backend))")
        } catch {
            FileLog.shared.addMessage("[FunctionGemma] Session creation failed: \(error)")
            self.currentSession = nil
        }
    }

    // MARK: - Model Download

    private func ensureModelDownloaded() async throws {
        guard !modelFilesReady() else { return }

        let modelDir = FunctionGemmaPaths.modelDir
        let (data, _) = try await URLSession.shared.data(from: Self.manifestURL)
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        if let asset = manifest.assets["model.litertlm"] {
            FileLog.shared.addMessage("[FunctionGemma] Downloading LiteRT model (\(asset.bytes / 1_048_576)MB)...")
            try await downloadAsset(asset, to: modelDir.appendingPathComponent("model.litertlm"))
        }

        if let asset = manifest.assets["model.mlmodel"] {
            FileLog.shared.addMessage("[FunctionGemma] Downloading Core ML model (\(asset.bytes / 1_048_576)MB)...")
            try await downloadAsset(asset, to: modelDir.appendingPathComponent("model.mlmodel"))
            try await compileCoreMLModel(at: modelDir)
        }

        if let asset = manifest.assets["tools.json"] {
            FileLog.shared.addMessage("[FunctionGemma] Downloading tools.json...")
            try await downloadAsset(asset, to: modelDir.appendingPathComponent("tools.json"))
        }

        FileLog.shared.addMessage("[FunctionGemma] Model download complete.")
    }

    private func downloadAsset(_ asset: ModelAsset, to url: URL) async throws {
        guard let remoteURL = URL(string: asset.url) else {
            throw DownloadError.invalidURL
        }
        // TODO: verify sha256 after download
        let (dlURL, _) = try await URLSession.shared.download(from: remoteURL)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: dlURL, to: url)
    }

    enum DownloadError: Error {
        case invalidURL
    }

    /// Compiles a downloaded `.mlmodel` to `.mlmodelc` on-device.
    private func compileCoreMLModel(at modelDir: URL) async throws {
        let mlmodelURL = modelDir.appendingPathComponent("model.mlmodel")
        let compiledURL = modelDir.appendingPathComponent("model.mlmodelc")

        guard !FileManager.default.fileExists(atPath: compiledURL.path) else { return }
        guard FileManager.default.fileExists(atPath: mlmodelURL.path) else { return }

        FileLog.shared.addMessage("[FunctionGemma] Compiling Core ML model...")
        let result = try await MLModel.compileModel(at: mlmodelURL)
        try? FileManager.default.removeItem(at: compiledURL)
        try FileManager.default.moveItem(at: result, to: compiledURL)
        FileLog.shared.addMessage("[FunctionGemma] Core ML compilation complete.")
    }

    func acquire() -> (any InferenceSession)? { currentSession }

    func scheduleReplacement() {
        guard hasTokenCounts else { return }
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

    enum SessionError: Error {
        case noModelAvailable
    }
}

/// Resolves the session backend from the files present on disk.
///
/// Core ML is preferred when a conformant `.mlmodelc` exists; a non-conformant
/// Core ML model fails closed and falls back to LiteRT-LM so a bad export can
/// never silently produce an unclassifiable router (see functiongemma-engagement.md).
private struct DefaultFunctionGemmaSessionFactory: FunctionGemmaSessionFactory {
    func makeSession() async throws -> MadeSession {
        let modelDir = FunctionGemmaPaths.modelDir
        let compiledURL = modelDir.appendingPathComponent("model.mlmodelc")
        let litertURL = modelDir.appendingPathComponent("model.litertlm")

        if FileManager.default.fileExists(atPath: compiledURL.path) {
            do {
                let session = try await CoreMLSession.create(modelURL: compiledURL)
                return MadeSession(session: session, backend: .coreml)
            } catch {
                FileLog.shared.addMessage("[FunctionGemma] Core ML session rejected (\(error)); falling back to LiteRT")
            }
        }

        #if canImport(LiteRTLM)
        if FileManager.default.fileExists(atPath: litertURL.path) {
            let session = try await LiteRTSession.create(modelURL: litertURL)
            return MadeSession(session: session, backend: .litert)
        }
        #endif

        throw FunctionGemmaSessionPool.SessionError.noModelAvailable
    }
}

// MARK: - Model paths

enum FunctionGemmaPaths {
    static var modelDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Auris/Models/functiongemma-model")
    }

    static func hasUsableModel() -> Bool {
        let compiledURL = modelDir.appendingPathComponent("model.mlmodelc")
        let litertURL = modelDir.appendingPathComponent("model.litertlm")
        return FileManager.default.fileExists(atPath: compiledURL.path)
            || FileManager.default.fileExists(atPath: litertURL.path)
    }
}

// MARK: - InferenceSession protocol

protocol InferenceSession {
    /// Prefills the system prompt and returns the token count consumed, or nil
    /// when the runtime does not expose token counts (rotation is then disabled).
    func prefill(_ prompt: String) async throws -> Int?
    /// Runs generation and returns the output text.
    func generate(_ prompt: String) throws -> String
    /// Releases any held resources.
    func close()
}

// MARK: - Core ML contract

/// The documented Core ML model I/O contract the iOS client loads.
///
/// The client feeds a string prompt and reads a string generation result. The
/// current causal-LM export in `training/function-call/export_coreml.py`
/// (input_ids → logits) does NOT satisfy this contract; loading it must fail
/// closed instead of silently returning empty classifications.
enum CoreMLModelContract {
    static let inputFeature = "input_text"
    static let outputFeature = "output_text"

    enum ContractError: Error, Equatable {
        case unsupportedModelContract(inputs: [String], outputs: [String])
    }

    static func validate(inputNames: [String], outputNames: [String]) throws {
        guard inputNames.contains(inputFeature), outputNames.contains(outputFeature) else {
            throw ContractError.unsupportedModelContract(inputs: inputNames, outputs: outputNames)
        }
    }
}

// MARK: - CoreMLSession

class CoreMLSession: InferenceSession {
    private let model: MLModel

    private init(model: MLModel) {
        self.model = model
    }

    static func create(modelURL: URL) async throws -> CoreMLSession {
        let model = try await MLModel.load(contentsOf: modelURL, configuration: {
            let config = MLModelConfiguration()
            #if targetEnvironment(simulator)
            config.computeUnits = .cpuOnly
            #else
            config.computeUnits = .cpuAndNeuralEngine
            #endif
            return config
        }())
        let inputNames = Array(model.modelDescription.inputDescriptionsByName.keys)
        let outputNames = Array(model.modelDescription.outputDescriptionsByName.keys)
        try CoreMLModelContract.validate(inputNames: inputNames, outputNames: outputNames)
        return CoreMLSession(model: model)
    }

    func prefill(_ prompt: String) async throws -> Int? {
        _ = try await generate(prompt)
        // The Core ML runtime does not expose per-conversation token counts, so
        // rotation stays disabled rather than relying on character-count guesses.
        return nil
    }

    func generate(_ prompt: String) throws -> String {
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
            CoreMLModelContract.inputFeature: MLFeatureValue(string: prompt)
        ]) else {
            return ""
        }
        let prediction = try model.prediction(from: input)
        guard let output = prediction.featureValue(for: CoreMLModelContract.outputFeature)?.stringValue else {
            return ""
        }
        return output
    }

    func close() {}
}

// MARK: - LiteRTSession

#if canImport(LiteRTLM)

class LiteRTSession: InferenceSession {
    private let engine: Engine
    private var conversation: Conversation?

    private init(engine: Engine) {
        self.engine = engine
    }

    static func create(modelURL: URL) async throws -> LiteRTSession {
        let config = try EngineConfig(
            modelPath: modelURL.path,
            backend: .gpu,
            cacheDir: NSTemporaryDirectory()
        )
        let engine = Engine(engineConfig: config)
        try await engine.initialize()
        return LiteRTSession(engine: engine)
    }

    func prefill(_ prompt: String) async throws -> Int? {
        conversation = try await engine.createConversation()
        // Send the actual system prompt (developer message + tool declarations).
        // An empty first message previously left the model without any tool
        // context, so it could never emit a function call (functiongemma-engagement.md).
        _ = try await conversation?.sendMessage(Message(prompt))
        // LiteRT-LM does not expose per-conversation token counts in the current
        // API; return nil so the pool keeps rotation disabled (no fake counts).
        return nil
    }

    func generate(_ prompt: String) throws -> String {
        // LiteRT-LM generation is async; use a Task to bridge.
        // The session pool serializes access, so concurrent calls
        // are not a concern.
        var result = ""
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            guard let conversation = self.conversation else { return }
            let response = try? await conversation.sendMessage(Message(prompt))
            result = response?.toString ?? ""
        }
        semaphore.wait()
        return result
    }

    func close() {
        conversation = nil
    }
}
#endif
