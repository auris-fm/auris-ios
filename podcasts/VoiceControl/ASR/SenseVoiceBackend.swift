import Foundation
import PocketCastsUtils

/// sherpa-onnx `SherpaOnnxOfflineRecognizer` backend running SenseVoice-Small (int8).
/// CTC, non-autoregressive, native text output with built-in language identification
/// across zh/en/ja/ko/yue. No translation capability — the downstream `TranslationStage`
/// converts non-English transcripts to English.
final class SenseVoiceBackend: AsrBackend {

    private let modelDir: String
    private var recognizer: SherpaOnnxOfflineRecognizer?

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
        let rec = recognizer
        guard let rec else { return AsrResult(text: "", detectedLanguage: nil) }
        do {
            let result = rec.decode(samples: samples, sampleRate: sampleRateHz)
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return AsrResult(text: "", detectedLanguage: nil)
            }
            // SenseVoice auto-LID prefixes text like "<|zh|>..."; strip + detect.
            let lang = detectLanguage(trimmed)
            let clean = stripLanguageTag(trimmed)
            return AsrResult(text: clean, detectedLanguage: lang)
        } catch {
            FileLog.shared.addMessage("[SenseVoice] transcription failed: \(error)")
            return AsrResult(text: "", detectedLanguage: nil)
        }
    }

    func release() {
        recognizer = nil
        FileLog.shared.addMessage("[SenseVoice] released")
    }

    static let langPattern = try! NSRegularExpression(pattern: "^<\\|(\\w+)\\|>")

    private func detectLanguage(_ text: String) -> String? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = SenseVoiceBackend.langPattern.firstMatch(in: text, range: range),
              match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private func stripLanguageTag(_ text: String) -> String {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return SenseVoiceBackend.langPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
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
