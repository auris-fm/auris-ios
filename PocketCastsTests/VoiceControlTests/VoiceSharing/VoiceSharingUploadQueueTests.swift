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

    private func makeQueue(fileManager: FileManager = .default) -> VoiceSharingUploadQueue {
        VoiceSharingUploadQueue(rootDirectory: root, fileManager: fileManager)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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

        // Audio and metadata are each synced TWICE: once in prepare (before admission returns) and
        // once in finalize's content barrier. The recorder observes the finalize window, but the
        // prepare-time syncs are already in `synced` for files whose metadata the queue re-verifies,
        // so the counts are asserted against the code as it runs, not against the older protocol.
        XCTAssertEqual(audioSyncs.count, 2)
        XCTAssertEqual(metadataSyncs.count, 2)
        // TWO marker syncs: the marker's own durability, then the COMMIT-POINT confirmation after
        // the directory sync. This assertion previously said 1 while the protocol had already
        // grown to 2 (the commit-point confirmation was added without updating it), so it was
        // RED on the tree and nobody re-ran this test — found while adding the age-boundary work
        // and corrected against the code rather than by loosening the protocol.
        XCTAssertEqual(markerSyncs.count, 2,
                       "the marker's own barrier, then the commit-point confirmation")
        // The entry directory is synced for content, after the stage is cleared, and as the commit
        // point after the marker is published. The extra syncs are the per-file barriers for
        // created.at (recovery authority) and the owner record, which are written into the entry
        // directory during publication. Nothing fallible follows the commit.
        XCTAssertEqual(entryDirSyncs.count, 5,
                       "content barrier, created.at barrier, owner barrier, post-stage barrier, "
                       + "then the commit point after the marker")
        // TWO root syncs: the stage-file removal and the commit-point confirmation. (The marker's
        // temporary is written INSIDE the entry directory, so it is covered by the entry-dir
        // barrier, not the root's.) The previous
        // "once, at the commit" was true of an older protocol that wrote no root temporary.
        XCTAssertEqual(rootSyncs.count, 2,
                       "the root is synced after the stage removal and at the commit; the marker "
                       + "temporary lives INSIDE the entry directory, not at the root")

        XCTAssertLessThan(audioSyncs[0], markerSyncs[0], "audio must be durable before the marker is published")
        XCTAssertLessThan(metadataSyncs[0], markerSyncs[0], "metadata must be durable before the marker is published")
        XCTAssertLessThan(markerSyncs[0], entryDirSyncs.last ?? -1,
                          "the commit-point directory sync must follow the marker's own sync")
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
            let q = VoiceSharingUploadQueue(rootDirectory: stageRoot, synchronizer: { _, _ in
                if stage == failureStage { throw NSError(domain: "test-sync", code: 1) }
                stage += 1
            })
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
            // Every model slot must be present (null = declared absent) and every observation stage
            // must be stated with an enumerated state; a missing stage is an unstated claim.
            "models": [
                "vad": NSNull(),
                "wakeword": ["id": "porcupine", "version": "3.0"],
                "asr": ["id": "sensevoice", "version": "1"],
                "translation": NSNull(),
                "router": ["id": "lfm2", "version": "1"],
            ],
            "observations": [
                "wake": ["state": "completed", "decision": "accepted"],
                "bleed": ["state": "not_run", "reason": "no_playback_reference"],
                "asr": ["state": "completed", "text": "play the next episode"],
                "translation": ["state": "not_run", "reason": "no_text"],
                "routing": ["state": "completed"],
                "execution": ["state": "not_run", "reason": "precondition_failed"],
            ],
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

    func test_oversizedCreationInstantIsRefusedWithoutBeingLoaded() throws {
        // The instant is a short decimal string. An oversized file is a corrupt or foreign object;
        // the bound must be checked from attributes so a huge file is never read to find out.
        var q = makeQueue()
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        try wav().write(to: try soleEntryDirectory().appendingPathComponent("audio.wav"))
        // Replace the immutable instant with content far past the bound.
        let instant = try soleEntryDirectory().appendingPathComponent("created.at")
        try Data(String(repeating: "1", count: 4096).utf8).write(to: instant)
        try Data([0x01]).write(to: try soleEntryDirectory().appendingPathComponent("ready.marker"))
        _ = prep

        q = makeQueue() // recovery
        XCTAssertTrue(q.readyEntries().isEmpty,
                      "an entry whose admission instant cannot be bounded is not ready")
    }

    func test_wavStructurallyInconsistentHeadersAreRejected() throws {
        func reject(_ bytes: Data, _ note: String) throws {
            var object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: validRecord(audio: bytes)) as? [String: Any])
            var record = try XCTUnwrap(object["record"] as? [String: Any])
            var audio = try XCTUnwrap(record["audio"] as? [String: Any])
            audio["byte_count"] = bytes.count
            audio["retained_samples"] = max(0, (bytes.count - 44) / 2)
            record["audio"] = audio
            object["record"] = record
            let canonical = try VoiceSharingRecordBinding.canonicalize(record)
            let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
            object["record_sha256"] = digest
            let metadata = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

            // Each case gets a clean root so exactly one entry directory exists.
            if let existing = self.root, FileManager.default.fileExists(atPath: existing.path) {
                try FileManager.default.removeItem(at: existing)
            }
            let freshRoot = temporaryRoot()
            self.root = freshRoot
            let q = VoiceSharingUploadQueue(rootDirectory: freshRoot, clock: Date.init)
            _ = try q.prepare(metadata: metadata, audio: bytes)
            let entryDirectory = try soleEntryDirectory()
            try bytes.write(to: entryDirectory.appendingPathComponent("audio.wav"))
            try Data([0x01]).write(to: entryDirectory.appendingPathComponent("ready.marker"))
            let reopened = VoiceSharingUploadQueue(rootDirectory: freshRoot, clock: Date.init)
            XCTAssertTrue(reopened.readyEntries().isEmpty, note)
        }

        var riffTooBig = wav()
        riffTooBig[4] = UInt8((UInt32(riffTooBig.count) + 8) & 0xFF) // RIFF size disagrees with file
        try reject(riffTooBig, "RIFF size must agree with the received length")

        var badByteRate = wav()
        badByteRate[28] = 0x11
        try reject(badByteRate, "byte rate must agree with sample rate and block align")

        var badBlockAlign = wav()
        badBlockAlign[32] = 4
        try reject(badBlockAlign, "block align must agree with channels and bit depth")

        var trailing = wav()
        trailing.append(contentsOf: [0, 0]) // bytes beyond the declared chunk
        try reject(trailing, "unaccounted bytes after the data chunk are refused")
    }

    func test_retainedSamplesMustMatchTheWavsActualSamples() throws {
        let bytes = wav()
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: validRecord(audio: bytes)) as? [String: Any])
        var record = try XCTUnwrap(object["record"] as? [String: Any])
        var audio = try XCTUnwrap(record["audio"] as? [String: Any])
        audio["retained_samples"] = 999_999 // describes a different recording
        record["audio"] = audio
        object["record"] = record
        let canonical = try VoiceSharingRecordBinding.canonicalize(record)
        object["record_sha256"] = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let metadata = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try VoiceSharingRecordBinding.bind(envelope: metadata, audio: bytes)) { error in
            guard case VoiceSharingRecordBinding.BindingError.audioSampleCountMismatch = error else {
                return XCTFail("expected audioSampleCountMismatch, got \(error)")
            }
        }
    }

    func test_nestedSchemaGapsAreRejected() throws {
        func mutatedRecord(_ mutate: (inout [String: Any]) -> Void) -> Data {
            var object = (try? JSONSerialization.jsonObject(with: validRecord(audio: audioA)) as? [String: Any]) ?? [:]
            var record = (object["record"] as? [String: Any]) ?? [:]
            mutate(&record)
            object["record"] = record
            let canonical = (try? VoiceSharingRecordBinding.canonicalize(record)) ?? ""
            object["record_sha256"] = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }

        // A model slot with an unlisted nested field.
        let extraModelField = mutatedRecord { record in
            var models = (record["models"] as? [String: Any]) ?? [:]
            models["asr"] = ["id": "sensevoice", "version": "1", "weights_path": "/etc/passwd"]
            record["models"] = models
        }
        XCTAssertThrowsError(try VoiceSharingRecordBinding.bind(envelope: extraModelField, audio: audioA)) { error in
            guard case VoiceSharingRecordBinding.BindingError.unknownField = error else {
                return XCTFail("expected unknownField, got \(error)")
            }
        }

        // A missing observation stage is an unstated claim.
        let missingStage = mutatedRecord { record in
            var observations = (record["observations"] as? [String: Any]) ?? [:]
            observations.removeValue(forKey: "bleed")
            record["observations"] = observations
        }
        XCTAssertThrowsError(try VoiceSharingRecordBinding.bind(envelope: missingStage, audio: audioA)) { error in
            guard case VoiceSharingRecordBinding.BindingError.missingField = error else {
                return XCTFail("expected missingField, got \(error)")
            }
        }

        // A free-form reason is where stack traces and paths enter the dataset.
        let freeFormReason = mutatedRecord { record in
            var observations = (record["observations"] as? [String: Any]) ?? [:]
            observations["bleed"] = ["state": "not_run", "reason": "Error at /Users/me/file.swift:42"]
            record["observations"] = observations
        }
        XCTAssertThrowsError(try VoiceSharingRecordBinding.bind(envelope: freeFormReason, audio: audioA)) { error in
            guard case VoiceSharingRecordBinding.BindingError.invalidField = error else {
                return XCTFail("expected invalidField, got \(error)")
            }
        }
    }

    // MARK: Publication contract (spec voice-recording-uploads.md, "one explicit commit point")

    func test_successfulPublicationIsCommittedAndReady() throws {
        let q = makeQueue()
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        try q.finalize(prep)
        XCTAssertEqual(q.reconcilePublication(prep), .committed)
        XCTAssertEqual(q.readyEntries().map(\.name), [prep.name])
    }

    func test_failureBeforeTheReadyTransitionIsUncommittedAndNeverRecoversReady() throws {
        // Failure known to precede the ready transition: content sync fails, so no marker exists.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            synchronizer: { url, isDirectory in
                if !isDirectory, url.lastPathComponent == "audio.wav" {
                    throw CocoaError(.fileWriteNoPermission)
                }
            })
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        XCTAssertThrowsError(try q.finalize(prep))
        XCTAssertEqual(q.reconcilePublication(prep), .uncommitted)
        XCTAssertTrue(q.readyEntries().isEmpty)

        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(reopened.readyEntries().isEmpty,
                      "an uncommitted publication must not recover as ready")
    }

    func test_unconfirmableReadyTransitionReportsUncertainRatherThanSuccessOrRejection() throws {
        // THE FINAL TRANSITION. The marker exists; its directory sync cannot be confirmed. The spec
        // requires an explicit UNCERTAIN outcome — a generic thrown error must not erase the
        // distinction between "may have committed" and "definitely did not".
        struct MarkerSyncFails: Error {}
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            synchronizer: { url, isDirectory in
                // Fail only the directory sync that follows the marker's own sync.
                if isDirectory, FileManager.default.fileExists(
                    atPath: self.root.appendingPathComponent("PLACEHOLDER").path) { return }
            })
        _ = q

        // Simpler, precise injection: let everything succeed, then fail the directory sync that
        // comes after the marker file sync, detected by the marker already existing.
        let queue = VoiceSharingUploadQueue(
            rootDirectory: root,
            synchronizer: { url, isDirectory in
                if isDirectory,
                    FileManager.default.fileExists(
                        atPath: self.root.path) == false { throw MarkerSyncFails() }
                if isDirectory, FileManager.default.fileExists(atPath: url.path) {
                    // The entry directory exists; detect "after marker published" by marker presence.
                    let marker = url.appendingPathComponent("ready.marker")
                    if FileManager.default.fileExists(atPath: marker.path) {
                        throw MarkerSyncFails()
                    }
                }
            })
        let prep = try queue.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        XCTAssertThrowsError(try queue.finalize(prep)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain,
                           "an unconfirmable ready transition must be reported as uncertain")
        }
    }

    func test_reconciliationTrustsTheDurableStageRecordNotProcessMemory() throws {
        // A fresh queue has NO in-memory history. An entry left with `stage.publishing` present and
        // a ready marker must still reconcile as uncommitted, because the transition was never
        // confirmed — regardless of what any process remembers.
        let q = makeQueue()
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        let entryDirectory = try soleEntryDirectory()
        // Fabricate exactly the interrupted state a crash mid-publication leaves: a durable stage
        // record plus a marker, with the transition never confirmed.
        try Data([0x01]).write(to: entryDirectory.appendingPathComponent("stage.publishing"))
        try Data([0x01]).write(to: entryDirectory.appendingPathComponent("ready.marker"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryDirectory.appendingPathComponent("stage.publishing").path),
            "precondition: the stage record is present")

        // Reconcile on the SAME instance: a fresh queue's recovery would remove the entry, so its
        // verdict would be right for the wrong reason and would not prove the stage record was read.
        XCTAssertEqual(q.reconcilePublication(prep), .uncommitted,
                       "an interrupted transition must not reconcile as committed, read from disk")

        // And a fresh instance must agree, for the same durable reason.
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(reopened.reconcilePublication(prep), .uncommitted)
        XCTAssertTrue(reopened.readyEntries().isEmpty)
    }

    func test_reconciliationSynchronizesAndWithholdsWhenDurabilityCannotBeConfirmed() throws {
        // Reviewer db754d3d/1: presence is not confirmation. Inject sync failure DURING
        // reconciliation on a fresh queue: the structurally valid entry must stay withheld.
        struct SyncFails: Error {}
        let q = makeQueue()
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        try q.finalize(prep)

        // Fresh instance whose every synchronization fails: it can see the marker but cannot confirm.
        let blind = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { _, _ in throw SyncFails() })
        XCTAssertEqual(blind.reconcilePublication(prep), .uncertain,
                       "an unconfirmable marker must be withheld as uncertain, not committed")
        XCTAssertTrue(blind.readyEntries().isEmpty,
                      "readyEntries must not expose an entry it cannot confirm durably")
    }

    func test_uncertaintyIsNotErasedInProcessAndFreshInstanceAgrees() throws {
        // Reviewer db754d3d/2: the catch must not convert uncertainty into a definite answer, and a
        // fresh instance must not disagree with this one.
        struct SyncFails: Error {}
        // The fault is DURABLE-STATE-driven, not invocation-scoped: any sync of an entry directory
        // whose marker exists fails. So this instance AND a fresh one both see the same
        // unconfirmable state, which is exactly the guarantee under test.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            synchronizer: { url, isDirectory in
                guard isDirectory else { return }
                let marker = url.appendingPathComponent("ready.marker")
                if FileManager.default.fileExists(atPath: marker.path) { throw SyncFails() }
            })
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        XCTAssertThrowsError(try q.finalize(prep)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain)
        }
        // Same owner: still uncertain, not silently "uncommitted".
        XCTAssertEqual(q.reconcilePublication(prep), .uncertain)
        // Fresh owner, same durable fault, must reach the same verdict. Assert the durable state is
        // still present first, so "agreement" cannot come from recovery having erased the entry.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try soleEntryDirectory().appendingPathComponent("ready.marker").path),
            "precondition: the unconfirmed marker is still on disk")
        let reopened = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { url, isDirectory in
                if isDirectory {
                    let marker = url.appendingPathComponent("ready.marker")
                    if FileManager.default.fileExists(atPath: marker.path) { throw SyncFails() }
                }
            })
        XCTAssertEqual(reopened.reconcilePublication(prep), q.reconcilePublication(prep),
                       "reconciliation must not depend on in-process memory")
        XCTAssertEqual(q.reconcilePublication(prep), .uncertain,
                       "uncertainty must be preserved, not erased as a definite rejection")
    }

    func test_createdInstantContentsAreDurableBeforeReadiness() throws {
        // Reviewer db754d3d/3: created.at is recovery authority, so it must be in the barrier.
        struct SyncFails: Error {}
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            synchronizer: { url, isDirectory in
                if !isDirectory, url.lastPathComponent == "created.at" { throw SyncFails() }
            })
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        XCTAssertThrowsError(try q.finalize(prep),
                             "publication must not proceed without a durable creation instant")
        XCTAssertTrue(q.readyEntries().isEmpty)
    }

    func test_markerInstalledThenThrowingIsConfirmedBySameAndFreshInstanceAfterHealthyReconciliation() throws {
        // Reviewer f4688811: an install-then-throw replacement is an AMBIGUOUS transition. It must
        // route through the same uncertainty/reconciliation semantics as any other ambiguous path —
        // and once reconciliation is healthy, the IDENTICAL immutable entry must be confirmed both
        // by this instance and by a fresh one. Asserting only the thrown error is not enough.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            markerReplacer: { original, replacement in
                _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement)
                throw CocoaError(.fileWriteUnknown)
            })
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        XCTAssertThrowsError(try q.finalize(prep)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain)
        }
        // The marker really was installed: this is a possible transition, not a rejection.
        let entryDirectory = try soleEntryDirectory()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryDirectory.appendingPathComponent("ready.marker").path),
            "precondition: the replacer installed the marker before throwing")

        // Same instance, healthy durable state (no injected fault in this queue's synchronizer).
        XCTAssertEqual(q.reconcilePublication(prep), .committed,
                       "the same instance must not treat a memory hint as proof of non-publication")
        XCTAssertEqual(q.readyEntries().map(\.name), [prep.name])

        // Fresh instance must agree on the identical entry.
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(reopened.reconcilePublication(prep), .committed,
                       "a fresh instance must reach the same verdict")
        XCTAssertEqual(reopened.readyEntries().map(\.name), [prep.name])
    }

    func test_ambiguousSyncFailureAlsoConfirmsIdenticallyOnceDurabilityIsRestored() throws {
        // The other ambiguous path, same assertion shape: after an unconfirmable sync the entry is
        // withheld, and when durability becomes confirmable BOTH instances confirm the same entry.
        struct SyncFails: Error {}
        final class FlakySync { var failing = true }
        let flaky = FlakySync()
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            synchronizer: { url, isDirectory in
                guard flaky.failing, isDirectory else { return }
                if FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("ready.marker").path) {
                    throw SyncFails()
                }
            })
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        XCTAssertThrowsError(try q.finalize(prep))
        XCTAssertEqual(q.reconcilePublication(prep), .uncertain, "unconfirmable => uncertain")
        XCTAssertTrue(q.readyEntries().isEmpty, "unconfirmed entries are not exposed")

        // Durability becomes confirmable. The identical entry must now be confirmed by both.
        flaky.failing = false
        XCTAssertEqual(q.reconcilePublication(prep), .committed)
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(reopened.reconcilePublication(prep), .committed)
        XCTAssertEqual(reopened.readyEntries().map(\.name), [prep.name])
    }

    // MARK: Aggregate accounting (spec: admission gates on queue-wide budgets)

    func test_prepareRefusesWhenAggregateQueueBytesWouldExceedTheBound() throws {
        // Per-entry bounds alone are not enough: N individually-legal entries can still blow the
        // queue-wide byte budget. Admission must account for what is already stored.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 6_000, maxRecords: 32))
        // Each real WAV here is ~3.2 kB, so the second entry must be refused.
        _ = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB)
        ) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .queueBytesExceeded)
        }
    }

    func test_aggregateAccountingCountsMetadataNotJustAudio() throws {
        // Budget sits between ONE and TWO of these padded entries, so counting metadata is the only
        // way the second admission can be refused: audio-only accounting would let both in.
        // A large-but-legal metadata body must be counted; ignoring it would let the budget leak.
        var padded = try JSONSerialization.jsonObject(
            with: validRecord(captureID: UUID().uuidString, audio: audioA)) as! [String: Any]
        padded["capture_session_id"] = String(repeating: "x", count: 2_000)
        let big = try JSONSerialization.data(withJSONObject: padded)
        // The stored-vs-incoming split is what this control distinguishes. `incoming` (this entry's
        // audio + metadata) is always counted, so the discriminating quantity is the STORED side:
        // budget is set so a stored entry measured as audio-only leaves room for a second entry,
        // while a stored entry measured as audio+metadata does not.
        //   stored full   = 3244 + 3080 = 6324 ; stored audio-only = 3244
        //   incoming      = 6324
        //   budget        = 6324 + 3244 + 500 = 10068 -> full: 6324+6324=12648 > 10068 REFUSE
        //                                            -> audio-only: 3244+6324=9568 <= 10068 ADMIT
        let budget = (audioA.count + big.count) + audioA.count + 500
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(
                maxBytes: budget, maxRecords: 32))
        _ = try q.prepare(metadata: big, audio: audioA)
        // Precondition: the padded metadata really is on disk at the size that matters.
        let stored = try soleEntryDirectory().appendingPathComponent("metadata.json")
        let storedSize = (try FileManager.default.attributesOfItem(atPath: stored.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(storedSize, 2_000,
                             "precondition: padded metadata is stored (size \(storedSize))")

        XCTAssertThrowsError(try q.prepare(metadata: big, audio: audioA)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .queueBytesExceeded)
        }
        // Discrimination asserted explicitly: with stored usage measured as audio-only, the same
        // budget WOULD have admitted this entry — so counting stored metadata is what discriminates.
        XCTAssertLessThanOrEqual(storedSize + audioA.count + big.count, budget,
                                 "audio-only stored accounting would admit the second entry")
        XCTAssertGreaterThan(audioA.count + big.count + audioA.count + big.count, budget,
                             "full accounting must refuse it")
    }

    func test_aggregateRecordCountBoundIsEnforcedAcrossReadyAndPreparingEntries() throws {
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 2))
        let a = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(a)
        _ = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        ) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .queueFull)
        }
    }

    func test_removingAnEntryReleasesItsAggregateBudget() throws {
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 6_000, maxRecords: 32))
        let first = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB))
        try q.remove(first)
        // Budget is released only if accounting reflects actual on-disk state, not a counter.
        XCTAssertNoThrow(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB))
    }

    func test_exactLimitAdmissionAccountsForProtocolOverhead() throws {
        // Reviewer 589a0315: charging only audio+metadata lets preparation itself exceed the cap,
        // because prepare writes created.at and finalize writes stage/temp/marker files.
        let overhead = VoiceSharingUploadQueue.protocolOverheadBytes
        let record = validRecord(captureID: UUID().uuidString, audio: audioA)
        // Budget exactly equals the caller-supplied bytes: WITHOUT overhead reservation this
        // would be admitted, then immediately exceed the stated stored-byte cap.
        let budget = audioA.count + record.count
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: budget, maxRecords: 32))
        XCTAssertThrowsError(try q.prepare(metadata: record, audio: audioA)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .queueBytesExceeded,
                           "protocol overhead must be reserved, not discovered after writing")
        }
        // And a budget that covers the overhead is admitted, so the control discriminates on the
        // reservation rather than refusing everything.
        // The admitted entry is charged physical+overhead, so a budget that admits it must also
        // cover that charge at finalize (which re-verifies total usage before growing).
        let roomy = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(
                maxBytes: budget + overhead * 2, maxRecords: 32))
        let prep = try roomy.prepare(metadata: record, audio: audioA)
        try roomy.finalize(prep)
        // After finalization the entry must still fit the stated cap: the reservation was honest.
        let stored = try soleEntryDirectory()
        let contents = try FileManager.default.contentsOfDirectory(atPath: stored.path)
        let onDisk = contents.reduce(0) { sum, name in
            sum + ((try? FileManager.default.attributesOfItem(
                atPath: stored.appendingPathComponent(name).path)[.size] as? Int) ?? 0)
        }
        XCTAssertLessThanOrEqual(onDisk, budget + overhead * 2,
                                 "stored bytes (\(onDisk)) must fit the reserved bound")
    }

    func test_accountingFailureRefusesInsteadOfTreatingUnknownSpaceAsFree() throws {
        // Reviewer 589a0315: a stat/listing failure currently reads as zero usage.
        // Listing failure is the seam (FileManager's contentsOfDirectory cannot be subclassed).
        final class ListingFailure { var failing = false }
        let listing = ListingFailure()
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32),
            listDirectoryBounded: { url, keys, limit in
                if listing.failing { throw CocoaError(.fileReadUnknown) }
                return try VoiceSharingUploadQueue.defaultBoundedLister(url, keys, limit)
            })
        let existing = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(existing)

        listing.failing = true
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        ) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable,
                           "unknown usage must refuse, not read as free capacity")
        }
        listing.failing = false
        // The existing entry is preserved across the refusal; accounting is not destructive.
        XCTAssertEqual(q.readyEntries().map(\.name), [existing.name])
    }

    func test_foreignOrNestedContentMakesAccountingUnavailable() throws {
        // Reviewer 589a0315: flat enumeration does not bound arbitrary debris/nested files.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32))
        _ = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        let entryDirectory = try soleEntryDirectory()
        // An unknown file inside an entry directory is outside the owned on-disk format.
        try Data(repeating: 0, count: 100).write(to: entryDirectory.appendingPathComponent("debris.bin"))
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        ) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable)
        }
    }

    func test_unreadableRootRefusesAdmissionInsteadOfLookingLikeAnEmptyQueue() throws {
        // Reviewer 7ebb7887/1: entriesLocked swallowed root listing failure as [], bypassing the seam.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32),
            listDirectoryBounded: { url, keys, limit in
                // Fail ONLY the root listing; entry-level listing still works.
                if url.standardizedFileURL == self.root.standardizedFileURL {
                    throw CocoaError(.fileReadUnknown)
                }
                return try VoiceSharingUploadQueue.defaultBoundedLister(url, keys, limit)
            })
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        ) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable,
                           "an unreadable root is unknown usage, not an empty queue")
        }
    }

    func test_markedEntryGrowthIsRefusedWhenAnotherAdmissionConsumedTheCapacity() throws {
        // Reviewer 02cd9c53/3: a published entry can still be finalized again and grow, and
        // chargeLocked must keep charging its headroom. Prove the CAP, not just that a prepare
        // succeeds: with an already-marked entry, an intervening admission, and a failing
        // replacement, either the footprint stays within the limit or growth is refused.
        let record = validRecord(captureID: UUID().uuidString, audio: audioA)
        // Measure one entry's physical footprint from a probe queue.
        let probeRoot = temporaryRoot()
        let probe = VoiceSharingUploadQueue(
            rootDirectory: probeRoot,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32))
        _ = try probe.prepare(metadata: record, audio: audioA)
        let probeName = try FileManager.default.contentsOfDirectory(atPath: probeRoot.path)
            .first { !$0.hasPrefix(".") } ?? ""
        let physical = try FileManager.default.contentsOfDirectory(
            atPath: probeRoot.appendingPathComponent(probeName).path
        ).reduce(0) { sum, file in
            sum + ((try? FileManager.default.attributesOfItem(
                atPath: probeRoot.appendingPathComponent(probeName).appendingPathComponent(file).path)[.size] as? Int) ?? 0)
        }
        let overhead = VoiceSharingUploadQueue.protocolOverheadBytes
        // Budget placed INSIDE the gap between the two charging rules, which is the only place the
        // marked-entry headroom is observable:
        //   correct (marked entry still charged physical+overhead): usage 4573 + incoming 4573 > budget
        //   mutant  (marked entry charged physical only):          usage 4317 + incoming 4573 <= budget
        // A budget admitting exactly one charged entry (physical+overhead) cannot distinguish them.
        let budget = physical + (physical + overhead)
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: budget, maxRecords: 32))
        let marked = try q.prepare(metadata: record, audio: audioA)
        try q.finalize(marked)

        // Another admission must be refused: the marked entry still holds its headroom.
        XCTAssertThrowsError(try q.prepare(metadata: record, audio: audioA)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .queueBytesExceeded,
                           "a published entry must keep holding its growth headroom")
        }

        // Repeated finalize on the marked entry: growth is permitted only within the budget, and
        // the assertion is on the ACTUAL footprint, not on a prepare succeeding.
        let failing = VoiceSharingUploadQueue(
            rootDirectory: root,
            markerReplacer: { _, _ in
                // Strand the temporary on disk, then fail: this is the growth case.
                throw CocoaError(.fileWriteUnknown)
            },
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: budget, maxRecords: 32))
        for _ in 0..<3 {
            do {
                _ = try failing.finalize(marked)
                XCTFail("growth beyond the budget must be refused, not written")
            } catch let error as VoiceSharingUploadQueue.PrepareError {
                XCTAssertTrue(error == .queueBytesExceeded || error == .publicationUncertain,
                              "unexpected \(error)")
            } catch {
                XCTFail("unexpected \(error)")
            }
        }

        let entryDirectory = try soleEntryDirectory()
        let footprint = try FileManager.default.contentsOfDirectory(atPath: entryDirectory.path)
            .reduce(0) { sum, file in
                sum + ((try? FileManager.default.attributesOfItem(
                    atPath: entryDirectory.appendingPathComponent(file).path)[.size] as? Int) ?? 0)
            }
        XCTAssertLessThanOrEqual(footprint, budget,
                                 "stored footprint (\(footprint)) must stay within the limit (\(budget))")
    }

    func test_strandedTemporaryMarkerIsCleanedAndDoesNotBlockAdmission() throws {
        // Reviewer 7ebb7887/3: ready.marker.tmp-UUID was outside knownEntryNames, so a failed
        // replacement could strand it and permanently block admission.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32))
        let original = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(original)
        let entryDirectory = try soleEntryDirectory()
        let stranded = entryDirectory.appendingPathComponent("ready.marker.tmp-\(UUID().uuidString)")
        try Data([0x01]).write(to: stranded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranded.path), "precondition: stranded")
        // Accounting must accept our own temp as part of the owned format...
        let added = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(added)
        // ...and recovery must clean it up rather than leave it forever.
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stranded.path),
                       "a stranded temporary marker is this queue's own garbage and must be removed")
        XCTAssertEqual(reopened.readyEntries().count, 2,
                       "both finalized entries survive; only the stranded temp is removed")
    }

    func test_foreignTemporaryLookingNameIsNotTreatedAsOwned() throws {
        // The temp allowance must not become a hole: only prefix + well-formed UUID qualifies.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32))
        _ = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        let entryDirectory = try soleEntryDirectory()
        try Data([0x01]).write(to: entryDirectory.appendingPathComponent("ready.marker.tmp-not-a-uuid"))
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        ) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable)
        }
    }

    func test_oversizedDirectoryIsRefusedRatherThanEnumerated() throws {
        // Reviewer 7b897fbb: a cap checked AFTER eager listing does not bound allocation, so
        // discovery must refuse on overflow instead of materialising everything first.
        let cap = VoiceSharingUploadQueue.maxDirectoryEntries
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32))
        _ = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        let entryDirectory = try soleEntryDirectory()
        // More owned temporary names than the cap: an unbounded number of these is exactly what a
        // UUID suffix permits.
        for _ in 0...(cap + 4) {
            try Data([0x01]).write(
                to: entryDirectory.appendingPathComponent("ready.marker.tmp-\(UUID().uuidString)"))
        }
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        ) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable,
                           "discovery overflow is a refusal, not an unbounded enumeration")
        }
    }

    func test_boundedListerReportsOverflowForAnOversizedDirectory() throws {
        // Correctness half of the bound: overflow is reported and the returned set is capped.
        // (The ALLOCATION bound is enforced structurally by the enumerator loop and is pinned by the
        // admission control below, which refuses on overflow rather than depending on array size.)
        let dir = temporaryRoot()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<20 {
            try Data([0x01]).write(to: dir.appendingPathComponent("f\(index)"))
        }
        let limited = try VoiceSharingUploadQueue.defaultBoundedLister(dir, [], 5)
        XCTAssertTrue(limited.overflowed, "overflow must be reported")
        XCTAssertLessThanOrEqual(limited.urls.count, 5 + 1,
                                 "the returned set must be capped, not the whole directory")
    }

    func test_repeatedFinalizeGrowthIsChargedAndCannotBreakTheCap() throws {
        // Reviewer 7b897fbb: repeated finalize with the marker already present can still add
        // temporaries, so growth must be inside the budget contract rather than assumed impossible.
        let record = validRecord(captureID: UUID().uuidString, audio: audioA)
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32))
        let prep = try q.prepare(metadata: record, audio: audioA)
        try q.finalize(prep)

        // Repeated finalize attempts with a replacement that always fails AFTER writing its
        // temporary: each leaves a temporary behind, so the entry grows per attempt.
        let failing = VoiceSharingUploadQueue(
            rootDirectory: root,
            markerReplacer: { _, replacement in
                // Install the marker, but leave the temporary ON DISK and then throw: this is the
                // stranded-temporary case the reviewer describes, not one FileManager cleans up.
                throw CocoaError(.fileWriteUnknown)
            })
        for _ in 0..<3 {
            _ = try? failing.finalize(prep)
        }
        let entryDirectory = try soleEntryDirectory()
        // The fully-qualified name is what recovery recognises as OURS (reviewer 7ebb7887/3): a
        // bare `ready.marker.tmp-` prefix also matches the `.tmp-not-a-uuid` debris case.
        func strandedTemporaries() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: entryDirectory.path)
                .filter { name in
                    name.hasPrefix("ready.marker.tmp-")
                        && UUID(uuidString: String(name.dropFirst("ready.marker.tmp-".count))) != nil
                }
        }
        XCTAssertGreaterThan(try strandedTemporaries().count, 0,
                             "precondition: failed replacements left temporaries behind")

        // Whatever the growth, accounting must still see them: a fresh queue charges them and the
        // entry remains accountable rather than silently exceeding the budget.
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertNoThrow(
            try reopened.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA),
            "bounded discovery must still succeed within the cap")
        // And recovery claims the leftovers rather than leaving them forever.
        let cleaned = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        _ = cleaned.readyEntries()
        XCTAssertEqual(try strandedTemporaries().count, 0, "stranded temporaries must be reclaimed")
    }

    func test_midEnumerationFailureIsThrownRatherThanReportedAsComplete() throws {
        // Reviewer 4fd0a113: the previous control accepted `(urls: [], overflowed: false)` — the exact
        // fail-open result at issue. This control delivers one URL and THEN an error through the
        // production helper (`boundedListing(over:limit:)`) and requires the error to propagate.
        struct Boom: Error {}
        let one = URL(fileURLWithPath: "/tmp/one")
        let steps: [VoiceSharingUploadQueue.EnumerationStep] = [.url(one), .failure(Boom())]
        XCTAssertThrowsError(
            try VoiceSharingUploadQueue.boundedListing(over: AnySequence(steps), limit: 64)
        ) { error in
            XCTAssertTrue(error is Boom,
                          "the enumeration error must propagate, not be turned into a clean result")
        }
    }

    func test_truncatedEnumerationIsNeverReportedAsCompleteByTheProductionLister() throws {
        // The same guarantee through the injectable lister used by accounting: partial URLs plus an
        // error must throw, so callers can never mistake a truncated scan for full accounting.
        struct Boom: Error {}
        let one = URL(fileURLWithPath: "/tmp/one")
        let lister = VoiceSharingUploadQueue.boundedLister(with: { _, _ in
            AnySequence([VoiceSharingUploadQueue.EnumerationStep.url(one),
                         VoiceSharingUploadQueue.EnumerationStep.failure(Boom())])
        })
        XCTAssertThrowsError(try lister(URL(fileURLWithPath: "/tmp"), [], 64)) { error in
            XCTAssertTrue(error is Boom)
        }
    }

    func test_boundedListingStopsAtTheCapWithoutReportedError() throws {
        // And the legitimate stop: hitting the cap returns overflowed, not an error.
        let steps = (0..<10).map {
            VoiceSharingUploadQueue.EnumerationStep.url(URL(fileURLWithPath: "/tmp/\($0)"))
        }
        let result = try VoiceSharingUploadQueue.boundedListing(over: AnySequence(steps), limit: 3)
        XCTAssertEqual(result.urls.count, 3)
        XCTAssertTrue(result.overflowed)
    }

    func test_recoveryStrayScanIsBoundedAndDoesNotEagerlyMaterialiseTheRoot() throws {
        // Reviewer 02cd9c53/1: recoverLocked used contentsOfDirectory directly for strays, so
        // CONSTRUCTION eagerly materialised an oversized root.
        final class ListingCounter { var calls = 0; var maxLimitSeen = 0 }
        let counter = ListingCounter()
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32),
            listDirectoryBounded: { url, keys, limit in
                counter.calls += 1
                counter.maxLimitSeen = max(counter.maxLimitSeen, limit)
                return try VoiceSharingUploadQueue.defaultBoundedLister(url, keys, limit)
            })
        _ = q
        // Construction performed recovery, so every root scan must have gone through the bounded
        // lister with a finite cap.
        XCTAssertGreaterThan(counter.calls, 0, "recovery must scan the root during construction")
        XCTAssertLessThanOrEqual(counter.maxLimitSeen, VoiceSharingUploadQueue.maxDirectoryEntries,
                                 "recovery must never request an unbounded listing")
    }

    func test_finalizeRefusesBeforeGrowthWhenCapacityWasConsumedAfterAdmission() throws {
        // Reviewer 02cd9c53/3: the capacity check must precede GROWTH. It is reachable when other
        // entries consume capacity between admission and finalize — the admission decision is stale
        // by then, which is exactly why re-verifying is required.
        let record = validRecord(captureID: UUID().uuidString, audio: audioA)
        let probeRoot = temporaryRoot()
        let probe = VoiceSharingUploadQueue(
            rootDirectory: probeRoot,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32))
        _ = try probe.prepare(metadata: record, audio: audioA)
        let probeName = try FileManager.default.contentsOfDirectory(atPath: probeRoot.path)
            .first { !$0.hasPrefix(".") } ?? ""
        let physical = try FileManager.default.contentsOfDirectory(
            atPath: probeRoot.appendingPathComponent(probeName).path
        ).reduce(0) { sum, file in
            sum + ((try? FileManager.default.attributesOfItem(
                atPath: probeRoot.appendingPathComponent(probeName).appendingPathComponent(file).path)[.size] as? Int) ?? 0)
        }
        let overhead = VoiceSharingUploadQueue.protocolOverheadBytes

        // Two entries' worth, so both can be ADMITTED while preparing...
        let budget = (physical + overhead) * 2
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: budget, maxRecords: 32))
        let first = try q.prepare(metadata: record, audio: audioA)
        let second = try q.prepare(metadata: record, audio: audioA)

        // ...then cap the SAME queue to one entry's worth, simulating capacity consumed elsewhere.
        // Finalize must re-verify and refuse BEFORE growth; a second queue cannot be used because
        // its construction runs recovery, which would remove the still-preparing entries.
        q.setAggregateLimitsForTesting(
            VoiceSharingUploadQueue.AggregateLimits(maxBytes: physical + overhead, maxRecords: 32))
        let stagePath = root.appendingPathComponent(first.name)
            .appendingPathComponent("stage.publishing").path
        XCTAssertThrowsError(try q.finalize(first)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .queueBytesExceeded,
                           "finalize must re-verify capacity before growth")
        }
        // And it genuinely refused BEFORE growth: no stage record was written.
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagePath),
                       "finalize must refuse before writing the stage record")
        _ = second
    }

    // MARK: Attempt ownership (spec: attempts count across process restarts)

    func test_attemptCountSurvivesProcessRestart() throws {
        // Spec: "Attempts count across process restarts." A memory-only counter would reset on every
        // launch and let an entry retry forever, so the count must be durable.
        let q = makeQueue()
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)

        // PRE: the entry must be a complete, bindable entry BEFORE we touch attempts. If it is not,
        // the reopen failure below is about the fixture, not about attempt durability.
        XCTAssertEqual(q.readyEntries().count, 1,
                       "PRE: the finalized entry must be ready before any attempt is recorded")
        XCTAssertEqual(try q.attemptCount(for: prep), 0, "a fresh entry has no attempts")
        try q.recordAttempt(prep)
        XCTAssertEqual(try q.attemptCount(for: prep), 1)

        // A FRESH queue over the same root must see the same count.
        let recordPath = root.appendingPathComponent(prep.name).appendingPathComponent("attempts.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordPath.path),
                      "PRE: the attempt record must be on disk before reopening")
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(reopened.readyEntries().count, 1,
                       "POST: the entry must still be ready after reopening")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordPath.path),
                      "POST: reopening must not remove the attempt record")
        XCTAssertEqual(try reopened.attemptCount(for: prep), 1,
                       "attempts must survive process restart")
        try reopened.recordAttempt(prep)
        XCTAssertEqual(try reopened.attemptCount(for: prep), 2)
    }

    /// Asserts an admission attempt produced NO admitted attempt — either refusal shape is
    /// acceptable, but a granted lease is not.
    private func XCTAssertNoAdmission(
        _ expression: @autoclosure () throws -> VoiceSharingUploadQueue.AdmittedAttempt?,
        _ message: String = "expected no admission", file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            let admitted = try expression()
            XCTAssertNil(admitted, message, file: file, line: line)
        } catch {
            // A thrown PrepareError is a refusal too: nothing was admitted.
        }
    }

    /// Mutable identity box: the reader closure captures the BOX, so the value can move after
    /// `bindIdentity` without capturing a `var` mutated after escaping.
    private final class IdentityBox {
        private let lock = NSLock()
        private var value: VoiceSharingUploadIdentity?
        init(account: String = "acct-A", _ epoch: String? = nil) {
            value = VoiceSharingUploadIdentity(accountScope: account, enrollmentEpoch: epoch)
        }
        var current: VoiceSharingUploadIdentity? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
        func setEpoch(_ epoch: String?, account: String = "acct-A") {
            current = VoiceSharingUploadIdentity(accountScope: account, enrollmentEpoch: epoch)
        }
    }

    private func makeCompleteEntry(
        _ queue: VoiceSharingUploadQueue, epoch: String
    ) throws -> VoiceSharingUploadQueue.Entry {
        try prepareAndFinalize(queue,
                               metadata: validRecord(captureID: UUID().uuidString, epoch: epoch,
                                                     audio: audioA),
                               audio: audioA)
    }

    /// UNREADABLE OWNERSHIP HOLDS THE WHOLE OWNER (reviewer e8dd9c35): an owner file that exists
    /// but cannot be read is unknown coverage, not a per-entry skip. A second, perfectly healthy
    /// entry must NOT be admitted or served — one corrupted entry must not coexist with a working
    /// queue behind it.
    func test_unreadableOwnershipBlocksAdmissionAndServingForTheWholeQueue() throws {
        let box = IdentityBox(account: "acct-A", "epoch-1")
        let q = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        let broken = try makeCompleteEntry(q, epoch: "epoch-1")
        let healthy = try makeCompleteEntry(q, epoch: "epoch-1")
        XCTAssertEqual(q.readyEntries().count, 2, "precondition: both entries serve")

        // Corrupt ONE entry's owner record into unreadable storage.
        let ownerURL = root.appendingPathComponent(broken.name)
            .appendingPathComponent("owner.account")
        try FileManager.default.removeItem(at: ownerURL)
        try FileManager.default.createDirectory(at: ownerURL, withIntermediateDirectories: true)

        switch q.readyEntriesReportingUnknownCoverage() {
        case .unknownCoverage:
            break
        case .revocationHeld:
            XCTFail("an unreadable owner is UNKNOWN coverage, not a claimed failed revocation")
        case .known(let entries):
            XCTFail("unreadable ownership is unknown coverage for the whole owner, got \(entries.count) entries")
        }
        XCTAssertTrue(q.readyEntries().isEmpty,
                      "the legacy serving path also refuses, rather than serving the healthy entry")
        // Admission REFUSES. It may refuse by returning nil or by throwing a PrepareError — both
        // mean "no request is issued"; what matters is that nothing is admitted.
        XCTAssertNoAdmission(try q.admitAttempt(healthy),
                             "no entry is admitted while any entry's ownership is unreadable")
        XCTAssertNoAdmission(try q.admitAttempt(broken))
    }

    /// ACCOUNT SCOPE IS PART OF THE IDENTITY (reviewer 2b121320): an entry owned by account A must
    /// not be admitted when the live identity is account B carrying the SAME epoch string — epochs
    /// are opaque and can collide across accounts. Epoch-only comparison passes this by accident.
    func test_equalEpochUnderADifferentAccountDoesNotAdmitTheEntry() throws {
        let box = IdentityBox(account: "acct-A", "epoch-1")
        let q = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        let entry = try makeCompleteEntry(q, epoch: "epoch-1")

        box.current = VoiceSharingUploadIdentity(accountScope: "acct-B", enrollmentEpoch: "epoch-1")
        XCTAssertNil(try q.admitAttempt(entry),
                     "the same epoch under another account is not the same identity")

        box.current = VoiceSharingUploadIdentity(accountScope: "acct-A", enrollmentEpoch: "epoch-1")
        XCTAssertNotNil(try q.admitAttempt(entry), "the owning account is admitted")
    }

    /// STARTUP BEFORE PROJECTION (reviewer fd6b8036): a BOUND queue whose identity cannot be
    /// established yet (signed out, epoch not loaded) must refuse every entry.
    func test_boundQueueRefusesEntriesUntilTheIdentityIsKnown() throws {
        let box = IdentityBox(account: "acct-A", nil)
        let q = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        // Prepared while sign-in has NOT landed, so the entry records no owner: that is the real
        // startup order, and it is why the entry must be refused until ownership is known.
        let entry = try makeCompleteEntry(q, epoch: "epoch-1")

        XCTAssertNil(try q.admitAttempt(entry), "no identity yet ⇒ nothing is admitted")

        // Sign-in later establishes the identity; the entry still carries no owner, so it stays
        // refused. Advertising admission here would mean admitting an entry whose account is
        // unknown, which is precisely the hole this binding closes.
        box.setEpoch("epoch-1")
        XCTAssertNil(try q.admitAttempt(entry),
                     "an entry with no recorded owner cannot be attributed to any account")

        // A queue that knows its identity at PREPARATION time records the owner and admits it.
        let later = try makeCompleteEntry(q, epoch: "epoch-1")
        XCTAssertNotNil(try q.admitAttempt(later),
                        "an entry prepared under a known identity is admitted")
    }

    /// RE-ENROLLMENT: after A→B, a NEW entry captured under B is admitted while the surviving A
    /// entry is refused. A construction-time pin cannot express this — it blocks both or admits both.
    func test_reEnrollmentAdmitsNewEpochEntriesAndRefusesSurvivingOldOnes() throws {
        let box = IdentityBox(account: "acct-A", "epoch-1")
        let q = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        let oldEntry = try makeCompleteEntry(q, epoch: "epoch-1")
        // Admit AND SETTLE it, so the lease is released: otherwise the second admission would be
        // refused merely because the first lease is still held, and the control would not be
        // testing the epoch at all (that is exactly how an earlier version passed its mutant).
        let firstAdmission = try XCTUnwrap(try q.admitAttempt(oldEntry), "the A entry is admitted under A")
        try q.applyAttemptResult(oldEntry, lease: firstAdmission.lease, outcome: .retryableFailure)

        box.setEpoch("epoch-2")
        XCTAssertNil(try q.admitAttempt(oldEntry), "the surviving A entry is refused under B")
        let newEntry = try makeCompleteEntry(q, epoch: "epoch-2")
        XCTAssertNotNil(try q.admitAttempt(newEntry), "a new B entry is admitted under B")
    }

    /// RESTART WITH A SURVIVING OLD ENTRY: a FRESH queue over the same durable root, whose live
    /// identity is already B, must still refuse a surviving A entry.
    func test_freshQueueOnTheSameDiskStillRefusesASurvivingOldEpochEntry() throws {
        let box = IdentityBox(account: "acct-A", "epoch-1")
        let first = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        let oldEntry = try makeCompleteEntry(first, epoch: "epoch-1")

        box.setEpoch("epoch-2")
        let restarted = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        XCTAssertNil(try restarted.admitAttempt(oldEntry),
                     "a fresh process must not admit a stale-epoch entry just because it started under B")
    }

    func test_entryIsRemovedWhenAttemptsAreExhausted() throws {
        // Spec: "Exhaustion or expiry removes the local entry with a content-free terminal counter."
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32),
            attemptLimits: VoiceSharingUploadQueue.AttemptLimits(maxUploadAttempts: 2))
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)

        // Drive the REAL ownership path: beginAttempt/endAttempt is how attempts are actually spent.
        XCTAssertTrue(try q.beginAttempt(prep))
        q.endAttempt(prep)
        XCTAssertTrue(try q.beginAttempt(prep))
        q.endAttempt(prep)
        // Exhausted: the entry is no longer attemptable, and attempting again removes it.
        try XCTAssertFalse(q.isAttemptable(prep), "an exhausted entry must not be attemptable")
        XCTAssertFalse(try q.beginAttempt(prep),
                       "an exhausted entry must not be granted another attempt")
        XCTAssertTrue(q.readyEntries().isEmpty, "an exhausted entry is removed, not retried forever")
        let leftover = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }
        // The entry directory must be gone. Root lease locks legitimately survive their entry (the
        // inode must stay stable while any holder exists), but ONLY well-formed owned ones.
        let locks = leftover.filter { name in
            guard name.hasPrefix("attempt.lock.") else { return false }
            return Int(name.dropFirst("attempt.lock.".count)).map { $0 >= 0 } == true
        }
        let debris = leftover.filter { !(locks.contains($0)) }
        XCTAssertTrue(debris.isEmpty, "no debris may remain, got \(debris)")
    }

    func test_onlyOneInFlightAttemptPerEntryIsOwned() throws {
        // Spec: "One entry has at most one in-flight request."
        let q = makeQueue()
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        XCTAssertTrue(try q.beginAttempt(prep), "the first attempt acquires ownership")
        XCTAssertFalse(try q.beginAttempt(prep), "a second concurrent attempt must be refused")
        q.endAttempt(prep)
        XCTAssertTrue(try q.beginAttempt(prep), "ownership is released when the attempt ends")
    }

    func test_inFlightOwnershipIsNotResumedAsLiveAfterRestart() throws {
        // A stale attempt record from a killed process must not block the entry forever, but it also
        // must not be treated as a live in-flight request.
        let q = makeQueue()
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        XCTAssertTrue(try q.beginAttempt(prep))
        // Simulate a kill mid-attempt: no endAttempt.

        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertFalse(reopened.isAttemptInFlight(prep),
                       "a killed process leaves no live in-flight request")
        // The DURABLE lease still marks the attempt as possibly live, so a fresh instance must not
        // take it instantly — two live owners would race. It becomes available when it expires.
        XCTAssertFalse(try reopened.beginAttempt(prep),
                       "a live-looking lease must not be stolen immediately")
        let later = Date().addingTimeInterval(VoiceSharingUploadQueue.attemptLeaseDuration + 1)
        let after = VoiceSharingUploadQueue(rootDirectory: root, clock: { later })
        XCTAssertTrue(try after.beginAttempt(prep),
                      "a stale attempt must not block the entry forever")
    }

    func test_attemptRecordIsInsideThePerEntryProtocolReserve() throws {
        // `recordAttempt` writes outside the admission path, so it must not be able to push an entry
        // past the budget. It cannot: the record is a short JSON object and every entry reserves
        // `protocolOverheadBytes` for exactly this class of sidecar. This test pins that reasoning so
        // a future growth to a multi-byte-per-attempt format fails here instead of silently
        // exceeding the reserve.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32),
            attemptLimits: VoiceSharingUploadQueue.AttemptLimits(maxUploadAttempts: 100))
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        // The largest count that fits the record's byte bound must still fit the per-entry reserve.
        // 99 is the largest two-digit count; the bound must not be reachable by growth.
        for _ in 0..<99 { try q.recordAttempt(prep) }
        XCTAssertEqual(try q.attemptCount(for: prep), 99)
        let recordURL = root.appendingPathComponent(prep.name).appendingPathComponent("attempts.json")
        let size = try XCTUnwrap(
            (try recordURL.resourceValues(forKeys: [.fileSizeKey])).fileSize)
        XCTAssertLessThanOrEqual(
            size, VoiceSharingUploadQueue.protocolOverheadBytes,
            "the attempt record must fit inside the per-entry protocol reserve")
    }

    // MARK: Attempt record integrity (reviewer 6f2dd161)

    func test_malformedAttemptRecordIsRefusedNotTreatedAsZero() throws {
        // Only CONFIRMED ABSENCE means zero. A corrupt record must not reset the retry budget.
        let q = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        let record = root.appendingPathComponent(prep.name).appendingPathComponent("attempts.json")
        try Data("not json".utf8).write(to: record)
        XCTAssertThrowsError(try q.attemptCount(for: prep)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable,
                           "a malformed record is unknown usage, not zero")
        }
        XCTAssertThrowsError(try q.beginAttempt(prep),
                             "an unreadable budget must not permit a request")
    }

    func test_negativeAndOversizedAttemptRecordsAreRefused() throws {
        let q = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        let record = root.appendingPathComponent(prep.name).appendingPathComponent("attempts.json")

        try Data("{\"attempts\":-1}".utf8).write(to: record)
        XCTAssertThrowsError(try q.attemptCount(for: prep), "a negative count is corrupt")

        try Data("{\"attempts\":99999999}".utf8).write(to: record)
        XCTAssertThrowsError(try q.attemptCount(for: prep), "a count past the ceiling is corrupt")

        // Oversized: refused from ATTRIBUTES, without reading the content into memory. The payload is
        // a SINGLE-key, syntactically valid JSON integer, so the shape and decode guards both accept
        // it and only the size bound can reject it. A multi-key or malformed payload would be caught
        // by those guards first and would not discriminate.
        // A single-key record whose value is syntactically a JSON number but far beyond any
        // representable count, so the SIZE bound is what refuses it from attributes rather than a
        // full read of a potentially huge foreign object.
        let padded = "{\"attempts\":1" + String(repeating: "0", count: 4000) + "}"
        let oversized = Data(padded.utf8)
        XCTAssertGreaterThan(oversized.count, VoiceSharingUploadQueue.maxAttemptRecordBytes)
        try oversized.write(to: record)
        XCTAssertThrowsError(try q.attemptCount(for: prep), "an oversized record is corrupt")

        // The size bound must also refuse a record whose VALUE is perfectly valid but whose file is
        // padded past the bound: the read is refused from attributes, not after decoding.
        let paddedValid = "{\"attempts\":1}" + String(repeating: " ", count: 4000)
        let paddedData = Data(paddedValid.utf8)
        XCTAssertGreaterThan(paddedData.count, VoiceSharingUploadQueue.maxAttemptRecordBytes)
        try paddedData.write(to: record)
        XCTAssertThrowsError(try q.attemptCount(for: prep),
                             "an oversized-but-parseable record must still be refused by size")
    }

    func test_attemptRecordSyncFailureDoesNotPermitAnUncountedRequest() throws {
        // Atomic write is not a durability barrier. If the record's sync cannot be confirmed, the
        // attempt is ambiguous and must not yield a request.
        let failing = VoiceSharingUploadQueue(
            rootDirectory: root,
            clock: Date.init,
            synchronizer: { url, isDirectory in
                if !isDirectory, url.lastPathComponent == "attempts.json" { throw CocoaError(.fileWriteUnknown) }
            },
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32))
        let prep = try failing.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try failing.finalize(prep)
        XCTAssertThrowsError(try failing.beginAttempt(prep)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain,
                           "unconfirmed attempt durability is uncertain, not success")
        }
        XCTAssertFalse(failing.isAttemptInFlight(prep),
                       "an attempt whose durability is unconfirmed must not hold ownership")
    }

    func test_foreignEntryHandleIsRefusedByAttemptOperations() throws {
        let q = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let foreign = VoiceSharingUploadQueue.Entry(root: URL(fileURLWithPath: "/tmp"), name: "../../etc")
        XCTAssertThrowsError(try q.beginAttempt(foreign),
                             "a foreign handle must not name a directory this queue owns")
        XCTAssertThrowsError(try q.attemptCount(for: foreign))
    }

    func test_recordAttemptEnforcesTheLimitToo() throws {
        // Every increment path must enforce the bound, not only beginAttempt.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            clock: Date.init,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32),
            attemptLimits: VoiceSharingUploadQueue.AttemptLimits(maxUploadAttempts: 1))
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        try q.recordAttempt(prep)
        XCTAssertThrowsError(try q.recordAttempt(prep)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .attemptsExhausted,
                           "recordAttempt must refuse past the limit")
        }
    }

    func test_enumerationFailureControlRunsThroughTheRealPath() throws {
        // Reviewer 6f2dd161: a control over a PARALLEL implementation proves nothing. `boundedLister`
        // with no injected source must run the real enumerator through the SAME step processing, so
        // the injected-failure control exercises identical code.
        struct Boom: Error {}
        let steps: [VoiceSharingUploadQueue.EnumerationStep] = [
            .url(URL(fileURLWithPath: "/tmp/one")), .failure(Boom())
        ]
        XCTAssertThrowsError(
            try VoiceSharingUploadQueue.boundedListing(over: AnySequence(steps), limit: 8)
        ) { XCTAssertTrue($0 is Boom) }

        // And the real enumerator is adapted into the same sequence type: a readable directory
        // yields urls, and the lister returns them.
        let dir = temporaryRoot()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: dir.appendingPathComponent("a"))
        let listed = try VoiceSharingUploadQueue.defaultBoundedLister(dir, [], 8)
        XCTAssertEqual(listed.urls.count, 1)
        XCTAssertFalse(listed.overflowed)
    }

    func test_realStepsSurfacesErrorHandlerFailures() throws {
        // Reviewer 988cf96c: FileManager delivers errors to `errorHandler`; `nextObject()` never
        // yields an Error. A synthetic `.failure` step cannot prove the adapter propagates an error
        // the ENUMERATOR reported. This exercises `realSteps` itself: the error handler is invoked
        // with a real error and the sequence must yield `.failure`, not silently end.
        //
        // A directory whose ACL denies traversal to a child, plus a child we then remove mid-flight,
        // is not reliably reproducible here, so the handler contract is asserted directly: any error
        // captured by the adapter must appear as a step.
        let dir = temporaryRoot()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: dir.appendingPathComponent("a"))
        let steps = Array(VoiceSharingUploadQueue.realSteps(dir, []))
        XCTAssertEqual(steps.count, 1)
        guard case .url(let first) = steps[0] else {
            return XCTFail("a readable directory must yield a URL step, got \(steps[0])")
        }
        XCTAssertEqual(first.lastPathComponent, "a")

        // A directory that does not exist makes the REAL FileManager enumerator invoke its error
        // handler (verified by instrumenting the handler: it fires once with NSCocoaError 260). The
        // adapter must turn that captured error into a `.failure` step and `boundedListing` must
        // throw — the previous version of this test accepted "no steps at all", which is the
        // fail-open outcome being guarded against.
        let missing = dir.appendingPathComponent("does-not-exist")
        let missingSteps = Array(VoiceSharingUploadQueue.realSteps(missing, []))
        XCTAssertFalse(missingSteps.isEmpty,
                       "an unreadable directory must not enumerate as empty success")
        XCTAssertTrue(missingSteps.contains { if case .failure = $0 { return true } else { return false } },
                      "the error-handler error must be surfaced as a .failure step")
        XCTAssertThrowsError(
            try VoiceSharingUploadQueue.boundedListing(over: AnySequence(missingSteps), limit: 8))
        XCTAssertThrowsError(try VoiceSharingUploadQueue.defaultBoundedLister(missing, [], 8),
                             "the production lister must refuse an unreadable directory")
    }

    func test_unreadableAttemptRecordPathIsNotTreatedAsAbsent() throws {
        // Reviewer 988cf96c: `fileExists(false)` is not confirmed absence. Only ENOENT may mean zero;
        // an unreadable path must refuse so the retry budget cannot be reset by a permission fault.
        XCTAssertEqual(VoiceSharingUploadQueue.statKind(of: URL(fileURLWithPath: "/definitely/not/here")),
                       .absent, "a genuinely missing path is absent")
        let dir = temporaryRoot()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: dir.appendingPathComponent("f"))
        XCTAssertEqual(VoiceSharingUploadQueue.statKind(of: dir.appendingPathComponent("f")), .present)

        // A path through a regular file is ENOTDIR, which is a FAILURE, not absence.
        let throughFile = dir.appendingPathComponent("f").appendingPathComponent("attempts.json")
        XCTAssertEqual(VoiceSharingUploadQueue.statKind(of: throughFile), .failure,
                       "ENOTDIR is not absence")

        // And it surfaces as a REFUSAL from the count read, not as zero attempts. Build a real
        // entry, then replace its attempts.json with a path through a regular file (ENOTDIR).
        let q = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        // attempts.json does not exist until the first attempt, so create the obstruction directly.
        let record = root.appendingPathComponent(prep.name).appendingPathComponent("attempts.json")
        // Make the ENTRY DIRECTORY unsearchable: lstat of a child then fails with EACCES, which is
        // the `.failure` case (a non-ENOENT errno). This is the only route that reaches it, since
        // ENOTDIR cannot occur (attempts.json's parent is always a real directory).
        let entryDir = root.appendingPathComponent(prep.name)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: entryDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entryDir.path) }
        XCTAssertEqual(VoiceSharingUploadQueue.statKind(of: record), .failure,
                       "an unsearchable parent is a FAILURE, not absence")
        XCTAssertThrowsError(try q.attemptCount(for: prep),
                             "an unreadable record path must refuse, not report zero attempts")
    }

    func test_beginAttemptRequiresACompleteReadyEntry() throws {
        // Reviewer 988cf96c: attempt ownership must not be granted for an entry that is still being
        // prepared, disqualified, or otherwise not ready.
        let q = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let record = validRecord(captureID: UUID().uuidString, audio: audioA)
        let prepared = try q.prepare(metadata: record, audio: audioA)
        // Still preparing: no ready marker yet.
        XCTAssertFalse(try q.isAttemptable(prepared),
                       "a preparing entry is not attemptable")
        XCTAssertFalse(try q.beginAttempt(prepared),
                       "a preparing entry must not be granted an attempt")

        try q.finalize(prepared)
        XCTAssertTrue(try q.isAttemptable(prepared), "a ready entry is attemptable")

        // A disqualified entry (publication.failed present) is not attemptable.
        let failedTicket = try q.prepare(metadata: record, audio: audioA)
        let failedDirectory = root.appendingPathComponent(failedTicket.name)
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        try Data([0x01]).write(to: failedDirectory.appendingPathComponent("publication.failed"))
        XCTAssertFalse(try q.isAttemptable(failedTicket),
                       "a disqualified entry is not attemptable")
    }

    // MARK: Cross-instance attempt ownership (reviewer 6886455c)

    func test_twoQueueInstancesCannotBothOwnAnAttempt() throws {
        // A per-instance serial queue does not serialize a shared attempts.json, so two instances
        // over one root must not both start a request for the same entry.
        let a = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try a.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try a.finalize(prep)
        let b = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)

        XCTAssertTrue(try a.beginAttempt(prep), "the first owner acquires the lease")
        XCTAssertFalse(try b.beginAttempt(prep),
                       "a second instance must not also own the same entry's attempt")
        XCTAssertEqual(try a.attemptCount(for: prep), 1,
                       "a refused acquisition must not have spent an attempt")
        a.endAttempt(prep)
        XCTAssertTrue(try b.beginAttempt(prep), "the lease is available once released")
    }

    func test_staleAttemptLeaseIsReclaimableAfterItsOwnerDies() throws {
        // A killed process leaves its lease on disk. It must be reclaimable — but not instantly, or
        // two live instances would race; and not never, or the entry is blocked forever.
        let a = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try a.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try a.finalize(prep)
        XCTAssertTrue(try a.beginAttempt(prep))
        // Deliberately no endAttempt: this models a kill while owning the lease.

        let b = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertFalse(try b.beginAttempt(prep),
                       "a FRESH lease must not be stealable while it may be live")

        // The lease is reclaimable once it has expired. A killed owner cannot renew it.
        let later = Date().addingTimeInterval(
            VoiceSharingUploadQueue.attemptLeaseDuration + 1)
        let c = VoiceSharingUploadQueue(rootDirectory: root, clock: { later })
        XCTAssertTrue(try c.beginAttempt(prep),
                      "an expired lease must be reclaimable")
        XCTAssertEqual(try c.attemptCount(for: prep), 2,
                       "reclaiming spends a new attempt")
    }

    // MARK: Atomic claim and fencing (reviewer 3ab75638)

    func test_simultaneousAcquisitionAdmitsExactlyOneOwner() throws {
        // A sequential test cannot prove mutual exclusion: stat->write lets both instances observe
        // absence. This releases N instances from a barrier at the same instant; the OS-backed
        // exclusive create must admit exactly one.
        let setup = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try setup.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try setup.finalize(prep)

        let instances = (0..<8).map { _ in
            VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        }
        let barrier = DispatchGroup()
        let results = LockedBox<[Bool]>([])
        for queue in instances {
            barrier.enter()
        }
        for queue in instances {
            DispatchQueue.global().async {
                // Wait until every contender is ready, then race.
                barrier.wait()
                let won = (try? queue.beginAttempt(prep)) ?? false
                results.mutate { $0.append(won) }
            }
            barrier.leave()
        }
        barrier.wait()
        // Give the racers a moment to finish appending (the group only covers the start).
        let deadline = Date().addingTimeInterval(2)
        while results.value.count < instances.count, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertEqual(results.value.count, instances.count, "every contender must report")
        XCTAssertEqual(results.value.filter { $0 }.count, 1,
                       "exactly one owner may win a simultaneous acquisition")
        XCTAssertEqual(try setup.attemptCount(for: prep), 1,
                       "only the winner may have spent an attempt")
    }

    func test_staleOwnerCannotReleaseItsSuccessorsLease() throws {
        // Reviewer 3ab75638/2: elapsed time does not prove the old writer died. After expiry a
        // successor acquires; the old owner's endAttempt must not delete the successor's lease.
        let first = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try first.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try first.finalize(prep)
        XCTAssertTrue(try first.beginAttempt(prep))

        let later = Date().addingTimeInterval(VoiceSharingUploadQueue.attemptLeaseDuration + 1)
        let successor = VoiceSharingUploadQueue(rootDirectory: root, clock: { later })
        XCTAssertTrue(try successor.beginAttempt(prep), "an expired lease is reclaimable")

        // The stale owner now "finishes". Its release must be fenced by identity.
        first.endAttempt(prep)
        let another = VoiceSharingUploadQueue(rootDirectory: root, clock: { later })
        XCTAssertFalse(try another.beginAttempt(prep),
                       "the successor's lease must survive the stale owner's release")

    }

    func test_staleOwnerIsNotStillOwnerAfterReclaim() throws {
        // A stale completion must be checkable: the old owner must see that it no longer holds the
        // lease, so it cannot report a result as current.
        let first = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try first.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try first.finalize(prep)
        let lease = try XCTUnwrap(first.beginLeaseForTesting(prep))
        XCTAssertTrue(first.stillOwns(prep, lease: lease), "the live owner still owns it")

        let later = Date().addingTimeInterval(VoiceSharingUploadQueue.attemptLeaseDuration + 1)
        let successor = VoiceSharingUploadQueue(rootDirectory: root, clock: { later })
        XCTAssertTrue(try successor.beginAttempt(prep))
        XCTAssertFalse(first.stillOwns(prep, lease: lease),
                       "after reclaim the old owner must NOT believe it still owns the lease")
    }

    func test_refusedAttemptLeavesNoLeaseBehind() throws {
        // Reviewer 3ab75638/3: a refusal after claiming must settle the lease.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32),
            attemptLimits: VoiceSharingUploadQueue.AttemptLimits(maxUploadAttempts: 1))
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        // A NOT-READY entry is refused AFTER the lease is claimed, and this refusal does NOT delete
        // the entry — so only explicit settlement can clear the lease. (The exhausted path removes
        // the whole directory, which would make this control unable to distinguish anything.)
        let notReady = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        XCTAssertFalse(try q.beginAttempt(notReady),
                       "a preparing entry is refused")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(notReady.name).appendingPathComponent("attempt.lease").path),
            "a refused attempt must not leave a lease behind")
        _ = prep
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(prep.name).appendingPathComponent("attempt.lease").path),
            "a refused attempt must not leave a lease behind")
    }

    // MARK: Lease transition serialization (reviewer 08baa9f0)

    func test_simultaneousExpiredReclaimAdmitsExactlyOneSuccessor() throws {
        // Two reclaimers over the same expired lease must not both read the old generation, both
        // remove, and let the later remover destroy the first successor's lease.
        let setup = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try setup.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try setup.finalize(prep)
        // Seed an EXPIRED lease.
        let expired = Date().addingTimeInterval(-1)
        let seeder = VoiceSharingUploadQueue(rootDirectory: root, clock: { expired })
        _ = try seeder.beginLeaseForTesting(prep)

        let later = Date().addingTimeInterval(VoiceSharingUploadQueue.attemptLeaseDuration + 1)
        let reclaimers = (0..<8).map { _ in
            VoiceSharingUploadQueue(rootDirectory: root, clock: { later })
        }
        let barrier = DispatchGroup()
        let results = LockedBox<[Bool]>([])
        for queue in reclaimers { barrier.enter() }
        for queue in reclaimers {
            DispatchQueue.global().async {
                barrier.wait()
                let won = (try? queue.beginAttempt(prep)) ?? false
                results.mutate { $0.append(won) }
            }
            barrier.leave()
        }
        barrier.wait()
        let deadline = Date().addingTimeInterval(2)
        while results.value.count < reclaimers.count, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(results.value.filter { $0 }.count, 1,
                       "exactly one reclaimer may win an expired lease")
        // The surviving lease must be the WINNER's, not a stale remnant.
        let winner = VoiceSharingUploadQueue(rootDirectory: root, clock: { later })
        XCTAssertFalse(try winner.beginAttempt(prep),
                       "the winner's fresh lease must hold against new contenders")
    }

    func test_endAttemptFromAnInstanceThatNeverAcquiredRemovesNothing() throws {
        // Reviewer 08baa9f0: releaseLeaseLocked(owner: nil) unconditionally removed whatever lease
        // existed, so a bystander's endAttempt could delete another owner's lease.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        XCTAssertTrue(try owner.beginAttempt(prep))

        let bystander = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        bystander.endAttempt(prep) // never acquired
        let checker = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertFalse(try checker.beginAttempt(prep),
                       "the owner's lease must survive a bystander's release")
    }

    func test_leaseLockActuallyExcludesAcrossInstances() throws {
        // Reviewer 08baa9f0: a comparison alone is not conditional unlink; the flock must genuinely
        // serialize. Hold the lock from one instance and verify another instance cannot run its
        // critical section until it is released.
        let dir = temporaryRoot()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let type = VoiceSharingUploadQueue.self
        let lockA = try type.LeaseLock(entryName: "TEST-ENTRY", rootDirectory: dir)
        try lockA.lockExclusive()
        let lockB = try type.LeaseLock(entryName: "TEST-ENTRY", rootDirectory: dir)

        let acquired = LockedBox<Bool>(false)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // A non-blocking attempt must FAIL while A holds the lock.
            do {
                let fd = try type.LeaseLock(entryName: "TEST-ENTRY", rootDirectory: dir)
                try fd.tryLockForTesting()
                acquired.mutate { $0 = true }
            } catch { acquired.mutate { $0 = false } }
            done.signal()
        }
        done.wait()
        XCTAssertFalse(acquired.value,
                       "a second holder must not acquire while the first holds the lock")

        lockA.close()
        // After release, acquisition must succeed.
        let second = try type.LeaseLock(entryName: "TEST-ENTRY", rootDirectory: dir)
        try second.tryLockForTesting()
        XCTAssertTrue(true, "acquisition after release succeeds")
        second.close()
        _ = lockB
    }

    // MARK: LeaseLock lifecycle (reviewer 8f964e8c)

    func test_leaseLockCloseIsIdempotent() throws {
        // A non-idempotent close closes the descriptor twice; if the number was reused in between,
        // the second close hits an unrelated file or socket. close() must invalidate the stored
        // descriptor so defer/deinit/closeAfter cannot double-close.
        let dir = temporaryRoot()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = try VoiceSharingUploadQueue.LeaseLock(entryName: "TEST", rootDirectory: dir)
        try lock.lockExclusive()
        lock.close()

        // Occupy the descriptor number the lock just released. A NON-idempotent second close would
        // close THIS descriptor; the victim file must stay open and writable.
        let victimPath = dir.appendingPathComponent("victim")
        FileManager.default.createFile(atPath: victimPath.path, contents: nil)
        let victim = victimPath.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDWR)
        }
        XCTAssertGreaterThan(victim, 2)

        // Closing again must be a no-op, not a second Darwin.close on a reused descriptor.
        lock.close()
        lock.close()

        // The victim must be untouched: writable and its descriptor valid.
        let probe = write(victim, "x", 1)
        XCTAssertGreaterThanOrEqual(probe, 0,
                                    "the second close must not have closed a reused descriptor")
        Darwin.close(victim)
    }

    func test_leaseLockSurvivesRecoveryAndEntryRemoval() throws {
        // Reviewer 8f964e8c: the lock file lived inside the entry directory, which recovery and
        // exhaustion remove whole — destroying the inode live holders rely on. It must now live at
        // the root, be skipped by the stray scan, and survive entry removal.
        let q = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        XCTAssertTrue(try q.beginAttempt(prep))
        q.endAttempt(prep) // release; the lock FILE stays (stable inode by design)
        let lockPath = root.appendingPathComponent(
            VoiceSharingUploadQueue.rootLeaseLockName(for: prep.name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path),
                      "the lock file is created at the ROOT on first lease use")

        // Exhaustion removes the entry directory; the lock file must survive it. Exhaustion must be
        // driven through the OWNING instance: a fresh queue would simply start its own attempt.
        let limited = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32),
            attemptLimits: VoiceSharingUploadQueue.AttemptLimits(maxUploadAttempts: 2))
        try limited.recordAttempt(prep) // count -> 2 = exhausted (q already spent 1)
        _ = try? limited.beginAttempt(prep) // refused after claiming; removes the entry
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(prep.name).path), "entry removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path),
                      "the lock inode must survive entry removal")

        // Recovery must also skip it as a stray.
        _ = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath.path),
                      "recovery must not delete a well-formed lease lock")
    }

    func test_lifetimeEntriesDoNotAccumulateRootLockFiles() throws {
        // Reviewer 17c4310f: UUID-per-entry locks accumulated forever, and past the root's bounded
        // discovery limit admission was permanently disabled even with an empty queue. The fixed
        // lock pool must bound root artifacts across repeated acquire/exhaust/remove cycles.
        let limits = VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32)
        for cycle in 0..<80 {
            let q = VoiceSharingUploadQueue(
                rootDirectory: root, clock: Date.init,
                aggregateLimits: limits,
                attemptLimits: VoiceSharingUploadQueue.AttemptLimits(maxUploadAttempts: 1))
            let audio = cycle % 2 == 0 ? audioA : audioB
            let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audio), audio: audio)
            try q.finalize(prep)
            _ = try q.beginAttempt(prep)
            q.endAttempt(prep)
            // Second attempt is refused (exhausted) and removes the entry.
            _ = try? q.beginAttempt(prep)
        }
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }
        let lockFiles = rootNames.filter { $0.hasPrefix("attempt.lock.") }
        XCTAssertLessThanOrEqual(lockFiles.count, VoiceSharingUploadQueue.maxRootLockFiles,
                                 "the lock namespace is fixed, not per-entry")
        // Admission still works after all those cycles: an empty queue is an usable queue.
        let fresh = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init, aggregateLimits: limits)
        let prep = try fresh.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try fresh.finalize(prep)
        XCTAssertEqual(fresh.readyEntries().count, 1,
                       "admission must survive a lifetime of entries")
        XCTAssertTrue(try fresh.beginAttempt(prep))
    }

    func test_sameEntryAlwaysMapsToTheSameLockFile() throws {
        // Mutual exclusion depends on the same entry locking the same inode every time.
        let names = Set((0..<50).map { _ in UUID().uuidString }.map {
            VoiceSharingUploadQueue.rootLeaseLockName(for: $0)
        })
        XCTAssertLessThanOrEqual(names.count, VoiceSharingUploadQueue.leaseLockPoolSize)
        // And deterministically: the same name always maps identically.
        for name in names.prefix(5) {}
        let sample = UUID().uuidString
        XCTAssertEqual(VoiceSharingUploadQueue.rootLeaseLockName(for: sample),
                       VoiceSharingUploadQueue.rootLeaseLockName(for: sample))
    }

    func test_concurrentAttemptRecordingLosesNoCounts() throws {
        // Reviewer da806c31 follow-through: attempts.json read-increment-write was a lost-update
        // race across instances. N concurrent recorders must yield exactly N.
        let setup = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try setup.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try setup.finalize(prep)

        let recorders = (0..<12).map { _ in
            VoiceSharingUploadQueue(
                rootDirectory: root, clock: Date.init,
                aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxBytes: 10_000_000, maxRecords: 32),
                attemptLimits: VoiceSharingUploadQueue.AttemptLimits(maxUploadAttempts: 100))
        }
        let barrier = DispatchGroup()
        let failures = LockedBox<[Error]>([])
        for queue in recorders { barrier.enter() }
        for queue in recorders {
            DispatchQueue.global().async {
                barrier.wait()
                do { try queue.recordAttempt(prep) } catch { failures.mutate { $0.append(error) } }
            }
            barrier.leave()
        }
        barrier.wait()
        let deadline = Date().addingTimeInterval(2)
        while failures.value.count + 0 < recorders.count, Date() < deadline { usleep(10_000) }
        // Every increment must be counted: no lost updates, none refused by a stale read.
        XCTAssertEqual(try setup.attemptCount(for: prep), recorders.count,
                       "N concurrent recorders must produce exactly N counted attempts")
        XCTAssertTrue(failures.value.isEmpty, "unexpected failures: \(failures.value)")
    }

    // MARK: Atomic result application (reviewer d3972319)

    func test_resultApplicationIsRefusedAfterLeaseReclaim() throws {
        // An intervening expiry/reclaim means the old owner's result is STALE: it must not delete
        // an entry a successor is now uploading.
        let first = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try first.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try first.finalize(prep)
        let lease = try XCTUnwrap(first.beginLeaseForTesting(prep))

        let later = Date().addingTimeInterval(VoiceSharingUploadQueue.attemptLeaseDuration + 1)
        let successor = VoiceSharingUploadQueue(rootDirectory: root, clock: { later })
        XCTAssertTrue(try successor.beginAttempt(prep))

        // The old owner reports DELIVERED. It no longer owns the lease.
        XCTAssertThrowsError(try first.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .resultStale,
                           "a stale owner's result must be refused")
        }
        // The entry must still exist: the successor owns it now.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(prep.name).path),
                      "a stale result must not delete the successor's entry")
    }

    func test_deliveredResultRemovesEntryAndReleasesLeaseAtomically() throws {
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))

        try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(prep.name).path),
                       "a delivered entry is removed")
        XCTAssertFalse(owner.isAttemptInFlight(prep), "ownership is released with the result")
    }

    func test_retryableFailureKeepsTheEntryForTheNextAttempt() throws {
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))

        try owner.applyAttemptResult(prep, lease: lease, outcome: .retryableFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(prep.name).path),
                      "a retryable failure keeps the entry")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(prep.name).appendingPathComponent("attempt.lease").path),
            "the failed request releases its lease")
        // And the entry is attemptable again.
        let next = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(try next.beginAttempt(prep))
    }

    func test_settlementFailureIsNotReportedAsSuccess() throws {
        // Reviewer d258d06a: a lock serializes transitions; it does not make failed filesystem
        // operations succeed. Removal failure must surface as uncertain, and ownership must be
        // RETAINED so the caller can settle again.
        final class RemovingFailingFileManager: FileManager {
            var failRemovals = false
            override func removeItem(at URL: URL) throws {
                if failRemovals { throw CocoaError(.fileWriteUnknown) }
                try super.removeItem(at: URL)
            }
        }
        let fm = RemovingFailingFileManager()
        let owner = VoiceSharingUploadQueue(rootDirectory: root, fileManager: fm, clock: Date.init)
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))

        fm.failRemovals = true
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain,
                           "unknown settlement is uncertain, not success")
        }
        XCTAssertTrue(owner.isAttemptInFlight(prep),
                      "ownership is retained so the caller can settle again")
        fm.failRemovals = false
        // Settlement can then succeed.
        try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(prep.name).path))
    }

    func test_postRemovalSyncFailureIsAlsoUncertainAndRetainsOwnership() throws {
        // The removal can succeed and its durability confirmation can still fail: that too is
        // uncertain, and ownership must be retained for re-settlement.
        var failSync = false
        let rootPath = root.path
        let owner = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { url, isDirectory in
                if failSync, isDirectory, url.path == rootPath {
                    throw CocoaError(.fileWriteUnknown)
                }
            })
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))

        failSync = true
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain,
                           "unconfirmed removal durability is uncertain")
        }
        XCTAssertTrue(owner.isAttemptInFlight(prep), "ownership retained for re-settlement")
        failSync = false
        try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)
        XCTAssertFalse(owner.isAttemptInFlight(prep))
    }

    // MARK: Reconciliation across repeated settlement (reviewer 64629ed5)

    func test_persistentRootSyncFailureStaysUncertainAcrossTwoSettlements() throws {
        // Retry is a REPEAT of the durability barrier, not a shortcut around it: while the root
        // barrier keeps failing, settlement keeps reporting uncertain and keeps ownership.
        var failSync = false
        let rootPath = root.path
        let owner = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { url, isDirectory in
                if failSync, isDirectory, url.path == rootPath { throw CocoaError(.fileWriteUnknown) }
            })
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))

        failSync = true
        for round in 1...2 {
            XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
                XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain,
                               "round \(round): unconfirmed is uncertain")
            }
            XCTAssertTrue(owner.isAttemptInFlight(prep), "round \(round): ownership retained")
        }
        failSync = false
        try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)
        XCTAssertFalse(owner.isAttemptInFlight(prep))
    }

    func test_leaseRemovalThenSyncFailureThenRetryReconcilesWithoutResultStale() throws {
        // Lease removal landed, entry-dir sync failed: the retained owner's RETRY must finish the
        // settlement, not be told resultStale by its own successful earlier mutation.
        var failSync = false
        var failingDir: URL?
        let owner2 = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { url, isDirectory in
                if failSync, isDirectory, let target = failingDir, url.path == target.path {
                    throw CocoaError(.fileWriteUnknown)
                }
            })
        let prep = try owner2.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner2.finalize(prep)
        let lease = try XCTUnwrap(owner2.beginLeaseForTesting(prep))
        failingDir = root.appendingPathComponent(prep.name)

        failSync = true
        XCTAssertThrowsError(try owner2.applyAttemptResult(prep, lease: lease, outcome: .retryableFailure)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain)
        }
        XCTAssertTrue(owner2.isAttemptInFlight(prep))
        // Retry: the lease file is gone but the sync now succeeds -> reconcile, release.
        failSync = false
        try owner2.applyAttemptResult(prep, lease: lease, outcome: .retryableFailure)
        XCTAssertFalse(owner2.isAttemptInFlight(prep))
        // Entry still present and attemptable by a fresh instance.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(try fresh.beginAttempt(prep), "fresh-owner recovery after reconciled retry")
    }

    func test_absentLeaseIsNotReconciledByAForeignHandle() throws {
        // Absence reconciliation is reserved for the recorded owner: a different lease token must
        // get resultStale even when no lease file exists.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))
        let entryDir = root.appendingPathComponent(prep.name)
        try FileManager.default.removeItem(at: entryDir.appendingPathComponent("attempt.lease"))

        let foreign = VoiceSharingUploadQueue.AttemptLease(
            generation: UUID().uuidString, acquiredAt: Date(), owner: Int32(getpid()))
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: foreign, outcome: .retryableFailure)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .resultStale)
        }
        // Round 50: reconciliation is bound to a DURABLY RECORDED intent. A lease removed by
        // another path — no settlement record exists — is refused even for the recorded owner:
        // absence without intent is not settled success. Ownership is retained; the live-lease
        // path (fresh settlement) remains available for a genuine completion.
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .retryableFailure)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .resultStale)
        }
        XCTAssertTrue(owner.isAttemptInFlight(prep))
        // Restoring the lease lets a fresh settlement proceed normally.
        try Data("{}".utf8).write(to: entryDir.appendingPathComponent("attempt.lease"))
    }

    // MARK: Recorded settlement intent (reviewer 4b02a457)

    func test_contradictoryRetryIsRejected() throws {
        // retryable lease removal -> sync failure -> DELIVERED retry: the pending record says
        // retryable; delivered would claim a removal that intent never authorized.
        var failSync = false
        var failingDir: URL?
        let owner = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { url, isDirectory in
                if failSync, isDirectory, let target = failingDir, url.path == target.path {
                    throw CocoaError(.fileWriteUnknown)
                }
            })
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))
        failingDir = root.appendingPathComponent(prep.name)

        failSync = true
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .retryableFailure)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain)
        }
        // Contradictory retry is REJECTED, entry retained.
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .settlementConflict,
                           "the pending intent binds the outcome; delivered contradicts it")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(prep.name).path))
        // Consistent retry completes the recorded transition.
        failSync = false
        try owner.applyAttemptResult(prep, lease: lease, outcome: .retryableFailure)
        XCTAssertFalse(owner.isAttemptInFlight(prep))
    }

    func test_leaseRemovedByAnotherPathIsNotMistakenForSettlement() throws {
        // No intent recorded + lease gone (removed externally): absence must NOT be read as
        // settled success, even for the recorded in-flight owner.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))
        let entryDir = root.appendingPathComponent(prep.name)
        try FileManager.default.removeItem(at: entryDir.appendingPathComponent("attempt.lease"))

        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .retryableFailure)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .resultStale,
                           "no recorded intent: absence proves nothing")
        }
        XCTAssertTrue(owner.isAttemptInFlight(prep), "ownership retained; nothing was settled")
    }

    func test_settlementIntentSurvivesCrashForFreshOwnerRecovery() throws {
        // Removal landed, confirmation failed: the intent record is still on disk. A FRESH
        // instance (crashed original gone) retries the SAME outcome and reconciles exactly that
        // transition.
        // Reviewer 3aa2b731: the recovery must be proven AFTER the entry removal, not at the
        // intent write. Fail only root syncs AFTER the first (the intent write's own barrier).
        let rootPath = root.path
        var armed = false
        var armedRootSyncs = 0
        let crashed = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { url, isDirectory in
                guard armed, isDirectory, url.path == rootPath else { return }
                armedRootSyncs += 1
                if armedRootSyncs > 1 { throw CocoaError(.fileWriteUnknown) }
            })
        let prep = try crashed.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try crashed.finalize(prep)
        let lease = try XCTUnwrap(crashed.beginLeaseForTesting(prep))
        // The intent is durably written (armed root sync #1), the entry removal LANDS, then its
        // root barrier (#2) fails => uncertain, removal unconfirmed, intent on disk.
        armed = true
        XCTAssertThrowsError(try crashed.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(prep.name).path),
                       "the removal landed; only its barrier failed")
        // "Crash": the original instance is gone. A fresh instance sees the durable intent and
        // reconciles exactly that transition.
        let settlementURL = root.appendingPathComponent(
            VoiceSharingUploadQueue.settlementRecordName(for: prep.name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: settlementURL.path),
                      "the intent must be on disk after the failed barrier")
        let successor = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        try successor.applyAttemptResult(prep, lease: lease, outcome: .delivered)
        let settlementGone = !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                VoiceSharingUploadQueue.settlementRecordName(for: prep.name)).path)
        XCTAssertTrue(settlementGone, "the intent record is cleared after confirmation")
    }

    func test_entryRemovedByAnotherPathIsNotMistakenForSettlement() throws {
        // Entry directory removed externally, no settlement intent recorded: the caller's
        // in-memory token proves nothing about WHO removed it or whether it persisted.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))
        try FileManager.default.removeItem(at: root.appendingPathComponent(prep.name))

        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .resultStale,
                           "no intent, no settled success")
        }
        XCTAssertTrue(owner.isAttemptInFlight(prep), "ownership retained: nothing was settled")
    }

    func test_confirmedPhaseSurvivesFinalClearBarrierFailure() throws {
        // Reviewer 737cba7c (3): arm relative to a captured BASELINE, and assert WHICH barrier
        // failed and what phase is on disk — an absolute sync count can fail the intent barrier
        // instead of the confirmed-phase one.
        let rootPath = root.path
        var rootSyncCount = 0
        var armAt: Int? = nil
        let owner = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { url, isDirectory in
                guard isDirectory, url.path == rootPath else { return }
                rootSyncCount += 1
                if let armAt, rootSyncCount > armAt { throw CocoaError(.fileWriteUnknown) }
            })
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))
        let settlementURL = root.appendingPathComponent(
            VoiceSharingUploadQueue.settlementRecordName(for: prep.name))

        // Baseline: how many root syncs happen before this settlement starts. The settlement
        // performs, in order: (a) intent write barrier, (b) entry-removal barrier,
        // (c) confirmed-phase write barrier. Arming at baseline+2 fails exactly (c).
        let baseline = rootSyncCount
        armAt = baseline + 2
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain)
        }
        // Exactly three settlement root syncs were attempted, failing on the third (confirmed).
        XCTAssertEqual(rootSyncCount, baseline + 3, "the CONFIRMED-phase barrier is the one that failed")
        // The record is VISIBLE with the confirmed phase (visibility is not durability evidence,
        // but it is the recoverable state the retry needs): the rewrite landed, its barriers did
        // not both succeed.
        let onDisk = try String(contentsOf: settlementURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("\"phase\":\"confirmed\""),
                      "the confirmed rewrite is visible for recovery, got \(onDisk)")
        // RESTORED RETRY: the confirmed record is visibly present and phase-marked (recovery
        // state), so the retry reconciles it
        // (verify state, retire record) and succeeds without re-removing anything.
        armAt = nil
        try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settlementURL.path),
                       "confirmed record retired")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settlementURL.path),
                       "confirmed record retired after reconciliation")
        XCTAssertFalse(owner.isAttemptInFlight(prep))
        // The entry stays removed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(prep.name).path))
    }

    func test_malformedIntentRefusesSettlementInsteadOfOverwriting() throws {
        // Reviewer 3aa2b731 (3): an unreadable/malformed/oversized intent is UNKNOWN pending
        // state — refuse (accountingUnavailable); never overwrite as a fresh transition.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))
        let settlementURL = root.appendingPathComponent(
            VoiceSharingUploadQueue.settlementRecordName(for: prep.name))

        try Data("not json at all".utf8).write(to: settlementURL)
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: settlementURL), Data("not json at all".utf8),
                       "the unknown intent is preserved, not overwritten")
        XCTAssertTrue(owner.isAttemptInFlight(prep))

        // Oversized intent is equally unknown.
        try Data(repeating: 0x41, count: VoiceSharingUploadQueue.maxSettlementRecordBytes + 1)
            .write(to: settlementURL)
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable)
        }
    }

    func test_confirmedRecordRejectsForeignGenerationAndContradictoryOutcome() throws {
        // Reviewer 737cba7c (1): a SURVIVING confirmed record must not let a foreign token or a
        // contradictory outcome claim success.
        let rootPath = root.path
        var armed = false
        var rootSyncs = 0
        var armAt: Int? = nil
        let owner = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { url, isDirectory in
                guard isDirectory, url.path == rootPath else { return }
                rootSyncs += 1
                if let armAt, rootSyncs > armAt { throw CocoaError(.fileWriteUnknown) }
            })
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))
        let settlementURL = root.appendingPathComponent(
            VoiceSharingUploadQueue.settlementRecordName(for: prep.name))

        // Leave a CONFIRMED record on disk by failing its confirmed-phase barrier.
        let baseline = rootSyncs
        armAt = baseline + 2
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered))
        armAt = nil
        XCTAssertTrue(try String(contentsOf: settlementURL, encoding: .utf8).contains("confirmed"))

        // Foreign generation against a surviving confirmed record.
        let foreign = VoiceSharingUploadQueue.AttemptLease(
            generation: UUID().uuidString, acquiredAt: Date(), owner: Int32(getpid()))
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: foreign, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .resultStale,
                           "a foreign token must not settle a surviving confirmed record")
        }
        // Contradictory outcome, correct generation.
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .retryableFailure)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .settlementConflict,
                           "a different outcome must not claim the recorded transition")
        }
        // The record survives both refusals; the correct retry then reconciles it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: settlementURL.path))
        try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settlementURL.path))
    }

    func test_recoveryRetiresOnlyConfirmedRecordsAndNeverPending() throws {
        // Reviewer 737cba7c (2): recovery must not touch a PENDING record (its owner/successor
        // needs it) and must retire a CONFIRMED one whose state verifies.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let pendingEntry = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(pendingEntry)
        _ = try owner.beginLeaseForTesting(pendingEntry)
        // A PENDING record with the entry still present.
        let pendingURL = root.appendingPathComponent(
            VoiceSharingUploadQueue.settlementRecordName(for: pendingEntry.name))
        try Data("{\"generation\":\"G\",\"outcome\":\"delivered\",\"owner\":1,\"phase\":\"pending\"}"
            .utf8).write(to: pendingURL)

        // A CONFIRMED record whose entry is gone.
        let goneName = UUID().uuidString
        let confirmedURL = root.appendingPathComponent(
            VoiceSharingUploadQueue.settlementRecordName(for: goneName))
        try Data("{\"generation\":\"G\",\"outcome\":\"delivered\",\"owner\":1,\"phase\":\"confirmed\"}"
            .utf8).write(to: confirmedURL)

        // A fresh instance's recovery runs on construction.
        _ = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path),
                      "recovery must never retire a PENDING record")
        XCTAssertFalse(FileManager.default.fileExists(atPath: confirmedURL.path),
                       "recovery retires a CONFIRMED record whose state verifies")
    }

    func test_confirmedRewriteFileBarrierFailureRefusesSuccessAndKeepsRecoveryState() throws {
        // Reviewer d28594ef: every journal rewrite must synchronize FILE then root. A
        // FILE-barrier failure on the confirmed rewrite must refuse success and leave a
        // recoverable record — not let the root barrier publish non-durable content.
        let rootPath = root.path
        var armed = false
        var fileSyncs = 0
        let owner = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { url, isDirectory in
                guard !isDirectory, url.path == rootPath + "/probe" else {
                    if !isDirectory, armed { fileSyncs += 1 }
                    if !isDirectory, armed, fileSyncs > 1 {
                        // The confirmed rewrite's FILE barrier: the pending write's file barrier
                        // was the first.
                        throw CocoaError(.fileWriteUnknown)
                    }
                    return
                }
            })
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let lease = try XCTUnwrap(owner.beginLeaseForTesting(prep))
        let settlementURL = root.appendingPathComponent(
            VoiceSharingUploadQueue.settlementRecordName(for: prep.name))

        // Sync order during settlement: intent FILE (1), intent root, entry-removal root,
        // confirmed FILE (2 => FAIL), confirmed root (never reached).
        armed = true
        XCTAssertThrowsError(try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .publicationUncertain,
                           "a failed file barrier refuses success")
        }
        XCTAssertEqual(fileSyncs, 2, "the failure is the CONFIRMED rewrite's file barrier")
        // The record is still present and readable as recovery state.
        let onDisk = try String(contentsOf: settlementURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("\"phase\""), "a recoverable record survives")
        // Restored: the retry completes the settlement.
        armed = false
        try owner.applyAttemptResult(prep, lease: lease, outcome: .delivered)
        XCTAssertFalse(owner.isAttemptInFlight(prep))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settlementURL.path))
    }

    private func directorySize(at url: URL) throws -> Int {
        var total = 0
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? []
        if !files.isEmpty {
            for f in files {
                let full = url.appendingPathComponent(f)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir),
                    !isDir.boolValue,
                    let attrs = try? FileManager.default.attributesOfItem(atPath: full.path),
                    let bytes = attrs[.size] as? Int {
                    total += bytes
                }
            }
        }
        return total
    }

    // MARK: Shared-queue coverage clarification 7e9606b (spec 0b5841c2)

    func test_unknownCoverageHoldsServingUntilSuccessfulScan() throws {
        var failListing = false
        let rootPath = root.path
        let q = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            listDirectoryBounded: { url, keys, limit in
                if failListing, url.path == rootPath {
                    throw CocoaError(.fileReadUnknown)
                }
                let urls = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys)
                return (urls: Array(urls.prefix(limit)), overflowed: urls.count > limit)
            })
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        guard case .known(let ready) = q.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("healthy root must report known coverage")
        }
        XCTAssertEqual(ready.count, 1)

        // Scan failure: serving is HELD (unknown), not read as an empty queue. Admission is
        // equally held (fail-closed accounting).
        failListing = true
        guard case .unknownCoverage = q.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("unknown coverage must hold serving, not report an empty queue")
        }
        XCTAssertThrowsError(try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB))

        // Restoration: a bounded SUCCESSFUL scan reopens serving.
        failListing = false
        guard case .known(let restored) = q.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("restored scan must reopen serving")
        }
        XCTAssertEqual(restored.count, 1)
    }

    func test_disposalIntentsAreDiscoveredChargedAndRetained() throws {
        // Disposal/disqualification intents (publication.failed) are discovered state: the entry
        // is retained by recovery, never served, but REMAINS owned and charged in accounting.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let livePrep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(livePrep)
        let failedPrep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB)
        try owner.finalize(failedPrep)
        try Data([0x01]).write(to: root.appendingPathComponent(failedPrep.name).appendingPathComponent("publication.failed"))

        // A fresh instance's recovery must NOT delete the disqualified entry.
        let recovered = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(failedPrep.name).path),
            "a disposal intent is discovered state, not debris")
        // It is not served...
        guard case .known(let ready) = recovered.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("healthy root")
        }
        XCTAssertEqual(Set(ready.map(\.name)), [livePrep.name],
                       "the disqualified entry is never served")
        // ...but it remains owned and charged. ISOLATE the survivor: measure the candidate
        // entry's real bytes in a scratch root first, then size maxBytes to EXACTLY live +
        // candidate. Only the DISQUALIFIED survivor's charge can then explain a refusal.
        let liveBytes = try directorySize(at: root.appendingPathComponent(livePrep.name))
        let scratchRoot = root.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: root.appendingPathComponent(livePrep.name),
            to: scratchRoot.appendingPathComponent(livePrep.name))
        // Admission charges each stored entry physical bytes + protocolOverheadBytes and reserves
        // audio+metadata+overhead for the incoming one. Mirror that math exactly so the uncrowded
        // root fits and ONLY the survivor's charge can push the crowded root over.
        let candidateOverhead = VoiceSharingUploadQueue.protocolOverheadBytes
        let liveCharge = liveBytes + candidateOverhead
        // The candidate uses the SAME audio as the live entry, and UUID capture IDs are fixed
        // length, so the reserved incoming bytes are computed exactly.
        let incoming = audioA.count
            + validRecord(captureID: UUID().uuidString, audio: audioA).count + candidateOverhead
        let limits = VoiceSharingUploadQueue.AggregateLimits(
            maxBytes: liveCharge + incoming, maxRecords: 8)
        let uncrowded = VoiceSharingUploadQueue(
            rootDirectory: scratchRoot, clock: Date.init, aggregateLimits: limits)
        XCTAssertNoThrow(try uncrowded.prepare(
            metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA),
            "without the survivor, live + candidate fits the budget")
        let crowded = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init, aggregateLimits: limits)
        XCTAssertThrowsError(try crowded.prepare(
            metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA),
            "the retained survivor's charge is what refuses the new entry")
    }

    func test_attemptsWithHeldHandlesHoldUnderUnknownCoverage() throws {
        // Spec c988cb1b: attempt paths honor unknown coverage even for already-held entry
        // handles. A failed bounded scan HOLDS the attempt; a successful scan admits it.
        var failListing = false
        let rootPath = root.path
        let owner = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            listDirectoryBounded: { url, keys, limit in
                if failListing, url.path == rootPath {
                    throw CocoaError(.fileReadUnknown)
                }
                let urls = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys)
                return (urls: Array(urls.prefix(limit)), overflowed: urls.count > limit)
            })
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)

        failListing = true
        // The handle is valid and the entry directory readable — coverage is not.
        XCTAssertThrowsError(try owner.beginAttempt(prep)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable,
                           "unknown coverage holds attempts, even with a held handle")
        }
        XCTAssertFalse(owner.isAttemptInFlight(prep), "no lease survives a coverage hold")
        // Restoration: a successful scan admits the attempt.
        failListing = false
        XCTAssertTrue(try owner.beginAttempt(prep))
        owner.endAttempt(prep)
    }

    func test_inaccessibleRequiredFileHoldsServingForTheWholeOwner() throws {
        // Reviewer c4d5ecb4: one inaccessible required file must hold coverage for the WHOLE
        // owner — it must not coexist with .known(otherReadyEntries).
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let good = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(good)
        let broken = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB)
        try owner.finalize(broken)
        // Make the broken entry's REQUIRED files stat-fail: strip all permissions from its
        // directory. No-follow lstat of its children then fails with EACCES — a FAILURE, which
        // must never collapse into absence.
        let brokenDir = root.appendingPathComponent(broken.name)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: brokenDir.path)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: brokenDir.path) }

        guard case .unknownCoverage = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("one inaccessible entry must hold coverage for the whole owner")
        }
        // Restoration: permissions back => known coverage, broken entry filtered, good served.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: brokenDir.path)
        guard case .known(let ready) = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("restored access reports known coverage")
        }
        XCTAssertEqual(ready.count, 2, "restored: both entries are valid and served")
    }

    func test_oversizedCreatedAtHoldsCoverageInsteadOfLoading() throws {
        // Reviewer f2d68c23 (1): the created-at read keeps the bounded-reader discipline — an
        // oversized/nonregular file is UNKNOWN coverage, refused before allocation.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)
        let createdURL = root.appendingPathComponent(prep.name).appendingPathComponent("created.at")
        try Data(repeating: 0x41, count: VoiceSharingUploadQueue.maxCreationInstantBytes + 1)
            .write(to: createdURL)
        guard case .unknownCoverage = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("oversized created-at must hold coverage for the whole owner")
        }
        // Nonregular created-at is equally unknown.
        try FileManager.default.removeItem(at: createdURL)
        try FileManager.default.createDirectory(at: createdURL, withIntermediateDirectories: true)
        guard case .unknownCoverage = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("nonregular created-at must hold coverage")
        }
    }

    func test_attemptGateSharesTheStrictOwnerWideCoverageAuthority() throws {
        // Reviewer f2d68c23 (2): beginAttempt must establish STRICT owner-wide coverage, not just
        // its own entry's. Entry B's unknown coverage holds entry A's attempt.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let a = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(a)
        let b = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB)
        try owner.finalize(b)
        // B's required coverage becomes unknown.
        let bDir = root.appendingPathComponent(b.name)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bDir.path) }

        XCTAssertThrowsError(try owner.beginAttempt(a)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable,
                           "B's unknown coverage holds A's attempt")
        }
        XCTAssertFalse(owner.isAttemptInFlight(a), "no lease survives the coverage hold")
        // Restore B: A's attempt is admitted.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bDir.path)
        XCTAssertTrue(try owner.beginAttempt(a))
        owner.endAttempt(a)
    }

    func test_createdAtReadFailureHoldsCoverageAndReadyGateConfirmsHoldAttempts() throws {
        // Reviewer 72e9362d: (a) a present, bounded created-at whose READ fails is UNKNOWN
        // coverage, never .incomplete; (b) B's durability-confirmation failure holds A's held-
        // handle attempt via the shared authority.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let good = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(good)
        let broken = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB)
        try owner.finalize(broken)

        // (a) Replace created.at via an unreplicable-in-content path: make the file unreadable
        // while stat-visible — chmod 000 on the FILE itself (stat ok, read fails).
        let createdURL = root.appendingPathComponent(broken.name).appendingPathComponent("created.at")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: createdURL.path)
        guard case .unknownCoverage = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a bounded created-at whose read fails must hold coverage")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: createdURL.path)

        // (b) B's ready marker present but its durability witness unconfirmable: chmod 000 on the
        // marker — stat-visible, but the confirmation's open/fsync fails while entry state is
        // still .bound, isolating the CONFIRMATION failure from the state check.
        let markerURL = root.appendingPathComponent(broken.name).appendingPathComponent("ready.marker")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: markerURL.path)
        let perms = try FileManager.default.attributesOfItem(atPath: markerURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o000, "chmod applied? path=\(markerURL.path)")
        let fd = open(markerURL.path, O_WRONLY)
        if fd >= 0 { close(fd) }
        XCTAssertFalse(fd >= 0, "probe: O_WRONLY open on 000 marker must fail (fd=\(fd))")
        guard case .unknownCoverage = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("serving holds with unconfirmable ready marker")
        }
        XCTAssertThrowsError(try owner.beginAttempt(good)) { error in
            // The authority surfaces raw I/O failure (synchronizer's NSError), not a classified
            // outcome — the point is that it THROWS and no lease survives.
            XCTAssertNotNil(error as? NSError, "B's confirmation failure holds A's attempt")
        }
        XCTAssertFalse(owner.isAttemptInFlight(good), "no lease survives the hold")
        guard case .unknownCoverage = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("serving holds equally")
        }
        // Restoration: marker readable again — A's attempt is admitted.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: markerURL.path)
        guard case .known(let ready) = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("restored coverage")
        }
        XCTAssertEqual(ready.count, 2, "restored: both entries are valid and served")
        XCTAssertTrue(try owner.beginAttempt(good))
        owner.endAttempt(good)
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

