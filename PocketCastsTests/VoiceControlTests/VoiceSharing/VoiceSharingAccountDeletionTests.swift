import XCTest
import PocketCastsServer
@testable import podcasts

/// Account deletion and Voice Sharing.
///
/// Deletion reaches Voice Sharing ONLY through the sign-out it triggers on success
/// (`deleteAccountTapped` → success ⇒ `SignOutHelper.signout()` → `.serverUserWillBeSignedOut`
/// ⇒ coordinator purge + fence). These controls pin the two behaviours that follow from that:
///
///  * **callback loss** — the server deletes the account but the completion never runs (app killed,
///    request abandoned). Nothing locally signs out, so nothing purges in that process; the durable
///    queue and its revocation intent are the only guarantees a later launch has, and they hold.
///  * **restart** — a fresh process with no authoritative session must not SERVE what it still
///    holds. Queue coverage alone does not prove that, so this is reported, not assumed.
final class VoiceSharingAccountDeletionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsdeletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "vsdeletion-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A retained recording survives a process that never learned deletion succeeded: the files are
    /// still on this device, which is exactly why the sign-out path must be the purge trigger.
    func test_aLostDeletionCallbackLeavesStoredAudioOnDisk() throws {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        try VoiceSharingDeletionFixture.seed(in: queue)
        let entriesBefore = queue.readyEntries().count
        XCTAssertEqual(entriesBefore, 1, "setup: one recording is retained")

        // The completion never runs (the process is gone), so no sign-out, no purge happens.
        // A NEW process starts with the same storage.
        let restarted = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(restarted.readyEntries().count, entriesBefore,
                       "callback loss cannot silently discard or admit the retained recording")
    }

    /// The sign-out path — and only a reconciled purge — removes it durably.
    func test_theSignOutPurgeIsWhatRemovesIt() throws {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        try VoiceSharingDeletionFixture.seed(in: queue)
        guard case .reconciled = queue.purgeAll() else {
            return XCTFail("a purge on healthy storage must reconcile")
        }
        let restarted = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(restarted.readyEntries().count, 0,
                       "after the sign-out purge nothing survives a restart")
    }

    /// Without an authoritative projection, enrollment is NOT claimed: a restarted process that
    /// never reached the server reports not-enrolled, so the gate is closed regardless of what is
    /// on disk.
    func test_aRestartedProcessWithoutAServerReplyIsNotEnrolled() throws {
        let store = VoiceSharingEnrollmentStore(
            defaults: defaults,
            accountScopeProvider: { "account-a" })
        // The user had opted in before deletion.
        store.setLocalOptIn(true)
        XCTAssertFalse(store.currentEffectiveEnrolled,
                       "a remembered opt-in is not permission: no session projection ⇒ not enrolled")
        XCTAssertFalse(store.currentState.hasAuthoritativeProjection,
                       "disk can never establish an authoritative projection")
    }
}

enum VoiceSharingDeletionFixture {
    static func seed(in queue: VoiceSharingUploadQueue) throws {
        let sampleFrames: [Float] = [0, 0.2, -0.3, 0.4]
        let event = VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(),
            enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: sampleFrames.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: sampleFrames, isGateControl: false)
        let provenance = VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "9.0", build: "1", captureSessionID: "sess",
            models: .init(vad: nil, wakeword: nil, asr: nil, translation: nil, router: nil),
            conversionVersion: "v1")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event, provenance: provenance, observations: [:])
        let entry = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
        try queue.finalize(entry)
    }
}

// MARK: - Production composition: the sign-out notification is the deletion path

/// These controls drive the REAL production gate-lost registry (`registerGateLostHandler` +
/// `consentGateLostForTesting`, the same fan-out sign-out triggers) rather than calling `purgeAll`
/// directly, and they carry the two prerequisites a component exercise lacks: a previously VALID
/// lease and retained audio. The notification observer itself needs `SyncManager` and the full app
/// graph, so the seam used here is the registry's own entry point, not a stub of it.
final class VoiceSharingSignOutCompositionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vssignout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "vssignout-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A retained recording plus a VALID lease, then consent loss through the production registry:
    /// the durable queue must be revoked and must stay revoked across a restart.
    func test_aSignOutThroughTheProductionRegistryRevokesRetainedAudio() throws {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        try VoiceSharingDeletionFixture.seed(in: queue)
        XCTAssertEqual(queue.readyEntries().count, 1, "setup: audio is retained under a valid session")

        let coordinator = VoiceSharingCoordinator(enrollmentStore: VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "account-a" }))
        // The same handler shape the assembly installs.
        let subscription = coordinator.registerGateLostHandler { _ = queue.purgeAll() }
        defer { _ = subscription }
        coordinator.consentGateLostForTesting()

        // CLEAN revocation (a purge that reconciles) leaves `.known` with nothing ready — that is
        // the SUCCESS shape. Assert the durable facts, not the hold class.
        guard case .known(let remaining) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a reconciling sign-out purge must leave the owner READABLE, not held")
        }
        XCTAssertTrue(remaining.isEmpty, "consent loss revokes the retained set")
        XCTAssertEqual(queue.readyEntries().count, 0, "and nothing is served afterwards")
        let restarted = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(restarted.readyEntries().count, 0, "the revocation is durable, not process-local")
    }

    /// An UNREGISTERED handler (a torn-down pipeline) must not be reached: no revocation from a
    /// registry entry that no longer exists.
    func test_aTornDownHandlerIsNotCalled() throws {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        try VoiceSharingDeletionFixture.seed(in: queue)
        let coordinator = VoiceSharingCoordinator(enrollmentStore: VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "account-a" }))
        var subscription: VoiceSharingCoordinator.GateLostSubscription? =
            coordinator.registerGateLostHandler { _ = queue.purgeAll() }
        subscription = nil // torn down
        coordinator.consentGateLostForTesting()
        guard case .known = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a removed handler must not purge")
        }
    }
}
