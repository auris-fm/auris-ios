import Foundation
import PocketCastsUtils

/// sherpa-onnx `SherpaOnnxOfflineRecognizer` backend running SenseVoice-Small (int8).
/// CTC, non-autoregressive, native text output with built-in language identification
/// across zh/en/ja/ko/yue. No translation capability — the downstream `TranslationStage`
/// converts non-English transcripts to English.
final class SenseVoiceBackend: AsrBackend {

    private let modelDir: String
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let transcribeQueue = DispatchQueue(label: "com.auris.sensevoice", qos: .userInitiated)

    let capabilities = AsrCapabilities(
        languages: ["zh", "en", "ja", "ko", "yue"],
        canTranslateToEnglish: false,
        requiresHardwareAccel: false
    )

    var requiredModel: ModelSpec {
        ModelSpec(
            id: "sensevoice",
            files: [
                ModelFile(
                    url: URL(string: "\(Self.baseURL)/\(Self.modelFilename)")!,
                    filename: Self.modelFilename,
                    sha256: nil
                ),
                ModelFile(
                    url: URL(string: "\(Self.baseURL)/\(Self.tokensFilename)")!,
                    filename: Self.tokensFilename,
                    sha256: nil
                ),
            ],
            targetDir: "sensevoice-model"
        )
    }

    init(modelDir: String) {
        self.modelDir = modelDir
    }

    func ensureReady() async -> Result<Void, Error> {
        // Rebuild the recognizer if not present (e.g. first call, or after model dir change).
        if recognizer != nil { return .success(()) }

        do {
            try await downloadModels()
        } catch {
            return .failure(error)
        }

        let encoderPath = (modelDir as NSString).appendingPathComponent(Self.modelFilename)
        let tokensPath = (modelDir as NSString).appendingPathComponent(Self.tokensFilename)
        guard FileManager.default.fileExists(atPath: encoderPath),
              FileManager.default.fileExists(atPath: tokensPath) else {
            return .failure(BackendError.modelMissing)
        }

        let config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: tokensPath,
                numThreads: 4,
                provider: "cpu",
                senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(model: encoderPath)
            )
        )

        // Just-created local structs must be kept alive until init completes.
        var cfg = config
        let recognizer = SherpaOnnxOfflineRecognizer(config: &cfg)
        self.recognizer = recognizer
        FileLog.shared.addMessage("[SenseVoice] backend ready")
        return .success(())
    }

    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        // Serialize sherpa-onnx offline decode — not thread-safe across concurrent Tasks.
        return await withCheckedContinuation { continuation in
            transcribeQueue.async { [weak self] in
                guard let self, let rec = self.recognizer else {
                    continuation.resume(returning: AsrResult(text: "", detectedLanguage: nil))
                    return
                }
                do {
                    let result = rec.decode(samples: samples, sampleRate: sampleRateHz)
                    let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        continuation.resume(returning: AsrResult(text: "", detectedLanguage: nil))
                        return
                    }
                    // Prefer structured LID; normalize <|zh|> → zh so Apple Translation
                    // gets a real language code (raw tags cause translate=fail(<|zh|>)).
                    let lang = Self.resolveDetectedLanguage(
                        structuredLang: result.lang,
                        text: trimmed
                    )
                    let clean = self.stripLanguageTag(trimmed)
                    continuation.resume(returning: AsrResult(text: clean, detectedLanguage: lang))
                } catch {
                    FileLog.shared.addMessage("[SenseVoice] transcription failed: \(error)")
                    continuation.resume(returning: AsrResult(text: "", detectedLanguage: nil))
                }
            }
        }
    }

    func release() {
        recognizer = nil
        FileLog.shared.addMessage("[SenseVoice] released")
    }

    deinit { release() }

    /// Downloads each ModelFile into the model dir if not already present. Routed through
    /// `ModelDownloader` so the spec's download contract applies (resumable + atomic rename,
    /// SHA-256 verification when a hash is pinned). TODO(ASR-debt): pin SHA-256 for the
    /// SenseVoice assets (currently unset) so integrity is enforced on download.
    private func downloadModels() async throws {
        // `download(files:to:)` short-circuits on first failure and creates the directory.
        let result = await ModelDownloader().download(files: requiredModel.files, to: URL(fileURLWithPath: modelDir))
        if case .failure(let error) = result {
            throw error
        }
    }

    /// Matches `<|zh|>` / `<|zh/en|>` at the start of a string (or the whole string).
    static let langTagPattern = try! NSRegularExpression(
        pattern: "^<\\|([a-zA-Z0-9]+)(?:/[a-zA-Z0-9]+)?\\|>"
    )
    private static let supportedLangs: Set<String> = ["zh", "en", "ja", "ko", "yue"]

    /// Prefer structured LID; fall back to a leading text tag. Always returns a bare
    /// code (`zh`, `en`, …) — never the raw `<|zh|>` token sherpa puts in `result.lang`.
    static func resolveDetectedLanguage(structuredLang: String?, text: String) -> String? {
        if let normalized = normalizeLanguageCode(structuredLang) { return normalized }
        return detectLanguage(from: text)
    }

    /// Maps `<|zh|>` / `<|zh/en|>` / `zh` → `zh`; unrecognized / unsupported → nil.
    static func normalizeLanguageCode(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let ns = trimmed as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = langTagPattern.firstMatch(in: trimmed, range: range),
           match.range(at: 1).location != NSNotFound,
           match.range == range {
            let code = ns.substring(with: match.range(at: 1)).lowercased()
            return supportedLangs.contains(code) ? code : nil
        }
        let lower = trimmed.lowercased()
        guard lower.range(of: #"^[a-z]{2,8}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return supportedLangs.contains(lower) ? lower : nil
    }

    private static func detectLanguage(from text: String) -> String? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = langTagPattern.firstMatch(in: text, range: range),
              match.range(at: 1).location != NSNotFound else { return nil }
        let code = ns.substring(with: match.range(at: 1)).lowercased()
        return supportedLangs.contains(code) ? code : nil
    }

    private func stripLanguageTag(_ text: String) -> String {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return Self.langTagPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let baseURL = "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main"
    private static let modelFilename = "model.int8.onnx"
    private static let tokensFilename = "tokens.txt"

    enum BackendError: Error, LocalizedError {
        case modelMissing

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return "SenseVoice model files missing"
            }
        }
    }
}
