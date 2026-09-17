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
        /// Precomputed so the per-window hot path never rebuilds a Set from the
        /// full hash list (PR #14 review).
        let hashSet: Set<UInt32>
    }

    private var checkpoints: [Checkpoint] = []

    /// Adds a reference checkpoint (timestamp in seconds, sorted hash set).
    /// `durationSeconds` is the checkpoint spacing metadata from the server
    /// reference; client matching derives its own windows, so it is not used
    /// for scoring today — the parameter is accepted to keep the builder
    /// contract mirroring the server's reference format.
    func add(timestampSeconds: Float, hashes: [UInt32], durationSeconds: Float) {
        checkpoints.append(Checkpoint(timestampSeconds: timestampSeconds, hashes: hashes, hashSet: Set(hashes)))
    }

    func clear() {
        checkpoints.removeAll()
    }

    var count: Int { checkpoints.count }

    /// Returns the top `maxResults` reference checkpoints by overlap score.
    func findTopMatches(queryHashes: [UInt32], maxResults: Int) -> [Match] {
        guard !queryHashes.isEmpty else { return [] }
        let querySet = Set(queryHashes)
        return checkpoints
            .map { Match(timestampSeconds: $0.timestampSeconds, score: Self.overlapScore(querySet, queryHashes, $0.hashSet)) }
            .sorted { $0.score > $1.score }
            .prefix(maxResults)
            .map { $0 }
    }

    /// Overlap score = |A ∩ B| / min(|A|, |B|) ∈ [0, 1].
    static func overlapScore(_ a: [UInt32], _ b: [UInt32]) -> Float {
        overlapScore(Set(a), a, Set(b))
    }

    /// Set-form hot path: reuses precomputed hash sets so matching every
    /// window against every checkpoint allocates nothing (PR #14 review).
    /// Iterates the smaller set; membership is checked against the larger.
    static func overlapScore(_ setA: Set<UInt32>, _ a: [UInt32], _ setB: Set<UInt32>) -> Float {
        guard !a.isEmpty, !setB.isEmpty else { return 0 }
        let iterateA = a.count <= setB.count
        let (iterate, target) = iterateA ? (setA, setB) : (setB, setA)
        let denominator = iterateA ? a.count : setB.count
        var intersection = 0
        for h in iterate where target.contains(h) {
            intersection += 1
        }
        return Float(intersection) / Float(denominator)
    }
}