/// Minimal thread-safe box for the concurrency control.
private final class LockedBox<T> {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}

// MARK: - Revocation-intent restart hold (spec 62d39f8f: durable purge coverage)

/// A purge that could not prove every barrier must survive a RESTART: the intent marker left on
/// disk keeps the owner held so an unmarked survivor can never be served by a fresh process. The
/// memory hold alone would be lost on relaunch — that is the whole point of the marker.
final class VoiceSharingRevocationRestartTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsrevocation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Minimal WAV (44-byte header + PCM16 mono 16 kHz), duplicated here because the queue suite's
    /// helpers are instance-private to that class.
    private static func testWAV(frames: Int) -> Data {
        var data = Data()
        let dataBytes = frames * 2
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16)
        append16(1); append16(1); append32(16_000); append32(16_000 * 2); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(UInt32(dataBytes))
        data.append(Data(repeating: 0, count: dataBytes))
        return data
    }

    private static func testRecord(captureID: String, audio: Data) throws -> Data {
        let digest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        let record: [String: Any] = [
            "schema_version": 1,
            "capture_id": captureID,
            "enrollment_epoch": "epoch-1",
            "platform": "ios",
            "app_version": "8.0",
            "build": "1",
            "capture_session_id": "session-1",
            "audio": [
                "sha256": digest,
                "byte_count": audio.count,
                "encoding": "pcm_s16le",
                "sample_rate_hz": 16_000,
                "channels": 1,
                "retained_samples": (audio.count - 44) / 2,
                "original_format": "pcm_s16le",
                "conversion_version": "1",
                "truncated": false,
                "dropped_spans": [Any](),
            ],
        ]
        return try JSONSerialization.data(withJSONObject: record)
    }

    private func seedEntry() throws {
        let audio = Self.testWAV(frames: 1_600)
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let prep = try queue.prepare(metadata: Self.testRecord(captureID: UUID().uuidString, audio: audio),
                                     audio: audio)
        try queue.finalize(prep)
    }

    /// A held purge leaves the intent marker; a FRESH queue must re-derive the hold from storage and
    /// refuse to serve anything — no entry, no "unknown only because listing failed", an explicit
    /// owner-wide hold.
    func test_aFailedPurgeHoldsAcrossRestart() throws {
        try seedEntry()
        // Force the purge to refuse: its first durable write cannot be synced.
        let refusing = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { _, _ in throw CocoaError(.fileWriteUnknown) })
        let outcome = refusing.purgeAll()
        guard case .refused = outcome else {
            return XCTFail("expected a refused purge, got \(outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("revocation.intent").path),
            "a refused purge must leave durable intent behind")

        // RESTART: a brand-new instance with a working file system must still be held.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        if case .known(let entries) = fresh.readyEntriesReportingUnknownCoverage() {
            XCTFail("a fresh process must not serve after an unproven revocation (saw \(entries.count))")
        }
    }

    /// The hold is cleared only by a SUCCESSFUL purge, not by restarting.
    func test_theRestartHoldIsClearedOnlyByASuccessfulPurge() throws {
        try seedEntry()
        let refusing = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { _, _ in throw CocoaError(.fileWriteUnknown) })
        guard case .refused = refusing.purgeAll() else {
            return XCTFail("setup: expected a refused purge")
        }
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        guard case .revocationHeld = fresh.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("setup: a fresh owner must re-derive the REVOCATION hold from disk")
        }
        // A purge that can complete its writes releases it.
        _ = fresh.purgeAll()
        let afterReconcile = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        switch afterReconcile.readyEntriesReportingUnknownCoverage() {
        case .known(let entries):
            XCTAssertEqual(entries.count, 0, "a reconciled owner serves nothing and is not held")
        case .revocationHeld:
            XCTFail("a completed purge must release the restart hold")
        case .unknownCoverage:
            XCTFail("a completed purge leaves READABLE storage, not unknown coverage")
        }
    }
}

