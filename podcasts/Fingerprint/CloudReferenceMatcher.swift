import Foundation

/// Set-overlap matcher for cloud reference fingerprints. The server's
/// `fingerprint-compact-v2` reference checkpoints and the client's
/// `CloudFingerprinter` windows use identical hash schemes, so a simple
/// set-overlap score is the correct similarity measure.
///
/// Replaces the Rust `CheckpointMatcher` for the cloud-alignment path only.
/// Score semantics match the existing pipeline: match floor 0.5, anchor
/// threshold 0.65, dominance gap 0.05 (see FingerprintConstants).
///
/// Storage: one sorted, deduplicated `[UInt32]` per checkpoint, membership by
/// binary search — no `Set` beside the array. A long episode holds thousands
/// of checkpoints; the array+Set pair cost several multiples of the raw hash
/// bytes per checkpoint, the compact shape costs 4 bytes per distinct hash.
final class CloudReferenceMatcher {
    struct Match {
        let timestampSeconds: Float
        let score: Float
    }

    private struct Checkpoint {
        let timestampSeconds: Float
        /// Sorted and deduplicated at `add`; the only hash storage kept.
        let hashes: [UInt32]
    }

    private var checkpoints: [Checkpoint] = []

    /// Adds a reference checkpoint (timestamp in seconds, hashes in any order;
    /// duplicates are collapsed). `durationSeconds` is the checkpoint spacing
    /// metadata from the server reference; client matching derives its own
    /// windows, so it is not used for scoring today — the parameter is accepted
    /// to keep the builder contract mirroring the server's reference format.
    func add(timestampSeconds: Float, hashes: [UInt32], durationSeconds: Float) {
        let sorted = hashes.sorted()
        var deduped: [UInt32] = []
        deduped.reserveCapacity(sorted.count)
        for h in sorted where deduped.last != h {
            deduped.append(h)
        }
        checkpoints.append(Checkpoint(timestampSeconds: timestampSeconds, hashes: deduped))
    }

    func clear() {
        checkpoints.removeAll()
    }

    var count: Int { checkpoints.count }

    /// Returns the top `maxResults` reference checkpoints by overlap score.
    func findTopMatches(queryHashes: [UInt32], maxResults: Int) -> [Match] {
        guard !queryHashes.isEmpty else { return [] }
        let query = Self.sortedDeduplicated(queryHashes)
        return checkpoints
            .map { Match(timestampSeconds: $0.timestampSeconds, score: Self.scoreSortedDeduplicated(query, $0.hashes)) }
            .sorted { $0.score > $1.score }
            .prefix(maxResults)
            .map { $0 }
    }

    /// Overlap score = |A ∩ B| / min(|A|, |B|) ∈ [0, 1], set semantics on both
    /// sides (duplicates collapse before counting). Public entry: normalizes
    /// its inputs first.
    static func overlapScore(_ a: [UInt32], _ b: [UInt32]) -> Float {
        scoreSortedDeduplicated(sortedDeduplicated(a), sortedDeduplicated(b))
    }

    /// Hot path for two sorted, deduplicated arrays: a merge walk counts the
    /// intersection without allocating. Iteration is O(|A| + |B|) with no
    /// per-hash table lookups; the denominator is the smaller distinct count.
    private static func scoreSortedDeduplicated(_ a: [UInt32], _ b: [UInt32]) -> Float {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var i = 0
        var j = 0
        var intersection = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                intersection += 1
                i += 1
                j += 1
            } else if a[i] < b[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return Float(intersection) / Float(min(a.count, b.count))
    }

    private static func sortedDeduplicated(_ hashes: [UInt32]) -> [UInt32] {
        let sorted = hashes.sorted()
        var deduped: [UInt32] = []
        deduped.reserveCapacity(sorted.count)
        for h in sorted where deduped.last != h {
            deduped.append(h)
        }
        return deduped
    }
}
