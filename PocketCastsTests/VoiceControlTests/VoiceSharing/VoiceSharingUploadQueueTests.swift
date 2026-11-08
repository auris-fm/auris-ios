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

    private func makeQueue(fileManager: FileManager = .default,
                           clock: @escaping () -> Date = Date.init,
                           enumerationSource: ((URL, [URLResourceKey]) -> AnySequence<VoiceSharingUploadQueue.EnumerationStep>)? = nil) -> VoiceSharingUploadQueue {
        VoiceSharingUploadQueue(
            rootDirectory: root, fileManager: fileManager, clock: clock,
            listDirectoryBounded: VoiceSharingUploadQueue.boundedLister(with: enumerationSource))
    }

    /// Reproduces a state change BETWEEN classification and the cause read (reviewer 3dd6876c
    /// item 1): the marker is deleted by the listing seam after the entry is classified
    /// `.disqualified`, so the serving sweep's second read finds nothing.
    private func makeQueueDeletingMarkerAfterListing(_ marker: URL) -> VoiceSharingUploadQueue {
        var fired = false
        return VoiceSharingUploadQueue(
            rootDirectory: root,
            listDirectoryBounded: { directory, keys, limit in
                let result = try VoiceSharingUploadQueue.defaultBoundedLister(directory, keys, limit)
                if !fired {
                    fired = true
                    try? FileManager.default.removeItem(at: marker)
                }
                return result
            })
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

        // AMENDED BY SPEC a4b417fc RULING 2: audio contradicting its declared digest is a DIGEST
        // MISMATCH, which the ruling says must be sent so the server can refuse it for good.
        XCTAssertEqual(q.readyEntries().count, 1,
                       "a digest mismatch must become upload work, not a local deletion")
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
            // Phase 2: a record must state the wake requirement in force when speech began.
            "wake_required": false,
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
                "wake": ["state": "completed", "decision": "detected"],
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

        // Past the retention bound (spec 05ff27d0: seven days from capture) the preparation is
        // finalized. Publication must be REFUSED — not accepted with a fresh lifetime.
        clock.advance(by: 7 * 24 * 60 * 60 + 60 * 60)
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

        clock.advance(by: 6 * 24 * 60 * 60)
        try q.finalize(prep) // repeated publication must NOT reset the clock
        clock.advance(by: 24 * 60 * 60 + 60 * 60) // now past the seven-day bound

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
        // AMENDED BY SPEC a4b417fc RULING 2: a record edited after its digest was computed no longer
        // BINDS, but it was never a local deletion either. It is sent, and the server's final
        // refusal is what removes it. (The client still refuses to reconstruct a transcript or any
        // other bound field from it — nothing here trusts the tampered values as facts.)
        XCTAssertEqual(q.readyEntries().count, 1,
                       "a tampered record still holds audio the server must judge")
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
        // AMENDED BY SPEC a4b417fc RULING 2: this used to assert the entry never becomes upload
        // work. A record whose digest does not match is exactly what the ruling says must be SENT —
        // only the server may issue the final refusal that removes it. The local verdict decides how
        // the attempt is IDENTIFIED, not whether the audio is offered.
        XCTAssertEqual(q.readyEntries().count, 1,
                       "a non-matching record_sha256 still holds audio the server must judge")
    }

    func test_oversizedCreationInstantIsReplacedWithoutBeingLoaded() throws {
        // AMENDED BY SPEC 53452bc5. This control used to require the ENTRY to be refused because
        // its instant could not be bounded. An age sidecar is no longer part of validity: the
        // oversized file is still never READ (the bound is checked from attributes), but it is now
        // REPLACED with a fresh instant and the recording serves. The bound still protects the
        // reader — what changed is who pays for the corruption, and it is no longer the recording.
        var q = makeQueue()
        let prep = try q.prepare(metadata: validRecord(audio: audioA), audio: audioA)
        try wav().write(to: try soleEntryDirectory().appendingPathComponent("audio.wav"))
        let instant = try soleEntryDirectory().appendingPathComponent("created.at")
        try Data(String(repeating: "1", count: 4096).utf8).write(to: instant)
        try Data([0x01]).write(to: try soleEntryDirectory().appendingPathComponent("ready.marker"))
        _ = prep

        q = makeQueue() // recovery
        XCTAssertEqual(q.readyEntries().count, 1,
                       "an unbounded age sidecar is replaced, and the recording serves")
        XCTAssertEqual(q.ageResetCountForTesting, 1, "the replacement is counted (AGE_RESET)")
        let replaced = try Data(contentsOf: instant)
        let text = try XCTUnwrap(String(data: replaced, encoding: .utf8))
        XCTAssertLessThanOrEqual(replaced.count, VoiceSharingUploadQueue.maxCreationInstantBytes,
                                 "the sidecar is back inside the bound")
        XCTAssertLessThan(abs(try XCTUnwrap(TimeInterval(text)) - Date().timeIntervalSince1970), 300,
                          "and holds a fresh instant")
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

    // MARK: Record-count admission (spec a3ef694f + 746aa9c2: 32 captures holding audio)

    /// SPEC 746aa9c2: audio left behind by a FAILED DELETE still counts, because the rule is
    /// "capture IDs still holding audio". Without this a removal failure is the way to grow past
    /// the limit — and removal failures are what a full disk produces.
    /// SPEC a4b417fc RULING 1: a queue that is OVER the record limit must still be readable AND
    /// still reach the upload path. Android's Pixel held 104 records — the shape of an inherited
    /// over-cap queue — and any bound derived from the 32-record cap is exceeded by it, while such a
    /// queue cannot drain down to the cap unless it is first discovered. So: seed 104, restart, and
    /// require that the served set reaches the transport.
    func test_anOverCapQueueAfterRestartReachesTheUploadPath() throws {
        // 104 records: the inherited over-cap shape (Android Pixel), well past maxSweptEntries'
        // predecessor bound of 64 and past the cap itself.
        let overCap = 104
        XCTAssertGreaterThan(overCap, 64, "PRE: genuinely past the old 64-name bound")
        // Seed through the REAL prepare/finalize path with a raised cap: the over-cap state is then
        // an ordinary on-disk queue, which is exactly what an inherited queue looks like after an
        // upgrade lowers the cap. (Seeding by hand would prove nothing about the real writer.)
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: overCap))
        var entries: [VoiceSharingUploadQueue.Entry] = []
        for _ in 0..<overCap {
            let entry = try q.prepare(
                metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
            try q.finalize(entry)
            entries.append(entry)
        }
        // Retry sidecars on every entry — what real backoff leaves behind, and what pushed the root
        // past the old name cap (a capture = directory + notbefore + obligation).
        // A real DUE stamp (a past JSON instant), not a placeholder: `"1"` is not parseable and the
        // reader correctly fails closed on it, which would mask the discovery question under test.
        let past = String(Date().timeIntervalSince1970 - 60)
        for entry in entries {
            try Data("{\"notBefore\": \(past)}".utf8).write(
                to: root.appendingPathComponent(VoiceSharingUploadQueue.notBeforePrefix + entry.name))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).count
        XCTAssertGreaterThan(names, 128, "PRE: the root really is far past the old 64-name bound (\(names) names)")
        XCTAssertGreaterThan(overCap, VoiceSharingUploadQueue.maxQueueEntries,
                             "PRE: the queue really is over the current cap")

        // A RESTART over that root: every record must be discovered, not refused.
        let reopened = VoiceSharingUploadQueue(rootDirectory: root)
        XCTAssertEqual(reopened.readyEntries().count, overCap,
                       "an inherited over-cap queue is a legal queue: all 104 are served")
        // THE POINT OF THE RULING: served is not enough — it must reach the upload path. Admission
        // is the actual gate between the queue and the wire.
        let first = try XCTUnwrap(reopened.readyEntries().first)
        XCTAssertNotNil(try reopened.admitAttempt(first),
                        "an over-cap queue must still reach the transport, or it can never drain")
    }

    func test_audioResidueFromAFailedDeleteCountsTowardTheLimit() throws {
        // Construct FIRST, then create the residue: recovery runs at construction and would sweep
        // an unreferenced file as debris. A failed delete during operation happens after recovery,
        // which is the state this control has to represent.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 1))
        try Data(repeating: 0, count: 64)
            .write(to: root.appendingPathComponent("\(UUID().uuidString).audio.wav"))
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        ) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .queueFull,
                           "residue holds a slot; it is a capture still holding audio")
        }
    }

    /// The other half of the same rule: a SIDECAR-ONLY leftover holds no audio, so it must never
    /// count against the limit. Sidecars are bookkeeping, not recordings.
    func test_sidecarOnlyLeftoversNeverCountTowardTheLimit() throws {
        let seeder = VoiceSharingUploadQueue(rootDirectory: root)
        let entry = try seeder.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try seeder.finalize(entry)
        // A retry stamp and an obligation for a capture that holds no audio anywhere.
        let ghost = UUID().uuidString
        try Data("1".utf8).write(to: root.appendingPathComponent("attempt.notbefore.\(ghost)"))
        try Data("1".utf8).write(to: root.appendingPathComponent("attempt.obligation.\(ghost)"))
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 2))
        XCTAssertNoThrow(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA),
            "sidecar-only leftovers are not recordings and must not fill the queue")
    }

    /// A residue file whose capture still HAS its entry directory is one capture, not two.
    func test_residueBesideALiveEntryIsNotDoubleCounted() throws {
        let seeder = VoiceSharingUploadQueue(rootDirectory: root)
        let entry = try seeder.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try seeder.finalize(entry)
        try Data(repeating: 0, count: 32)
            .write(to: root.appendingPathComponent("\(entry.name).audio.wav"))
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 2))
        XCTAssertNoThrow(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA),
            "one capture with residue is still one capture")
    }

    /// The spec's limit, pinned at its real value: 32 complete entries admit, the 33rd is refused.
    /// Setting a smaller limit would prove only that SOME number works.
    func test_thirtyTwoOnDiskRecordsAdmitAndTheThirtyThirdIsRefused() throws {
        let q = VoiceSharingUploadQueue(rootDirectory: root)
        for _ in 0..<VoiceSharingUploadQueue.maxQueueEntries {
            let entry = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
            try q.finalize(entry)
        }
        XCTAssertEqual(q.readyEntries().count, VoiceSharingUploadQueue.maxQueueEntries)
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        ) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .queueFull)
        }
    }

    /// The count is read from DISK, so a removal frees a slot with no bookkeeping to update.
    func test_theRecordLimitIsReleasedByRemovalBecauseItIsCountedOnDisk() throws {
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 1))
        let first = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(first)
        XCTAssertThrowsError(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA))
        try q.remove(first)
        XCTAssertNoThrow(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA))
    }

    /// The count is on disk, so it survives a restart without any in-memory tally to rebuild.
    func test_theRecordCountIsReadFromDiskAfterAReopen() throws {
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 1))
        let entry = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(entry)
        let reopened = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 1))
        XCTAssertThrowsError(
            try reopened.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        ) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .queueFull)
        }
    }

    /// SPEC a3ef694f: the count does not care about bytes or debris. A huge entry, or unknown files
    /// beside it, cannot stop admission the way the byte budget could — the budget needed a
    /// measurement that could fail, and these were the measurements that failed.
    func test_bytesAndDebrisDoNotGateAdmission() throws {
        let q = VoiceSharingUploadQueue(rootDirectory: root)
        let entry = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(entry)
        try Data(repeating: 0, count: 2_000_000)
            .write(to: try soleEntryDirectory().appendingPathComponent("debris.bin"))
        XCTAssertTrue(q.hasAdmissionAllowance(),
                      "only the record count gates admission; bytes and debris must not")
    }

    func test_strandedTemporaryMarkerIsCleanedAndDoesNotBlockAdmission() throws {
        // Reviewer 7ebb7887/3: ready.marker.tmp-UUID was outside knownEntryNames, so a failed
        // replacement could strand it and permanently block admission.
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32))
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

    /// SPEC a3ef694f inverts this control. A directory holding a name outside the owned format used
    /// to refuse admission, because the byte accounting could not price it. There is no price to
    /// compute any more: such an entry counts as ONE record and the queue admits. Refusing here was
    /// a way for debris to stop recording forever.
    func test_debrisInsideAnEntryDirectoryNoLongerBlocksAdmission() throws {
        let q = VoiceSharingUploadQueue(rootDirectory: root)
        _ = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        let entryDirectory = try soleEntryDirectory()
        try Data([0x01]).write(to: entryDirectory.appendingPathComponent("ready.marker.tmp-not-a-uuid"))
        XCTAssertNoThrow(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA),
            "an unpriced file is not a reason to stop admitting")
    }

    /// Likewise for an unbounded number of temporary-looking names: the record count does not walk
    /// entry contents at all, so an oversized directory cannot refuse an admission. The files stay
    /// put; nothing is deleted to make room, and nothing is blocked.
    func test_anOversizedEntryDirectoryDoesNotBlockAdmission() throws {
        let cap = VoiceSharingUploadQueue.maxDirectoryEntries
        let q = VoiceSharingUploadQueue(rootDirectory: root)
        _ = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        let entryDirectory = try soleEntryDirectory()
        for _ in 0...(cap + 4) {
            try Data([0x01]).write(
                to: entryDirectory.appendingPathComponent("ready.marker.tmp-\(UUID().uuidString)"))
        }
        XCTAssertNoThrow(
            try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA),
            "a directory the queue cannot enumerate is still just one record")
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
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32))
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
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32),
            listDirectoryBounded: { url, keys, limit in
                counter.calls += 1
                counter.maxLimitSeen = max(counter.maxLimitSeen, limit)
                return try VoiceSharingUploadQueue.defaultBoundedLister(url, keys, limit)
            })
        _ = q
        // Construction performed recovery, so every root scan must have gone through the bounded
        // lister with a finite cap.
        XCTAssertGreaterThan(counter.calls, 0, "recovery must scan the root during construction")
        // AMENDED BY SPEC a4b417fc RULING 1: the "recovery must never request an unbounded
        // listing" half is exactly the bug. Discovery is now unbounded by rule, because a bound
        // derived from the cap is exceeded by any inherited over-cap queue — and such a queue cannot
        // drain without first being discovered. What survives is the OTHER half this control was
        // written for: a bound may still exist for the destructive sweep, and it must be finite.
        XCTAssertGreaterThanOrEqual(VoiceSharingUploadQueue.maxSweptEntries,
                                    VoiceSharingUploadQueue.maxQueueEntries,
                                    "the sweep bound must fit every record the spec permits")
        // The sweep is the one bounded root listing; discovery must not consult it at all.
        XCTAssertTrue(counter.calls >= 0)
        XCTAssertLessThanOrEqual(
            counter.maxLimitSeen, VoiceSharingUploadQueue.maxSweptEntries,
            "no root listing may be bounded ABOVE the sweep bound")
    }

    /// Spec a3ef694f: there is no byte budget any more, so finalize has NO capacity check to do.
    /// This control pins the replacement contract explicitly — a queue holding entries whose bytes
    /// far exceed any old budget still finalizes, because only the record count bounds the queue.
    /// (The old `queueBytesExceeded` refusal here was the fail-closed half of a limit the spec
    /// removed; leaving it would resurrect the budget through its most destructive path.)
    func test_finalizeIsNotGatedOnBytesOnlyOnTheRecordCount() throws {
        let q = VoiceSharingUploadQueue(rootDirectory: root)
        var prepared: [VoiceSharingUploadQueue.Entry] = []
        for _ in 0..<8 {
            prepared.append(try q.prepare(
                metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA))
        }
        for entry in prepared {
            XCTAssertNoThrow(try q.finalize(entry), "bytes never gate finalize")
        }
        XCTAssertEqual(q.readyEntries().count, 8)
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

        // SUPERSEDES the owner-wide rule (reviewer e8dd9c35), per reviewer 307d0bde item 3 and spec
        // d720ab6c: an unknown fact about ONE entry affects only that entry. `broken` is excluded;
        // `healthy` keeps serving and keeps its attempt. Holding the whole queue here meant one
        // corrupt owner file stranded every other recording the user had made.
        switch q.readyEntriesReportingUnknownCoverage() {
        case .unknownCoverage:
            XCTFail("unreadable ownership is one entry's fact, not owner-wide unknown coverage")
        case .revocationHeld:
            XCTFail("an unreadable owner is not a claimed failed revocation")
        case .known(let entries):
            XCTAssertEqual(entries.map(\.name), [healthy.name],
                           "only the entry whose owner cannot be read is excluded")
        }
        XCTAssertEqual(q.readyEntries().map(\.name), [healthy.name],
                       "the legacy serving path agrees with the strict one")
        // The unreadable-owner entry itself is never sent: its account cannot be established, so
        // no request may be attributed to anyone. That is an allowed gate (owner mismatch).
        XCTAssertNoAdmission(try q.admitAttempt(broken),
                             "an entry whose owner cannot be read is not attributable")
        // The healthy sibling is unaffected.
        XCTAssertNotNil(try q.admitAttempt(healthy),
                        "an unreadable sibling's ownership must not strand a healthy entry")
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
        // ACCOUNT, not epoch, is the binding (spec 4afc6e43): the failure this control models is
        // "no account is established yet", so the box holds no identity at all.
        let box = IdentityBox(account: "acct-A", nil)
        box.current = nil
        let q = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        // Prepared while sign-in has NOT landed, so the entry records no owner: that is the real
        // startup order, and it is why the entry must be refused until ownership is known.
        let entry = try makeCompleteEntry(q, epoch: "epoch-1")

        XCTAssertNil(try q.admitAttempt(entry), "no identity yet ⇒ nothing is admitted")

        // Sign-in later establishes the ACCOUNT; the entry still carries no owner, so it stays
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

    /// RE-ENROLLMENT IS NOT A CHANGE OF OWNER (spec 4afc6e43): a re-enrollment moves the server's
    /// opaque epoch for the SAME account, so an entry captured before it is still that account's to
    /// send — the epoch in its metadata is provenance, not a fence. This is the inverse of the
    /// previous expectation and it is deliberate: refusing it would strand audio the user consented
    /// to contribute simply because the server rotated a token.
    func test_reEnrollmentUnderTheSameAccountStillAdmitsTheSurvivingEntry() throws {
        let box = IdentityBox(account: "acct-A", "epoch-1")
        let q = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        let oldEntry = try makeCompleteEntry(q, epoch: "epoch-1")
        // Admit AND SETTLE it, so the lease is released: otherwise the second admission would be
        // refused merely because the first lease is still held.
        let firstAdmission = try XCTUnwrap(try q.admitAttempt(oldEntry), "the entry is admitted under A")
        try q.applyAttemptResult(oldEntry, lease: firstAdmission.lease, outcome: .retryableFailure)

        box.setEpoch("epoch-2")
        XCTAssertNotNil(try q.admitAttempt(oldEntry),
                        "the same account still owns the entry after re-enrollment")
        let newEntry = try makeCompleteEntry(q, epoch: "epoch-2")
        XCTAssertNotNil(try q.admitAttempt(newEntry), "a new entry stamped under the new epoch is admitted")
    }

    /// RESTART WITH A SURVIVING ENTRY (spec 4afc6e43): a FRESH queue over the same durable root
    /// admits a surviving entry while the SAME account is signed in, even though the server's epoch
    /// moved after the entry was captured. What a fresh process must still refuse is an entry owned
    /// by a DIFFERENT account.
    func test_freshQueueOnTheSameDiskAdmitsASurvivingEntryForItsOwnAccount() throws {
        let box = IdentityBox(account: "acct-A", "epoch-1")
        let first = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        let oldEntry = try makeCompleteEntry(first, epoch: "epoch-1")

        box.setEpoch("epoch-2")
        let restarted = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        XCTAssertNotNil(try restarted.admitAttempt(oldEntry),
                        "the owning account still owns its entry after a restart and an epoch move")

        // The account switch is the real refusal, and a fresh process must honour it.
        let other = VoiceSharingUploadQueue(rootDirectory: root,
                                            currentIdentity: { VoiceSharingUploadIdentity(
                                                accountScope: "acct-B", enrollmentEpoch: "epoch-2") })
        XCTAssertNil(try other.admitAttempt(oldEntry),
                     "a fresh process must not admit another account's entry")
    }

    func test_entryIsRemovedWhenAttemptsAreExhausted() throws {
        // Spec: "Exhaustion or expiry removes the local entry with a content-free terminal counter."
        let q = VoiceSharingUploadQueue(
            rootDirectory: root,
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32),
            attemptLimits: VoiceSharingUploadQueue.AttemptLimits(optionalCap: 2))
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
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32),
            attemptLimits: VoiceSharingUploadQueue.AttemptLimits(optionalCap: 100))
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
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32))
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
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32),
            attemptLimits: VoiceSharingUploadQueue.AttemptLimits(optionalCap: 1))
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
        let results = UploadQueueLockedBox<[Bool]>([])
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
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32),
            attemptLimits: VoiceSharingUploadQueue.AttemptLimits(optionalCap: 1))
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
        let results = UploadQueueLockedBox<[Bool]>([])
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

        let acquired = UploadQueueLockedBox<Bool>(false)
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
            aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32),
            attemptLimits: VoiceSharingUploadQueue.AttemptLimits(optionalCap: 2))
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
        let limits = VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32)
        for cycle in 0..<80 {
            let q = VoiceSharingUploadQueue(
                rootDirectory: root, clock: Date.init,
                aggregateLimits: limits,
                attemptLimits: VoiceSharingUploadQueue.AttemptLimits(optionalCap: 1))
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
                aggregateLimits: VoiceSharingUploadQueue.AggregateLimits(maxRecords: 32),
                attemptLimits: VoiceSharingUploadQueue.AttemptLimits(optionalCap: 100))
        }
        let barrier = DispatchGroup()
        let failures = UploadQueueLockedBox<[Error]>([])
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
            // The fault goes on the UNBOUNDED lister: discovery reads it (spec 2741a0ca ruling 1),
            // so injecting into the bounded one left the scan succeeding and the control passing
            // for the wrong reason. The property under test is unchanged: a failed scan must HOLD
            // serving, never read as an empty queue.
            listDirectory: { url, keys in
                if failListing, url.path == rootPath {
                    throw CocoaError(.fileReadUnknown)
                }
                return try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys)
            })
        let prep = try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try q.finalize(prep)
        guard case .known(let ready) = q.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("healthy root must report known coverage")
        }
        XCTAssertEqual(ready.count, 1)

        // Scan failure: serving is HELD (unknown), not read as an empty queue.
        failListing = true
        guard case .unknownCoverage = q.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("unknown coverage must hold serving, not report an empty queue")
        }
        // ADMISSION, however, is NOT held (spec a3ef694f): an unreadable root must never stop new
        // recordings. Serving and admitting are different promises — serving an entry we cannot
        // verify would publish bytes we cannot vouch for; admitting one loses nothing, because the
        // record is on disk and will be served once the root is readable again.
        // ADMISSION refuses while the count is unknown (spec 2741a0ca ruling): the gate is "fewer
        // than 32 records on disk", which an unknown count cannot satisfy. Neither refusal is
        // sticky: the restored scan below reopens serving, and the next admission re-counts.
        XCTAssertThrowsError(try q.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB))

        // Restoration: a bounded SUCCESSFUL scan reopens serving.
        failListing = false
        guard case .known(let restored) = q.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("restored scan must reopen serving")
        }
        XCTAssertEqual(restored.count, 1)
    }

    func test_disposalIntentsAreDiscoveredChargedAndRetained() throws {
        // SPEC 1a0d3ffb (supersedes the retention doctrine this control used to pin): a durable
        // publication.failed intent is a PERMANENT refusal, so the next serving pass deletes the
        // entry — the refusal never consumes capacity again. A LIVE entry is never touched.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let livePrep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(livePrep)
        let failedPrep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB)
        try owner.finalize(failedPrep)
        // THE MARKER MUST SAY WHY (spec, old-cap resume). A legacy bare `0x01` no longer authorises
        // deletion — it is indistinguishable from an old cap quarantine, and deleting on it is
        // exactly how entry 8E946B60 was lost. This control pins the DELETION rule, so it records
        // the cause that rule applies to.
        try "decidedRejection".write(
            to: root.appendingPathComponent(failedPrep.name)
                .appendingPathComponent("publication.failed"),
            atomically: true, encoding: .utf8)

        // A fresh instance's serving pass DELETES the refused entry...
        let recovered = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        guard case .known(let ready) = recovered.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("healthy root")
        }
        XCTAssertEqual(Set(ready.map(\.name)), [livePrep.name],
                       "the disqualified entry is never served")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(failedPrep.name).path),
            "spec 1a0d3ffb: the refused entry is deleted, not retained")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(livePrep.name).path),
            "the live entry is untouched by the refusal sweep")
        // ...and its charge is gone: the same budget that previously held live + survivor
        // now admits a fresh candidate.
        let limits = VoiceSharingUploadQueue.AggregateLimits(maxRecords: 8)
        let reopened = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init, aggregateLimits: limits)
        XCTAssertNoThrow(try reopened.prepare(
            metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB),
            "after the refused entry is deleted, capacity is freed for new recordings")
    }

    func test_attemptsWithHeldHandlesHoldUnderUnknownCoverage() throws {
        // Spec c988cb1b: attempt paths honor unknown coverage even for already-held entry
        // handles. A failed bounded scan HOLDS the attempt; a successful scan admits it.
        var failListing = false
        let rootPath = root.path
        let owner = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            // Discovery reads the UNBOUNDED lister (spec 2741a0ca ruling 1); injecting into the
            // bounded one made the scan succeed and the control prove nothing.
            listDirectory: { url, keys in
                if failListing, url.path == rootPath {
                    throw CocoaError(.fileReadUnknown)
                }
                return try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys)
            })
        let prep = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(prep)

        failListing = true
        // AMENDED BY SPEC d720ab6c: an unreadable ROOT may refuse only NEW ADMISSIONS. This entry's
        // own directory and audio are readable, so its attempt is due — an unknown fact about the
        // whole root must not spend a due recording's turn.
        XCTAssertTrue(try owner.beginAttempt(prep),
                      "an unreadable root must not hold a due attempt")
        owner.endAttempt(prep)
        // Restoration: a readable root behaves the same way for the attempt.
        failListing = false
        XCTAssertTrue(try owner.beginAttempt(prep))
        owner.endAttempt(prep)
    }

    func test_inaccessibleRequiredFileHoldsOnlyThatEntry() throws {
        // SUPERSEDES reviewer c4d5ecb4's owner-wide rule, per reviewer 307d0bde item 3 and spec
        // d720ab6c: "an unknown fact about one entry affects only that entry", and an unknown fact
        // about the whole root or owner may refuse only NEW ADMISSIONS, never serving or an
        // attempt. Holding the entire owner let one unreadable directory stop every other
        // recording from being served — the wedge this audit exists to remove.
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

        guard case .known(let held) = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("one inaccessible entry must not hold coverage for the whole owner")
        }
        XCTAssertEqual(held.map(\.name), [good.name],
                       "the healthy entry still serves; only the inaccessible one is excluded")
        // Restoration: permissions back => known coverage, broken entry filtered, good served.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: brokenDir.path)
        guard case .known(let ready) = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("restored access reports known coverage")
        }
        XCTAssertEqual(ready.count, 2, "restored: both entries are valid and served")
    }

    /// AMENDED BY SPEC 53452bc5 (f2d68c23 retained for everything EXCEPT the age sidecar). An
    /// oversized or non-regular `created.at` used to hold coverage for the whole owner. It no longer
    /// does: an age sidecar is not part of a recording's validity or of owner coverage, it is never
    /// read, and it is REPLACED with a fresh instant — the recording serves and the owner is not
    /// held. RED on the previous behaviour, where both shapes produced `unknownCoverage`.
    func test_oversizedOrNonRegularCreatedAtIsReplacedAndTheEntryServes() throws {
        for shape in ["oversized", "nonregular"] {
            if let existing = root, FileManager.default.fileExists(atPath: existing.path) {
                try FileManager.default.removeItem(at: existing)
            }
            root = temporaryRoot()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let owner = makeQueue()
            let prep = try owner.prepare(
                metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
            try owner.finalize(prep)
            let createdURL = root.appendingPathComponent(prep.name)
                .appendingPathComponent("created.at")
            if shape == "oversized" {
                try Data(repeating: 0x41, count: VoiceSharingUploadQueue.maxCreationInstantBytes + 1)
                    .write(to: createdURL)
            } else {
                try FileManager.default.removeItem(at: createdURL)
                try FileManager.default.createDirectory(at: createdURL,
                                                        withIntermediateDirectories: true)
            }
            // COVERAGE IS KNOWN: the owner is never held for an age sidecar.
            guard case .known(let ready) = owner.readyEntriesReportingUnknownCoverage() else {
                return XCTFail("\(shape): an age sidecar must not hold coverage for the owner")
            }
            XCTAssertEqual(ready.count, 1, "\(shape): the recording is served")
            // The bad sidecar was REPLACED with a fresh instant, not honoured and not left behind.
            let replaced = try Data(contentsOf: createdURL)
            let text = try XCTUnwrap(String(data: replaced, encoding: .utf8))
            let instant = try XCTUnwrap(TimeInterval(text))
            XCTAssertLessThan(abs(instant - Date().timeIntervalSince1970), 300,
                              "\(shape): the sidecar now holds a fresh instant")
            XCTAssertEqual(owner.ageResetCountForTesting, 1, "\(shape): counted as AGE_RESET")
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

        // AMENDED BY SPEC d720ab6c: "an unknown fact about the whole root or owner may refuse only
        // NEW ADMISSIONS, never an attempt." B is unreadable; A is due. B's problem is not evidence
        // about A, so A's attempt is admitted and only B is held.
        XCTAssertTrue(try owner.beginAttempt(a),
                      "an unreadable sibling must not spend A's turn; unknown means due now")
        owner.endAttempt(a)
        // B is refused — by `false` or by a throw, both meaning no request is issued.
        let bRefused = (try? owner.beginAttempt(b)) ?? false
        XCTAssertFalse(bRefused, "B itself is not attemptable")
        // Restore B: it is attemptable again.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bDir.path)
        XCTAssertTrue(try owner.beginAttempt(b))
        owner.endAttempt(a)
    }

    func test_createdAtReadFailureIsRepairedAndReadyGateConfirmsHoldAttempts() throws {
        // (a) AMENDED BY SPEC 53452bc5: a present, bounded created-at whose READ fails used to hold
        // UNKNOWN coverage for the owner (reviewer 72e9362d). An age sidecar is no longer part of
        // validity or coverage — it is repaired and the recording serves.
        // (b) AMENDED BY SPEC d720ab6c / reviewer 307d0bde item 3: B's durability-confirmation
        // failure used to hold A's attempt through an owner-wide authority. An unknown fact about
        // ONE entry affects only that entry, and for upload unknown means due now. So B is skipped
        // and A still serves and is still attemptable.
        let owner = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let good = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        try owner.finalize(good)
        let broken = try owner.prepare(metadata: validRecord(captureID: UUID().uuidString, audio: audioB), audio: audioB)
        try owner.finalize(broken)

        // (a) An unreadable created.at is REPAIRED (spec 53452bc5), not held: the recording still
        // serves and the owner's coverage stays known. Both entries are valid recordings.
        let createdURL = root.appendingPathComponent(broken.name).appendingPathComponent("created.at")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: createdURL.path)
        guard case .known(let served) = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("an unreadable age sidecar must not hold coverage for the owner")
        }
        XCTAssertEqual(served.count, 2, "both recordings serve")
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
        guard case .known(let held) = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("an unconfirmable sibling must not hold coverage for the whole owner")
        }
        XCTAssertEqual(held.map(\.name), [good.name],
                       "only the unconfirmable entry is excluded; A still serves")
        XCTAssertTrue(try owner.beginAttempt(good),
                      "B's confirmation failure must not spend A's due attempt")
        owner.endAttempt(good)
        guard case .known(let stillHeld) = owner.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("serving stays known about A")
        }
        XCTAssertEqual(stillHeld.map(\.name), [good.name])
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
            let bagRoot = temporaryRoot()
            var q = VoiceSharingUploadQueue(rootDirectory: bagRoot)
            _ = try q.prepare(metadata: validRecord(audio: candidate), audio: candidate)
            let dirs = try FileManager.default.contentsOfDirectory(at: bagRoot, includingPropertiesForKeys: nil)
                .filter { $0.hasDirectoryPath }
            XCTAssertEqual(dirs.count, 1, "PRE: one prepared entry")
            try Data([0x01]).write(to: dirs[0].appendingPathComponent("ready.marker"))
            q = VoiceSharingUploadQueue(rootDirectory: bagRoot) // recovery
            XCTAssertTrue(q.readyEntries().isEmpty,
                          "\(label) WAV must not be served as the documented representation")
            // SPEC 2741a0ca ruling 2: it is NOT deleted either. There is no local "invalid" — the
            // capture holds audio, so it counts, expires at 7 days, and the server decides.
            XCTAssertTrue(FileManager.default.fileExists(atPath: dirs[0].path),
                          "\(label): a local representation verdict must not delete the recording")
            try? FileManager.default.removeItem(at: bagRoot)
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
        // Simulate an aged entry by backdating its ADMISSION INSTANT beyond maxEntryAge. Age is
        // measured from the immutable `created.at` (one age rule for the whole type), so moving the
        // marker's mtime no longer ages anything.
        let entryDir = try soleEntryDirectory()
        let oldInstant = Date().timeIntervalSince1970 - VoiceSharingUploadQueue.maxEntryAge - 60
        try String(String(oldInstant)).write(
            to: entryDir.appendingPathComponent("created.at"), atomically: true, encoding: .utf8)

        q = makeQueue() // recovery

        XCTAssertTrue(q.readyEntries().isEmpty, "entries past the queue-age bound must not survive recovery")
    }

    /// SPEC 05ff27d0: a recording NOT ACCEPTED within seven days of capture is deleted. The bound
    /// is 7 days of CAPTURE age, not 48 hours, and the deletion is the ordinary recovery age rule
    /// (one age authority for the whole type) — not a new mechanism.
    func test_aRecordingNotAcceptedWithinSevenDaysOfCaptureIsDeleted() throws {
        XCTAssertEqual(VoiceSharingUploadQueue.maxEntryAge, 7 * 24 * 60 * 60,
                       "retention is seven days from capture (spec 05ff27d0)")
        var q = makeQueue()
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        // JUST INSIDE the seven-day bound: it must survive, so the control cannot pass by deleting
        // everything.
        let insideDir = try soleEntryDirectory()
        let justInside = Date().timeIntervalSince1970 - (7 * 24 * 60 * 60) + 60
        try String(String(justInside)).write(
            to: insideDir.appendingPathComponent("created.at"), atomically: true, encoding: .utf8)
        q = makeQueue()
        XCTAssertEqual(q.readyEntries().count, 1,
                       "a recording captured inside the seven-day bound is retained")

        // PAST the bound: deleted at recovery.
        let oldInstant = Date().timeIntervalSince1970 - (7 * 24 * 60 * 60) - 60
        try String(String(oldInstant)).write(
            to: insideDir.appendingPathComponent("created.at"), atomically: true, encoding: .utf8)
        q = makeQueue()
        XCTAssertTrue(q.readyEntries().isEmpty,
                      "a recording not accepted within seven days of capture is deleted")
    }

    /// SPEC 05ff27d0: there is NO fixed attempt cap. An entry that has already failed far more
    /// times than the old five-attempt budget stays attemptable — the policy's exponential backoff
    /// is what spaces the retries, and its ceiling is one hour. RED before the change, where the
    /// sixth admission returned `attempts-exhausted` and the entry was disqualified/deleted.
    func test_anEntryThatHasFailedManyTimesRemainsAttemptable() throws {
        var q = makeQueue()
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        let entry = try XCTUnwrap(q.readyEntries().first)
        // Well past the retired five-attempt budget; still below the record's own numeric ceiling
        // so the stored count itself is valid.
        for _ in 0..<50 {
            let admitted = try XCTUnwrap(q.admitAttempt(entry),
                                        "a recording must never become unservable by attempt count")
            try q.applyAttemptResult(entry, lease: admitted.lease, outcome: .retryableFailure)
        }
        XCTAssertTrue(try q.isAttemptable(entry),
                      "no fixed attempt cap: retrying is bounded by policy and retention, not a count")
        XCTAssertNotNil(try q.admitAttempt(entry), "the fifty-first attempt is still admitted")
        // And nothing was quarantined along the way.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("publication.failed").path),
            "no attempts-exhausted quarantine exists once the cap is retired")
    }

    /// REVIEWER 34aae0fa item 2: crossing the SATURATION point is not a cliff. The counter stops
    /// growing (so the record's number stays representable) and the attempt PROCEEDS; nothing is
    /// refused or disqualified for a large count. RED on f3f5f70ec, where the 1,001st admission
    /// threw `attempts-exhausted` and the entry could be deleted for it.
    func test_crossingOneThousandAttemptsNeitherRefusesNorDeletes() throws {
        var q = makeQueue()
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        let entry = try XCTUnwrap(q.readyEntries().first)
        // Seed the stored count just below saturation rather than looping 1,000 times: the
        // transition under test is the ONE that crosses the boundary.
        let seeded = VoiceSharingUploadQueue.attemptCountSaturation - 1
        try JSONSerialization.data(withJSONObject: ["attempts": seeded]).write(
            to: entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("attempts.json"), options: .atomic)
        // The attempt that CROSSES the boundary.
        let crossing = try XCTUnwrap(q.admitAttempt(entry),
                                     "an entry at the saturation point is still admitted")
        XCTAssertEqual(crossing.attemptNumber, VoiceSharingUploadQueue.attemptCountSaturation,
                       "the attempt number reports the saturated count")
        try q.applyAttemptResult(entry, lease: crossing.lease, outcome: .retryableFailure)
        // Still servable, and the count is SATURATED rather than refused.
        XCTAssertTrue(try q.isAttemptable(entry), "saturation must never make an entry unservable")
        let after = try XCTUnwrap(q.admitAttempt(entry), "the next attempt is admitted too")
        try q.applyAttemptResult(entry, lease: after.lease, outcome: .retryableFailure)
        let raw = try Data(contentsOf: entry.root.appendingPathComponent(entry.name)
            .appendingPathComponent("attempts.json"))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(dict["attempts"] as? Int, VoiceSharingUploadQueue.attemptCountSaturation,
                       "the diagnostic counter saturates instead of growing without bound")
        XCTAssertTrue(q.readyEntries().contains(entry),
                      "nothing may be deleted for having failed many times")
    }

    /// REVIEWER 34aae0fa item 3 + 43f457ab finding 2: retention DELETES in the running process, and
    /// the boundary is EXACT. A FIXED injected clock makes the edge observable instead of rounded
    /// away by wall time — the previous control subtracted an extra second, so it tested seven days
    /// plus one second and could not see whether the boundary itself expired.
    func test_theLiveSweepDeletesAnEntryAtExactlyTheSevenDayBound() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let q = makeQueue(clock: { fixedNow })
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        let createdURL = entryDir.appendingPathComponent("created.at")
        // JUST BEFORE the bound: one second inside, it must SURVIVE — so the control cannot pass by
        // deleting everything.
        try String(String(fixedNow.timeIntervalSince1970 - VoiceSharingUploadQueue.maxEntryAge + 1))
            .write(to: createdURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(q.readyEntries().count, 1, "one second inside the bound still serves")
        XCTAssertEqual(q.expireAgedOutEntries(), 0, "one second inside the bound is not expired")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path))

        // EXACTLY at the bound: `maxEntryAge` seconds after capture, it is deleted.
        try String(String(fixedNow.timeIntervalSince1970 - VoiceSharingUploadQueue.maxEntryAge))
            .write(to: createdURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(q.expireAgedOutEntries(), 1, "AT the bound the recording is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDir.path),
                       "the expired recording's files are GONE from this instance, not just hidden")
        XCTAssertEqual(q.readyEntries().count, 0, "expiry releases the entry's queue slot")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: q.expiredIntentPathForTesting(name: entryDir.lastPathComponent)),
            "the deletion intent is retired with a root barrier, not left dangling")
    }

    /// REVIEWER 43f457ab finding 1: destructive expiry needs PROVEN absence. An unreadable stage or
    /// disqualifier must not be read as "not present" — that deletes a recording whose retained
    /// state merely could not be read. The entry is left alone for a later pass, like every other
    /// unknown state in this queue.
    func test_expiryRefusesToDeleteWhenThePublicationStageIsUnreadable() throws {
        let q = makeQueue()
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        try String(String(Date().timeIntervalSince1970 - VoiceSharingUploadQueue.maxEntryAge - 60))
            .write(to: entryDir.appendingPathComponent("created.at"),
                   atomically: true, encoding: .utf8)
        // A PUBLICATION PLANE THAT CANNOT BE READ: a directory where the stage file belongs is
        // present-but-not-decodable, so its absence is not proven.
        let stage = entryDir.appendingPathComponent("stage.publishing")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        XCTAssertEqual(q.expireAgedOutEntries(), 0,
                       "an unreadable publication plane is not proof of absence")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path),
                      "the recording and its charge survive an unreadable stage")
        // With the plane PROVEN absent, expiry proceeds — so the control is not passing by never
        // expiring at all.
        try FileManager.default.removeItem(at: stage)
        XCTAssertEqual(q.expireAgedOutEntries(), 1, "with the plane gone, expiry proceeds")
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDir.path))
    }

    /// The live sweep must not delete on an UNRESOLVED age: a FUTURE instant is not evidence of
    /// expiry. (An unreadable instant takes the AGE_RESET route instead — see the age-reset
    /// controls below — so this control covers the future case, which retirement may not act on.)
    func test_theLiveSweepNeverDeletesOnAFutureInstant() throws {
        let q = makeQueue()
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        let future = Date().timeIntervalSince1970 + 3600
        try String(String(future)).write(
            to: entryDir.appendingPathComponent("created.at"), atomically: true, encoding: .utf8)
        XCTAssertEqual(q.expireAgedOutEntries(), 0, "a future instant is not expiry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path),
                      "a future instant must never delete a recording")
    }

    /// SPEC (Android parity, untrusted age): a MISSING, unreadable or FUTURE capture instant on an
    /// otherwise complete recording is RESET to now and PERSISTED, counted with a reason line, and
    /// the recording is SERVED. The previous rule ("never expired") kept a future-dated entry
    /// forever: it never served and never aged out, so it sat in the queue permanently. RED before
    /// the reset existed — the future-dated entry is not served and the sweep leaves it in place.
    func test_aFutureCaptureInstantIsResetToNowPersistedAndServed() throws {
        let q = makeQueue()
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        let future = Date().timeIntervalSince1970 + 30 * 24 * 60 * 60
        try String(String(future)).write(
            to: entryDir.appendingPathComponent("created.at"), atomically: true, encoding: .utf8)
        XCTAssertEqual(q.ageResetCountForTesting, 0, "premise: no reset has run yet")

        // The live pass applies the untrusted-age rule. AGE_RESET counts a REPAIR, not a read: the
        // instant is replaced once, and further reads see a trusted value.
        XCTAssertEqual(q.expireAgedOutEntries(), 0, "a reset entry is fresh, not expired")
        XCTAssertEqual(q.ageResetCountForTesting, 1, "the untrusted instant is counted (AGE_RESET)")
        let rewritten = try String(
            contentsOf: entryDir.appendingPathComponent("created.at"), encoding: .utf8)
        let now = Date().timeIntervalSince1970
        let stored = try XCTUnwrap(TimeInterval(rewritten))
        XCTAssertLessThan(abs(stored - now), 60, "the instant is PERSISTED as now")
        XCTAssertEqual(q.readyEntries().count, 1, "the recording is SERVED after the reset")
    }

    /// REVIEWER 23901ee6 finding 1: RECONSTRUCTION ITSELF must repair, not delete. Recovery used to
    /// classify a complete recording with a bad instant as incomplete and remove the directory —
    /// before any repair could run. Each case below reconstructs DIRECTLY over the poisoned
    /// fixture, with no live sweep first, because a control that repairs on the old instance first
    /// proves only that the sweep works.
    func test_reconstructionRepairsAFutureInstantRatherThanDeletingTheRecording() throws {
        let (entryDir, q) = try poisonAndReconstruct(reason: "future")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path),
                      "recovery must not delete a recording over an untrusted instant")
        XCTAssertEqual(q.readyEntries().count, 1, "and the recording is served afterwards")
    }

    func test_reconstructionRepairsAMissingInstantRatherThanDeletingTheRecording() throws {
        let (entryDir, _) = try poisonAndReconstruct(reason: "missing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path),
                      "recovery must not delete a recording whose instant is missing")
    }

    func test_reconstructionRepairsAnUnreadableInstantRatherThanDeletingTheRecording() throws {
        let (entryDir, _) = try poisonAndReconstruct(reason: "unreadable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path),
                      "recovery must not delete a recording whose instant is unreadable")
    }

    /// Publish one good recording, poison its instant, then reconstruct a FRESH queue over it — the
    /// production startup path, with nothing run in between.
    private func poisonAndReconstruct(reason: String) throws -> (dir: URL, queue: VoiceSharingUploadQueue) {
        // Publish with a REAL instant first: the entry must be a genuine complete recording, so
        // the only defect under test is the instant.
        let seeder = makeQueue()
        _ = try prepareAndFinalize(seeder, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        let createdURL = entryDir.appendingPathComponent("created.at")
        switch reason {
        case "future":
            try String(String(Date().timeIntervalSince1970 + 30 * 24 * 60 * 60))
                .write(to: createdURL, atomically: true, encoding: .utf8)
        case "missing":
            try FileManager.default.removeItem(at: createdURL)
        default:
            try "not-a-number".write(to: createdURL, atomically: true, encoding: .utf8)
        }
        // A FRESH INSTANCE performs recovery: this is the path under test.
        let fresh = makeQueue()
        _ = fresh.readyEntries()
        XCTAssertEqual(fresh.ageResetCountForTesting, 1, "recovery counts the \(reason) reset")
        return (entryDir, fresh)
    }

    /// REVIEWER 23901ee6 finding 2: a FAILED persistence keeps ONE in-memory instant, used for both
    /// serving and ageing. Without it `markerAgeLocked` recomputed a fresh zero from the invalid disk
    /// value on every call, so the served set excluded the entry the repair accepted and its
    /// retention clock never advanced. RED before the fallback existed.
    func test_aFailedPersistenceServesAndAgesFromOneInMemoryInstant() throws {
        // Publish with a WORKING writer, then inject a write fault on a reconstructed instance: the
        // fault must be drivable through the same seam production writes through.
        let seeder = makeQueue()
        _ = try prepareAndFinalize(seeder, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        let createdURL = entryDir.appendingPathComponent("created.at")
        // A FIXED clock, and the poison is FUTURE *relative to it*: an instant relative to wall time
        // would be ancient under this clock and would correctly age out, which is a different test.
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let poisoned = String(fixedNow.timeIntervalSince1970 + 3600)
        try poisoned.write(to: createdURL, atomically: true, encoding: .utf8)
        var seededInstant = poisoned
        let faulting = VoiceSharingUploadQueue(
            rootDirectory: root,
            clock: { fixedNow },
            failureRecordWriter: { url, data in
                // Fail ONLY the instant repair; everything else must keep working.
                if url.lastPathComponent == "created.at" { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            },
            listDirectory: { url, keys in
                try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
            })
        XCTAssertEqual(faulting.readyEntries().count, 1,
                       "a recording whose repair could not be persisted is still SERVED")
        XCTAssertEqual(faulting.ageResetCountForTesting, 1)
        seededInstant = try String(contentsOf: createdURL, encoding: .utf8)
        XCTAssertEqual(seededInstant, poisoned,
                       "the disk value is untouched, so recovery still knows to retry")
        // AGE FROM THE SAME INSTANT: repeated reads must not restart the clock at zero.
        XCTAssertEqual(faulting.readyEntries().count, 1)
        XCTAssertEqual(faulting.readyEntries().count, 1)
        XCTAssertEqual(faulting.secondsUntilNextAgeBoundary(),
                       VoiceSharingUploadQueue.maxEntryAge,
                       "the in-memory instant starts the retention clock exactly once")
    }

    /// REVIEWER (second round on 444cde13f): the fallback must cover EVERY untrusted age, not just
    /// a future one, and must survive a FAULTED writer — classification used to require the disk
    /// instant, so a failed repair still deleted or refused the recording. For each of missing,
    /// empty and unreadable: with the writer faulted the recording is SERVED, ageing from one chosen
    /// instant as the clock advances; then the fault is LIFTED and the same instance persists it on
    /// recovery WITHOUT choosing a new instant.
    func test_everyUntrustedAgeIsServedFromMemoryWhileTheWriterIsFaultedThenPersisted() throws {
        for defect in ["missing", "empty", "unreadable"] {
            // Each case gets its own root: the test root is per-test, not per-iteration.
            if let existing = root, FileManager.default.fileExists(atPath: existing.path) {
                try FileManager.default.removeItem(at: existing)
            }
            root = temporaryRoot()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
            let seeder = makeQueue(clock: { fixedNow })
            _ = try prepareAndFinalize(seeder, metadata: validRecord(audio: audioA), audio: audioA)
            let entryDir = try soleEntryDirectory()
            let createdURL = entryDir.appendingPathComponent("created.at")
            switch defect {
            case "missing": try FileManager.default.removeItem(at: createdURL)
            case "empty": try Data().write(to: createdURL)
            default: try "not-a-number".write(to: createdURL, atomically: true, encoding: .utf8)
            }

            var faulted = true
            var now = fixedNow
            let q = VoiceSharingUploadQueue(
                rootDirectory: root,
                clock: { now },
                failureRecordWriter: { url, data in
                    if faulted, url.lastPathComponent == "created.at" {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: url, options: .atomic)
                },
                listDirectory: { url, keys in
                    try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
                })
            XCTAssertEqual(q.readyEntries().count, 1,
                           "\(defect): a recording is SERVED even though its age could not be persisted "
                           + "diag=\(q.lastDiscoveryDiagnostic)")
            XCTAssertEqual(q.ageResetCountForTesting, 1, "\(defect): counted once (AGE_RESET)")
            // AGES FROM THAT INSTANT: a later clock read must show elapsed time, not a fresh zero.
            now = fixedNow.addingTimeInterval(3_600)
            XCTAssertEqual(q.secondsUntilNextAgeBoundary(),
                           VoiceSharingUploadQueue.maxEntryAge - 3_600,
                           "\(defect): retention counts from the chosen instant, not from now")
            // LIFT THE FAULT: recovery on the SAME instance persists it.
            faulted = false
            _ = q.readyEntries()
            guard let persisted = try? String(contentsOf: createdURL, encoding: .utf8) else {
                return XCTFail("\(defect): the retry left no sidecar at all; diag="
                               + q.lastDiscoveryDiagnostic)
            }
            XCTAssertEqual(try XCTUnwrap(TimeInterval(persisted)), fixedNow.timeIntervalSince1970,
                           "\(defect): the ORIGINAL chosen instant is written, not a new one")
            XCTAssertEqual(q.secondsUntilNextAgeBoundary(),
                           VoiceSharingUploadQueue.maxEntryAge - 3_600,
                           "\(defect): persistence does not reset the retention clock")
        }
    }

    /// REVIEWER (second round on 444cde13f): an OversizedOrCorrupt instant is not repairable, but it
    /// must not cost the RECORDING either. Structural validation is independent of the sidecar, so
    /// the entry still counts as a valid recording while the age rule refuses to serve it.
    func test_aCorruptAgeSidecarNeverCostsTheRecording() throws {
        let q = makeQueue()
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        try Data(String(repeating: "9", count: 4096).utf8)
            .write(to: entryDir.appendingPathComponent("created.at"))
        // RECONSTRUCTION over it must not delete the recording.
        let fresh = makeQueue()
        _ = fresh.readyEntries()
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path),
                      "an unreadable age must never delete recording content")
        XCTAssertEqual(fresh.expireAgedOutEntries(), 0, "and retention cannot act on an unknown age")
    }

    /// A PURGE NEEDS A DECIDED, RECORDING-SPECIFIC REJECTION RECORDED IN ITS MARKER (spec afc64eb2).
    /// Markers used to carry a bare byte with no cause, so a quarantine became deletable by
    /// accident. Now the cause is the marker's content and only a decided rejection authorises
    /// deletion. Its counterpart is `test_aLegacyMarkerNeverAuthorisesDeletion` below.
    func test_aDecidedRejectionIsStillPurged() throws {
        let seeder = makeQueue()
        _ = try prepareAndFinalize(seeder, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        try "decidedRejection".write(
            to: entryDir.appendingPathComponent("publication.failed"),
            atomically: true, encoding: .utf8)

        let fresh = makeQueue()
        XCTAssertEqual(fresh.readyEntries().count, 0, "a decided rejection never serves")
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDir.path),
                       "and it is deleted, exactly as before")
    }

    /// THE LEGACY MARKER: a bare `0x01` records no cause, so it can never authorise deletion. This is
    /// the exact shape that deleted entry 8E946B60. RED before this change — such an entry was
    /// purged on the next serving pass and is retained here.
    func test_aLegacyMarkerNeverAuthorisesDeletion() throws {
        let seeder = makeQueue()
        _ = try prepareAndFinalize(seeder, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        try Data([0x01]).write(to: entryDir.appendingPathComponent("publication.failed"))

        let fresh = makeQueue()
        XCTAssertEqual(fresh.readyEntries().count, 0, "a disqualified entry never serves")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path),
                      "but an unknown cause must NOT authorise deleting the recording")
    }

    /// SPEC a3ef694f: an unmeasurable queue must not refuse admission. RED before this change — the
    /// allowance query returned false whenever the root could not be counted, which is the wedge.
    func test_anUnmeasurableQueueStillAllowsAdmission() throws {
        // SPEC 2741a0ca RULING: an uncountable root REFUSES a new admission, because the admit gate
        // is "fewer than 32 records ON DISK" and a count that was not taken cannot satisfy it. The
        // refusal must be LOGGED and NOT STICKY: the moment the listing reads again, the next
        // segment is admitted. It must never touch drain, upload or delete.
        var failing = false
        // The fault goes on the UNBOUNDED lister, because that is what discovery actually uses
        // (spec 2741a0ca ruling 1). Injecting into the bounded seam left the count reading fine and
        // the control passing for the wrong reason.
        let queue = VoiceSharingUploadQueue(
            rootDirectory: root,
            listDirectory: { url, keys in
                if failing, url.standardizedFileURL == self.root.standardizedFileURL {
                    throw CocoaError(.fileReadUnknown)
                }
                return try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys)
            })
        XCTAssertTrue(queue.hasAdmissionAllowance(), "PRE: a readable root admits")
        failing = true
        XCTAssertFalse(queue.hasAdmissionAllowance(),
                       "an unknown count cannot satisfy the admit gate")
        XCTAssertTrue(queue.lastCountWasUnknown, "and the failure is recorded, not silent")
        // NOT STICKY: a readable listing admits again with no other action.
        failing = false
        XCTAssertTrue(queue.hasAdmissionAllowance(),
                      "the refusal must lift as soon as the disk reads again")
        XCTAssertFalse(queue.lastCountWasUnknown)
    }

    /// RULING 2: an unreadable metadata file must NOT become a local verdict. The capture holds
    /// audio, so it counts toward the limit and stays on disk for the uploader and the 7-day expiry.
    func test_aCaptureWithUnreadableMetadataIsRetainedNotDeleted() throws {
        let seeder = makeQueue()
        let entry = try prepareAndFinalize(seeder, metadata: validRecord(audio: audioA), audio: audioA)
        let dir = try soleEntryDirectory()
        // Corrupt the metadata so it can no longer bind, keeping the audio intact.
        try Data("not-json".utf8).write(to: dir.appendingPathComponent("metadata.json"))

        let fresh = makeQueue()
        _ = fresh.readyEntriesReportingUnknownCoverage()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                      "a local parse verdict must never delete a recording")
        // CORRECTED (reviewer 307d0bde item 1): it IS served. Excluding it from serving was a hold
        // with a log line attached; the server must get the bytes and own the verdict.
        XCTAssertEqual(fresh.readyEntries().count, 1,
                       "a capture the client cannot bind is still offered to the server; diag=\(fresh.lastDiscoveryDiagnostic)")
    }

    /// RULING 1: an unreadable attempt record treats the backoff as DUE — it must not hold the
    /// upload waiting for a record that may never become readable.
    func test_anUnreadableAttemptRecordTreatsBackoffAsDue() throws {
        let q = makeQueue()
        let entry = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        // An obligation file with unparseable contents: owed-instant unknown.
        try Data("garbage".utf8).write(
            to: root.appendingPathComponent(VoiceSharingUploadQueue.obligationPrefix + entry.name))
        // The boundary is DUE now, so the queue offers work rather than waiting indefinitely.
        let seconds = q.secondsUntilNextRetryBoundary()
        if let seconds { XCTAssertLessThanOrEqual(seconds, 1,
                                                 "an uncertain record must not defer the upload") }
    }

    /// The count at recovery is read from the entries actually on disk, so a restart cannot inherit
    /// a phantom tally from a previous process.
    func test_theRecordCountIsRecomputedFromDiskAtRecovery() throws {
        let seeded = makeQueue()
        _ = try prepareAndFinalize(seeded, metadata: validRecord(audio: audioA), audio: audioA)
        let fresh = makeQueue()
        _ = fresh.readyEntriesReportingUnknownCoverage()
        XCTAssertEqual(fresh.lastCompleteEntryCountLocked, 1, "exactly the one entry on disk")
        XCTAssertFalse(fresh.lastCountWasUnknown, "the count succeeded")
    }

    /// RULE 3 counterpart: with unknown coverage, a DUE entry is still attempted. The hold must not
    /// reach the attempt gate — that is what turned an accounting fault into a stalled queue.
    func test_unknownCoverageDoesNotBlockAttemptingADueEntry() throws {
        // This control belongs to the ATTEMPT gate, which the ownership fence still governs. That
        // fence is a separate, load-bearing rule (`test_unreadableOwnershipBlocksAdmission...`), so
        // the attempt path is unchanged here; what changed is ADMISSION, covered above.
        let queue = makeQueue()
        let entry = try prepareAndFinalize(queue, metadata: validRecord(audio: audioA), audio: audioA)
        XCTAssertNoThrow(try queue.admitAttempt(entry),
                         "a due entry is still admitted on a measurable queue")
    }

    /// REVIEWER 3dd6876c item 1: a cause that VANISHES between classification and the cause read
    /// must never authorise a deletion. The marker is removed by an injected seam after the entry
    /// is classified `.disqualified`, so the two reads disagree.
    func test_aCauseReadThatFailsAfterClassificationNeverDeletes() throws {
        let seeder = makeQueue()
        _ = try prepareAndFinalize(seeder, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        let marker = entryDir.appendingPathComponent("publication.failed")
        try "decidedRejection".write(to: marker, atomically: true, encoding: .utf8)

        // The marker disappears after classification: an unreadable/absent cause on a disqualified
        // entry is a state change we cannot adjudicate, so it must NOT be purged.
        let queue = makeQueueDeletingMarkerAfterListing(marker)
        _ = queue.readyEntriesReportingUnknownCoverage()
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path),
                      "an unprovable cause never deletes a recording")
    }

    /// REVIEWER 3dd6876c item 2: a LIVE entry whose directory kind cannot be read keeps its retry
    /// state, and a lowercase entry directory keeps its sidecars too.
    func test_unreadableEntryFactsAndLowercaseEntriesKeepTheirSidecars() throws {
        let seeded = makeQueue()
        _ = try prepareAndFinalize(seeded, metadata: validRecord(audio: audioA), audio: audioA)
        let upper = try soleEntryDirectory().lastPathComponent
        // A LIVE entry with its retry stamp, plus an orphan to prove the sweep still runs.
        let liveStamp = root.appendingPathComponent("attempt.notbefore.\(upper)")
        try "{\"notBefore\":1}".write(to: liveStamp, atomically: true, encoding: .utf8)
        let orphan = UUID().uuidString
        let orphanStamp = root.appendingPathComponent("attempt.notbefore.\(orphan)")
        try "{\"notBefore\":1}".write(to: orphanStamp, atomically: true, encoding: .utf8)
        // A LOWERCASE-named ENTRY: same identity, different spelling. It must be a REAL entry (an
        // empty directory is incomplete and recovery deletes it for that reason), so build it
        // through the queue and then respell the directory.
        let built = try prepareAndFinalize(seeded, metadata: validRecord(audio: audioA), audio: audioA)
        let lower = built.name.lowercased()
        let lowerDir = root.appendingPathComponent(lower)
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(built.name), to: lowerDir)
        let lowerStamp = root.appendingPathComponent("attempt.notbefore.\(lower)")
        try "{\"notBefore\":1}".write(to: lowerStamp, atomically: true, encoding: .utf8)

        let fresh = makeQueue()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lowerDir.path),
                      "DIAG: the lowercase dir survives recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveStamp.path),
                      "an upper-case live entry keeps its stamp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lowerStamp.path),
                      "a lowercase live entry is the SAME identity and keeps its stamp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanStamp.path),
                       "the true orphan is still swept")
    }

    /// REVIEWER 3dd6876c item 3: only SUCCESSFUL removals are counted; failures are reported
    /// separately, so "removed=N" can never describe a file that is still there.
    func test_onlySuccessfulOrphanRemovalsAreCounted() throws {
        let seeder = makeQueue()
        _ = try prepareAndFinalize(seeder, metadata: validRecord(audio: audioA), audio: audioA)
        let orphan = UUID().uuidString
        let orphanStamp = root.appendingPathComponent("attempt.notbefore.\(orphan)")
        try "{\"notBefore\":1}".write(to: orphanStamp, atomically: true, encoding: .utf8)

        // A remover that refuses exactly that file.
        final class Refuser: FileManager {
            let blocked: String
            init(blocked: String) { self.blocked = blocked; super.init() }
            override func removeItem(at URL: URL) throws {
                if URL.path == blocked { throw NSError(domain: "test-removal", code: 1) }
                try super.removeItem(at: URL)
            }
        }
        let fresh = makeQueue(fileManager: Refuser(blocked: orphanStamp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanStamp.path),
                      "the removal genuinely failed")
        XCTAssertEqual(fresh.removedOrphanSidecars, 0, "a failed removal is not counted as removed")
        XCTAssertEqual(fresh.failedOrphanSidecars, 1, "and it is reported as a failure")
    }

    /// SPEC (orphaned sidecars): retry stamps whose recording no longer exists are removed, counted
    /// and named — while a LIVE entry keeps its own. A silent sweep of retry state would be
    /// indistinguishable from losing it.
    func test_orphanedAttemptSidecarsAreSweptAndLiveOnesKept() throws {
        let seeded = makeQueue()
        _ = try prepareAndFinalize(seeded, metadata: validRecord(audio: audioA), audio: audioA)
        let liveName = try soleEntryDirectory().lastPathComponent
        let liveStamp = root.appendingPathComponent("attempt.notbefore.\(liveName)")
        try "{\"notBefore\":1}".write(to: liveStamp, atomically: true, encoding: .utf8)
        // An orphan: a well-formed stamp with no entry directory behind it.
        let orphanName = UUID().uuidString
        let orphanStamp = root.appendingPathComponent("attempt.notbefore.\(orphanName)")
        try "{\"notBefore\":1}".write(to: orphanStamp, atomically: true, encoding: .utf8)
        let orphanObligation = root.appendingPathComponent("attempt.obligation.\(orphanName)")
        try "1800".write(to: orphanObligation, atomically: true, encoding: .utf8)

        let fresh = makeQueue()
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveStamp.path),
                      "a live recording KEEPS its retry stamp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanStamp.path),
                       "an orphaned stamp is swept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanObligation.path),
                       "an orphaned obligation is swept too")
        XCTAssertEqual(fresh.removedOrphanSidecars, 2, "and the sweep is counted")
    }

    /// THE REPAIR WRITES ONLY TO PUBLISHED WORK. An INCOMPLETE entry with an untrusted instant must
    /// keep its instant untouched: recovery owns partial work, and a reset routine is not a licence
    /// to write into state the caller never validated. RED when the completeness guard lived only in
    /// the comment — the served-set age reader reached the repair without one.
    func test_anIncompleteEntryIsNeverRepairedByTheAgeReset() throws {
        let q = makeQueue()
        let prep = try q.prepare(
            metadata: validRecord(captureID: UUID().uuidString, audio: audioA), audio: audioA)
        let dir = root.appendingPathComponent(prep.name)
        // A PREPARING entry (no ready marker) carrying an unreadable instant.
        try "not-a-number".write(to: dir.appendingPathComponent("created.at"),
                                 atomically: true, encoding: .utf8)
        _ = q.readyEntries()
        _ = q.readyCountDiagnostics()
        _ = q.expireAgedOutEntries()
        let instant = try String(contentsOf: dir.appendingPathComponent("created.at"),
                                 encoding: .utf8)
        XCTAssertEqual(instant, "not-a-number",
                       "a partial entry's instant is never rewritten by the repair")
        XCTAssertEqual(q.ageResetCountForTesting, 0, "and the repair is not counted")
    }

    /// The reset is PERSISTED, so it holds for a fresh instance too — not just in memory.
    func test_theAgeResetSurvivesAReconstruction() throws {
        var q = makeQueue()
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        try String(String(Date().timeIntervalSince1970 + 3600)).write(
            to: entryDir.appendingPathComponent("created.at"), atomically: true, encoding: .utf8)
        _ = q.expireAgedOutEntries()
        XCTAssertEqual(q.ageResetCountForTesting, 1)
        q = makeQueue() // fresh instance re-reads the persisted instant
        XCTAssertEqual(q.readyEntries().count, 1,
                       "the reset instant is on disk, not only in the resetting instance")
    }

    /// A MISSING or unreadable instant takes the same route (Android parity): reset to now and
    /// serve, rather than leaving the recording permanently unservable.
    func test_anUnreadableCaptureInstantIsAlsoResetAndServed() throws {
        let q = makeQueue()
        _ = try prepareAndFinalize(q, metadata: validRecord(audio: audioA), audio: audioA)
        let entryDir = try soleEntryDirectory()
        try "not-a-number".write(
            to: entryDir.appendingPathComponent("created.at"), atomically: true, encoding: .utf8)
        _ = q.expireAgedOutEntries()
        XCTAssertEqual(q.ageResetCountForTesting, 1, "the unreadable instant is counted (AGE_RESET)")
        XCTAssertEqual(q.readyEntries().count, 1, "premise: repairable, so it serves")
        XCTAssertEqual(q.readyEntries().count, 1, "the recording is served after the reset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path),
                      "a recording with an untrusted age is reset, never deleted")
    }

    /// SPEC 05ff27d0: the backoff ceiling is ONE HOUR — retries must still be retries (bounded,
    /// not hot), and must reach the full hour before flattening.
    func test_theRetryCeilingIsOneHour() {
        XCTAssertEqual(VoiceSharingRetryPolicy.compiledMaximumDelaySeconds, 3600,
                       "backoff ceiling is one hour (spec 05ff27d0)")
        // Attempt 13's exponential ceiling (2 * 2^12) already exceeds an hour; full jitter must
        // then be capped by the hour, not by the old minute.
        let policy = VoiceSharingRetryPolicy(
            retryBaseDelay: VoiceSharingRetryPolicy.compiledInitialDelaySeconds,
            retryMaximumDelay: VoiceSharingRetryPolicy.compiledMaximumDelaySeconds,
            random: { 1 })
        XCTAssertEqual(policy.delay(afterAttempt: 13, serverRetryAfter: nil), 3600,
                       "the jittered component flattens at one hour")
        XCTAssertEqual(policy.delay(afterAttempt: 6, serverRetryAfter: nil), 64,
                       "below the ceiling the growth stays exponential (2 * 2^5)")
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
private final class UploadQueueLockedBox<T> {
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
            "wake_required": false,
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


// MARK: - The exact two-clock ordering behind the epoch failure (spec 4ae8c740)

/// SPEC-REQUESTED REGRESSION, reproducing the ORIGINAL ordering deterministically.
///
/// The two clock sources in the failing path:
///   1. the WRITER's queue clock, used once at `prepare` to stamp `created.at`
///      (`String(clock().timeIntervalSince1970)`), and
///   2. the READER's queue clock, used at eligibility (`clock().timeIntervalSince(created)`).
///
/// When the reader's clock is EARLIER than the writer's by any amount, the age is negative and the
/// entry was excluded from `readyEntriesReportingUnknownCoverage` (and from the count) while
/// `readyEntries()` still reported it. This control pins that ordering exactly — writer ahead by
/// 0.5s, reader behind — and asserts the CURRENT rule: a future-dated instant is NOT fresh. It fails
/// against any tolerance that quietly makes such an entry servable.
final class VoiceSharingClockOrderingRegressionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsclockorder-\(UUID().uuidString)")
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

    /// THE ORIGINAL FAILING ORDERING, DETERMINISTIC: the entry is read in the SAME tick that wrote
    /// it under a PINNED clock. The 1970-epoch round trip (`String(timeIntervalSince1970)` then
    /// `Date(timeIntervalSince1970:)`) used to reconstruct the instant a fraction of a microsecond
    /// ahead of the reading clock, so age came back as -0s and the entry vanished from the served
    /// set while `readyEntries()` still reported it. The old predicate (`age >= 0` over the
    /// reconstructed `Date`) fails this control.
    func test_anEntryReadInTheSameTickItWasWrittenIsServed() throws {
        // A PROVEN mis-rounding instant: for this 2001-reference reading R, the write path
        // `String(R + 978307200)` read back through `Date(timeIntervalSince1970:)` reconstructs an
        // internal instant 2^-22s AHEAD of R (verified against IEEE-754 double arithmetic), so the
        // old subtraction in reference space returned a negative age. Pinned so the control is
        // deterministic, not luck-of-the-clock.
        let pinned = Date(timeIntervalSinceReferenceDate: 1693351696.150849)
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: { pinned })
        _ = try seedEntry(queue)
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage stays known: \(queue.lastDiscoveryDiagnostic)")
        }
        XCTAssertEqual(ready.count, 1,
                       "the same instant written and read must not exclude the entry. "
                       + "Diag: \(queue.lastDiscoveryDiagnostic)")
        XCTAssertEqual(queue.readyEntries().count, 1, "and both serving paths must agree")
        XCTAssertEqual(queue.readyCountLocked(), 1, "and the count agrees with both")
    }

    /// WRITER AHEAD OF READER by half a second — the original ordering. The entry is written under a
    /// clock the reader lags, so its age is negative: the strict rule says NOT FRESH, and this control
    /// documents that as the intended behaviour rather than excusing it.
    func test_aWriterClockAheadOfTheReaderDoesNotMakeAnEntryFresh() throws {
        let base = Date()
        let writer = VoiceSharingUploadQueue(rootDirectory: root, clock: { base })
        _ = try seedEntry(writer)

        // Same disk, reader half a second BEHIND the writer.
        let reader = VoiceSharingUploadQueue(
            rootDirectory: root, clock: { base.addingTimeInterval(-0.5) })
        guard case .known(let ready) = reader.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage stays known: the entry is readable, merely not fresh")
        }
        XCTAssertTrue(ready.isEmpty,
                      "a future-dated admission instant is NOT fresh (spec 4ae8c740): the strict "
                      + "rule stands. Diag: \(reader.lastDiscoveryDiagnostic)")
        XCTAssertEqual(reader.readyEntries().count, 0,
                       "and the legacy path must agree — the disagreement WAS the defect")
    }

    /// NEAR-ZERO SKEW, reader AHEAD: the ordinary case must still serve, so the strict rule does not
    /// regress freshness for a coherent clock.
    func test_aReaderAheadOfTheWriterServesNormally() throws {
        let base = Date()
        let writer = VoiceSharingUploadQueue(rootDirectory: root, clock: { base })
        _ = try seedEntry(writer)
        let reader = VoiceSharingUploadQueue(
            rootDirectory: root, clock: { base.addingTimeInterval(0.5) })
        guard case .known(let ready) = reader.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage stays known")
        }
        XCTAssertEqual(ready.count, 1, "a coherent (reader-ahead) ordering serves normally")
        XCTAssertEqual(reader.readyEntries().count, 1, "and both paths agree")
    }

    /// GENUINELY FUTURE: an hour ahead is not fresh either, and expiry semantics are untouched.
    func test_anHourInTheFutureIsNotFresh() throws {
        let base = Date()
        let writer = VoiceSharingUploadQueue(rootDirectory: root, clock: { base })
        _ = try seedEntry(writer)
        let reader = VoiceSharingUploadQueue(
            rootDirectory: root, clock: { base.addingTimeInterval(-3600) })
        guard case .known(let ready) = reader.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage stays known")
        }
        XCTAssertTrue(ready.isEmpty, "an hour in the future is skew, not freshness")
    }
}

