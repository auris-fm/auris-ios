import XCTest
@testable import podcasts

/// Controls for the BUILT-DISABLED Voice Sharing settings surface.
///
/// The property under test is not "the screen shows numbers" but "this screen cannot authorize
/// anything": no control enables collection, deletion routes through the owner-wide purge, and
/// every failure is reported rather than rendered as calm emptiness.
final class VoiceSharingSettingsModelTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingUploadQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vssettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func model(permitted: Bool = false,
                       queue: VoiceSharingUploadQueue? = nil) -> VoiceSharingSettingsModel {
        VoiceSharingSettingsModel(queue: queue ?? self.queue,
                                  isCollectionPermitted: { permitted })
    }

    /// The surface must be COMPILED OFF. If someone flips this, they are activating a feature —
    /// which is an owner decision, not a refactor.
    func test_surfaceIsCompiledOff() {
        XCTAssertFalse(VoiceSharingSettingsModel.surfaceEnabled,
                       "the settings surface must stay disabled until the owner approves activation")
        XCTAssertFalse(model().isSurfaceEnabled)
    }

    /// No settings control may enable collection: the model reports the LIVE policy and has no
    /// mutation that can change it. Removing the injectable permitted flag is impossible; this
    /// pins that the reported value is always exactly what the policy says, both ways.
    func test_reportedPermissionIsOnlyEverTheLivePolicy() {
        XCTAssertFalse(model(permitted: false).status().collectionPermitted)
        XCTAssertTrue(model(permitted: true).status().collectionPermitted)
        // Deleting contributions is not an authorization change: permission reads identically
        // before and after.
        _ = model(permitted: true).deleteAllContributions()
        XCTAssertTrue(model(permitted: true).status().collectionPermitted)
    }

    /// An empty queue reports zero entries and NOT held — the healthy case.
    func test_emptyQueueReportsHealthyStatus() {
        let status = model().status()
        XCTAssertEqual(status.readyEntries, 0)
        XCTAssertFalse(status.held, "an empty root with no intent is not a held owner")
    }

    /// A held owner (unknown coverage / unreconciled revocation) must render as HELD, never as a
    /// calm "0 stored contributions" that hides a problem.
    func test_heldOwnerRendersAsHeldNotEmpty() throws {
        // Leave a durable revocation intent that a purge could not retire.
        try Data([0x01]).write(to: root.appendingPathComponent("revocation.intent"))
        let heldQueue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let status = model(queue: heldQueue).status()
        XCTAssertTrue(status.held, "an unreconciled revocation must surface as held")
        XCTAssertEqual(status.readyEntries, 0)
    }

    /// Deletion goes through the owner-wide purge and reports the ACTUAL outcome.
    func test_deleteAllReportsTheRealPurgeOutcome() {
        let result = model().deleteAllContributions()
        XCTAssertTrue(result.fullyRevoked, "an empty queue reconciles trivially")
        XCTAssertEqual(result.removed, 0)

        // A refused purge (unlistable root) must report incompleteness, not success.
        let refusing = VoiceSharingUploadQueue(
            rootDirectory: root,
            clock: Date.init,
            listDirectoryBounded: { _, _, _ in throw CocoaError(.fileReadNoPermission) })
        let refused = model(queue: refusing).deleteAllContributions()
        XCTAssertFalse(refused.fullyRevoked, "a refused purge must never be reported as complete")
        XCTAssertEqual(refused.removed, 0)
    }

    /// The compiled bounds line is descriptive text built from the queue's own constants — it must
    /// not invent limits the queue does not enforce.
    func test_compiledBoundsDescriptionMatchesTheQueueConstants() {
        let text = model().compiledBoundsDescription
        XCTAssertTrue(text.contains("\(VoiceSharingUploadQueue.maxEntryAudioBytes / 1024) KB"))
        XCTAssertTrue(text.contains("\(Int(VoiceSharingUploadQueue.maxEntryAge / 3600)) hours"))
    }
}
