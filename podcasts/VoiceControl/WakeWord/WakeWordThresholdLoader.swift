import CryptoKit
import Foundation

/// Loads the wake-word deployment threshold from the bundled eval manifest per
/// recognition-pipeline.md "Threshold". The threshold is not a fixed default:
/// the loader requires `deployment_threshold` plus `asset_hashes` pinning every
/// bundled model file, and fails closed (never falls back to 0.5 or a legacy
/// balanced/optimal field).
enum WakeWordThresholdLoader {
    struct LoadError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    struct Deployment {
        let threshold: Float
        let identity: VoiceSharingContributionEncoder.ModelRef?
    }

    static func load(manifestURL: URL, modelDirectory: URL) -> Result<Float, Error> {
        loadDeployment(manifestURL: manifestURL, modelDirectory: modelDirectory).map { $0.threshold }
    }

    static func loadDeployment(manifestURL: URL, modelDirectory: URL) -> Result<Deployment, Error> {
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .failure(LoadError(reason: "eval manifest missing at \(manifestURL.path)"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(LoadError(reason: "eval manifest is not valid JSON"))
        }
        guard let thresholdNumber = json["deployment_threshold"] as? NSNumber else {
            return .failure(LoadError(reason: "eval manifest has no deployment_threshold"))
        }
        guard let assetHashes = json["asset_hashes"] as? [String: String], !assetHashes.isEmpty else {
            return .failure(LoadError(reason: "eval manifest must pin asset_hashes for the deployable asset set"))
        }

        for (filename, expected) in assetHashes {
            let assetURL = modelDirectory.appendingPathComponent(filename)
            guard let assetData = try? Data(contentsOf: assetURL) else {
                return .failure(LoadError(reason: "pinned asset missing: \(filename)"))
            }
            let digest = SHA256.hash(data: assetData)
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest == expected.lowercased() else {
                return .failure(LoadError(reason: "hash mismatch for \(filename)"))
            }
        }

        return .success(Deployment(
            threshold: thresholdNumber.floatValue,
            identity: LoadedModelAssets.reference(id: "auris", digests: assetHashes.mapValues { $0.lowercased() })))
    }
}
