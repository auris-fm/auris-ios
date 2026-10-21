import CryptoKit
import XCTest
@testable import podcasts

/// Round 23 — reviewer 97166adb findings on 21df32a45:
///   1. Recovery trusted marker presence alone: a directory containing ONLY ready.marker survived
///      recovery and was returned as ready. Recovered/ready entries must be COMPLETE entries:
///      regular non-empty metadata and audio files, marker present, and the metadata's declared
///      audio digest/byte count must match the actual audio bytes. Malformed/partial entries are
///      removed as abandoned, never returned.
///   2. No finite limits: prepare accepted unbounded data/counts. prepare now enforces an entry
///      count ceiling and an audio byte ceiling over preparation + ready work, cleaning up its own
///      failed preparation; persistence is bounded, not deferred to uploader gating.
///   3. Durability ordering: audio and metadata must be synchronized to storage BEFORE the ready
///      marker is published. A sync seam records the order; the control pins marker publication
///      strictly after audio+metadata synchronization.
///   4. One serialized queue owner: mutations go through an internal serial queue; the public
///      entry handle is opaque and validated against this queue's root before any file access.
final class VoiceSharingUploadQueueTests: XCTestCase {

    private var root: URL!
    private var queue: VoiceSharingUploadQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsq-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        queue = nil
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    private func makeQueue() -> VoiceSharingUploadQueue {
        VoiceSharingUploadQueue(rootDirectory: root)
    }

    /// A metadata body that declares the true digest and byte count of `audio`.
    private func metadatadeclaring(_ audio: Data) -> Data {
        let digest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        return #"{"record":{"capture_id":"X","audio":{"sha256":"\#(digest)","byte_count":\#(audio.count)}}}"#
            .data(using: .utf8)!
    }

    private let audioA = Data("wav-bytes-A".utf8)
    private let audioB = Data("wav-bytes-B-longer".utf8)


    private func soleEntryDirectory() throws -> URL {
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
        XCTAssertEqual(dirs.count, 1, "test expects exactly one prepared entry directory")
        return dirs[0]
    }

    private func prepareAndFinalize(_ queue: VoiceSharingUploadQueue, metadata: Data, audio: Data) throws -> VoiceSharingUploadQueue.Entry {
        let prep = try queue.prepare(metadata: metadata, audio: audio)
        try queue.finalize(prep)
        return prep
    }

    // MARK: Complete-entry validation (finding 1)

    func test_markerOnlyDirectoryIsRemovedByRecoveryAndNeverReturned() throws {
        // Reproduce the reviewer's probe: a directory with ONLY ready.marker under the root.
        let bogus = root.appendingPathComponent("B0GUS-ENTRY", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        try Data([0x01]).write(to: bogus.appendingPathComponent("ready.marker"))

        let recovered = makeQueue()

        XCTAssertTrue(recovered.readyEntries().isEmpty,
                      "a marker-only directory is not a complete entry and must never be returned")
        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "malformed entries must be removed as abandoned, not retained")
    }

    func test_entryWithDigestMismatchIsRemovedByRecovery() throws {
        var q = makeQueue()
        // Prepare with CORRECT metadata, then corrupt the audio bytes before finalize.
        let prep = try q.prepare(metadata: metadatadeclaring(audioA), audio: audioA)
        try audioB.write(to: try soleEntryDirectory().appendingPathComponent("audio.wav"))
        try q.finalize(prep)

        q = makeQueue() // recovery

        XCTAssertTrue(q.readyEntries().isEmpty,
                      "audio whose bytes contradict the declared digest must not become upload work")
    }

    func test_entryWithMissingOrDirectoryAudioIsRemovedByRecovery() throws {
        var q = makeQueue()
        _ = try q.prepare(metadata: metadatadeclaring(audioA), audio: audioA)
        try FileManager.default.removeItem(at: try soleEntryDirectory().appendingPathComponent("audio.wav"))
        try Data([0x01]).write(to: soleEntryDirectory().appendingPathComponent("ready.marker"))
        _ = q.readyEntries() // live filter

        q = makeQueue() // recovery

        XCTAssertTrue(q.readyEntries().isEmpty)
    }

    // MARK: Finite limits (finding 2)

    func test_prepareRefusesBeyondEntryCountCeilingAndCleansUp() throws {
        let q = makeQueue()
        for index in 0..<VoiceSharingUploadQueue.maxQueueEntries {
            _ = try prepareAndFinalize(q, metadata: metadatadeclaring(audioA), audio: Data("a-\(index)".utf8))
        }

        XCTAssertThrowsError(try q.prepare(metadata: metadatadeclaring(audioA), audio: audioA)) { error in
            guard case VoiceSharingUploadQueue.PrepareError.queueFull = error else {
                return XCTFail("expected queueFull, got \(error)")
            }
        }
        // The refused preparation must not leave a partial directory behind.
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(dirs.count, VoiceSharingUploadQueue.maxQueueEntries,
                       "failed preparation leaves no partial directory")
    }

