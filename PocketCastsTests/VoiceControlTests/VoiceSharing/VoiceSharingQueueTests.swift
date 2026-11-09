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

    func test_publishCreatesOneFolderWithBothFiles() async throws {
        let queue = makeQueue()
        let published = await queue.publish(audio: audio(), metadata: metadata())
        let name = try XCTUnwrap(published)

        let folder = root.appendingPathComponent(name, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("metadata.json").path))
        let pendingCount = await queue.count()
        XCTAssertEqual(pendingCount, 1)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".") },
            "no temporary name may survive a successful publish")
    }

    func test_publishDropsAndLogsWhenTheQueueIsFull() async throws {
        let queue = makeQueue()
        for _ in 0..<VoiceSharingQueue.capacity {
            let published = await queue.publish(audio: audio(), metadata: metadata())
            XCTAssertNotNil(published)
        }
        let overCapacity = await queue.publish(audio: audio(), metadata: metadata())
        XCTAssertNil(overCapacity, "a full queue drops the recording")
        let pendingCount = await queue.count()
        XCTAssertEqual(pendingCount, VoiceSharingQueue.capacity)
        XCTAssertTrue(log.contains { $0.contains("drop reason=queue-full") })
    }

    // MARK: Housekeeping

    func test_anIncompleteWriteIsRemovedAtStartup() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let leftover = root.appendingPathComponent(".writing-orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        let queue = makeQueue()
        await queue.removeTemporaryEntries()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path),
                       "an unpublished folder is never a valid recording")
        XCTAssertTrue(log.contains { $0.contains("reason=incomplete-write") })
    }

    // MARK: Due entries

    func test_aRecordingOlderThanSevenDaysIsDeletedNotReturned() async throws {
        // Published under the real clock, then read after the bound has passed: the recording is
        // aged by TIME, which is the condition the queue's expiry rule is about.
        let queue = makeQueue()
        let first = await queue.publish(audio: audio(), metadata: metadata())
        _ = try XCTUnwrap(first)
        let later = makeQueue(now: { Date().addingTimeInterval(VoiceSharingQueue.maximumAge + 60) })

        let retained = await later.count()
        XCTAssertEqual(retained, 1, "setup: one recording is retained")
        let offered = await later.dueEntries()
        XCTAssertTrue(offered.isEmpty, "an expired recording is not offered")
        let remaining = await later.count()
        XCTAssertEqual(remaining, 0, "expired recordings are removed, not skipped; log=\(log!)")
        XCTAssertTrue(log.contains { $0.contains("delete reason=expired") })
    }

    func test_aDeferredEntryIsNotDueUntilItsWindowPasses() async throws {
        let created = Date(timeIntervalSince1970: 1_000_000)
        var current = created
        let queue = makeQueue(now: { current })
        _ = await queue.publish(audio: audio(), metadata: metadata())
        let publishedEntries = await queue.entries()
        let entry = try XCTUnwrap(publishedEntries.first)

        await queue.deferUntil(created.addingTimeInterval(60), entry: entry)
        let insideWindow = await queue.dueEntries()
        XCTAssertTrue(insideWindow.isEmpty, "inside the backoff window the entry is not offered")

        current = created.addingTimeInterval(61)
        let afterWindow = await queue.dueEntries()
        XCTAssertEqual(afterWindow.count, 1, "after the window it is offered again")
    }

    func test_entriesAreOfferedOldestFirst() async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var current = base
        let queue = makeQueue(now: { current })
        _ = await queue.publish(audio: audio(), metadata: metadata(), name: "second")
        current = base.addingTimeInterval(10)
        _ = await queue.publish(audio: audio(), metadata: metadata(), name: "third")

        let due = await queue.dueEntries()
        let names = due.map(\.name)
        XCTAssertEqual(names.count, 2)
        XCTAssertLessThanOrEqual(names[0], names[1], "oldest first")
    }
}