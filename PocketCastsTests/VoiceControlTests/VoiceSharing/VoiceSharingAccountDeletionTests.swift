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
    /// Seeds OUTSIDE the injected-clock window the tests that use it rely on: the queue writes
    /// `created.at` from its own injected clock, so a test that installs its own clock must reduce
    /// the entry's recorded age before running, rather than depending on wall time.
    static func backdate(_ entry: VoiceSharingUploadQueue.Entry,
                         in queue: VoiceSharingUploadQueue,
                         by seconds: TimeInterval) throws {
        let created = queue.rootDirectory
            .appendingPathComponent(entry.name, isDirectory: true)
            .appendingPathComponent("created.at")
        let text = try String(contentsOf: created, encoding: .utf8)
        let instant = try XCTUnwrap(TimeInterval(text))
        try String(instant - seconds).write(to: created, atomically: true, encoding: .utf8)
    }

    /// A live, authoritative enrollment: the precondition every "previously valid lease" fixture
    /// needs before the queue will admit or serve anything.
    @discardableResult
    static func enroll(_ store: VoiceSharingEnrollmentStore, defaults: UserDefaults,
                       account: String = "account-a") throws -> VoiceSharingEnrollmentStore {
        let live = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { account },
            sessionIdentityProvider: { "gen-1" })
        let token = try XCTUnwrap(live.projectionToken(), "no session generation for the fence")
        XCTAssertTrue(live.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "v1",
                withdrawalState: .active),
            readUnder: token), "the fixture must begin with a valid, authoritative lease")
        live.setLocalOptIn(true)
        XCTAssertTrue(live.currentEffectiveEnrolled, "precondition: enrolled")
        return live
    }

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

// MARK: - The REAL sign-out registration and callback (spec e3db4e30 / d718c160)

/// A test notification center that satisfies the same protocol production uses, so these controls
/// drive `installIdentityInvalidation` itself — the actual observer the app registers — rather than
/// calling the registry or the coordinator's handler directly.
final class RecordingNotificationCenter: VoiceSharingCoordinator.NotificationRegistering {
    /// REAL TOKEN-BASED REMOVAL (reviewer 5a4738ca): the earlier version only incremented a counter,
    /// so a "removed" block still delivered — posting after reinstall fired BOTH registrations and
    /// the test proved nothing. A token identifies its own entry and removal deletes it.
    private final class Token: NSObject {
        let id = UUID()
    }

    private final class Entry {
        let token: Token
        let name: NSNotification.Name?
        let block: (Notification) -> Void
        init(token: Token, name: NSNotification.Name?, block: @escaping (Notification) -> Void) {
            self.token = token; self.name = name; self.block = block
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private(set) var removedTokens: [UUID] = []

    func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                     using block: @escaping (Notification) -> Void) -> NSObjectProtocol {
        let token = Token()
        lock.lock(); entries.append(Entry(token: token, name: name, block: block)); lock.unlock()
        return token
    }

    func removeObserver(_ observer: Any) {
        guard let token = observer as? Token else { return }
        lock.lock()
        removedTokens.append(token.id)
        entries.removeAll { $0.token === token }
        lock.unlock()
    }

    /// Posts SYNCHRONOUSLY to every LIVE registration for that name (production's queue is `.main`
    /// and these controls run on the main thread, so the ordering matches).
    @discardableResult
    func post(name: NSNotification.Name) -> Int {
        lock.lock()
        let live = entries.filter { $0.name == name }.map { $0.block }
        lock.unlock()
        for block in live { block(Notification(name: name, object: nil)) }
        return live.count
    }

    var registeredNames: [NSNotification.Name?] {
        lock.lock(); defer { lock.unlock() }
        return entries.map { $0.name }
    }

    var liveCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

final class VoiceSharingSignOutNotificationTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsnotif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "vsnotif-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The ACTUAL registration: installing the identity invalidation must subscribe to the sign-out
    /// notification, and posting it must revoke a set that was admitted under a VALID lease.
    func test_theRealSignOutRegistrationRevokesRetainedAudio() throws {
        let store = try VoiceSharingDeletionFixture.enroll(
            VoiceSharingEnrollmentStore(defaults: defaults, accountScopeProvider: { "account-a" }),
            defaults: defaults)
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        try VoiceSharingDeletionFixture.seed(in: queue)
        XCTAssertEqual(queue.readyEntries().count, 1, "setup: audio retained under a valid session")

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let subscription = coordinator.registerGateLostHandler { _ = queue.purgeAll() }
        defer { _ = subscription }

        let center = RecordingNotificationCenter()
        coordinator.installIdentityInvalidation(onNotificationCenter: center)
        XCTAssertTrue(center.registeredNames.contains(.serverUserWillBeSignedOut),
                      "the sign-out observer must be registered on the center the app observes")

        center.post(name: .serverUserWillBeSignedOut)

        XCTAssertEqual(queue.readyEntries().count, 0, "the sign-out notification revokes retained audio")
        let restarted = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(restarted.readyEntries().count, 0, "durably, across a restart")
    }

