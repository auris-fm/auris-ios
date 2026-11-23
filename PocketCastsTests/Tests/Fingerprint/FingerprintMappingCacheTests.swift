import XCTest

@testable import podcasts

final class FingerprintMappingCacheTests: XCTestCase {

    typealias Entry = FingerprintTimingManager.TimeMappingEntry

    private var tempDir: URL!
    private var audioPath: String!
    private var referencePath: String!
    private var referenceData: Data!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FingerprintMappingCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let audioURL = tempDir.appendingPathComponent("episode.mp3")
        try Data(repeating: 0xab, count: 1024).write(to: audioURL)
        audioPath = audioURL.path

        referenceData = Data("reference-bytes-v1".utf8)
        let refURL = tempDir.appendingPathComponent("episode.ref.fp.json")
        try referenceData.write(to: refURL)
        referencePath = refURL.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        audioPath = nil
        referencePath = nil
        referenceData = nil
        try super.tearDownWithError()
    }

    // MARK: - Round-trip

    func testFullCoverageMappingRoundTrips() throws {
        let entries = makeFullCoverageEntries()
        FingerprintMappingCache.save(
            entries,
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100
        )

        let loaded = try XCTUnwrap(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: referenceData
            )
        )
        XCTAssertEqual(loaded.entries.count, entries.count)
        XCTAssertEqual(loaded.referenceDuration, 100, accuracy: 0.001)
        for (i, original) in entries.enumerated() {
            XCTAssertEqual(loaded.entries[i].playbackTime, original.playbackTime, accuracy: 0.001)
            XCTAssertEqual(loaded.entries[i].referenceTime, original.referenceTime, accuracy: 0.001)
            XCTAssertEqual(loaded.entries[i].score, original.score, accuracy: 0.0001)
        }
    }

    // MARK: - Validations

    func testCacheIsRejectedWhenReferenceHashChanges() {
        FingerprintMappingCache.save(
            makeFullCoverageEntries(),
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100
        )

        let differentReference = Data("different-reference".utf8)
        XCTAssertNil(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: differentReference
            )
        )
    }

    func testCacheIsRejectedWhenAudioFileSizeChanges() throws {
        FingerprintMappingCache.save(
            makeFullCoverageEntries(),
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100
        )

        let url = URL(fileURLWithPath: audioPath)
        try Data(repeating: 0xcd, count: 4096).write(to: url)

        XCTAssertNil(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: referenceData
            )
        )
    }

    func testCacheIsRejectedWhenAudioFileMTimeChanges() throws {
        FingerprintMappingCache.save(
            makeFullCoverageEntries(),
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100
        )

        // Bump mtime well beyond the load path's 1.0s tolerance, leaving size untouched.
        let bumpedDate = Date(timeIntervalSinceNow: 60)
        try FileManager.default.setAttributes(
            [.modificationDate: bumpedDate],
            ofItemAtPath: audioPath
        )

        XCTAssertNil(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: referenceData
            )
        )
    }

    func testCacheIsRejectedWhenAudioContentChanges() throws {
        FingerprintMappingCache.save(
            makeFullCoverageEntries(),
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100
        )

        // Preserve original attributes so size/mtime checks pass.
        let attrs = try FileManager.default.attributesOfItem(atPath: audioPath)
        let originalDate = try XCTUnwrap(attrs[.modificationDate] as? Date)

        // Rewrite with different content but same size.
        try Data(repeating: 0xff, count: 1024).write(to: URL(fileURLWithPath: audioPath))
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: audioPath
        )

        XCTAssertNil(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: referenceData
            )
        )
    }

    func testCacheIsRejectedWhenReferenceFileSizeChanges() throws {
        FingerprintMappingCache.save(
            makeFullCoverageEntries(),
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100
        )

        // Replace the reference file with different-sized content.
        try Data("much-longer-reference-content-that-changes-the-file-size".utf8)
            .write(to: URL(fileURLWithPath: referencePath))

        XCTAssertNil(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: referenceData
            )
        )
    }

    func testCacheIsRejectedWhenReferenceFileMTimeChanges() throws {
        FingerprintMappingCache.save(
            makeFullCoverageEntries(),
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100
        )

        // Bump mtime well beyond the 1.0s tolerance.
        let bumpedDate = Date(timeIntervalSinceNow: 60)
        try FileManager.default.setAttributes(
            [.modificationDate: bumpedDate],
            ofItemAtPath: referencePath
        )

        XCTAssertNil(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: referenceData
            )
        )
    }

    func testPartialCoverageCacheIsNotPersisted() {
        let partial = [
            Entry(playbackTime: 0, referenceTime: 0, score: 0.9),
            Entry(playbackTime: 10, referenceTime: 10, score: 0.9)
        ]
        FingerprintMappingCache.save(
            partial,
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: FingerprintMappingCache.mappingPath(forAudioFilePath: audioPath))
        )
    }

    func testEmptyEntriesAreNotPersisted() {
        FingerprintMappingCache.save(
            [],
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: FingerprintMappingCache.mappingPath(forAudioFilePath: audioPath))
        )
    }

    func testMissingCacheLoadsAsNil() {
        XCTAssertNil(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: referenceData
            )
        )
    }

    // MARK: - Helpers

    // MARK: - Auris reference format

    /// A mapping matched against a v2 Auris reference is discarded once this build
    /// accepts only v3 — even though the transcript reference file is byte-identical,
    /// so the hash guard cannot catch it. The two guards cover different references.
    func testAMappingBuiltAgainstAV2AurisReferenceIsDiscarded() throws {
        let entries = makeFullCoverageEntries()
        FingerprintMappingCache.save(
            entries,
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100,
            aurisFormat: "fingerprint-compact-v2"
        )

        XCTAssertNil(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: referenceData,
                aurisFormat: "fingerprint-compact-v3"
            ),
            "the transcript reference is unchanged, so only the recorded Auris format can reject this"
        )
    }

    /// The same mapping is reusable when the format matches, which is what makes the
    /// case above a rejection rather than a cache that never loads at all.
    func testAMappingBuiltAgainstV3IsReusable() throws {
        let entries = makeFullCoverageEntries()
        FingerprintMappingCache.save(
            entries,
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100,
            aurisFormat: "fingerprint-compact-v3"
        )

        let loaded = try XCTUnwrap(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: referenceData,
                aurisFormat: "fingerprint-compact-v3"
            )
        )
        XCTAssertEqual(loaded.entries.count, entries.count)
    }

    /// A cache written before this build carries no Auris format at all. It must be
    /// discarded rather than treated as current, since nothing records which endpoint
    /// reference its entries came from.
    func testAMappingSavedBeforeThisBuildIsDiscarded() throws {
        let entries = makeFullCoverageEntries()
        // Written with no format recorded, exactly as the previous build wrote it.
        FingerprintMappingCache.save(
            entries,
            audioFilePath: audioPath,
            referenceFilePath: referencePath,
            referenceData: referenceData,
            referenceDuration: 100
        )

        XCTAssertNil(
            FingerprintMappingCache.load(
                audioFilePath: audioPath,
                referenceFilePath: referencePath,
                referenceData: referenceData,
                aurisFormat: "fingerprint-compact-v3"
            )
        )
    }

    private func makeFullCoverageEntries() -> [Entry] {
        // Reference duration = 100s; last entry at 99s clears fullCoverageThreshold = 0.95.
        return stride(from: 0.0, through: 99.0, by: 1.0).map {
            Entry(playbackTime: $0, referenceTime: $0, score: 0.85)
        }
    }
}