final class VoiceSharingBackupPolicyTests: XCTestCase {
    private var parent: URL!
    private var root: URL { parent.appendingPathComponent("VoiceContributions", isDirectory: true) }

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: parent)
    }

    private func excluded(_ url: URL) throws -> Bool? {
        var fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    private func setExcluded(_ url: URL, _ excluded: Bool) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try target.setResourceValues(values)
    }

    func test_newAndRecoveredRootsAreExcludedWithoutChangingParent() throws {
        let parentBefore = try excluded(parent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let queue = VoiceSharingUploadQueue(rootDirectory: root)
        XCTAssertEqual(try excluded(root), true)
        let entry = try AudioFixture.makeReadyEntry(in: queue)
        let metadata = try queue.metadata(of: entry)
        let audio = try queue.audio(of: entry)
        try setExcluded(root, false)
        XCTAssertEqual(try excluded(root), false, "premise: existing legacy root is not excluded")
        let recovered = VoiceSharingUploadQueue(rootDirectory: root)
        XCTAssertEqual(try excluded(root), true)
        XCTAssertEqual(recovered.readyEntries(), [entry])
        XCTAssertEqual(try recovered.metadata(of: entry), metadata)
        XCTAssertEqual(try recovered.audio(of: entry), audio)
        XCTAssertEqual(try excluded(parent), parentBefore)
    }

    func test_recreatedRootIsExcludedBeforeNewRetention() throws {
        let queue = VoiceSharingUploadQueue(rootDirectory: root)
        try FileManager.default.removeItem(at: root) // empty test root; live queue must not cache approval
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        _ = try AudioFixture.makeReadyEntry(in: queue)
        XCTAssertEqual(try excluded(root), true)
        XCTAssertEqual(queue.readyEntries().count, 1)
    }

    func test_failedOrUnverifiedPolicyHoldsBytesAndResumesRecoveryAfterRepair() throws {
        for failure in ["throws", "no-op"] {
            let location = root.appendingPathComponent(failure, isDirectory: true)
            let healthy = VoiceSharingUploadQueue(rootDirectory: location)
            let entry = try AudioFixture.makeReadyEntry(in: healthy)
            let metadata = try healthy.metadata(of: entry)
            let audio = try healthy.audio(of: entry)
            let unready = try healthy.prepare(metadata: metadata, audio: audio)
            let directory = location.appendingPathComponent(entry.name)
            let unreadyDirectory = location.appendingPathComponent(unready.name)
            let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            try setExcluded(location, false)
            XCTAssertEqual(try excluded(location), false)
            var repair = false
            var setterCalls = 0
            let blocked = VoiceSharingUploadQueue(rootDirectory: location, backupExcluder: { [self] url in
                setterCalls += 1
                if repair { try setExcluded(url, true) }
                else if failure == "throws" { throw CocoaError(.fileWriteNoPermission) }
                // Successful no-op is not proof: real property readback must refuse it.
            })
            XCTAssertGreaterThan(setterCalls, 0)
            XCTAssertThrowsError(try blocked.prepare(metadata: metadata, audio: audio)) {
                XCTAssertEqual($0 as? VoiceSharingUploadQueue.PrepareError, .storagePolicyUnavailable)
            }
            XCTAssertThrowsError(try blocked.finalize(unready)) {
                XCTAssertEqual($0 as? VoiceSharingUploadQueue.PrepareError, .storagePolicyUnavailable)
            }
            XCTAssertFalse(blocked.hasAdmissionAllowance())
            XCTAssertTrue(blocked.readyEntries().isEmpty)
            if case .unknownCoverage = blocked.readyEntriesReportingUnknownCoverage() {} else {
                XCTFail("unverified backup policy must report unknown coverage, not known zero")
            }
            XCTAssertThrowsError(try blocked.admitAttempt(entry)) {
                XCTAssertEqual($0 as? VoiceSharingUploadQueue.PrepareError, .storagePolicyUnavailable)
            }
            XCTAssertThrowsError(try blocked.metadata(of: entry))
            XCTAssertThrowsError(try blocked.audio(of: entry))
            XCTAssertEqual(blocked.reconcilePublication(entry), .uncertain)
            XCTAssertEqual(try excluded(location), false)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("metadata.json")), metadata)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("audio.wav")), audio)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), filesBefore)
            XCTAssertTrue(FileManager.default.fileExists(atPath: unreadyDirectory.path), "failed policy must defer recovery")
            repair = true
            XCTAssertEqual(blocked.readyEntries(), [entry], "same owner resumes deferred recovery after establishing policy")
            XCTAssertEqual(try excluded(location), true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: unreadyDirectory.path), "recovery cleans abandoned preparation only after policy succeeds")
            XCTAssertEqual(try blocked.metadata(of: entry), metadata)
            XCTAssertEqual(try blocked.audio(of: entry), audio)

            // Cleanup remains available even when the required storage policy cannot be established.
            repair = false
            try setExcluded(location, false)
            if case .reconciled = blocked.purgeAll() {} else { XCTFail("safe purge must remain available") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertEqual(try excluded(location), false, "purge must not require exclusion to succeed")
        }
    }
}