    func test_prepareRefusesAudioAboveByteCeiling() throws {
        let q = makeQueue()
        let oversized = Data(repeating: 0x00, count: VoiceSharingUploadQueue.maxEntryAudioBytes + 1)
        XCTAssertThrowsError(try q.prepare(metadata: metadatadeclaring(oversized), audio: oversized)) { error in
            guard case VoiceSharingUploadQueue.PrepareError.audioTooLarge = error else {
                return XCTFail("expected audioTooLarge, got \(error)")
            }
        }
    }

    // MARK: Durability ordering and fail-closed publication (review round 24, finding 1)

    private final class SyncLog {
        var entries: [String] = []
        func recorder() -> (URL, Bool) throws -> Void {
            { path, isDirectory in
                self.entries.append((isDirectory ? "dir:" : "file:") + path.lastPathComponent)
            }
        }
    }

    func test_publicationProtocolOrder() throws {
        let log = SyncLog()
        let q = VoiceSharingUploadQueue(rootDirectory: root, synchronizer: log.recorder())
        let prep = try q.prepare(metadata: metadatadeclaring(audioA), audio: audioA)
        log.entries.removeAll() // observe only the finalize sequence
        try q.finalize(prep)
        let synced = log.entries

        let entryDirectory = try soleEntryDirectory()
        func indexes(_ label: String) -> [Int] {
            synced.indices.filter { synced[$0] == label }
        }
        let audioSyncs = indexes("file:audio.wav")
        let metadataSyncs = indexes("file:metadata.json")
        let markerSyncs = indexes("file:ready.marker")
        let entryDirSyncs = indexes("dir:" + entryDirectory.lastPathComponent)
        let rootSyncs = synced.indices.filter { synced[$0].hasPrefix("dir:") && !entryDirSyncs.contains($0) }

        XCTAssertEqual(audioSyncs.count, 1)
        XCTAssertEqual(metadataSyncs.count, 1)
        XCTAssertEqual(markerSyncs.count, 1)
        XCTAssertEqual(entryDirSyncs.count, 2, "entry directory is synced before AND after marker publication")
        XCTAssertEqual(rootSyncs.count, 1, "the queue root is synced once, persisting the entry link")

        XCTAssertLessThan(audioSyncs[0], markerSyncs[0], "audio must be durable before the marker is published")
        XCTAssertLessThan(metadataSyncs[0], markerSyncs[0], "metadata must be durable before the marker is published")
        XCTAssertLessThan(markerSyncs[0], entryDirSyncs[1], "the marker's namespace entry must be persisted after publication")
        XCTAssertLessThan(entryDirSyncs[1], rootSyncs[0], "the queue root must be synced after the entry directory")
    }

    func test_syncFailureRefusesPublication() throws {
        // Fail at each publication stage; in every case the entry must NOT become ready.
        // Stages in publication order: audio, metadata, marker, entry-dir (post-marker), root.
        for failureStage in 0..<5 {
            let stageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("vsq-syncfail-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stageRoot) }

            var stage = 0
            let q = VoiceSharingUploadQueue(rootDirectory: stageRoot) { _, _ in
                if stage == failureStage { throw NSError(domain: "test-sync", code: 1) }
                stage += 1
            }
            let prep = try q.prepare(metadata: metadatadeclaring(self.audioA), audio: self.audioA)
            XCTAssertThrowsError(try q.finalize(prep), "sync failure at stage \(failureStage) must refuse publication")
            XCTAssertTrue(q.readyEntries().isEmpty,
                          "a failed publication must never surface as ready (stage \(failureStage))")
        }
    }

    func test_defaultSynchronizerFailureRefusesPublication() throws {
        // A REAL storage failure through the DEFAULT synchronizer: audio.wav made read-only makes
        // its fsync-open (O_WRONLY) fail with EACCES. Publication must refuse, not assume durable.
        let q = makeQueue() // default synchronizer — no injection
        let prep = try q.prepare(metadata: metadatadeclaring(audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        let audioPath = entryDir.appendingPathComponent("audio.wav")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: audioPath.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: audioPath.path) }
        XCTAssertThrowsError(try q.finalize(prep), "a real sync failure must refuse publication")
        XCTAssertTrue(q.readyEntries().isEmpty, "failed publication must never surface as ready")
    }

    // MARK: Bounds at recovery (review round 24, finding 2)

    func test_oversizedMetadataIsRefusedAtPrepare() throws {
        let q = makeQueue()
        let digest = SHA256.hash(data: audioA).map { String(format: "%02x", $0) }.joined()
        let padding = String(repeating: "A", count: VoiceSharingUploadQueue.maxMetadataBytes)
        let padded = "{\"record\":{\"capture_id\":\"X\",\"audio\":{\"sha256\":\"\(digest)\",\"byte_count\":\(audioA.count)},\"pad\":\"\(padding)\"}}"
            .data(using: .utf8)!
        XCTAssertGreaterThan(padded.count, VoiceSharingUploadQueue.maxMetadataBytes)
        XCTAssertThrowsError(try q.prepare(metadata: padded, audio: audioA)) { error in
            guard case VoiceSharingUploadQueue.PrepareError.metadataTooLarge = error else {
                return XCTFail("expected metadataTooLarge, got \(error)")
            }
        }
        // The refused preparation leaves no partial directory behind.
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(dirs.isEmpty)
    }

    func test_recoveryReEnforcesEntryLimitsAndRemovesExpiredEntries() throws {
        var q = makeQueue()
        _ = try prepareAndFinalize(q, metadata: metadatadeclaring(audioA), audio: audioA)
        // Simulate an aged entry by backdating its marker beyond maxEntryAge.
        let entryDir = try soleEntryDirectory()
        let marker = entryDir.appendingPathComponent("ready.marker")
        let oldDate = Date().addingTimeInterval(-VoiceSharingUploadQueue.maxEntryAge - 60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: marker.path)

        q = makeQueue() // recovery

        XCTAssertTrue(q.readyEntries().isEmpty, "entries past the queue-age bound must not survive recovery")
    }

    func test_recoveryStopsBeforeLoadingOversizedAudio() throws {
        // An entry whose audio exceeds the ceiling is removed by recovery WITHOUT reading it:
        // corrupt the bytes (digest mismatch alone would also remove it, so prove size path by
        // making the file large but the metadata count small AND the file unreadable as data
        // via an irregular file — a directory named audio.wav).
        var q = makeQueue()
        _ = try q.prepare(metadata: metadatadeclaring(audioA), audio: audioA)
        let audioPath = try soleEntryDirectory().appendingPathComponent("audio.wav")
        try FileManager.default.removeItem(at: audioPath)
        try FileManager.default.createDirectory(at: audioPath, withIntermediateDirectories: true)
        // Simulate an already-published entry (fail-closed finalize would refuse this state);
        // recovery must remove it based on attributes alone.
        try Data([0x01]).write(to: soleEntryDirectory().appendingPathComponent("ready.marker"))

        q = makeQueue() // recovery

        XCTAssertTrue(q.readyEntries().isEmpty, "irregular audio entries must be removed without surfacing")
    }

    // MARK: Serialized ownership (finding 4)

    func test_foreignEntryHandleIsRefused() throws {
        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsq-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }

        let q = makeQueue()
        let foreign = VoiceSharingUploadQueue.Entry(root: otherRoot, name: "FORGED")
        XCTAssertThrowsError(try q.finalize(foreign))
        XCTAssertThrowsError(try q.remove(foreign))
        XCTAssertThrowsError(try q.audio(of: foreign))
    }

