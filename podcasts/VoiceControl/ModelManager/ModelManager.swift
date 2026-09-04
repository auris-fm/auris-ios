import Foundation
import CryptoKit
import PocketCastsUtils

struct LfmAsset: Equatable {
    let name: String
    let url: String
    let bytes: Int64
    let sha256: String
}

struct LfmRelease: Equatable {
    let version: String
    let requiredAssets: [LfmAsset]
}

enum LfmManifestError: Error, LocalizedError, Equatable {
    case missingAsset(String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .missingAsset(let name): return "LFM manifest must contain \(name)"
        case .invalidJSON: return "LFM manifest JSON is invalid"
        }
    }
}

func parseLfmManifest(_ json: String) throws -> LfmRelease {
    guard let data = json.data(using: .utf8),
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = root["version"] as? String,
          let assets = root["assets"] as? [String: Any]
    else {
        throw LfmManifestError.invalidJSON
    }

    let requiredNames = [
        ModelManager.lfmModelFilename,
        ModelManager.lfmClassifierFilename,
        ModelManager.lfmLabelMapFilename,
    ]
    let requiredAssets: [LfmAsset] = try requiredNames.map { name in
        guard let asset = assets[name] as? [String: Any],
              let url = asset["url"] as? String,
              let sha256 = asset["sha256"] as? String
        else {
            throw LfmManifestError.missingAsset(name)
        }
        let bytesValue = asset["bytes"]
        let bytes: Int64
        if let int = bytesValue as? Int {
            bytes = Int64(int)
        } else if let int64 = bytesValue as? Int64 {
            bytes = int64
        } else if let number = bytesValue as? NSNumber {
            bytes = number.int64Value
        } else {
            throw LfmManifestError.missingAsset(name)
        }
        return LfmAsset(name: name, url: url, bytes: bytes, sha256: sha256)
    }
    return LfmRelease(version: version, requiredAssets: requiredAssets)
}

class ModelManager: ObservableObject {
    static let lfmModelFilename = "model.gguf"
    static let lfmClassifierFilename = "classifier.bin"
    static let lfmLabelMapFilename = "label_map.json"
    private static let lfmManifestFilename = "manifest.json"
    private static let lfmLatestURL = URL(string: "https://download.auris.fm/function-call/latest.json")!

    @Published var isReady = false

    private let downloader: ModelDownloader
    private let storageDir: URL
    private let session: URLSession

    /// Application Support/.../Auris/Models root (injectable via init for tests).
    var filesDir: URL { storageDir }

    var lfmDir: URL { storageDir.appendingPathComponent("function-call") }
    var lfmModelFile: URL { lfmDir.appendingPathComponent(Self.lfmModelFilename) }
    var lfmClassifierFile: URL { lfmDir.appendingPathComponent(Self.lfmClassifierFilename) }
    var lfmLabelMapFile: URL { lfmDir.appendingPathComponent(Self.lfmLabelMapFilename) }
    private var lfmManifestFile: URL { lfmDir.appendingPathComponent(Self.lfmManifestFilename) }

    init(
        storageDir: URL? = nil,
        downloader: ModelDownloader = ModelDownloader(),
        session: URLSession = .shared
    ) {
        self.downloader = downloader
        self.session = session
        if let storageDir {
            self.storageDir = storageDir
        } else {
            self.storageDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("Auris/Models")
        }
        try? FileManager.default.createDirectory(at: self.storageDir, withIntermediateDirectories: true)
    }

    func ensureSelectedModels() async {
        let whisperSpec = ModelSpec(
            id: "whisper",
            files: [
                ModelFile(
                    url: URL(string: "https://download.auris.fm/whisper/ggml-small-q5_1.bin")!,
                    filename: "ggml-small-q5_1.bin",
                    sha256: nil
                ),
            ],
            targetDir: "whisper-model"
        )
        _ = await downloadModel(spec: whisperSpec)
        _ = await ensureLfmModel()
        isReady = isLfmModelReady()
    }

    func isLfmModelReady() -> Bool {
        guard FileManager.default.fileExists(atPath: lfmManifestFile.path),
              let json = try? String(contentsOf: lfmManifestFile, encoding: .utf8),
              let release = try? parseLfmManifest(json)
        else {
            return false
        }
        return release.requiredAssets.allSatisfy { asset in
            let file = lfmDir.appendingPathComponent(asset.name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = attrs[.size] as? NSNumber,
                  size.int64Value == asset.bytes
            else {
                return false
            }
            return lfmAssetLooksIntact(name: asset.name, file: file)
        }
    }

    /// Deletes on-disk LFM assets so the next `ensureLfmModel` re-downloads.
    /// Used when size-ok files still fail native load (corrupt-but-same-size).
    func invalidateLfmModel() {
        let names = [
            Self.lfmModelFilename,
            Self.lfmClassifierFilename,
            Self.lfmLabelMapFilename,
            Self.lfmManifestFilename,
        ]
        for name in names {
            let url = lfmDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
        }
        isReady = false
    }

    func lfmReleaseVersion() -> String? {
        guard FileManager.default.fileExists(atPath: lfmManifestFile.path),
              let json = try? String(contentsOf: lfmManifestFile, encoding: .utf8),
              let release = try? parseLfmManifest(json)
        else {
            return nil
        }
        return release.version
    }

    func ensureLfmModel() async -> Result<Void, Error> {
        if isLfmModelReady() { return .success(()) }
        do {
            try FileManager.default.createDirectory(at: lfmDir, withIntermediateDirectories: true)
            let (data, _) = try await session.data(from: Self.lfmLatestURL)
            guard let manifest = String(data: data, encoding: .utf8) else {
                throw LfmManifestError.invalidJSON
            }
            let release = try parseLfmManifest(manifest)
            for asset in release.requiredAssets {
                guard let url = URL(string: asset.url) else {
                    throw ModelError.downloadFailed
                }
                let result = await downloader.download(
                    url: url,
                    sha256: asset.sha256,
                    to: lfmDir
                )
                if case .failure(let error) = result {
                    return .failure(error)
                }
            }
            try manifest.write(to: lfmManifestFile, atomically: true, encoding: .utf8)
            FileLog.shared.addMessage("[VoicePipeline] Release \(release.version) ready")
            return .success(())
        } catch {
            FileLog.shared.addMessage("[VoicePipeline] Download failed: \(error)")
            return .failure(error)
        }
    }

    /// Cheap integrity beyond byte-size: classifier magic + parseable label map.
    /// GGUF relies on native load failure → `invalidateLfmModel` re-download.
    private func lfmAssetLooksIntact(name: String, file: URL) -> Bool {
        switch name {
        case Self.lfmClassifierFilename:
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            let magic = handle.readData(ofLength: 4)
            return magic == Data("LFMC".utf8)
        case Self.lfmLabelMapFilename:
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["labels"] as? [Any] != nil
            else {
                return false
            }
            return true
        default:
            return true
        }
    }

    private func downloadModel(spec: ModelSpec) async -> Result<Void, Error> {
        let targetDir = storageDir.appendingPathComponent(spec.targetDir)
        // download(files:to:) creates the directory and applies the per-file contract
        // (resumable + SHA-verify-when-pinned + atomic rename) for each asset in the spec.
        return await downloader.download(files: spec.files, to: targetDir)
    }
}