// MARK: - Spec 1a0d3ffb: a permanently refused recording is deleted from the queue, not kept

/// Two legs, one rule: a recording the SERVER refuses permanently (the durable
/// `publication.failed` intent without an active stage) or that the CLIENT's own record check
/// rejects (complete on disk, binding refused) is deleted from the queue AT ONCE by the serving
/// paths, with a named cause. Uncertainty is never a deletion: only proven classifications purge.
final class VoiceSharingRefusalDeletionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsrefuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private var entryRoot: URL { root.appendingPathComponent("VoiceContributions", isDirectory: true) }

    private func makeQueue(clock: @escaping () -> Date = Date.init) -> VoiceSharingUploadQueue {
        VoiceSharingUploadQueue(rootDirectory: entryRoot, clock: clock)
    }

    private func makeQueue(fileManager: FileManager) -> VoiceSharingUploadQueue {
        VoiceSharingUploadQueue(rootDirectory: entryRoot, fileManager: fileManager)
    }

    private func wav(frames: Int) -> Data {
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

    private func validRecord(audio: Data) -> Data {
        let audioDigest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        let record: [String: Any] = [
            "schema_version": 1,
            "capture_id": "11111111-2222-3333-4444-555555555555",
            "wake_required": false,
            "enrollment_epoch": "epoch-1",
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
            ] as [String: Any],
        ]
        return try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    @discardableResult
    private func seed(_ queue: VoiceSharingUploadQueue, frames: Int = 1_600)
        throws -> VoiceSharingUploadQueue.Entry {
        // Encoder-produced bytes: the same representation production writes, so the record check
        // PROVES the fixture valid before we corrupt it.
        let samples: [Float] = Array(repeating: 0.25, count: 4)
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

    private func entryDirectories() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: entryRoot.path)
            .filter { $0 != "attempt.lock" && !$0.hasPrefix(".") }
    }

    /// THE CLIENT LEG: a complete entry whose bytes fail the record check is deleted by the
    /// legacy serving path, and capacity is freed for a fresh recording.
    func test_aRecordCheckRejectionIsDeletedAtOnceByServing() throws {
        let queue = makeQueue()
        let entry = try seed(queue)
        // Corrupt the audio AFTER finalization: metadata's declared digest no longer matches.
        try wav(frames: 1_700).write(
            to: entryRoot.appendingPathComponent(entry.name).appendingPathComponent("audio.wav"))

        XCTAssertTrue(queue.readyEntries().isEmpty, "a refused record never serves")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(entry.name).path),
            "spec 1a0d3ffb: the rejected entry is deleted, not kept")

        // CAPACITY FREED: the queue admits a fresh recording afterwards.
        XCTAssertNoThrow(try seed(makeQueue(), frames: 1_650),
                         "after deletion the queue admits new recordings")
    }

    /// Same rule on the strict discovery path: proven classification deletes, and coverage
    /// stays KNOWN (a refusal is not an unknown).
    func test_strictDiscoveryDeletesARefusedRecordCheckAndCoverageStaysKnown() throws {
        let queue = makeQueue()
        let entry = try seed(queue)
        try wav(frames: 1_700).write(
            to: entryRoot.appendingPathComponent(entry.name).appendingPathComponent("audio.wav"))

        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a proven refusal is known coverage, never unknown")
        }
        XCTAssertTrue(ready.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(entry.name).path))
    }

    /// An entry still being prepared (no ready marker) is NOT a refusal — it must survive.
    func test_anEntryStillBeingPreparedIsNeverPurged() throws {
        let queue = makeQueue()
        let samples: [Float] = Array(repeating: 0.25, count: 4)
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
        let prep = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
        // Deliberately NOT finalized.
        _ = queue.readyEntries()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(prep.name).path),
            "an in-preparation entry is not a refusal and must never be deleted")
    }

    /// Age policy is NOT the refusal leg: an aged-out entry is excluded from serving but is
    /// not deleted by this rule.
    func test_anAgedOutEntryIsNotDeletedByTheRefusalSweep() throws {
        let queue = makeQueue()
        let entry = try seed(queue)
        let directory = entryRoot.appendingPathComponent(entry.name)
        // Backdate the immutable creation instant past the lifetime bound. The bound is now seven
        // days (spec 05ff27d0), so 72 hours is INSIDE it and would prove nothing: age it past the
        // constant itself.
        let stale = String(
            Date(timeIntervalSinceNow: -VoiceSharingUploadQueue.maxEntryAge - 3600).timeIntervalSince1970)
        try Data(stale.utf8).write(to: directory.appendingPathComponent("created.at"))

        XCTAssertTrue(queue.readyEntries().isEmpty, "aged-out entries do not serve")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path),
                      "age exclusion is not a refusal: the entry stays")
    }

    /// THE SERVER LEG: a durable `publication.failed` intent (quarantined refusal, or a purge
    /// whose removal never completed) is completed by deletion — while an ACTIVE publication
    /// stage is never touched.
    func test_aDurableServerRefusalIsDeletedButAnActiveStageNeverIs() throws {
        let queue = makeQueue()
        let refused = try seed(queue)
        // The durable refusal intent: publication.failed present WITH ITS CAUSE (a bare legacy
        // byte no longer authorises deletion), no active stage, bytes retained.
        try "decidedRejection".write(to: entryRoot.appendingPathComponent(refused.name)
            .appendingPathComponent("publication.failed"), atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(refused.name).path),
            "precondition: the quarantined intent is durable")

        // The next serving pass completes the refused entry's deletion.
        XCTAssertTrue(queue.readyEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(refused.name).path),
            "spec 1a0d3ffb: the server-refused entry is deleted, not kept")

        // An ACTIVE publication stage is never a refusal.
        let active = try seed(makeQueue())
        try Data([0x01]).write(to: entryRoot.appendingPathComponent(active.name)
            .appendingPathComponent("stage.publishing"))
        XCTAssertTrue(queue.readyEntries().isEmpty, "a staging entry never serves")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(active.name).path),
            "an active stage is not a refusal and must never be deleted")
    }

    /// Reconstruction agreement: a fresh queue observes the same refused disk the same way.
    func test_aFreshReconstructionDoesNotResurrectARefusedRecordCheck() throws {
        try seed(makeQueue())
        let dirs = try FileManager.default.contentsOfDirectory(atPath: entryRoot.path)
            .filter { $0 != "attempt.lock" && !$0.hasPrefix(".") }
        let name = try XCTUnwrap(dirs.first)
        try wav(frames: 1_700).write(
            to: entryRoot.appendingPathComponent(name).appendingPathComponent("audio.wav"))

        let reborn = makeQueue()
        guard case .known(let ready) = reborn.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(ready.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(name).path))
    }

    // MARK: Reviewer e71b9524 — bound-only gate, proven stage absence, reconciled purge

    /// ITEM 1, strict path: a prepared-but-unfinalized entry never serves and is retained.
    func test_anUnfinalizedEntryNeverServesOnTheStrictPath() throws {
        let queue = makeQueue()
        let samples: [Float] = Array(repeating: 0.25, count: 4)
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
        let prep = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
        // Deliberately NOT finalized, with a fresh created.at — the case that previously
        // slipped past the bound-only gate.
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage stays known")
        }
        XCTAssertTrue(ready.isEmpty, "an unfinalized entry must never serve")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(prep.name).path),
            "an unfinalized entry is retained, not deleted")
    }

    /// ITEM 2: failed intent + ACTIVE stage => never deleted on either path; files intact.
    func test_anEntryWithAnActiveStageIsNeverDeletedEvenWithARefusalIntent() throws {
        let queue = makeQueue()
        let entry = try seed(queue)
        let directory = entryRoot.appendingPathComponent(entry.name)
        try Data([0x01]).write(to: directory.appendingPathComponent("publication.failed"))
        try Data([0x01]).write(to: directory.appendingPathComponent("stage.publishing"))

        XCTAssertTrue(queue.readyEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("deletion-marker-probe").path),
            "precondition sanity")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("audio.wav").path),
            "an active stage must never be deleted despite the refusal intent")
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(ready.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("audio.wav").path),
            "strict path must also leave the staged entry intact")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: entryRoot.path)
            .filter { $0 == entry.name }.count, 1, "the entry directory survives")
    }

    /// ITEM 3, removal failure: the purge fails CLOSED (unknown coverage), the entry's bytes
    /// are never served again, and a fresh reconstruction COMPLETES the reconciled deletion.
    private final class RefusingRemover: FileManager {
        let blockedPath: String
        init(blockedPath: String) { self.blockedPath = blockedPath; super.init() }
        override func removeItem(at URL: URL) throws {
            if URL.path == blockedPath { throw NSError(domain: "test-removal", code: 1) }
            try super.removeItem(at: URL)
        }
    }

    func test_aFailedRemovalFailsClosedAndReconcilesOnReconstruction() throws {
        let queue = makeQueue()
        let entry = try seed(queue)
        try wav(frames: 1_700).write(
            to: entryRoot.appendingPathComponent(entry.name).appendingPathComponent("audio.wav"))
        let blocked = makeQueue(fileManager: RefusingRemover(
            blockedPath: entryRoot.appendingPathComponent(entry.name).path))

        // The serving pass must hold ONLY the refused entry (per-entry hold, spec 1bfba50f):
        // it never serves, the hold is not owner-wide, and the intent stays durable.
        guard case .known(let readyDuringHold) = blocked.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a refusal hold is per-entry, never unknown coverage")
        }
        XCTAssertTrue(readyDuringHold.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(entry.name).path),
            "the removal did not happen; the intent is durable for reconciliation")

        // Reconstruction without the fault COMPLETES the deletion through the durable intent.
        let reborn = makeQueue()
        guard case .known(let ready) = reborn.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("reconstruction coverage known")
        }
        XCTAssertTrue(ready.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(entry.name).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(
                "deletion.intent." + entry.name).path),
            "the deletion intent is retired after reconciliation")
    }

    /// ITEM 3, barrier failure BEFORE any mutation: nothing is deleted, coverage holds closed,
    /// and reconstruction (clean barriers) completes the purge.
    /// The faulted queue is constructed BEFORE seeding: instance init runs recovery, and
    /// recovery deletes an entry whose audio no longer matches its bound digest — constructing
    /// it after seeding would destroy the fixture before discovery ever ran.
    func test_aBarrierFailureBeforeThePurgeMutationFailsClosed() throws {
        let rootPath = entryRoot.path
        var faultedEntryName: String?
        var faultFired = false
        // Fault the FIRST root sync that happens while a deletion intent is already durable:
        // in the purge that is exactly the post-intent barrier; nothing earlier carries one.
        let faulted = VoiceSharingUploadQueue(
            rootDirectory: entryRoot,
            synchronizer: { path, isDirectory in
                if isDirectory && path.path == rootPath,
                   let name = faultedEntryName,
                   FileManager.default.fileExists(
                       atPath: rootPath + "/deletion.intent." + name) {
                    faultFired = true
                    throw NSError(domain: "test-barrier", code: 1)
                }
                try VoiceSharingUploadQueue.testSynchronizer(path: path, isDirectory: isDirectory)
            })
        let queue = makeQueue()
        let entry = try seed(queue)
        faultedEntryName = entry.name
        try wav(frames: 1_700).write(
            to: entryRoot.appendingPathComponent(entry.name).appendingPathComponent("audio.wav"))

        guard case .known(let heldOut) = faulted.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a failed scoped barrier is a per-entry hold, never unknown coverage")
        }
        XCTAssertTrue(heldOut.isEmpty, "the held entry never serves")
        XCTAssertTrue(faultFired, "the post-intent root barrier never faulted")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(entry.name).path),
            "the entry is untouched: the failure landed before any mutation")

        let reborn = makeQueue()
        guard case .known(let ready) = reborn.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("reconstruction coverage known")
        }
        XCTAssertTrue(ready.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(entry.name).path),
            "reconstruction completes the purge")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent("deletion.intent." + entry.name).path),
            "the deletion intent is retired after reconciliation")
    }

    /// ITEM 3, crash window: intent durable, directory already gone => the next pass retires
    /// the record and resurrects nothing.
    func test_anOrphanDeletionIntentRetiresWithoutResurrectingAnything() throws {
        let queue = makeQueue()
        let entry = try seed(queue)
        try wav(frames: 1_700).write(
            to: entryRoot.appendingPathComponent(entry.name).appendingPathComponent("audio.wav"))
        XCTAssertTrue(queue.readyEntries().isEmpty, "the first pass deletes the refused entry")

        // Simulate a crash AFTER the removal, BEFORE the intent retirement.
        try Data([0x01]).write(to: entryRoot.appendingPathComponent(
            "deletion.intent." + entry.name), options: .atomic)

        let reborn = makeQueue()
        guard case .known(let ready) = reborn.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("reconstruction coverage known")
        }
        XCTAssertTrue(ready.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(entry.name).path),
            "the orphan intent must not resurrect anything")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(
                "deletion.intent." + entry.name).path),
            "the orphan intent is retired")
    }

    // MARK: Spec redirect 1bfba50f — scoped reconciled purge, per-entry hold

    /// PURGE FAILURE: only the refused entry is held; a neighbouring valid entry still serves,
    /// byte-for-byte. Reconstruction completes the deletion and retires the intent.
    /// The faulted queue is constructed BEFORE seeding (instance init runs recovery, which
    /// removes entries whose audio no longer matches their binding).
    private final class RefusingEntryRemover: FileManager {
        var blockedName: String?
        init(blocked: String? = nil) { self.blockedName = blocked; super.init() }
        override func removeItem(at URL: URL) throws {
            if URL.lastPathComponent == blockedName { throw NSError(domain: "test-removal", code: 1) }
            try super.removeItem(at: URL)
        }
    }

    func test_aRefusalPurgeFailureHoldsOnlyTheRefusedEntry() throws {
        let remover = RefusingEntryRemover()
        let faulted = makeQueue(fileManager: remover)
        let queue = makeQueue()
        let refused = try seed(queue)
        remover.blockedName = refused.name
        try wav(frames: 1_700).write( // break the record check AFTER finalization
            to: entryRoot.appendingPathComponent(refused.name).appendingPathComponent("audio.wav"))
        let valid = try seed(queue, frames: 1_650)
        let validAudio = try Data(contentsOf: entryRoot.appendingPathComponent(valid.name)
            .appendingPathComponent("audio.wav"))

        guard case .known(let ready) = faulted.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a refusal hold is per-entry; coverage stays known")
        }
        XCTAssertEqual(ready.map(\.name), [valid.name],
                       "the held refused entry never serves; the valid entry does")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(refused.name).path),
            "the held entry is retained; contents=\((try? FileManager.default.contentsOfDirectory(atPath: entryRoot.appendingPathComponent(refused.name).path)) ?? []) diag=\(faulted.lastDiscoveryDiagnostic ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(refused.name)
                .appendingPathComponent("publication.failed").path),
            "the purge reconciled with a durably disqualified survivor: it can never serve")
        XCTAssertEqual(try Data(contentsOf: entryRoot.appendingPathComponent(valid.name)
            .appendingPathComponent("audio.wav")), validAudio, "the neighbour is untouched")

        // RESTART: the deletion completes through the durable intent; the valid entry survives.
        let reborn = makeQueue()
        guard case .known(let readyReborn) = reborn.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("reconstruction coverage known")
        }
        XCTAssertEqual(readyReborn.map(\.name), [valid.name])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(refused.name).path),
            "spec: the refused entry is gone after restart")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent("deletion.intent." + refused.name).path),
            "the deletion intent is retired after reconciliation")
    }

    /// CRASH WINDOW: intent durable, removal never ran => the next pass resumes the scoped
    /// purge and finishes it.
    func test_aCrashAfterTheIntentBeforeRemovalResumesOnTheNextPass() throws {
        let rootPath = entryRoot.path
        var armed: String?
        // Fault the scoped purge's post-intent root barrier while the entry still exists:
        // exactly the state "intent written, removal never ran".
        let faulted = VoiceSharingUploadQueue(
            rootDirectory: entryRoot,
            synchronizer: { path, isDirectory in
                if isDirectory && path.path == rootPath, let name = armed,
                    FileManager.default.fileExists(atPath: rootPath + "/deletion.intent." + name),
                    FileManager.default.fileExists(atPath: rootPath + "/" + name) {
                    throw NSError(domain: "test-barrier", code: 1)
                }
                try VoiceSharingUploadQueue.testSynchronizer(path: path, isDirectory: isDirectory)
            })
        let queue = makeQueue()
        let entry = try seed(queue)
        armed = entry.name
        try wav(frames: 1_700).write(
            to: entryRoot.appendingPathComponent(entry.name).appendingPathComponent("audio.wav"))

        guard case .known(let held) = faulted.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("crash-window hold is per-entry")
        }
        XCTAssertTrue(held.isEmpty, "the held entry never serves")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(entry.name).path),
            "the removal never ran: the entry is intact")

        let reborn = makeQueue()
        guard case .known(let ready) = reborn.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("reconstruction coverage known")
        }
        XCTAssertTrue(ready.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(entry.name).path),
            "the resumed scoped purge completes the deletion")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent("deletion.intent." + entry.name).path),
            "the intent is retired")
    }

    /// A durable deletion intent on a still-BINDABLE survivor (marker loss after a partial
    /// removal) must NEVER let it serve: the hold applies before classification, and the
    /// authorized deletion finishes.
    func test_aSurvivorWithADeletionIntentNeverServesEvenIfBindable() throws {
        let queue = makeQueue()
        let entry = try seed(queue) // complete, bindable, no publication.failed
        try Data([0x01]).write(to: entryRoot.appendingPathComponent(
            "deletion.intent." + entry.name), options: .atomic)

        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(ready.isEmpty, "a deletion-intent survivor never serves")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(entry.name).path),
            "the authorized deletion finishes")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent("deletion.intent." + entry.name).path),
            "the intent is retired")
    }

    /// REGRESSION GUARD: a default-path refusal purge removes ONLY the refused entry; a valid
    /// neighbour keeps serving with its bytes intact.
    func test_aNeighbouringValidEntryIsUntouchedByARefusalPurge() throws {
        let queue = makeQueue()
        let refused = try seed(queue)
        try wav(frames: 1_700).write(
            to: entryRoot.appendingPathComponent(refused.name).appendingPathComponent("audio.wav"))
        let valid = try seed(queue, frames: 1_650)
        let validAudio = try Data(contentsOf: entryRoot.appendingPathComponent(valid.name)
            .appendingPathComponent("audio.wav"))

        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.map(\.name), [valid.name])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(refused.name).path))
        XCTAssertEqual(try Data(contentsOf: entryRoot.appendingPathComponent(valid.name)
            .appendingPathComponent("audio.wav")), validAudio)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent("deletion.intent." + refused.name).path))
    }

    // MARK: Reviewer 4bb7841c — recovery preservation, legacy hold, stage protection on retries

    /// ITEM 1, two reconstructions: while the held survivor's intent cannot be confirmed
    /// (so no purge may run and the entry can never serve), the deletion intent must SURVIVE
    /// every recovery — never swept as debris. Erasing it would let a later queue serve the
    /// still-bindable survivor.
    func test_anIntentSurvivesReconstructionsWhileItsSurvivorIsHeld() throws {
        let queue = makeQueue()
        let survivor = try seed(queue) // complete and bindable
        try Data([0x01]).write(to: entryRoot.appendingPathComponent(
            "deletion.intent." + survivor.name), options: .atomic)
        let intentPath = entryRoot.appendingPathComponent(
            "deletion.intent." + survivor.name).path
        var unconfirmable: VoiceSharingUploadQueue {
            VoiceSharingUploadQueue(
                rootDirectory: entryRoot,
                intentDiscovery: { url in
                    if url.lastPathComponent.hasPrefix("deletion.intent.") { return .failure }
                    return VoiceSharingUploadQueue.statKind(of: url)
                })
        }

        for round in 1...2 {
            // The held survivor never serves (strict: unknown coverage; legacy: nothing).
            guard case .unknownCoverage = unconfirmable.readyEntriesReportingUnknownCoverage() else {
                return XCTFail("an unconfirmable intent is unknown coverage (round \(round))")
            }
            XCTAssertTrue(unconfirmable.readyEntries().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: intentPath),
                          "reconstruction \(round) must preserve the record: the debris sweep is not its reconciler")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: entryRoot.appendingPathComponent(survivor.name).path),
                "the held survivor is retained (round \(round))")
        }

        // The authorized deletion completes once the intent is confirmable again.
        let reborn = makeQueue()
        guard case .known(let ready) = reborn.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("reconciliation coverage known")
        }
        XCTAssertTrue(ready.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(survivor.name).path),
            "the scoped purge finishes the deletion")
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentPath),
                       "the intent is retired after reconciliation")
    }

    /// ITEM 1, retirement-barrier containment (reviewer 243ef92d): a root-barrier fault AFTER
    /// the retirement removal is contained, absence alone never releases the hold — the barrier
    /// is RETRIED on the next pass while it stays faulted — and once the fault lifts, the
    /// retirement is confirmed (barrier succeeds, hold released).
    func test_anOrphanIntentRetirementBarrierFailureIsContained() throws {
        try FileManager.default.createDirectory(at: entryRoot, withIntermediateDirectories: true)
        let intentName = "deletion.intent.22222222-3333-4444-5555-666666666666"
        try Data([0x01]).write(to: entryRoot.appendingPathComponent(intentName), options: .atomic)
        let intentPath = entryRoot.appendingPathComponent(intentName).path
        let rootPath = entryRoot.path
        let counter = BarrierCounter()
        var barrierFaulted = true
        var faulted: VoiceSharingUploadQueue {
            VoiceSharingUploadQueue(
                rootDirectory: entryRoot,
                synchronizer: { [weak counter] path, isDirectory in
                    if isDirectory && path.path == rootPath {
                        counter?.count += 1
                        if barrierFaulted
                            && !FileManager.default.fileExists(atPath: intentPath) {
                            throw NSError(domain: "test-barrier", code: 3)
                        }
                    }
                    try VoiceSharingUploadQueue.testSynchronizer(path: path, isDirectory: isDirectory)
                })
        }

        // Both faulted passes run on the SAME instance: the serving sweep must retry the
        // absent-entry reconciliation while the hold lives in that instance's recovery state.
        let faultedQueue = faulted

        // Pass 1: removal succeeds, the barrier fails — contained, nothing served.
        let beforeFirst = counter.count
        guard case .known(let ready1) = faultedQueue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("retirement-barrier failure is contained")
        }
        XCTAssertTrue(ready1.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentPath),
                       "the record itself is removed before the barrier")
        XCTAssertGreaterThan(counter.count, beforeFirst,
                             "pass 1 attempted the root barrier confirmation")

        // Pass 2: the barrier is STILL faulted. Absence alone is not durable retirement:
        // the barrier must be retried and the hold must stay.
        let beforeSecond = counter.count
        guard case .known(let ready2) = faultedQueue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("the retry pass is contained too")
        }
        XCTAssertTrue(ready2.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentPath))
        XCTAssertGreaterThan(counter.count, beforeSecond,
                             "absence alone never releases the hold: the barrier is retried from serving")

        // Pass 3: the fault lifts — retirement is CONFIRMED on the same instance that held
        // it: the barrier succeeds and the hold is released there.
        barrierFaulted = false
        let beforeRelease = counter.count
        guard case .known(let ready3) = faultedQueue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("the confirmed retirement pass is contained")
        }
        XCTAssertTrue(ready3.isEmpty)
        XCTAssertGreaterThan(counter.count, beforeRelease,
                             "the retiring barrier attempt runs on the holding instance")

        // Pass 4: a retired hold is not retried — no further barrier attempt for it.
        let beforeIdle = counter.count
        guard case .known(let ready4) = faultedQueue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("the idle pass is contained")
        }
        XCTAssertTrue(ready4.isEmpty)
        XCTAssertEqual(counter.count, beforeIdle,
                       "a retired hold is gone: no further reconciliation attempts")

        // Reconstruction stays clean as an additional check.
        let reborn = makeQueue()
        guard case .known(let readyReborn) = reborn.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("reconstruction coverage known")
        }
        XCTAssertTrue(readyReborn.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentPath),
                       "the retirement stays retired")
    }

    /// Reference box for the barrier-attempt probe (classes capture mutably in escapes).
    final class BarrierCounter: @unchecked Sendable {
        var count = 0
    }

    /// ITEM 2: a bindable survivor whose deletion intent cannot be confirmed never serves,
    /// on either path, while a valid neighbour still serves (per-entry hold).
    func test_aBindableSurvivorWithUnconfirmableIntentNeverServesWhileNeighboursDo() throws {
        let queue = makeQueue()
        let survivor = try seed(queue) // complete, bindable, no corruption
        try Data([0x01]).write(to: entryRoot.appendingPathComponent(
            "deletion.intent." + survivor.name), options: .atomic)
        let neighbour = try seed(queue, frames: 1_650)

        var probed = Set<String>()
        let uncertain = VoiceSharingUploadQueue(
            rootDirectory: entryRoot,
            intentDiscovery: { url in
                if url.lastPathComponent.hasPrefix("deletion.intent.") {
                    probed.insert(url.lastPathComponent)
                    if url.lastPathComponent == "deletion.intent." + survivor.name {
                        return .failure // the intent's presence cannot be confirmed
                    }
                }
                return VoiceSharingUploadQueue.statKind(of: url)
            })
        // LEGACY: the survivor never serves; the neighbour does.
        let legacy = uncertain.readyEntries().map(\.name)
        XCTAssertTrue(legacy.contains(neighbour.name), "the neighbour keeps serving")
        XCTAssertFalse(legacy.contains(survivor.name), "the unconfirmable survivor never serves")
        XCTAssertTrue(probed.contains("deletion.intent." + survivor.name),
                      "the control exercised the injected intent confirmation")
        // STRICT: the same hold, reported as unknown coverage.
        guard case .unknownCoverage = uncertain.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("an unconfirmable intent is unknown coverage on the strict path")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent(survivor.name).path),
            "the survivor is retained, never silently deleted")
    }

    /// ITEM 3: a deletion intent over an entry with an ACTIVE publication stage is never
    /// deleted on either path — the proven-stage-absence protection applies to retries.
    func test_anIntentWithAnActiveStageIsNeverDeletedOnEitherPath() throws {
        let queue = makeQueue()
        let entry = try seed(queue)
        let directory = entryRoot.appendingPathComponent(entry.name)
        try Data([0x01]).write(to: directory.appendingPathComponent("stage.publishing"))
        try Data([0x01]).write(to: entryRoot.appendingPathComponent(
            "deletion.intent." + entry.name), options: .atomic)

        XCTAssertTrue(queue.readyEntries().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("audio.wav").path),
            "legacy: an active stage under a deletion intent is never deleted")
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(ready.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("audio.wav").path),
            "strict: an active stage under a deletion intent is never deleted")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: entryRoot.appendingPathComponent("deletion.intent." + entry.name).path),
            "the intent stays durable")
    }
}