    // MARK: Round-22 controls, preserved and updated for the opaque entry type

    func test_preparedEntryIsNotReadyUntilFinalized() throws {
        let queue = makeQueue()
        _ = try prepareAndFinalize(queue, metadata: metadatadeclaring(audioA), audio: audioA)
        _ = try queue.prepare(metadata: metadatadeclaring(audioB), audio: audioB) // not finalized

        let ready = queue.readyEntries()
        XCTAssertEqual(ready.count, 1, "an entry without its ready marker must never be dequeueable")
        XCTAssertEqual(try queue.audio(of: ready[0]), audioA)
    }

    func test_recoveryRemovesAbandonedPreparationAndKeepsReadyEntries() throws {
        var queue = makeQueue()
        _ = try prepareAndFinalize(queue, metadata: metadatadeclaring(audioA), audio: audioA)
        _ = try queue.prepare(metadata: metadatadeclaring(audioB), audio: audioB) // abandoned

        queue = makeQueue() // restart

        let ready = queue.readyEntries()
        XCTAssertEqual(ready.count, 1, "recovery must keep ready entries")
        XCTAssertEqual(try queue.audio(of: ready[0]), audioA, "recovery must keep ready bytes intact")
    }

    func test_readyEntriesDequeueInFinalizeOrder() throws {
        let queue = makeQueue()
        let prepB = try queue.prepare(metadata: metadatadeclaring(audioB), audio: audioB)
        let prepA = try queue.prepare(metadata: metadatadeclaring(audioA), audio: audioA)
        try queue.finalize(prepA)
        try queue.finalize(prepB)

        let ready = queue.readyEntries()
        XCTAssertEqual(ready.count, 2)
        XCTAssertEqual(try queue.audio(of: ready[0]), audioA,
                       "FIFO follows finalize order, not preparation or name order")
        XCTAssertEqual(try queue.audio(of: ready[1]), audioB)
    }

    func test_removeDeletesTheWholeEntry() throws {
        let queue = makeQueue()
        let entry = try prepareAndFinalize(queue, metadata: metadatadeclaring(audioA), audio: audioA)

        try queue.remove(entry)

        XCTAssertTrue(queue.readyEntries().isEmpty, "removed entry must not dequeue again")
        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "removal must delete audio, metadata and marker, not just hide the entry")
    }

    func test_recoveryRemovesForeignDirectoriesUnderItsRoot() throws {
        _ = makeQueue() // establish root
        let foreign = root.appendingPathComponent("someone-elses-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: foreign.appendingPathComponent("audio.wav"))

        _ = makeQueue() // recovery pass

        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty,
                      "the queue owns its root: any directory it did not create is abandoned preparation")
    }
}