// MARK: - Revocation origin re-derivation (reviewer e40508a1)

extension VoiceSharingRevocationRestartTests {
    /// `revocationOriginUnknownLocked` must be re-derived at EVERY hold transition: an instance
    /// that first held because a READ failed must not label a later GENUINE failed revocation as
    /// unknown coverage (and vice versa).
    func test_unknownOriginIsRederviedByALaterKnownHold() throws {
        try seedEntry()
        // 1. Intent lookup cannot be read → hold with UNKNOWN origin.
        var failDiscovery = true
        let queue = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            intentDiscovery: { url in
                if failDiscovery, url.lastPathComponent == "revocation.intent" { return .failure }
                return VoiceSharingUploadQueue.statKind(of: url)
            })
        guard case .unknownCoverage = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("setup: an unreadable intent must report unknown coverage")
        }
        // 2. Discovery recovers and a REAL revocation attempt fails durably → KNOWN hold.
        failDiscovery = false
        let refusingSync = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { _, _ in throw CocoaError(.fileWriteUnknown) })
        guard case .refused = refusingSync.purgeAll() else {
            return XCTFail("setup: expected a refused purge")
        }
        // 3. The same owner, freshly constructed, must now report a KNOWN revocation hold,
        //    not "unknown coverage".
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        guard case .revocationHeld = fresh.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a KNOWN failed revocation must not be re-labelled as unknown coverage")
        }
    }

    /// And the reverse: after a KNOWN hold is released by a successful purge, a later unreadable
    /// intent must again report unknown coverage rather than a stale known hold.
    func test_aSuccessfulPurgeClearsTheKnownOrigin() throws {
        try seedEntry()
        let refusing = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { _, _ in throw CocoaError(.fileWriteUnknown) })
        guard case .refused = refusing.purgeAll() else { return XCTFail("setup: expected a refused purge") }
        let reconciling = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        guard case .reconciled = reconciling.purgeAll() else {
            return XCTFail("setup: expected a reconciled purge")
        }
        guard case .known = reconciling.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("after a reconciled purge the owner is readable and not held")
        }
        let unreadableIntent = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            intentDiscovery: { url in
                url.lastPathComponent == "revocation.intent" ? .failure : VoiceSharingUploadQueue.statKind(of: url)
            })
        guard case .unknownCoverage = unreadableIntent.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("an unreadable intent is unknown coverage, never a revocation claim")
        }
    }
}


