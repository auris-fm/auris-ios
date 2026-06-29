import Foundation

protocol AsrBackend {
    func ensureReady() async -> Result<Void, Error>
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult
    var requiredModel: ModelSpec { get }
    var capabilities: AsrCapabilities { get }
    func release()
}

struct AsrResult {
    let text: String
    let detectedLanguage: String?
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
