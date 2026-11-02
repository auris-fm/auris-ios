import CryptoKit
import Foundation

protocol AsrBackend {
    func ensureReady() async -> Result<Void, Error>
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult
    /// Reports the loaded instance at invocation entry, before potentially held decoding.
    func transcribe(samples: [Float], sampleRateHz: Int,
                    modelUsed: @escaping (VoiceSharingContributionEncoder.ModelRef?, Bool) -> Void) async -> AsrResult
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

// Unknown provenance is explicit for backends without a loaded-instance identity contract.
extension AsrBackend {
    func transcribe(samples: [Float], sampleRateHz: Int,
                    modelUsed: @escaping (VoiceSharingContributionEncoder.ModelRef?, Bool) -> Void) async -> AsrResult {
        modelUsed(nil, false)
        return await transcribe(samples: samples, sampleRateHz: sampleRateHz)
    }
}

/// Content identity of the exact asset set surrounding a successful component construction.
/// Call on a model worker, never the audio/main path. Provenance failure never prevents loading.
enum LoadedModelAssets {
    static func load<Component>(id: String, assets: [(name: String, url: URL)],
                                construct: () -> Component) -> (component: Component, identity: VoiceSharingContributionEncoder.ModelRef?) {
        let before = try? contentDigests(assets)
        let component = construct()
        let after = try? contentDigests(assets)
        let identity: VoiceSharingContributionEncoder.ModelRef?
        if let before, before == after {
            identity = reference(id: id, digests: before)
        } else {
            identity = nil
        }
        return (component, identity)
    }

    /// Stable logical asset names and content hashes only; filesystem paths never enter metadata.
    static func reference(id: String, digests: [String: String]) -> VoiceSharingContributionEncoder.ModelRef? {
        guard !id.isEmpty, !digests.isEmpty else { return nil }
        var setHash = SHA256()
        setHash.update(data: Data("auris-loaded-assets-v1\n".utf8))
        for name in digests.keys.sorted() {
            guard !name.isEmpty, let digest = digests[name], digest.count == 64,
                  digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            setHash.update(data: Data("\(name.utf8.count):\(name):\(digest)\n".utf8))
        }
        return .init(id: id, version: setHash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func contentDigests(_ assets: [(name: String, url: URL)]) throws -> [String: String] {
        var digests: [String: String] = [:]
        for asset in assets {
            guard digests[asset.name] == nil else { throw CocoaError(.fileReadCorruptFile) }
            let file = try FileHandle(forReadingFrom: asset.url)
            defer { try? file.close() }
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            digests[asset.name] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return digests
    }
}
