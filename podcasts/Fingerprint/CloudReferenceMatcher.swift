import Foundation

/// Set-overlap matcher for cloud reference fingerprints. The server's
/// `fingerprint-compact-v2` reference checkpoints and the client's
/// `CloudFingerprinter` windows use identical hash schemes, so a simple
/// set-overlap score is the correct similarity measure.
///
/// Replaces the Rust `CheckpointMatcher` for the cloud-alignment path only.
/// Score semantics match the existing pipeline: match floor 0.5, anchor
/// threshold 0.65, dominance gap 0.05 (see FingerprintConstants).
final class CloudReferenceMatcher {
    struct Match {
        let timestampSeconds: Float
        let score: Float
    }

    private struct Checkpoint {
        let timestampSeconds: Float
        let hashes: [UInt32]
    }

    private var checkpoints: [Checkpoint] = []

    /// Adds a reference checkpoint (timestamp in seconds, sorted hash set).
    func add(timestampSeconds: Float, hashes: [UInt32], durationSeconds: Float) {
        checkpoints.append(Checkpoint(timestampSeconds: timestampSeconds, hashes: hashes))
    }

    func clear() {
        checkpoints.removeAll()
    }

    var count: Int { checkpoints.count }

    /// Returns the top `maxResults` reference checkpoints by overlap score.
    func findTopMatches(queryHashes: [UInt32], maxResults: Int) -> [Match] {
        guard !queryHashes.isEmpty else { return [] }
        return checkpoints
            .map { Match(timestampSeconds: $0.timestampSeconds, score: Self.overlapScore(queryHashes, $0.hashes)) }
            .sorted { $0.score > $1.score }
            .prefix(maxResults)
            .map { $0 }
    }

    /// Overlap score = |A ∩ B| / min(|A|, |B|) ∈ [0, 1].
    static func overlapScore(_ a: [UInt32], _ b: [UInt32]) -> Float {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let small = a.count < b.count ? a : b
        let large = a.count < b.count ? b : a
        let set = Set(large)
        var intersection = 0
        for h in small where set.contains(h) {
            intersection += 1
        }
        return Float(intersection) / Float(small.count)
    }
}
