import XCTest

@testable import PocketCastsServer
@testable import PocketCastsUtils
@testable import podcasts

/// ACCOUNT replacement.
///
/// A recording belongs to the enrollment epoch it was captured under. When the signed-in account
/// changes, the live identity moves and every recording stamped with the old epoch belongs to an
/// epoch that is gone. The rule this control pins is that such a recording is DELETED rather than
/// sent: it must never travel under the new account's credential.
final class VoiceSharingAccountReplacementLiveControls: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AcctReplacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    /// An entry whose epoch does not match the live identity is deleted, and nothing is sent.
    func test_aRecordingFromASupersededEpochIsDeletedRatherThanSent() async throws {
        let queue = VoiceSharingQueue(root: root)
        try AudioFixture.makeReadyEntry(in: queue)
        XCTAssertEqual(queue.count(), 1, "setup: one recording is retained")

        var sent: [VoiceSharingQueue.Entry] = []
        // The live identity now names a different epoch from the one on the record.
        let uploader = VoiceSharingUploader(
            queue: queue,
            send: { entry in sent.append(entry); return .response(status: 201) },
            refreshSignIn: { true },
            currentIdentity: { (account: "acct-2", epoch: "epoch-2") },
            sharingEnabled: { true },
            now: Date.init)

        await uploader.drain()

        XCTAssertTrue(sent.isEmpty,
                      "a recording from another epoch must never be sent, not even to be refused")
        XCTAssertEqual(queue.count(), 0,
                       "and it does not survive: it belongs to an epoch that is gone")
    }

    /// The same recording IS sent while its own epoch is still current — so the refusal above is
    /// attributable to the epoch, not to the uploader simply never working.
    func test_aRecordingIsSentWhileItsOwnEpochIsCurrent() async throws {
        let queue = VoiceSharingQueue(root: root)
        let fixture = try AudioFixture.makeReadyEntry(in: queue)
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadataURL)) as? [String: Any])
        let recordedEpoch = try XCTUnwrap(record["enrollment_epoch"] as? String)

        var sent: [VoiceSharingQueue.Entry] = []
        let uploader = VoiceSharingUploader(
            queue: queue,
            send: { entry in sent.append(entry); return .response(status: 201) },
            refreshSignIn: { true },
            currentIdentity: { (account: "acct-1", epoch: recordedEpoch) },
            sharingEnabled: { true },
            now: Date.init)

        await uploader.drain()

        XCTAssertEqual(sent.count, 1, "the owning epoch's recording does reach the wire")
        XCTAssertEqual(queue.count(), 0, "and an accepted recording is deleted")
    }
}