import XCTest

@testable import podcasts

/// Controls for the cloud reference matcher's storage shape (spec: one sorted,
/// deduplicated UInt32 array per checkpoint, membership by binary search, no
/// Set). Two properties are pinned:
///  1. Score parity — the compact matcher must return exactly the scores the
///     set-overlap semantics return, including duplicate handling.
///  2. Storage bound — a checkpoint's resident hash storage is the array alone
///     (4 bytes per hash), not an array plus a hash table beside it.
final class CloudReferenceMatcherStorageTests: XCTestCase {

    /// The old semantics, written out longhand: |A ∩ B| / min(|A|, |B|) with
    /// set membership on both sides. This is the oracle the compact matcher
    /// must agree with on every query.
    private func setOverlap(_ a: [UInt32], _ b: [UInt32]) -> Float {
        let sa = Set(a)
        let sb = Set(b)
        guard !sa.isEmpty, !sb.isEmpty else { return 0 }
        var intersection = 0
        for h in sa where sb.contains(h) { intersection += 1 }
        return Float(intersection) / Float(min(sa.count, sb.count))
    }

    func testScoresMatchSetSemanticsIncludingDuplicates() {
        // Deterministic pseudo-random hashes with deliberate collisions and
        // duplicates, at a scale where a wrong denominator shows up.
        var state: UInt64 = 0x5EED
        func next() -> UInt32 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: state >> 32) % 5000
        }
        let matcher = CloudReferenceMatcher()
        var checkpoints: [[UInt32]] = []
        for c in 0..<40 {
            var hashes: [UInt32] = []
            for _ in 0..<300 { hashes.append(next()) }
            // Duplicates inside a checkpoint must not inflate the score.
            hashes.append(contentsOf: hashes.prefix(50))
            checkpoints.append(hashes)
            matcher.add(timestampSeconds: Float(c), hashes: hashes, durationSeconds: 8)
        }
        for _ in 0..<60 {
            var query: [UInt32] = []
            for _ in 0..<200 { query.append(next()) }
            query.append(contentsOf: query.prefix(30))
            let matches = matcher.findTopMatches(queryHashes: query, maxResults: 40)
            XCTAssertEqual(matches.count, 40)
            for match in matches {
                let idx = Int(match.timestampSeconds)
                XCTAssertEqual(match.score, setOverlap(query, checkpoints[idx]), accuracy: 0.000001,
                               "checkpoint \(idx) diverged from set semantics")
            }
        }
    }

    func testSortedDedupMembershipHandlesEdges() {
        let matcher = CloudReferenceMatcher()
        matcher.add(timestampSeconds: 0, hashes: [7, 3, 3, 1, 9, 7], durationSeconds: 8)
        // Query fully inside the deduped set {1,3,7,9}: score 1.
        XCTAssertEqual(matcher.findTopMatches(queryHashes: [9, 1, 7, 3], maxResults: 1)[0].score, 1.0)
        // Half outside: 2 of 4.
        XCTAssertEqual(matcher.findTopMatches(queryHashes: [1, 3, 100, 200], maxResults: 1)[0].score, 0.5, accuracy: 0.000001)
        // Nothing inside: 0.
        XCTAssertEqual(matcher.findTopMatches(queryHashes: [100, 200], maxResults: 1)[0].score, 0.0)
        // Empty checkpoint scores zero but is still a candidate (the old
        // matcher returned it too); the score gates downstream discard it.
        matcher.add(timestampSeconds: 1, hashes: [], durationSeconds: 8)
        let withEmpty = matcher.findTopMatches(queryHashes: [1], maxResults: 2)
        XCTAssertEqual(withEmpty.count, 2)
        XCTAssertEqual(withEmpty[0].score, 1.0)
        XCTAssertEqual(withEmpty[1].score, 0.0)
    }

    /// The shared cross-platform duplicate fixture (spec rule, core PR 212):
    /// distinct query hashes found in the checkpoint over min(distinct query,
    /// distinct checkpoint). Same numbers as Android's PR 108.
    func testSharedDuplicateFixtureMatchesAndroid() {
        let matcher = CloudReferenceMatcher()
        matcher.add(timestampSeconds: 0, hashes: [7, 7, 9, 11, 11, 11], durationSeconds: 8)
        // Distinct query {7,9,42}: found {7,9} = 2, min(3, 3) = 3 -> 2/3.
        XCTAssertEqual(matcher.findTopMatches(queryHashes: [7, 7, 9, 42], maxResults: 1)[0].score,
                       Float(2) / 3, accuracy: 0.000001)
        // Min-side case: query {7,9} fully inside -> 2/2 = 1.0.
        XCTAssertEqual(matcher.findTopMatches(queryHashes: [7, 9], maxResults: 1)[0].score, 1.0)
        // Reverse case (core PR 212): the checkpoint is the smaller side.
        // Distinct checkpoint {7,9}, window {7,9,42}: found 2, min(3,2)=2 -> 1.0.
        // A window-only denominator would give 2/3.
        let reverse = CloudReferenceMatcher()
        reverse.add(timestampSeconds: 0, hashes: [7, 7, 9], durationSeconds: 8)
        XCTAssertEqual(reverse.findTopMatches(queryHashes: [7, 9, 42], maxResults: 1)[0].score, 1.0)
    }

    /// Storage bound: building a matcher over `n` hashes must not grow the
    /// heap by more than the array storage plus a fixed slack. The old
    /// array+Set shape costs roughly 3x the raw bytes; the compact shape is
    /// 4 bytes per hash. Measured as malloc-zone growth around the build,
    /// with the input arrays released first so only the matcher is counted.
    func testStorageIsBoundedByTheArrayAlone() throws {
        let hashCount = 200_000
        var state: UInt64 = 0xA11CE
        var inputs: [[UInt32]] = []
        for _ in 0..<20 {
            var hashes: [UInt32] = []
            hashes.reserveCapacity(hashCount / 20)
            for _ in 0..<(hashCount / 20) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                hashes.append(UInt32(truncatingIfNeeded: state >> 32))
            }
            inputs.append(hashes)
        }

        func zoneBytes() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return Int(stats.size_in_use)
        }

        // Warm the allocator so first-touch pages are not counted.
        _ = CloudReferenceMatcher()
        let before = zoneBytes()
        var matcher: CloudReferenceMatcher? = CloudReferenceMatcher()
        for (i, hashes) in inputs.enumerated() {
            matcher?.add(timestampSeconds: Float(i), hashes: hashes, durationSeconds: 8)
        }
        inputs.removeAll()
        let after = zoneBytes()
        let growth = after - before
        // 4 bytes/hash = 800 KB for 200k hashes. Allow 2x for allocator slack
        // and the checkpoint structs; the array+Set shape lands near 3-4x the
        // raw bytes and fails this bound.
        XCTAssertLessThan(growth, hashCount * 4 * 2,
                          "matcher storage grew \(growth) bytes for \(hashCount) hashes; expected the array alone")
        XCTAssertNotNil(matcher)
        matcher = nil
    }
}
