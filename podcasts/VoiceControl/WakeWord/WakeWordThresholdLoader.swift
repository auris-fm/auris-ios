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
        /// `wake_only_margin_ms`, or `nil` when the manifest has no usable value.
        ///
        /// Unlike the threshold this is NOT required: the spec says a missing or invalid margin
        /// disables the audio wake-only rule only, and does not make the detector not-ready. It
        /// ships with the wake model, so older manifests legitimately lack it.
        var wakeOnlyMarginMs: Int? = nil
    }

    /// Reads `wake_only_margin_ms` if, and only if, it is a non-negative integer.
    ///
    /// Anything else — absent, a string, a float, negative — is treated as "no margin", which
    /// leaves the audio rule off and routing unchanged. Reading it strictly matters: a silently
    /// coerced `-1` would invert the rule and drop ordinary commands.
    static func wakeOnlyMarginMs(fromManifestJSON json: [String: Any]) -> Int? {
        guard let number = json["wake_only_margin_ms"] as? NSNumber else { return nil }
        // A JSON float ("80.5") is a Double bridging to NSNumber; comparing against the double
        // rejects it, so an obviously wrong type cannot masquerade as a valid milliseconds value.
        guard number.doubleValue == number.doubleValue.rounded() else { return nil }
        let value = number.intValue
        return value >= 0 ? value : nil
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
            identity: LoadedModelAssets.reference(id: "auris", digests: assetHashes.mapValues { $0.lowercased() }),
            wakeOnlyMarginMs: wakeOnlyMarginMs(fromManifestJSON: json)))
    }
}
