import Foundation

protocol AsrBackend {
    func ensureReady() async -> Result<Void, Error>
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult
    var requiredModel: ModelSpec { get }
    var capabilities: AsrCapabilities { get }
    func release()
}

struct AsrToken {
    let text: String
    let startMs: Int
    let endMs: Int
}

struct AsrResult {
    let text: String
    let detectedLanguage: String?
    let tokens: [AsrToken]?

    init(text: String, detectedLanguage: String?, tokens: [AsrToken]? = nil) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.tokens = tokens
    }
}

struct AsrCapabilities: Equatable {
    let languages: Set<String>
    let canTranslateToEnglish: Bool
    let requiresHardwareAccel: Bool
}

struct ModelSpec {
    let id: String
    let files: [ModelFile]
    let targetDir: String
}

struct ModelFile {
    let url: URL
    let filename: String
    let sha256: String?
}
