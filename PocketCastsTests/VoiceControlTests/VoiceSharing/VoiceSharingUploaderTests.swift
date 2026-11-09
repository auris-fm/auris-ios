import XCTest
@testable import podcasts

/// Every server answer maps to exactly one outcome, and every delete happens for a permitted reason.
final class VoiceSharingUploaderTests: XCTestCase {

    private var root: URL!
    private var log: [String]!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsupload-\(UUID().uuidString)", isDirectory: true)
        // The queue writes into this directory, so it has to exist before the first publish.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        log = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Each case measures one recording of its own: a shared root let a previous case's leftover
    /// satisfy the next case's "nothing remains" assertion.
    private func resetRoot() throws {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func queue(now: @escaping () -> Date = Date.init) -> VoiceSharingQueue {
        VoiceSharingQueue(root: root, now: now, log: { [weak self] in self?.log.append($0) })
    }

    private func publish(_ queue: VoiceSharingQueue, name: String = UUID().uuidString) throws -> VoiceSharingQueue.Entry {
        _ = queue.publish(
            audio: Data(repeating: 7, count: 16),
            metadata: Data(#"{"enrollment_epoch":"epoch-1"}"#.utf8),
            name: name)
        return try XCTUnwrap(queue.entries().first { $0.name == name })
    }

    private func uploader(
        _ queue: VoiceSharingQueue,
        answer: @escaping (VoiceSharingQueue.Entry) async -> VoiceSharingUploader.Answer,
        refresh: @escaping () async -> Bool = { true },
        identity: @escaping () -> (account: String, epoch: String)? = { ("acct-1", "epoch-1") },
        sharing: @escaping () -> Bool = { true },
        now: @escaping () -> Date = Date.init
    ) -> VoiceSharingUploader {
        VoiceSharingUploader(
            queue: queue,
            send: answer,
            refreshSignIn: refresh,
            currentIdentity: identity,
            sharingEnabled: sharing,
            now: now,
            log: { [weak self] in self?.log.append($0) })
    }

    // MARK: The answer table

    func test_any2xxDeletesTheRecording() async throws {
        for status in [200, 201, 204] {
            let q = queue()
            _ = try publish(q)
            let u = uploader(q, answer: { _ in .response(status: status) })
            await u.drain()
            XCTAssertEqual(q.count(), 0, "\(status) is an acceptance")
        }
    }

    func test_401RefreshesSignInAndRetriesWithoutDeleting() async throws {
        let q = queue()
        _ = try publish(q)
        var refreshed = 0
        var calls = 0
        let u = uploader(
            q,
            answer: { _ in
                calls += 1
                return calls == 1 ? .response(status: 401) : .response(status: 201)
            },
            refresh: { refreshed += 1; return true })
        await u.drain()

        XCTAssertEqual(refreshed, 1, "an expired sign-in is refreshed")
        XCTAssertEqual(q.count(), 0, "the retry then succeeded")
    }

    func test_401ThatCannotRefreshRetainsTheRecording() async throws {
        let q = queue()
        _ = try publish(q)
        let u = uploader(q, answer: { _ in .response(status: 401) }, refresh: { false })
        await u.drain()

        XCTAssertEqual(q.count(), 1, "a failed refresh says nothing about the recording")
        XCTAssertFalse(log.contains { $0.hasPrefix("delete") })
    }

    func test_everyOther4xxDeletesTheRecordingAsAFinalRefusal() async throws {
        for status in [400, 403, 404, 409, 410, 413, 415, 422] {
            try resetRoot()
            let q = queue()
            _ = try publish(q)
            let u = uploader(q, answer: { _ in .response(status: status) })
            await u.drain()
            XCTAssertEqual(q.count(), 0, "\(status) is final")
            XCTAssertTrue(log.contains { $0.contains("delete reason=refused-\(status)") },
                          "\(status) must delete for its own reason; log=\(log!)")
        }
    }

    func test_serverFailuresRetainTheRecordingAndBackOff() async throws {
        for status in [500, 502, 503] {
            try resetRoot()
            let q = queue()
            _ = try publish(q)
            let u = uploader(q, answer: { _ in .response(status: status) })
            let outcomes = await u.drain()
            XCTAssertEqual(q.count(), 1,
                           "\(status) is retryable; outcomes=\(outcomes) log=\(log!) "
                           + "entries=\(q.entries().map(\.name))")
        }
    }

    func test_noAnswerAtAllRetainsTheRecording() async throws {
        let q = queue()
        _ = try publish(q)
        let u = uploader(q, answer: { _ in .noAnswer })
        await u.drain()
        XCTAssertEqual(q.count(), 1)
    }

    // MARK: The delete conditions

    func test_sharingOffDeletesEveryRecording() async throws {
        let q = queue()
        _ = try publish(q, name: "a")
        _ = try publish(q, name: "b")
        let u = uploader(q, answer: { _ in .response(status: 201) }, sharing: { false })
        await u.drain()

        XCTAssertEqual(q.count(), 0)
        XCTAssertTrue(log.contains { $0.contains("delete reason=sharing-off") })
    }

    func test_aRecordingFromAnotherEpochIsDeleted() async throws {
        let q = queue()
        _ = try publish(q)
        let u = uploader(q, answer: { _ in .response(status: 201) }, identity: { ("acct-1", "epoch-2") })
        await u.drain()

        XCTAssertEqual(q.count(), 0)
        XCTAssertTrue(log.contains { $0.contains("delete reason=epoch-changed") })
    }

    func test_anUnreadableRecordingIsDeleted() async throws {
        let q = queue()
        let entry = try publish(q)
        try Data("not json".utf8).write(to: entry.metadataURL)
        let u = uploader(q, answer: { _ in .response(status: 201) })
        await u.drain()

        XCTAssertEqual(q.count(), 0)
        XCTAssertTrue(log.contains { $0.contains("delete reason=unreadable") })
    }

    // MARK: Not stalling

    func test_oneFailingRecordingDoesNotBlockTheOthers() async throws {
        let q = queue()
        _ = try publish(q, name: "first")
        _ = try publish(q, name: "second")
        let u = uploader(q, answer: { entry in
            entry.name == "first" ? .response(status: 503) : .response(status: 201)
        })
        await u.drain()

        XCTAssertEqual(q.count(), 1, "only the retryable one remains")
        XCTAssertEqual(q.entries().first?.name, "first")
    }
}