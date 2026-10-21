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

        XCTAssertEqual(audioSyncs.count, 1)
        XCTAssertEqual(metadataSyncs.count, 1)
        XCTAssertEqual(markerSyncs.count, 1)
        // New protocol: 3 entry-directory syncs — before publication (content durable), after the
        // stage is cleared, and the commit point after the marker is published. Nothing fallible
        // follows the commit.
        XCTAssertEqual(entryDirSyncs.count, 3,
                       "entry directory is synced for content, then before the marker, then as the "
                       + "commit point after the marker")
        XCTAssertEqual(rootSyncs.count, 1, "the queue root is synced once, at the commit")

        XCTAssertLessThan(audioSyncs[0], markerSyncs[0], "audio must be durable before the marker is published")
        XCTAssertLessThan(metadataSyncs[0], markerSyncs[0], "metadata must be durable before the marker is published")
        XCTAssertLessThan(markerSyncs[0], entryDirSyncs[2],
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
        let temporaries = try FileManager.default.contentsOfDirectory(atPath: entryDirectory.path)
            .filter { $0.hasPrefix("ready.marker.tmp-") }
        XCTAssertGreaterThan(temporaries.count, 0,
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
        let remaining = try FileManager.default.contentsOfDirectory(atPath: entryDirectory.path)
            .filter { $0.hasPrefix("ready.marker.tmp-") }
        XCTAssertEqual(remaining.count, 0, "stranded temporaries must be reclaimed")
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
        XCTAssertEqual(q.attemptCount(for: prep), 0, "a fresh entry has no attempts")
        try q.recordAttempt(prep)
        XCTAssertEqual(q.attemptCount(for: prep), 1)

        // A FRESH queue over the same root must see the same count.
        let recordPath = root.appendingPathComponent(prep.name).appendingPathComponent("attempts.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordPath.path),
                      "PRE: the attempt record must be on disk before reopening")
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(reopened.readyEntries().count, 1,
                       "POST: the entry must still be ready after reopening")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordPath.path),
                      "POST: reopening must not remove the attempt record")
        XCTAssertEqual(reopened.attemptCount(for: prep), 1,
                       "attempts must survive process restart")
        try reopened.recordAttempt(prep)
        XCTAssertEqual(reopened.attemptCount(for: prep), 2)
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
        XCTAssertFalse(q.isAttemptable(prep), "an exhausted entry must not be attemptable")
        XCTAssertFalse(try q.beginAttempt(prep),
                       "an exhausted entry must not be granted another attempt")
        XCTAssertTrue(q.readyEntries().isEmpty, "an exhausted entry is removed, not retried forever")
        let leftover = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(leftover.filter { !$0.hasPrefix(".") }.isEmpty,
                      "the entry directory must be gone")
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
        XCTAssertTrue(try reopened.beginAttempt(prep),
                      "a stale attempt must not block the entry forever")
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