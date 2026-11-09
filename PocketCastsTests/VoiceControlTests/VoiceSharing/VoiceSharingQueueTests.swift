import XCTest
@testable import podcasts

/// The queue holds folders and nothing else, and deletes on exactly the conditions the spec lists.
final class VoiceSharingQueueTests: XCTestCase {

    private var root: URL!
    private var log: [String]!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsqueue-\(UUID().uuidString)", isDirectory: true)
        // The queue writes into this directory, so it must exist before the first publish; without
        // it every publish fails and the controls below would pass on an empty queue.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        log = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeQueue(now: @escaping () -> Date = Date.init) -> VoiceSharingQueue {
        VoiceSharingQueue(root: root, now: now, log: { [weak self] in self?.log.append($0) })
    }

    private func audio(_ bytes: Int = 16) -> Data { Data(repeating: 7, count: bytes) }
    private func metadata() -> Data { Data(#"{"enrollment_epoch":"epoch-1"}"#.utf8) }

    // MARK: Publishing

    func test_publishCreatesOneFolderWithBothFiles() throws {
        let queue = makeQueue()
        let name = try XCTUnwrap(queue.publish(audio: audio(), metadata: metadata()))

        let folder = root.appendingPathComponent(name, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("metadata.json").path))
        XCTAssertEqual(queue.count(), 1)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".") },
            "no temporary name may survive a successful publish")
    }

    func test_publishDropsAndLogsWhenTheQueueIsFull() throws {
        let queue = makeQueue()
        for _ in 0..<VoiceSharingQueue.capacity {
            XCTAssertNotNil(queue.publish(audio: audio(), metadata: metadata()))
        }
        XCTAssertNil(queue.publish(audio: audio(), metadata: metadata()), "a full queue drops the recording")
        XCTAssertEqual(queue.count(), VoiceSharingQueue.capacity)
        XCTAssertTrue(log.contains { $0.contains("drop reason=queue-full") })
    }

    // MARK: Housekeeping

    func test_anIncompleteWriteIsRemovedAtStartup() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let leftover = root.appendingPathComponent(".writing-orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        let queue = makeQueue()
        queue.removeTemporaryEntries()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path),
                       "an unpublished folder is never a valid recording")
        XCTAssertTrue(log.contains { $0.contains("reason=incomplete-write") })
    }

    // MARK: Due entries

    func test_aRecordingOlderThanSevenDaysIsDeletedNotReturned() throws {
        // Published under the real clock, then read after the bound has passed: the recording is
        // aged by TIME, which is the condition the queue's expiry rule is about.
        let queue = makeQueue()
        _ = try XCTUnwrap(queue.publish(audio: audio(), metadata: metadata()))
        let later = makeQueue(now: { Date().addingTimeInterval(VoiceSharingQueue.maximumAge + 60) })

        XCTAssertEqual(later.count(), 1, "setup: one recording is retained")
        XCTAssertTrue(later.dueEntries().isEmpty, "an expired recording is not offered")
        XCTAssertEqual(later.count(), 0, "expired recordings are removed, not skipped; log=\(log!)")
        XCTAssertTrue(log.contains { $0.contains("delete reason=expired") })
    }

    func test_aDeferredEntryIsNotDueUntilItsWindowPasses() throws {
        let created = Date(timeIntervalSince1970: 1_000_000)
        var current = created
        let queue = makeQueue(now: { current })
        _ = queue.publish(audio: audio(), metadata: metadata())
        let entry = try XCTUnwrap(queue.entries().first)

        queue.deferUntil(created.addingTimeInterval(60), entry: entry)
        XCTAssertTrue(queue.dueEntries().isEmpty, "inside the backoff window the entry is not offered")

        current = created.addingTimeInterval(61)
        XCTAssertEqual(queue.dueEntries().count, 1, "after the window it is offered again")
    }

    func test_entriesAreOfferedOldestFirst() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var current = base
        let queue = makeQueue(now: { current })
        _ = queue.publish(audio: audio(), metadata: metadata(), name: "second")
        current = base.addingTimeInterval(10)
        _ = queue.publish(audio: audio(), metadata: metadata(), name: "third")

        let names = queue.dueEntries().map(\.name)
        XCTAssertEqual(names.count, 2)
        XCTAssertLessThanOrEqual(names[0], names[1], "oldest first")
    }
}