import XCTest
@testable import podcasts

/// Round 22 — durable queue entry persistence (spec §Client queue and scheduling):
/// "Persist the metadata and audio as one queue entry using an atomic ready marker;
/// interrupted preparation is not a ready upload. The queue owns temporary files and
/// removes abandoned preparation files on recovery."
///
/// What these controls pin:
///   * A prepared entry is INVISIBLE to dequeue until its ready marker exists; a crash between
///     writing audio/metadata and the marker leaves nothing dequeueable.
///   * Recovery deletes abandoned preparation (no marker) and keeps ready entries intact,
///     bytes included — recovery must not silently drop durable upload work.
///   * Ready entries dequeue in finalize order (FIFO by ready time, not directory/name order).
///   * Removal deletes the WHOLE entry: audio, metadata and marker leave the disk.
///   * The queue never shares a root with anything else: every directory under the root it did
///     not create is treated as abandoned preparation and removed on recovery (ownership).
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

    private let audioA = Data("wav-bytes-A".utf8)
    private let audioB = Data("wav-bytes-B-longer".utf8)
    private let metadataA = #"{"record":{"capture_id":"A"}}"#
    private let metadataB = #"{"record":{"capture_id":"B"}}"#

    func test_preparedEntryIsNotReadyUntilFinalized() throws {
        let queue = makeQueue()
        let prep = try queue.prepare(metadata: metadataA.data(using: .utf8)!, audio: audioA)
        try queue.finalize(prep)

        // Interrupted case: prepare WITHOUT finalize is not dequeueable.
        _ = try queue.prepare(metadata: metadataB.data(using: .utf8)!, audio: audioB)

        let ready = queue.readyEntries()
        XCTAssertEqual(ready.count, 1, "an entry without its ready marker must never be dequeueable")
        XCTAssertEqual(try queue.metadata(of: ready[0]), metadataA.data(using: .utf8)!)
        XCTAssertEqual(try queue.audio(of: ready[0]), audioA)
    }

    func test_recoveryRemovesAbandonedPreparationAndKeepsReadyEntries() throws {
        var queue = makeQueue()
        let prepared = try queue.prepare(metadata: metadataA.data(using: .utf8)!, audio: audioA)
        try queue.finalize(prepared)
        _ = try queue.prepare(metadata: metadataB.data(using: .utf8)!, audio: audioB) // abandoned

        // Simulate process restart: a NEW queue instance over the same root must recover.
        queue = makeQueue()

        let ready = queue.readyEntries()
        XCTAssertEqual(ready.count, 1, "recovery must keep ready entries")
        XCTAssertEqual(try queue.audio(of: ready[0]), audioA, "recovery must keep ready bytes intact")
        XCTAssertEqual(try queue.metadata(of: ready[0]), metadataA.data(using: .utf8)!)
    }

    func test_readyEntriesDequeueInFinalizeOrder() throws {
        let queue = makeQueue()
        // Prepare B FIRST so directory/name order differs from finalize order.
        let prepB = try queue.prepare(metadata: metadataB.data(using: .utf8)!, audio: audioB)
        let prepA = try queue.prepare(metadata: metadataA.data(using: .utf8)!, audio: audioA)
        try queue.finalize(prepA)
        try queue.finalize(prepB)

        let ready = queue.readyEntries()
        XCTAssertEqual(ready.count, 2)
        XCTAssertEqual(try queue.metadata(of: ready[0]), metadataA.data(using: .utf8)!,
                       "FIFO follows finalize order, not preparation or name order")
        XCTAssertEqual(try queue.metadata(of: ready[1]), metadataB.data(using: .utf8)!)
    }

    func test_removeDeletesTheWholeEntry() throws {
        let queue = makeQueue()
        let prep = try queue.prepare(metadata: metadataA.data(using: .utf8)!, audio: audioA)
        try queue.finalize(prep)
        let entry = queue.readyEntries()[0]

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