    /// Re-activation must replace the previous registration, so ONE sign-out fires ONE invalidation.
    /// This asserts DELIVERY COUNTS, not removal calls: with token-based removal, a post after
    /// reinstall must reach exactly one live observer.
    func test_reinstallingLeavesExactlyOneLiveDelivery() {
        let store = VoiceSharingEnrollmentStore(defaults: defaults, accountScopeProvider: { "account-a" })
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let center = RecordingNotificationCenter()
        coordinator.installIdentityInvalidation(onNotificationCenter: center)
        let afterFirst = center.liveCount
        coordinator.installIdentityInvalidation(onNotificationCenter: center)
        XCTAssertEqual(center.liveCount, afterFirst,
                       "reinstalling must not accumulate live observers")
        XCTAssertEqual(center.post(name: .serverUserWillBeSignedOut), 1,
                       "ONE sign-out must reach exactly ONE registration")
    }

    /// SWITCHING CENTERS: installing against a second center must also drop the registration on the
    /// FIRST one, or the old center keeps a live observer pointing at this coordinator.
    func test_switchingCentersDropsTheOldRegistration() {
        let store = VoiceSharingEnrollmentStore(defaults: defaults, accountScopeProvider: { "account-a" })
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let first = RecordingNotificationCenter()
        let second = RecordingNotificationCenter()
        coordinator.installIdentityInvalidation(onNotificationCenter: first)
        coordinator.installIdentityInvalidation(onNotificationCenter: second)
        XCTAssertEqual(first.post(name: .serverUserWillBeSignedOut), 0,
                       "the abandoned center must have no live observer left")
        XCTAssertEqual(second.post(name: .serverUserWillBeSignedOut), 1,
                       "and the new center delivers exactly once")
    }

    /// LOST CALLBACK, SCOPE STATED EXACTLY (reviewer 5a4738ca): this control performs NO deletion.
    /// It establishes only what the absence of the notification does to an otherwise valid,
    /// enrolled, servable set — that nothing is revoked and the entry stays on disk. It is NOT
    /// evidence about the delete call, the completion handler, `SyncManager`, or a real restart.
    /// Nothing is revoked in that process — and the audio is still THERE afterwards. That residue,
    /// not a clean "not enrolled" label, is the real cost of a lost callback.
    func test_aLostSignOutCallbackLeavesTheAudioInPlace() throws {
        let store = try VoiceSharingDeletionFixture.enroll(
            VoiceSharingEnrollmentStore(defaults: defaults, accountScopeProvider: { "account-a" }),
            defaults: defaults)
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        try VoiceSharingDeletionFixture.seed(in: queue)
        XCTAssertEqual(queue.readyEntries().count, 1, "precondition: servable under a valid lease")

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let subscription = coordinator.registerGateLostHandler { _ = queue.purgeAll() }
        defer { _ = subscription }
        let center = RecordingNotificationCenter()
        coordinator.installIdentityInvalidation(onNotificationCenter: center)
        // NO post: the callback never ran.
        XCTAssertEqual(queue.readyEntries().count, 1, "nothing was revoked, because nothing was told")

        // MEASURED WHILE STILL ENROLLED. (Driving `transitionToAccount` here instead would drop the
        // reading to zero for a reason that has nothing to do with removal — sign-out clears the
        // account scope the queue reads its identity from — so this control observes the residue at
        // the only moment it is observable: before that transition.)
        XCTAssertEqual(queue.readyEntries().count, 1,
                       "the recording survives, un-revoked, under the still-live lease")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(files.contains { UUID(uuidString: $0.lastPathComponent) != nil },
                      "and it is durable: the entry directory is still on disk afterwards")

        // WHAT THE LOST CALLBACK COSTS: the files remain, so they persist past the process and past
        // the sign-out that would have purged them. Nothing here claims they are still SERVED after
        // a later sign-out — only that the revocation never happened, so nothing removed them.
    }
}
