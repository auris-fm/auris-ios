import Foundation
import PocketCastsUtils

/// sherpa-onnx `SherpaOnnxOfflineRecognizer` backend running NVIDIA Canary Flash 180m
/// (en/de/es/fr) for the de/es/fr cohort. Runs the native **translate** task
/// (`srcLang` = OS locale, `tgtLang` = "en") so commands arrive as English, matching the
/// monolingual intent-router design.
final class CanaryFlashBackend: AsrBackend {

    private let modelDir: String
    let srcLang: String
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var loadedTranslationTask = false
    private var loadedIdentity: VoiceSharingContributionEncoder.ModelRef?
    private let loadedLock = NSLock()
    private let transcribeQueue = DispatchQueue(label: "com.auris.canary", qos: .userInitiated)

    let capabilities = AsrCapabilities(
        languages: ["en", "de", "es", "fr"],
        canTranslateToEnglish: true,
        requiresHardwareAccel: false
    )

    var requiredModel: ModelSpec {
        ModelSpec(
            id: "canary-flash",
            files: [
                ModelFile(url: URL(string: "\(Self.baseURL)/\(Self.encoderFilename)")!, filename: Self.encoderFilename, sha256: nil),
                ModelFile(url: URL(string: "\(Self.baseURL)/\(Self.decoderFilename)")!, filename: Self.decoderFilename, sha256: nil),
                ModelFile(url: URL(string: "\(Self.baseURL)/\(Self.tokensFilename)")!, filename: Self.tokensFilename, sha256: nil),
            ],
            targetDir: "canary-flash-model"
        )
    }

    init(modelDir: String, srcLang: String) {
        self.modelDir = modelDir
        self.srcLang = srcLang
    }

    func ensureReady() async -> Result<Void, Error> {
        if loadedLock.withLock({ recognizer != nil }) { return .success(()) }

        // Reject unsupported source languages (e.g. forced locale) rather than passing an
        // invalid config to the runtime.
        guard Self.supportedLangs.contains(srcLang) else {
            return .failure(BackendError.unsupportedSource(srcLang))
        }

        do {
            try await downloadModels()
        } catch {
            return .failure(error)
        }

        return await withCheckedContinuation { continuation in
            transcribeQueue.async { [self] in
                continuation.resume(returning: loadRecognizer())
            }
        }
    }

    private func loadRecognizer() -> Result<Void, Error> {
        if loadedLock.withLock({ recognizer != nil }) { return .success(()) }
        let encoderPath = (modelDir as NSString).appendingPathComponent(Self.encoderFilename)
        let decoderPath = (modelDir as NSString).appendingPathComponent(Self.decoderFilename)
        let tokensPath = (modelDir as NSString).appendingPathComponent(Self.tokensFilename)
        guard FileManager.default.fileExists(atPath: encoderPath),
              FileManager.default.fileExists(atPath: decoderPath),
              FileManager.default.fileExists(atPath: tokensPath) else {
            return .failure(BackendError.modelMissing)
        }

        let canaryConfig = sherpaOnnxOfflineCanaryModelConfig(
            encoder: encoderPath, decoder: decoderPath,
            srcLang: srcLang, tgtLang: "en", usePnc: true)
        let config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: tokensPath,
                numThreads: 4,
                provider: "cpu",
                canary: canaryConfig
            )
        )

        var cfg = config
        let loaded = LoadedModelAssets.load(
            id: requiredModel.id,
            assets: requiredModel.files.map { ($0.filename, URL(fileURLWithPath: modelDir).appendingPathComponent($0.filename)) }) {
                SherpaOnnxOfflineRecognizer(config: &cfg)
            }
        loadedLock.withLock {
            self.recognizer = loaded.component
            self.loadedIdentity = loaded.identity
            self.loadedTranslationTask = Self.performsTranslation(canaryConfig)
        }
        FileLog.shared.addMessage("[CanaryFlash] backend ready (src=\(srcLang), tgt=en)")
        return .success(())
    }

    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        await transcribe(samples: samples, sampleRateHz: sampleRateHz, modelUsed: { _, _ in })
    }

    func transcribe(samples: [Float], sampleRateHz: Int,
                    modelUsed: @escaping (VoiceSharingContributionEncoder.ModelRef?, Bool) -> Void) async -> AsrResult {
        // Serialize sherpa-onnx offline decode — not thread-safe across concurrent Tasks.
        return await withCheckedContinuation { continuation in
            transcribeQueue.async { [weak self] in
                guard let self else {
                    modelUsed(nil, false)
                    continuation.resume(returning: AsrResult(text: "", detectedLanguage: nil))
                    return
                }
                let loaded = self.loadedLock.withLock { (self.recognizer, self.loadedIdentity, self.loadedTranslationTask) }
                guard let rec = loaded.0 else {
                    modelUsed(nil, false)
                    continuation.resume(returning: AsrResult(text: "", detectedLanguage: nil))
                    return
                }
                modelUsed(loaded.1, loaded.2)
                do {
                    let result = rec.decode(samples: samples, sampleRate: sampleRateHz)
                    let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        continuation.resume(returning: AsrResult(text: "", detectedLanguage: self.srcLang))
                        return
                    }
                    // English text, but language evidence stays the configured source (de/es/fr/en).
                    // IntentRoutingInput uses translationKind=.backend and omits sourceTranscript.
                    continuation.resume(returning: AsrResult(text: trimmed, detectedLanguage: self.srcLang))
                } catch {
                    FileLog.shared.addMessage("[CanaryFlash] transcription failed: \(error)")
                    continuation.resume(returning: AsrResult(text: "", detectedLanguage: nil))
                }
            }
        }
    }

    func release() {
        loadedLock.withLock {
            recognizer = nil
            loadedIdentity = nil
            loadedTranslationTask = false
        }
        FileLog.shared.addMessage("[CanaryFlash] released")
    }

    deinit { release() }

    /// sherpa-onnx Canary selects the task through its initial decoder source/target tokens.
    /// Equal source/target is transcription; differing supported languages request translation.
    /// This reads the exact native configuration used by the loaded recognizer, not capabilities.
    static func performsTranslation(_ config: SherpaOnnxOfflineCanaryModelConfig) -> Bool {
        guard let source = config.src_lang, let target = config.tgt_lang else { return false }
        return String(cString: source) != String(cString: target)
    }

    /// Downloads each ModelFile into the model dir if not already present. Routed through
    /// `ModelDownloader` so the spec's download contract applies (resumable + atomic rename,
    /// SHA-256 verification when a hash is pinned). TODO(ASR-debt): pin SHA-256 for the
    /// Canary Flash assets (currently unset) so integrity is enforced on download.
    private func downloadModels() async throws {
        // `download(files:to:)` short-circuits on first failure and creates the directory.
        let result = await ModelDownloader().download(files: requiredModel.files, to: URL(fileURLWithPath: modelDir))
        if case .failure(let error) = result {
            throw error
        }
    }

    private static let supportedLangs: Set<String> = ["en", "de", "es", "fr"]
    private static let baseURL = "https://hf-mirror.com/csukuangfj/sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8/resolve/main"
    private static let encoderFilename = "encoder.int8.onnx"
    private static let decoderFilename = "decoder.int8.onnx"
    private static let tokensFilename = "tokens.txt"

    enum BackendError: Error, LocalizedError {
        case unsupportedSource(String)
        case modelMissing

        var errorDescription: String? {
            switch self {
            case .unsupportedSource(let lang):
                return "Unsupported Canary source language: \(lang)"
            case .modelMissing:
                return "Canary Flash model files missing"
            }
        }
    }
}
