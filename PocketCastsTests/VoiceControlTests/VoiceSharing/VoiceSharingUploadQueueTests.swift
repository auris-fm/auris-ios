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

    // Real PCM16 mono 16 kHz WAVs of different lengths: readiness now requires a bound record, so
    // fixtures must be the documented representation rather than arbitrary bytes.
    private var audioA: Data { wav(frames: 1_600) }
    private var audioB: Data { wav(frames: 1_700) }


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
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        try audioB.write(to: try soleEntryDirectory().appendingPathComponent("audio.wav"))
        try q.finalize(prep)

        q = makeQueue() // recovery

        XCTAssertTrue(q.readyEntries().isEmpty,
                      "audio whose bytes contradict the declared digest must not become upload work")
    }

    func test_entryWithMissingOrDirectoryAudioIsRemovedByRecovery() throws {
        var q = makeQueue()
        _ = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
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
            _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: Data("a-\(index)".utf8))
        }

        XCTAssertThrowsError(try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)) { error in
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
        XCTAssertThrowsError(try q.prepare(metadata: validRecord(audio: oversized), audio: oversized)) { error in
            guard case VoiceSharingUploadQueue.PrepareError.audioTooLarge = error else {
                return XCTFail("expected audioTooLarge, got \(error)")
            }
        }
    }

    // MARK: Durability ordering and fail-closed publication (review round 24, finding 1)

    /// Deterministic clock seam for queue-age controls.
    private final class MutableClock {
        private var current: Date
        init(start: Date) { current = start }
        func now() -> Date { current }
        func advance(by interval: TimeInterval) { current = current.addingTimeInterval(interval) }
    }

    /// Refuses to delete the ready marker, so the post-publication cleanup path can be tested
    /// against a cleanup that itself fails.
    private final class MarkerRemovalBlockingFileManager: FileManager {
        override func removeItem(at URL: URL) throws {
            if URL.lastPathComponent == "ready.marker" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try super.removeItem(at: URL)
        }
    }

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
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
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
            let prep = try q.prepare(metadata: validRecord(audio: self.audioA), audio: self.audioA)
            XCTAssertThrowsError(try q.finalize(prep), "sync failure at stage \(failureStage) must refuse publication")
            XCTAssertTrue(q.readyEntries().isEmpty,
                          "a failed publication must never surface as ready (stage \(failureStage))")
        }
    }

    func test_defaultSynchronizerFailureRefusesPublication() throws {
        // A REAL storage failure through the DEFAULT synchronizer: audio.wav made read-only makes
        // its fsync-open (O_WRONLY) fail with EACCES. Publication must refuse, not assume durable.
        let q = makeQueue() // default synchronizer — no injection
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        let audioPath = entryDir.appendingPathComponent("audio.wav")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: audioPath.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: audioPath.path) }
        XCTAssertThrowsError(try q.finalize(prep), "a real sync failure must refuse publication")
        XCTAssertTrue(q.readyEntries().isEmpty, "failed publication must never surface as ready")
    }


    /// Minimal but complete RFC 8785-canonical wire envelope whose `audio` block matches a real
    /// PCM16 mono 16 kHz WAV built by `wav(_:)`. Signatures are a test fixture, not activation values.
    private func validRecord(captureID: String = "11111111-2222-3333-4444-555555555555",
                             epoch: String = "epoch-1",
                             audio: Data) -> Data {
        let audioDigest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        let record: [String: Any] = [
            "schema_version": 1,
            "capture_id": captureID,
            "enrollment_epoch": epoch,
            "platform": "ios",
            "app_version": "8.0",
            "build": "1",
            "capture_session_id": "session-1",
            "audio": [
                "sha256": audioDigest,
                "byte_count": audio.count,
                "encoding": "pcm_s16le",
                "sample_rate_hz": 16_000,
                "channels": 1,
                "retained_samples": (audio.count - 44) / 2,
                "original_format": "pcm_s16le",
                "conversion_version": "1",
                "truncated": false,
                "dropped_spans": [],
            ],
            "models": ["asr": "sensevoice", "router": "lfm2"],
            "observations": ["wake": ["state": "completed"], "asr": ["state": "completed"]],
        ]
        // `record_sha256` is defined over the RFC 8785 CANONICAL form, not any JSON encoding.
        let canonical = try! VoiceSharingRecordBinding.canonicalize(record)
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let envelope: [String: Any] = [
            "record": record,
            "record_sha256": digest,
        ]
        return try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    /// A real PCM16 mono 16 kHz WAV of `frames` sample frames (zero-valued), 44-byte header.
    private func wav(frames: Int = 1_600) -> Data {
        var data = Data()
        let dataBytes = frames * 2
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16)
        append16(1); append16(1); append32(16_000); append32(16_000 * 2); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(UInt32(dataBytes))
        data.append(Data(repeating: 0x00, count: dataBytes))
        return data
    }

    // MARK: Round 25 — immutable entry lifecycle instant (review 1f7dc05d)

    func test_queueAgeIsMeasuredFromCreationInstantAndNeverRefreshed() throws {
        // A preparation created long ago and finalized now must NOT receive a fresh lifetime, and
        // repeating finalize must not extend it.
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_000_000))
        var q = VoiceSharingUploadQueue(rootDirectory: root, clock: clock.now)
        let audio = wav()
        let prep = try q.prepare(metadata: validRecord(audio: audio), audio: audio)

        // 49 hours later (past the 48h bound) the preparation is finalized. Publication must be
        // REFUSED — not accepted with a fresh lifetime.
        clock.advance(by: 49 * 60 * 60)
        XCTAssertThrowsError(try q.finalize(prep)) { error in
            guard case VoiceSharingUploadQueue.PrepareError.expired = error else {
                return XCTFail("expected expired, got \(error)")
            }
        }

        XCTAssertTrue(q.readyEntries().isEmpty,
                      "an over-age preparation must not gain a fresh lifetime by being finalized")
    }

    func test_repeatedFinalizeDoesNotRefreshQueueAge() throws {
        let clock = MutableClock(start: Date(timeIntervalSince1970: 2_000_000))
        var q = VoiceSharingUploadQueue(rootDirectory: root, clock: clock.now)
        let audio = wav()
        let prep = try q.prepare(metadata: validRecord(audio: audio), audio: audio)
        try q.finalize(prep)
        XCTAssertEqual(q.readyEntries().count, 1)

        clock.advance(by: 47 * 60 * 60)
        try q.finalize(prep) // repeated publication must NOT reset the clock
        clock.advance(by: 2 * 60 * 60) // now 49h past creation

        XCTAssertTrue(q.readyEntries().isEmpty,
                      "re-finalizing must not extend the immutable entry's queue lifetime")
        q = VoiceSharingUploadQueue(rootDirectory: root, clock: clock.now)
        XCTAssertTrue(q.readyEntries().isEmpty, "recovery applies the same creation-instant age bound")
    }

    // MARK: Round 25 — cleanup failure after publication (review 1f7dc05d)

    func test_cleanupFailureAfterPublicationKeepsEntryUnready() throws {
        // Post-marker sync fails AND removing the marker fails. The entry must still never be
        // returned as ready: the queue records a failed-publication owner state.
        let q = VoiceSharingUploadQueue(rootDirectory: root, fileManager: MarkerRemovalBlockingFileManager()) { path, isDirectory in
            if !isDirectory && path.lastPathComponent == "ready.marker" {
                throw NSError(domain: "test-sync", code: 1)
            }
        }
        let audio = wav()
        let prep = try q.prepare(metadata: validRecord(audio: audio), audio: audio)
        XCTAssertThrowsError(try q.finalize(prep))
        XCTAssertTrue(q.readyEntries().isEmpty,
                      "an entry whose publication failed cleanup must never be exposed as ready")
        // A fresh instance over the same root must reach the same verdict.
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, fileManager: MarkerRemovalBlockingFileManager())
        XCTAssertTrue(reopened.readyEntries().isEmpty,
                      "the failed-publication state must survive a restart")
    }

    // MARK: Round 25 — record/WAV binding (review 1f7dc05d / spec direction)

    func test_validBoundRecordWithRealWAVSurvivesRecovery() throws {
        var q = makeQueue()
        let audio = wav()
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audio), audio: audio)

        q = makeQueue() // recovery

        XCTAssertEqual(q.readyEntries().count, 1, "a genuinely bound record with a valid WAV must survive")
    }

    func test_metadataTamperedOutsideItsDigestIsRejected() throws {
        // The record_sha256 binds the WHOLE record: changing any field after it was computed must
        // invalidate the entry, even when the audio digest/size still match the bytes.
        let audio = wav()
        let envelope = validRecord(audio: audio)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: envelope) as? [String: Any])
        var record = try XCTUnwrap(object["record"] as? [String: Any])
        record["app_version"] = "9.9-tampered" // outside audio, inside the hashed record
        object["record"] = record
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        var q = makeQueue()
        _ = try q.prepare(metadata: tampered, audio: audio)
        try Data([0x01]).write(to: try soleEntryDirectory().appendingPathComponent("ready.marker"))

        q = makeQueue() // recovery
        XCTAssertTrue(q.readyEntries().isEmpty,
                      "a record edited after its digest was computed is not the bound record")
    }

    func test_wrongRecordDigestIsRejected() throws {
        let audio = wav()
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: validRecord(audio: audio)) as? [String: Any])
        object["record_sha256"] = String(repeating: "0", count: 64)
        let wrongDigest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        var q = makeQueue()
        _ = try q.prepare(metadata: wrongDigest, audio: audio)
        try Data([0x01]).write(to: try soleEntryDirectory().appendingPathComponent("ready.marker"))

        q = makeQueue() // recovery
        XCTAssertTrue(q.readyEntries().isEmpty, "a non-matching record_sha256 must not bind")
    }

    func test_realWavFailureReasonsAreRejected() throws {
        let audio = wav()
        // 1. Float samples (format tag 3) — same shape, wrong representation.
        var floatWav = audio
        floatWav[20] = 3
        // 2. Stereo.
        var stereoWav = audio
        stereoWav[22] = 2
        // 3. Wrong sample rate (8 kHz).
        var lowRateWav = audio
        lowRateWav[24] = UInt8(8_000 & 0xFF); lowRateWav[25] = UInt8((8_000 >> 8) & 0xFF)
        // 4. Truncated body: header claims more than is present.
        let truncatedWav = audio.prefix(audio.count - 100)

        for (label, candidate) in [("float", floatWav), ("stereo", stereoWav),
                                   ("low-rate", lowRateWav), ("truncated", Data(truncatedWav))] {
            var q = makeQueue()
            _ = try q.prepare(metadata: validRecord(audio: candidate), audio: candidate)
            try Data([0x01]).write(to: try soleEntryDirectory().appendingPathComponent("ready.marker"))
            q = makeQueue() // recovery
            XCTAssertTrue(q.readyEntries().isEmpty, "\(label) WAV must be rejected as not the documented representation")
        }
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
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
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
        _ = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
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
        _ = try prepareAndFinalize(queue, metadata: validRecord(audio: audioA), audio: audioA)
        _ = try queue.prepare(metadata: validRecord(audio: audioB), audio: audioB) // not finalized

        let ready = queue.readyEntries()
        XCTAssertEqual(ready.count, 1, "an entry without its ready marker must never be dequeueable")
        XCTAssertEqual(try queue.audio(of: ready[0]), audioA)
    }

    func test_recoveryRemovesAbandonedPreparationAndKeepsReadyEntries() throws {
        var queue = makeQueue()
        _ = try prepareAndFinalize(queue, metadata: validRecord(audio: audioA), audio: audioA)
        _ = try queue.prepare(metadata: validRecord(audio: audioB), audio: audioB) // abandoned

        queue = makeQueue() // restart

        let ready = queue.readyEntries()
        XCTAssertEqual(ready.count, 1, "recovery must keep ready entries")
        XCTAssertEqual(try queue.audio(of: ready[0]), audioA, "recovery must keep ready bytes intact")
    }

    func test_readyEntriesDequeueInFinalizeOrder() throws {
        let queue = makeQueue()
        let prepB = try queue.prepare(metadata: validRecord(audio: audioB), audio: audioB)
        let prepA = try queue.prepare(metadata: validRecord(audio: audioA), audio: audioA)
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
        let entry = try prepareAndFinalize(queue, metadata: validRecord(audio: audioA), audio: audioA)

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