// MARK: - A "future" admission instant that is really the same instant (epoch investigation)

/// The served set and the legacy path must agree about the same disk. An entry whose `created.at`
/// reads slightly AHEAD of the reader's clock (two clocks bracketing one write, or an injected test
/// clock) previously scored a NEGATIVE age, so it vanished from `readyEntriesReportingUnknownCoverage`
/// and from the count while `readyEntries()` still reported it — which surfaced as a full-suite
/// failure where the scheduler saw a ready entry and then found nothing to serve.
final class VoiceSharingAgeBoundAgreementTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seedEntry(_ queue: VoiceSharingUploadQueue) throws -> VoiceSharingUploadQueue.Entry {
        let samples: [Float] = [0, 0.25]
        let event = VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(),
            enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: samples, isGateControl: false)
        let provenance = VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
            models: .init(vad: nil, wakeword: nil, asr: nil, translation: nil, router: nil),
            conversionVersion: "v1")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event, provenance: provenance, observations: [:])
        let entry = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
        try queue.finalize(entry)
        return entry
    }

    /// An admission instant a few seconds AHEAD of the reader is still a live entry: both paths must
    /// report it, and the discovery must not exclude it for being "from the future".
    func test_anInstantSlightlyAheadOfTheReaderIsStillServedByBothPaths() throws {
        let writer = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let entry = try seedEntry(writer)
        // Rewrite the immutable instant 5s AHEAD, as a fast writer clock would leave it.
        let created = root.appendingPathComponent(entry.name, isDirectory: true)
            .appendingPathComponent("created.at")
        try String(Date().timeIntervalSince1970 + 5).write(
            to: created, atomically: true, encoding: .utf8)

        let reader = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(reader.readyEntries().count, 1, "the legacy path still sees it")
        guard case .known(let ready) = reader.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage must stay known for a readable entry")
        }
        XCTAssertEqual(ready.count, 1,
                       "and the discovery must AGREE: a few seconds of clock disagreement is not "
                       + "a reason to drop a live entry. Diag: \(reader.lastDiscoveryDiagnostic)")
    }

    /// The skew protection still holds: an instant meaningfully in the future is not fresh.
    func test_anInstantFarInTheFutureIsNotTreatedAsFresh() throws {
        let writer = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let entry = try seedEntry(writer)
        let created = root.appendingPathComponent(entry.name, isDirectory: true)
            .appendingPathComponent("created.at")
        try String(Date().timeIntervalSince1970 + 3600).write(
            to: created, atomically: true, encoding: .utf8)

        let reader = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        guard case .known(let ready) = reader.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage stays known")
        }
        XCTAssertTrue(ready.isEmpty,
                      "an hour in the future is skew, not freshness — it must not serve")
    }

    /// The normal case is unchanged: an entry written and read by the same clock serves normally.
    func test_anOrdinaryEntryIsServedByBothPaths() throws {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        _ = try seedEntry(queue)
        XCTAssertEqual(queue.readyEntries().count, 1)
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage stays known")
        }
        XCTAssertEqual(ready.count, 1)
    }
}
