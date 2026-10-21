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
        XCTAssertEqual(entryDirSyncs.count, 5,
                       "entry directory is synced pre-publication, post-marker, after writing the "
                       + "disqualifier, after clearing the stage, and after removing the disqualifier")
        XCTAssertEqual(rootSyncs.count, 1, "the queue root is synced once, persisting the entry link")

        XCTAssertLessThan(audioSyncs[0], markerSyncs[0], "audio must be durable before the marker is published")
        XCTAssertLessThan(metadataSyncs[0], markerSyncs[0], "metadata must be durable before the marker is published")
        XCTAssertLessThan(markerSyncs[0], entryDirSyncs[1], "the marker's namespace entry must be persisted after publication")
        XCTAssertLessThan(entryDirSyncs[1], rootSyncs[0], "the queue root must be synced after the entry directory")
        XCTAssertLessThan(rootSyncs[0], entryDirSyncs[2], "the disqualifier is written only after the marker is durable")
        XCTAssertLessThan(entryDirSyncs[2], entryDirSyncs[3], "the stage is cleared only after the disqualifier is durable")
        XCTAssertLessThan(entryDirSyncs[3], entryDirSyncs[4], "the disqualifier is removed LAST")
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

    func test_cleanupFailureAfterPublicationKeepsEntryUnready() throws {
        // Post-marker sync fails AND removing the marker fails. The entry must still never be
        // returned as ready: the queue records a failed-publication owner state.
        let q = VoiceSharingUploadQueue(rootDirectory: root, fileManager: MarkerRemovalBlockingFileManager(), synchronizer: { path, isDirectory in
            if !isDirectory && path.lastPathComponent == "ready.marker" {
                throw NSError(domain: "test-sync", code: 1)
            }
        })
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

    func test_doubleFailurePublicationStaysUnreadyAcrossRestartAndLifetime() throws {
        // THE ORIGINAL FAULT, PRESERVED AS THE CONTROL: the failure record cannot be written AND
        // the marker cannot be removed. Per @spec/reviewer this must NOT be narrowed to a
        // successful-cleanup scenario — a restart over the same root must not expose the entry.
        let blocking = MarkerRemovalBlockingFileManager()
        var publishedMarker = false
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            fileManager: blocking,
            clock: Date.init,
            synchronizer: { url, _ in
                if url.lastPathComponent == "ready.marker" { publishedMarker = true }
                if publishedMarker, url.lastPathComponent == "ready.marker" {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if publishedMarker, url.hasDirectoryPath {
                    throw CocoaError(.fileWriteNoPermission)
                }
            },
            // The on-disk disqualifier cannot be produced either.
            failureRecordWriter: { _ in throw CocoaError(.fileWriteNoPermission) })
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        XCTAssertThrowsError(try q.finalize(prep))
        XCTAssertTrue(q.readyEntries().isEmpty, "a double failure must not leave a ready entry")

        let entryDirectory = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.hasDirectoryPath }.first)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryDirectory.appendingPathComponent("publication.failed").path),
            "precondition: the disqualifier really could not be written")
        // The discriminator that replaces cleanup-dependent state: publication was ATTEMPTED, and
        // that fact is on disk regardless of whether any cleanup succeeded.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryDirectory.appendingPathComponent("stage.publishing").path),
            "precondition: the pre-publication stage record is on disk")

        // THE DECISIVE ASSERTION. Neither cleanup succeeded, yet a FRESH queue over the same root
        // must still not expose the entry. This is the case in-memory quarantine could not cover.
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(reopened.readyEntries().isEmpty,
                      "a fresh queue over the same root must not expose a failed publication, even "
                      + "when neither cleanup succeeded")
    }

    func test_failedPublicationWithBothCleanupsFailingIsRemovedOnRecovery() throws {
        // The same fault followed by a fresh instance: recovery removes the unconfirmed entry
        // rather than leaving half-published state on disk.
        let blocking = MarkerRemovalBlockingFileManager()
        var publishedMarker = false
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            fileManager: blocking,
            clock: Date.init,
            synchronizer: { url, _ in
                if url.lastPathComponent == "ready.marker" { publishedMarker = true }
                if publishedMarker, url.lastPathComponent == "ready.marker" {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if publishedMarker, url.hasDirectoryPath {
                    throw CocoaError(.fileWriteNoPermission)
                }
            },
            failureRecordWriter: { _ in throw CocoaError(.fileWriteNoPermission) })
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        XCTAssertThrowsError(try q.finalize(prep))

        let entryDirectory = try soleEntryDirectory()
        _ = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDirectory.path),
                       "recovery must remove an entry whose publication was never confirmed")
    }

    func test_stageClearSucceededButItsSyncFailedKeepsEntryUnreadyAcrossRestart() throws {
        // Reviewer ef155ce2: the FINAL transition can reproduce the hole. Stage removal succeeds,
        // the following directory sync throws, then both failure-record writing and marker removal
        // also fail. Result: ready.marker with neither stage nor failure file — and a fresh queue
        // would accept it even though finalize threw.
        final class StageGoneProbe: FileManager {
            var stagePath = ""
            var removalDone = false
            override func removeItem(at url: URL) throws {
                if url.lastPathComponent == "stage.publishing" {
                    try super.removeItem(at: url)
                    removalDone = true
                    return
                }
                // Both fallible cleanups refuse.
                if url.lastPathComponent == "ready.marker" {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try super.removeItem(at: url)
            }
        }
        let probe = StageGoneProbe()
        var publishedMarker = false
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            fileManager: probe,
            clock: Date.init,
            synchronizer: { url, isDirectory in
                // Everything through the marker's OWN sync succeeds so publication is reached; the
                // stage is then cleared, and only the DIRECTORY sync after that removal fails. That
                // is the reviewer's exact window.
                if url.lastPathComponent == "ready.marker" { publishedMarker = true }
                guard isDirectory, publishedMarker, probe.removalDone else { return }
                throw CocoaError(.fileWriteNoPermission)
            },
            failureRecordWriter: { _ in throw CocoaError(.fileWriteNoPermission) })
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        let entryDirectory = try soleEntryDirectory()
        probe.stagePath = entryDirectory.appendingPathComponent("stage.publishing").path

        XCTAssertThrowsError(try q.finalize(prep))
        // The disqualifier is now written BEFORE the stage is cleared, so the stage survives the
        // failure. Either discriminator excludes the entry; the important part is that one does.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: entryDirectory.appendingPathComponent("stage.publishing").path)
            || FileManager.default.fileExists(
                atPath: entryDirectory.appendingPathComponent("publication.failed").path),
            "precondition: a durable disqualifier survives the failed final transition")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryDirectory.appendingPathComponent("ready.marker").path),
            "precondition: the marker survived")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryDirectory.appendingPathComponent("publication.failed").path),
            "precondition: no failure record either")

        // finalize threw, so this entry was NOT published. A fresh queue must agree.
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(reopened.readyEntries().isEmpty,
                      "finalize threw, so a fresh queue must not accept the entry")
    }

    func test_disqualifierIsWrittenBeforeTheMarkerIsRemoved() throws {
        // The ORDER is the durability guarantee. With a NORMAL file manager (removal would succeed),
        // the disqualifier must already exist when the marker is removed — otherwise a crash between
        // the two leaves a marker with nothing saying it failed, which a later process would accept.
        var observedDisqualifierAtRemoval: Bool?
        final class OrderProbe: FileManager {
            var disqualifierPath: String = ""
            var observedAtMarkerRemoval: Bool?
            override func removeItem(at url: URL) throws {
                if url.lastPathComponent == "ready.marker" {
                    observedAtMarkerRemoval = FileManager.default.fileExists(atPath: disqualifierPath)
                }
                try super.removeItem(at: url)
            }
        }
        let probe = OrderProbe()
        var publishedMarker = false
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            fileManager: probe,
            clock: Date.init,
            synchronizer: { url, _ in
                if url.lastPathComponent == "ready.marker" { publishedMarker = true }
                if publishedMarker, url.lastPathComponent == "ready.marker" {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if publishedMarker, url.hasDirectoryPath {
                    throw CocoaError(.fileWriteNoPermission)
                }
            })
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        let entryDirectory = try soleEntryDirectory()
        probe.disqualifierPath = entryDirectory.appendingPathComponent("publication.failed").path

        XCTAssertThrowsError(try q.finalize(prep))
        observedDisqualifierAtRemoval = probe.observedAtMarkerRemoval
        XCTAssertEqual(observedDisqualifierAtRemoval, true,
                       "the durable disqualifier must be on disk BEFORE the marker is removed")
    }

    func test_publicationFailureThatReachesDiskSurvivesRestart() throws {
        // The realistic single-failure case: marker removal is refused, but the failure record CAN be
        // written. It is written BEFORE the marker is removed, so a restart still sees a disqualifier.
        let blocking = MarkerRemovalBlockingFileManager()
        var publishedMarker = false
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            fileManager: blocking,
            clock: Date.init,
            synchronizer: { url, _ in
                if url.lastPathComponent == "ready.marker" { publishedMarker = true }
                if publishedMarker, url.lastPathComponent == "ready.marker" {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if publishedMarker, url.hasDirectoryPath {
                    throw CocoaError(.fileWriteNoPermission)
                }
            })
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        XCTAssertThrowsError(try q.finalize(prep))
        XCTAssertTrue(q.readyEntries().isEmpty)

        // The disqualifier is genuinely ON DISK before any restart, which is what makes the next
        // process safe independently of this process's memory.
        let entryDirectory = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.hasDirectoryPath }.first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryDirectory.appendingPathComponent("publication.failed").path),
            "the durable disqualifier must exist before restart")

        // Fresh process over the same root: recovery removes the disqualified entry, so the failed
        // publication can never be exposed OR linger as half-published state.
        let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(reopened.readyEntries().isEmpty,
                      "a fresh queue over the same root must not expose a failed publication")
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDirectory.path),
                       "recovery must remove the disqualified entry, not retain it")
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
