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

    /// Reads `wake_only_margin_ms` if, and only if, it is a non-negative NUMBER with no fractional
    /// part.
    ///
    /// Anything else — absent, a string, a boolean, a value with a fractional part, negative — is
    /// treated as "no margin", which leaves the audio rule off and routing unchanged. Reading it
    /// strictly matters: a silently coerced `-1` would invert the rule and drop ordinary commands.
    ///
    /// A WHOLE-VALUED float is accepted: JSON does not preserve the difference between `80` and
    /// `80.0` through `JSONSerialization`, both mean eighty milliseconds, and rejecting the second
    /// would fail a manifest over how it was written rather than what it says.
    static func wakeOnlyMarginMs(fromManifestJSON json: [String: Any]) -> Int? {
        guard let value = json["wake_only_margin_ms"] else { return nil }
        // TYPE FIRST, value second. A JSON boolean also bridges to NSNumber, where `true` reads as
        // 1.0 and `false` as 0.0 — both integral and non-negative — so any numeric check alone
        // accepts them and the rule runs on a margin nobody wrote. Asking whether the value IS a
        // number is the only way to tell the two apart after bridging.
        guard CFGetTypeID(value as CFTypeRef) == CFNumberGetTypeID() else { return nil }
        let number = value as! NSNumber
        // Measured in whole milliseconds, so a fractional value is not a count. A whole-valued
        // float survives this: it says the same thing `80` does, and JSON loses the distinction.
        guard number.doubleValue == number.doubleValue.rounded() else { return nil }
        let milliseconds = number.intValue
        return milliseconds >= 0 ? milliseconds : nil
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
