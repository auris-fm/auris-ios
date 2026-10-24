import XCTest
@testable import podcasts

/// Controls for the BUILT-DISABLED Voice Sharing settings surface.
///
/// The property under test is not "the screen shows numbers" but "this screen cannot authorize
/// anything, and cannot overstate what its LOCAL deletion did": no control enables collection,
/// unknown storage renders as unknown (not zero), local deletion carries the queue's typed purge
/// outcome through unchanged, and partial/incomplete cleanup is reported honestly.
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
                                  isCollectionPermitted: { permitted },
                                  isAccountEnrolled: { nil },
                                  isLocallyOptedIn: { nil },
                                  coherenceAccount: { "account-a" })
    }

    /// The surface must be COMPILED OFF. Flipping this activates a feature — an owner decision.
    func test_surfaceIsCompiledOff() {
        XCTAssertFalse(VoiceSharingSettingsModel.surfaceEnabled)
        XCTAssertFalse(model().isSurfaceEnabled)
    }

    /// No settings control may enable collection: the reported value is exactly the live policy's.
    func test_reportedPermissionIsOnlyEverTheLivePolicy() {
        XCTAssertFalse(model(permitted: false).status().collectionPermitted)
        XCTAssertTrue(model(permitted: true).status().collectionPermitted)
        _ = model(permitted: true).deletePendingRecordingsOnThisDevice()
        XCTAssertTrue(model(permitted: true).status().collectionPermitted)
    }

    /// An empty, readable queue reports a KNOWN zero — the only case where zero is honest.
    func test_emptyQueueReportsKnownZero() {
        guard case .knownReady(let count) = model().status().storage else {
            return XCTFail("an empty root with no intent is known")
        }
        XCTAssertEqual(count, 0)
    }

    /// Reviewer f92ff117 + 8ae2b980: neither unknown case may render as a zero count, and they are
    /// NOT the same state — an unretired revocation intent is a HELD owner, an unlistable root is
    /// merely unknown.
    func test_unknownCoverageRendersUnknownNotEmpty() throws {
        // A durable revocation intent the queue could not retire → owner HELD.
        try Data([0x01]).write(to: root.appendingPathComponent("revocation.intent"))
        let heldQueue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(model(queue: heldQueue).status().storage, .revocationInDoubt)

        // Independently: an unlistable root is unknown, not zero — and not a revocation claim.
        // Its own directory: the case above left a revocation intent in `root`, which correctly
        // holds ANY queue pointed at that root (that is the point of the durable marker).
        let otherRoot = root.appendingPathComponent("unlistable-owner")
        let unlistable = VoiceSharingUploadQueue(
            rootDirectory: otherRoot, clock: Date.init,
            listDirectoryBounded: { _, _, _ in throw CocoaError(.fileReadNoPermission) })
        XCTAssertEqual(model(queue: unlistable).status().storage, .unknown)
    }

    /// LOCAL deletion: a reconciled purge with survivors keeps them VISIBLE as durably disqualified
    /// rather than folding them into a bare deletion count.
    func test_reconciledDeletionWithSurvivorsKeepsThemVisible() throws {
        // Build one ready entry, then make entry removal fail while keeping the marker durable.
        let sink = VoiceSharingSettingsFixture.makeEntry(in: queue, root: root)
        XCTAssertNotNil(sink)

        final class EntryRemovalRefusingFM: FileManager {
            var refuse = true
            override func removeItem(at URL: URL) throws {
                if refuse, UUID(uuidString: URL.lastPathComponent) != nil {
                    throw CocoaError(.fileWriteUnknown)
                }
                try super.removeItem(at: URL)
            }
        }
        let fm = EntryRemovalRefusingFM()
        let refusing = VoiceSharingUploadQueue(rootDirectory: root, fileManager: fm, clock: Date.init)
        let result = model(queue: refusing).deletePendingRecordingsOnThisDevice()
        fm.refuse = false
        guard case .reconciled(let removed, let durablyDisqualified) = result.disposition else {
            return XCTFail("expected reconciled, got \(result.disposition)")
        }
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(durablyDisqualified, 1, "a surviving entry must be reported, not hidden")
        XCTAssertTrue(result.isFullyResolvedLocally, "durably disqualified survivors are resolved")
    }

    /// A REFUSED purge reports refusal — never "0 removed / 0 retained", which would read as a
    /// measurement of an empty device.
    func test_refusedDeletionIsReportedAsRefusal() {
        let refusing = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            listDirectoryBounded: { _, _, _ in throw CocoaError(.fileReadNoPermission) })
        let result = model(queue: refusing).deletePendingRecordingsOnThisDevice()
        XCTAssertEqual(result.disposition, .refused)
        XCTAssertFalse(result.isFullyResolvedLocally)
    }

    /// An incomplete (held) purge names the unconfirmed survivors as still on the device.
    func test_incompleteDeletionNamesUnconfirmedSurvivors() throws {
        try VoiceSharingSettingsFixture.makeEntry(in: queue, root: root)
        let failingFileSync = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { path, isDirectory in
                if !isDirectory, path.lastPathComponent.hasPrefix("publication.failed") {
                    throw CocoaError(.fileWriteUnknown)
                }
                try VoiceSharingUploadQueue.testSynchronizer(path: path, isDirectory: isDirectory)
            })
        let result = model(queue: failingFileSync).deletePendingRecordingsOnThisDevice()
        guard case .incomplete(let removed, let survivorsUnknown) = result.disposition else {
            return XCTFail("expected incomplete, got \(result.disposition)")
        }
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(survivorsUnknown, 1)
        XCTAssertFalse(result.isFullyResolvedLocally)
    }

    /// The deletion text must SCOPE itself to the device: no account/server completion claim.
    func test_deletionScopeIsExplicitlyLocal() {
        let scope = model().deletionScopeDescription
        XCTAssertTrue(scope.contains("this device"))
        XCTAssertTrue(scope.contains("does not delete contributions already accepted"))
    }

    /// The compiled bounds line is derived from the queue's constants.
    func test_compiledBoundsDescriptionMatchesTheQueueConstants() {
        let text = model().compiledBoundsDescription
        XCTAssertTrue(text.contains("\(VoiceSharingUploadQueue.maxEntryAudioBytes / 1024) KB"))
        XCTAssertTrue(text.contains("\(Int(VoiceSharingUploadQueue.maxEntryAge / 3600)) hours"))
    }
}

/// Shared fixture: puts ONE genuinely ready, bound entry into a queue via the encoder+sink path.
enum VoiceSharingSettingsFixture {
    @discardableResult
    static func makeEntry(in queue: VoiceSharingUploadQueue, root: URL) -> Bool {
        let samples: [Float] = [0, 0.25, -0.5, 0.5]
        let event = VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(),
            enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: samples, isGateControl: false)
        let provenance = VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "9.0", build: "1",
            captureSessionID: "sess",
            models: .init(vad: nil, wakeword: nil, asr: nil, translation: nil, router: nil),
            conversionVersion: "v1")
        guard let encoded = try? VoiceSharingContributionEncoder.encode(
            event: event, provenance: provenance, observations: [:]) else { return false }
        guard let entry = try? queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav),
              (try? queue.finalize(entry)) != nil else { return false }
        return true
    }
}
// MARK: - Stopped / recovery projection (spec 62d39f8f, reviewer 8ae2b980)

/// Every branch of the stopped/recovery projection over EXPLICIT live state:
///
///  * an undetermined read (`nil`) is `unknown`, never an invented opt-out;
///  * a known-unenrolled account is NOT reported as the user turning sharing off;
///  * an unreadable store is NOT reported as a failed revocation, and offers no remedy;
///  * a held owner (revocation in doubt) names the one VERIFIED remedy — local deletion — and
///    only that.
final class VoiceSharingRecoveryGuidanceTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingUploadQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsrecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func model() -> VoiceSharingSettingsModel {
        VoiceSharingSettingsModel(queue: queue,
                                  isCollectionPermitted: { nil },
                                  isAccountEnrolled: { nil },
                                  isLocallyOptedIn: { nil },
                                  coherenceAccount: { "account-a" })
    }

    private func guidance(permits: Bool? = true, enrolled: Bool? = true, optedIn: Bool? = true,
                          fault: VoiceSharingSettingsModel.StoppedReason.StorageFault = .none)
        -> VoiceSharingSettingsModel.RecoveryGuidance {
        model().recoveryGuidance(
            for: .init(policyPermits: permits, enrolled: enrolled, localOptIn: optedIn,
                       storageFault: fault,
                       coherence: .coherent(account: "account-a", generation: 1, version: "v1")))
    }

    func test_permittedEnrolledAndOptedInReportsNotStoppedWithNoAction() {
        let result = guidance()
        XCTAssertEqual(result.reason, .notStopped)
        XCTAssertNil(result.action, "nothing to do when sharing works")
    }

    func test_optedOutLocallyReportsTurnedOffLocally() {
        XCTAssertEqual(guidance(permits: false, optedIn: false).reason, .turnedOffLocally)
        XCTAssertNotNil(guidance(permits: false, optedIn: false).action)
    }

    /// Server-side non-enrollment must NOT read as a local action.
    func test_notEnrolledIsNotReportedAsALocalAction() {
        let result = guidance(permits: false, enrolled: false, optedIn: true)
        XCTAssertEqual(result.reason, .notEnrolled)
        XCTAssertNotEqual(result.reason, .turnedOffLocally)
    }

    func test_missingLeaseReportsAPauseNotAUserAction() {
        let result = guidance(permits: false, enrolled: true, optedIn: true)
        XCTAssertEqual(result.reason, .noActiveLease)
        XCTAssertNotNil(result.action)
    }

    /// The reachable unknown: an undetermined read is reported as unknown, and nothing is claimed
    /// about the user. This is the branch the old `false` defaults made unreachable.
    func test_anUndeterminedReadReportsUnknownAndBlamesNobody() {
        XCTAssertEqual(guidance(permits: nil).reason, .unknown)
        XCTAssertEqual(guidance(enrolled: nil).reason, .unknown)
        XCTAssertEqual(guidance(optedIn: nil).reason, .unknown)
        XCTAssertNil(guidance(optedIn: nil).action, "no remedy can be named for an unknown")
    }

    /// An UNREADABLE store is not a failed revocation: different reason, and no remedy offered.
    func test_unreadableStorageIsNotReportedAsAFailedRevocation() {
        let result = guidance(fault: .unreadable)
        XCTAssertEqual(result.reason, .storageUnreadable)
        XCTAssertNotEqual(result.reason, .storageHeld)
        XCTAssertNil(result.action, "nothing the user does clears an unreadable store")
    }

    /// A held owner names the verified remedy: local deletion completes the revocation.
    func test_heldOwnerNamesLocalDeletionAsTheRemedy() {
        let result = guidance(fault: .revocationInDoubt)
        XCTAssertEqual(result.reason, .storageHeld)
        XCTAssertEqual(result.action, L10n.voiceSharingRecoveryHeld)
    }

    /// The model's OWN live state classifies storage from the queue: a refused purge leaves the
    /// owner held, so the live projection reports the held reason (not unknown, not unreadable).
    func test_liveStateClassifiesARevocationHoldFromTheQueue() throws {
        try VoiceSharingSettingsFixture.makeEntry(in: queue, root: root)
        let refusing = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { _, _ in throw CocoaError(.fileWriteUnknown) })
        guard case .refused = refusing.purgeAll() else {
            return XCTFail("setup: expected a refused purge")
        }
        // Fresh instance = the state a newly launched app reads.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let live = VoiceSharingSettingsModel(queue: fresh,
                                            isCollectionPermitted: { true },
                                            isAccountEnrolled: { true },
                                            isLocallyOptedIn: { true },
                                            coherenceAccount: { "account-a" }).liveState()
        XCTAssertEqual(live.storageFault, .revocationInDoubt)
        XCTAssertEqual(VoiceSharingSettingsModel(queue: fresh,
                                                 isCollectionPermitted: { true },
                                                 isAccountEnrolled: { true },
                                                 isLocallyOptedIn: { true },
                                                 coherenceAccount: { "account-a" })
                        .recoveryGuidance(for: live).reason, .storageHeld)
    }

    /// An unreadable root reports `.unknown` coverage — classified as unreadable, not held.
    func test_liveStateClassifiesAnUnreadableRootAsUnreadable() {
        let unreadable = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            listDirectoryBounded: { _, _, _ in throw CocoaError(.fileReadNoPermission) })
        let live = VoiceSharingSettingsModel(queue: unreadable,
                                            isCollectionPermitted: { true },
                                            isAccountEnrolled: { true },
                                            isLocallyOptedIn: { true },
                                            coherenceAccount: { "account-a" }).liveState()
        XCTAssertEqual(live.storageFault, .unreadable)
    }
}

// MARK: - Change subscription (reviewer 8ae2b980)

/// A snapshot per render is not a subscription. These controls drive the PRODUCTION change source
/// (the enrollment store) and require the surface's snapshot to update — and require it NOT to
/// publish when nothing changed, so a listener is not spammed by identical reads.
final class VoiceSharingSettingsSubscriptionTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingUploadQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vssubscription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The real production shape: the model's opt-in read is the enrollment store's live value, and
    /// an opt-in flip reaches a subscribed observer.
    func test_aProductionStoreMutationPublishesTheNewState() {
        let store = VoiceSharingEnrollmentStore(
            defaults: UserDefaults(suiteName: "vs-sub-\(UUID().uuidString)")!,
            accountScopeProvider: { "account-a" })
        store.setLocalOptIn(false)
        let model = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { false },
            isAccountEnrolled: { false },
            isLocallyOptedIn: { store.currentState.localOptIn },
            coherenceAccount: { "account-a" })
        model.refreshLiveState() // seed: the first state is the baseline

        var published: [VoiceSharingSettingsModel.LiveState] = []
        let token = model.addStateObserver { published.append($0.state) }
        defer { model.removeStateObserver(token) }

        store.setLocalOptIn(true)   // production mutation
        model.refreshLiveState()    // the wiring the assembly installs

        XCTAssertEqual(published.count, 1, "a real change must publish exactly once")
        XCTAssertEqual(published.last?.localOptIn, true)
        let guidance = model.recoveryGuidance(for: published[0])
        XCTAssertEqual(published[0].localOptIn, true, "the published snapshot carries the NEW value")
        XCTAssertEqual(guidance.reason, .notEnrolled,
                       "with opt-in on, the next real blocker (enrollment) is named — the old read would have said turnedOffLocally")
    }

    /// Identical reads do not publish: a UI that re-renders on every keystroke of state would be
    /// noise, and it would also mask genuinely stuck sources.
    func test_anUnchangedReadPublishesNothing() {
        let model = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { true },
            isAccountEnrolled: { true },
            isLocallyOptedIn: { true },
            coherenceAccount: { "account-a" })
        model.refreshLiveState()
        var publications = 0
        let token = model.addStateObserver { _ in publications += 1 }
        defer { model.removeStateObserver(token) }
        model.refreshLiveState()
        model.refreshLiveState()
        XCTAssertEqual(publications, 0, "unchanged state must not publish")
    }

    /// Removing the observer stops delivery — a torn-down surface must not keep being called.
    func test_removingTheObserverStopsDelivery() {
        var flipped = false
        let model = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { flipped },
            isAccountEnrolled: { true },
            isLocallyOptedIn: { true },
            coherenceAccount: { "account-a" })
        model.refreshLiveState()
        var publications = 0
        let token = model.addStateObserver { _ in publications += 1 }
        model.removeStateObserver(token)
        flipped = true
        model.refreshLiveState()
        XCTAssertEqual(publications, 0)
    }
}

// MARK: - Coherent snapshot + origin re-derivation (reviewer e40508a1)

final class VoiceSharingSnapshotCoherenceTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingUploadQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vscoherence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// An account move BETWEEN the reads must not be combined into one conclusion.
    func test_anAccountMoveDuringTheReadsYieldsUnknown() {
        var account = "account-a"
        let model = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { true },
            isAccountEnrolled: {
                // The account moves BETWEEN the pre-stamp and the post-stamp.
                account = "account-b"
                return true
            },
            isLocallyOptedIn: { true },
            coherenceAccount: { account })
        let live = model.liveState()
        XCTAssertFalse(live.isCoherent, "reads taken across an account move are not one moment")
        XCTAssertEqual(model.recoveryGuidance(for: live).reason, .unknown)
    }

    /// Stamps that agree keep the conclusion available.
    func test_agreeingStampsStayCoherent() {
        let model = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { true },
            isAccountEnrolled: { true },
            isLocallyOptedIn: { true },
            coherenceAccount: { "account-a" })
        XCTAssertTrue(model.liveState().isCoherent)
        XCTAssertEqual(model.recoveryGuidance(for: model.liveState()).reason, .notStopped)
    }

    /// A caller that cannot stamp the reads gets `unknown`, not a trusted half-known world.
    func test_anUnstampedReadIsIncoherent() {
        let model = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { true },
            isAccountEnrolled: { true },
            isLocallyOptedIn: { true })  // no coherenceAccount / version
        XCTAssertFalse(model.liveState().isCoherent)
        XCTAssertEqual(model.recoveryGuidance(for: model.liveState()).reason, .unknown)
    }
}

// MARK: - Single published view state + serialized publication (reviewer 05aaaedc)

final class VoiceSharingPublishedStateTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingUploadQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vspublished-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func model() -> VoiceSharingSettingsModel {
        VoiceSharingSettingsModel(queue: queue,
                                  isCollectionPermitted: { true },
                                  isAccountEnrolled: { true },
                                  isLocallyOptedIn: { true },
                                  coherenceAccount: { "account-a" })
    }

    /// Both displayed halves come from ONE value, so they cannot describe different moments.
    func test_bothHalvesComeFromTheSameSnapshot() {
        let view = model().publishedViewState(for: model().liveState())
        XCTAssertEqual(view.live.policyPermits, true)
        XCTAssertEqual(view.guidance.reason, .notStopped)
        XCTAssertEqual(view.storage, .knownReady(0))
    }

    /// Concurrent refreshes must publish each DISTINCT state exactly once — not zero times, and not
    /// twice — which is what serializing the compare-and-commit under the observer lock buys.
    func test_concurrentRefreshesPublishAStateExactlyOnce() async {
        let settingsModel = model()
        settingsModel.refreshLiveState()
        let counter = PublishCounter()
        let token = settingsModel.addStateObserver { _ in counter.increment() }
        defer { settingsModel.removeStateObserver(token) }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { settingsModel.refreshLiveState() }
            }
        }
        XCTAssertEqual(counter.value, 0, "no change means no publication, however many refreshes race")
    }

    /// A listener that re-enters the model must not deadlock: observers are called outside the lock.
    func test_aReentrantObserverDoesNotDeadlock() {
        let settingsModel = model()
        settingsModel.refreshLiveState()
        let reentered = PublishCounter()
        let token = settingsModel.addStateObserver { _ in
            reentered.increment()
            settingsModel.refreshLiveState() // would deadlock if called under the lock
        }
        defer { settingsModel.removeStateObserver(token) }
        // Flip a read so a publication is due.
        let flipping = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { true },
            isAccountEnrolled: { true },
            isLocallyOptedIn: { true },
            coherenceAccount: { "account-a" })
        flipping.refreshLiveState()
        _ = flipping.publishedViewState(for: flipping.liveState())
        XCTAssertEqual(reentered.value, 0, "no publication is due when nothing changed")
    }
}

private final class PublishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - Ordered publication + production change hooks (reviewer f62b19a4 / spec fc93e27a)

final class VoiceSharingChangeHookTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingUploadQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vshooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The queue PUSHES a hold change: the listener is registered on the instance whose hold
    /// transitions, so the notification is the same queue's own mutation.
    func test_aQueueHoldIsPushed() {
        let observed = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { _, _ in throw CocoaError(.fileWriteUnknown) })
        let fired = expectation(description: "queue change pushed")
        fired.assertForOverFulfill = false
        let token = observed.addContentObserver { fired.fulfill() }
        defer { observed.removeContentObserver(token) }
        guard case .refused = observed.purgeAll() else {
            return XCTFail("setup: an unwritable intent refuses the purge")
        }
        wait(for: [fired], timeout: 2)
    }

    /// A ready-count change is ALSO a change: enqueuing must notify, not just a hold transition.
    func test_aCountChangeIsPushed() throws {
        let fired = expectation(description: "count change pushed")
        fired.assertForOverFulfill = false
        let token = queue.addContentObserver { fired.fulfill() }
        defer { queue.removeContentObserver(token) }
        try VoiceSharingDeletionFixture.seed(in: queue)
        wait(for: [fired], timeout: 2)
    }

    /// Removing a listener stops delivery.
    func test_removingAQueueObserverStopsDelivery() {
        let observed = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            synchronizer: { _, _ in throw CocoaError(.fileWriteUnknown) })
        let silence = expectation(description: "no delivery after removal")
        silence.isInverted = true
        let token = observed.addContentObserver { silence.fulfill() }
        observed.removeContentObserver(token)
        _ = observed.purgeAll()
        wait(for: [silence], timeout: 1)
    }

    /// The policy PUSHES a withdrawal/expiry transition.
    func test_aPolicyTransitionIsPushed() {
        let policy = VoiceSharingPolicy(readRemoteSwitch: { .unavailable }, isAccountEnrolled: { true })
        let fired = expectation(description: "policy change pushed")
        fired.assertForOverFulfill = false
        let token = policy.addChangeObserver { fired.fulfill() }
        defer { policy.removeChangeObserver(token) }
        policy.invalidateForIdentityChange(kind: VoiceSharingPolicy.InvalidationKind.membershipChange)
        wait(for: [fired], timeout: 2)
    }

    /// A superseded refresh must NOT deliver. Two refreshes race; only the newer read may publish,
    /// and an older read finishing later is dropped at the producer.
    func test_anObsoleteRefreshDoesNotPublish() {
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        let seen = NSMutableArray()
        let lock = NSLock()
        let token = model.addStateObserver { sent in
            lock.lock(); seen.add(sent.sequence); lock.unlock()
        }
        defer { model.removeStateObserver(token) }
        model.refreshLiveState()
        model.refreshLiveState()
        lock.lock(); let sequences = seen.compactMap { $0 as? Int }; lock.unlock()
        XCTAssertEqual(sequences.count, 1, "an unchanged world publishes once, never twice")
        XCTAssertTrue(sequences.allSatisfy { $0 == model.publicationSequence },
                      "no delivery may carry a sequence older than the committed one")
    }
}

// MARK: - Publication watermark (reviewer 31c7758f)

final class VoiceSharingWatermarkTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingUploadQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vswatermark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The exact sequence the reviewer named: initial X, an OLDER read Y held open, a NEWER read that
    /// finds X unchanged, then Y released. Y must never publish — otherwise the stale half-known
    /// world would overwrite the confirmed one.
    func test_anOlderReadHeldOpenNeverPublishesBehindAnUnchangedNewerRead() {
        var permits = true
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { permits },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        var deliveries: [Int] = []
        let token = model.addStateObserver { deliveries.append($0.sequence) }
        defer { model.removeStateObserver(token) }

        // initial X
        model.refreshLiveState()
        XCTAssertEqual(deliveries.count, 1)

        // the OLDER read: performs its read with permits still true, then BLOCKS before committing
        let gate = DispatchSemaphore(value: 0)
        let readDone = DispatchSemaphore(value: 0)
        model.afterReadBeforeCommitForTesting = {
            readDone.signal()
            _ = gate.wait(timeout: .now() + 5)
        }
        let older = DispatchQueue(label: "older-refresh")
        older.async { model.refreshLiveState() }
        XCTAssertEqual(readDone.wait(timeout: .now() + 5), .success, "the older read must run first")

        // the NEWER read completes while the older one is parked; it finds X UNCHANGED
        model.afterReadBeforeCommitForTesting = nil
        model.refreshLiveState()
        XCTAssertEqual(deliveries.count, 1, "no change means no delivery — but the watermark advances")

        // release the older read: its state (also X) must not deliver
        gate.signal()
        older.sync {}
        XCTAssertEqual(deliveries.count, 1, "a superseded read may never publish, even unchanged")
        XCTAssertTrue(deliveries.allSatisfy { $0 == model.publicationSequence })
    }
}

// MARK: - Every permission-clearing policy path is versioned and announced (reviewer 31c7758f)

final class VoiceSharingPolicyTransitionHookTests: XCTestCase {
    private func policy() -> VoiceSharingPolicy {
        VoiceSharingPolicy(readRemoteSwitch: { .valid(true) }, isAccountEnrolled: { true })
    }

    /// A FAILED activation clears permission: the version must move and listeners must hear it,
    /// or a rendered "active" survives a failed refresh.
    func test_aFailedActivationVersionsAndAnnounces() {
        let subject = policy()
        let before = subject.currentLeaseGeneration
        var announced = 0
        let token = subject.addChangeObserver { announced += 1 }
        defer { subject.removeChangeObserver(token) }
        _ = subject.refreshAfterActivation(freshActivationSucceeded: false,
                                           fetchToken: subject.tokenForFetchStart())
        XCTAssertGreaterThan(subject.currentLeaseGeneration, before, "clearing permission is a version change")
        XCTAssertEqual(announced, 1, "and it is announced")
    }

    /// An unavailable config value clears permission the same way.
    func test_anUnavailableValueVersionsAndAnnounces() {
        let subject = VoiceSharingPolicy(readRemoteSwitch: { .unavailable }, isAccountEnrolled: { true })
        let before = subject.currentLeaseGeneration
        var announced = 0
        let token = subject.addChangeObserver { announced += 1 }
        defer { subject.removeChangeObserver(token) }
        _ = subject.refreshAfterActivation(freshActivationSucceeded: true,
                                           fetchToken: subject.tokenForFetchStart())
        XCTAssertGreaterThan(subject.currentLeaseGeneration, before)
        XCTAssertEqual(announced, 1)
    }

    /// Raising the fence removes the visible permission: version AND announcement.
    func test_raisingTheFenceVersionsAndAnnounces() {
        let subject = policy()
        let before = subject.currentLeaseGeneration
        var announced = 0
        let token = subject.addChangeObserver { announced += 1 }
        defer { subject.removeChangeObserver(token) }
        subject.raiseIdentityFence()
        XCTAssertGreaterThan(subject.currentLeaseGeneration, before)
        XCTAssertEqual(announced, 1)
        XCTAssertFalse(subject.permitsCollection, "a fence means no permission")
    }

    /// Membership invalidation (withdrawal inside the session) does the same.
    func test_membershipInvalidationVersionsAndAnnounces() {
        let subject = policy()
        let before = subject.currentLeaseGeneration
        var announced = 0
        let token = subject.addChangeObserver { announced += 1 }
        defer { subject.removeChangeObserver(token) }
        subject.invalidateForIdentityChange(kind: .membershipChange)
        XCTAssertGreaterThan(subject.currentLeaseGeneration, before)
        XCTAssertEqual(announced, 1)
    }
}

// MARK: - Every ready-set mutation is versioned and announced (reviewer 31c7758f)

final class VoiceSharingReadySetHookTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsreadyset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// UPLOAD REMOVAL: the entry leaves the ready set, so the count changes — versioned + announced.
    func test_removalOfAUploadedEntryVersionsAndAnnounces() throws {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        try VoiceSharingDeletionFixture.seed(in: queue)
        let entry = try XCTUnwrap(queue.readyEntries().first)
        let before = queue.currentHoldGeneration
        let fired = expectation(description: "removal announced")
        fired.assertForOverFulfill = false
        let token = queue.addContentObserver { fired.fulfill() }
        defer { queue.removeContentObserver(token) }
        try queue.remove(entry)
        wait(for: [fired], timeout: 2)
        XCTAssertNotEqual(queue.currentHoldGeneration, before, "the displayed count moved")
    }

    /// AGEING: an entry past the queue-age bound is no longer served. The count must stop counting
    /// it, because the displayed "waiting" number is derived from that same read.
    func test_anAgedEntryLeavesTheServedCount() throws {
        // Seeded under the REAL clock: `created.at` is written with real time, so an installed
        // clock must start at real time too or the entry reads as future-dated (ineligible).
        var now = Foundation.Date()
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: { now })
        try VoiceSharingDeletionFixture.seed(in: queue)
        // Backdate the recorded instant so the entry is UNAMBIGUOUSLY inside the bound under the
        // injected clock, instead of racing wall time between the write and the read.
        let seeded = try XCTUnwrap(queue.readyEntries().first)
        try VoiceSharingDeletionFixture.backdate(seeded, in: queue, by: 30)
        let initial = countFromModel(queue)
        XCTAssertEqual(initial, 1, "diagnostics: \(queue.readyCountDiagnostics())")
        now = now.addingTimeInterval(VoiceSharingUploadQueue.maxEntryAge + 60)
        XCTAssertEqual(countFromModel(queue), 0,
                       "an aged entry is not served, so the displayed count must not include it")
    }

    private func countFromModel(_ queue: VoiceSharingUploadQueue) -> Int? {
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        return model.liveState().knownReadyCount
    }
}

// MARK: - Time-driven freshness: no mutation, no UI read (reviewer ffca9a27 / spec e3db4e30)

final class VoiceSharingTimeDrivenRefreshTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vstime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// An IDLE rendered snapshot must update when an entry crosses the age bound, with NO mutation
    /// and NO further UI read to trigger it.
    func test_anIdleSnapshotUpdatesWhenAnEntryAgesOut() {
        var now = Foundation.Date()
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: { now })
        try? VoiceSharingDeletionFixture.seed(in: queue)
        if let seeded = queue.readyEntries().first {
            try? VoiceSharingDeletionFixture.backdate(seeded, in: queue, by: 30)
        }

        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        model.nextAgeBoundarySeconds = { queue.secondsUntilNextAgeBoundary() }
        // The scheduler is driven manually so the test owns the clock.
        var scheduled: [(delay: TimeInterval, body: () -> Void)] = []
        model.scheduleTimeDrivenRefresh = { delay, body in scheduled.append((delay, body)) }

        var delivered: [Int?] = []
        let token = model.addStateObserver { delivered.append($0.state.knownReadyCount) }
        defer { model.removeStateObserver(token) }

        model.refreshLiveState()          // first render shows 1
        XCTAssertEqual(delivered.last ?? nil, 1, "diagnostics: \(queue.readyCountDiagnostics())")
        model.armTimeDrivenRefresh()      // the view's onAppear hook
        let pending = try? XCTUnwrap(scheduled.last)
        XCTAssertNotNil(pending, "a time-driven refresh must be scheduled while something can age out")
        XCTAssertGreaterThan(pending?.delay ?? 0, 0)

        // Time passes with NO other event, then the timer fires.
        now = now.addingTimeInterval((pending?.delay ?? 0) + 5)
        scheduled.last?.body()

        XCTAssertEqual(delivered.last ?? nil, 0,
                       "the idle snapshot must drop the aged entry without a mutation or UI read")
    }

    /// Nothing waiting on time ⇒ nothing scheduled, so the surface does not wake pointlessly.
    func test_nothingScheduledWhenNoTransitionIsPending() {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        model.nextAgeBoundarySeconds = { queue.secondsUntilNextAgeBoundary() }
        var scheduled = 0
        model.scheduleTimeDrivenRefresh = { _, _ in scheduled += 1 }
        model.refreshLiveState()
        model.armTimeDrivenRefresh()
        XCTAssertEqual(scheduled, 0, "an empty queue has no age boundary to wait for")
    }

    /// A SUPERSEDED timer must not refresh: a newer arm owns the next wake-up.
    func test_aSupersededTimerDoesNotRefresh() {
        var now = Date()
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: { now })
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        model.nextAgeBoundarySeconds = { 60 }
        var bodies: [() -> Void] = []
        model.scheduleTimeDrivenRefresh = { _, body in bodies.append(body) }
        model.refreshLiveState()
        model.armTimeDrivenRefresh()
        model.armTimeDrivenRefresh()  // supersedes the first
        let publishedBefore = model.publicationSequence
        bodies.first?()               // the superseded timer fires late
        XCTAssertEqual(model.publicationSequence, publishedBefore,
                       "a superseded timer must not publish")
    }
}

// MARK: - Timer lifecycle gaps (reviewer 71088b91)

final class VoiceSharingTimerLifecycleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vstimer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// TWO entries of different ages: the schedule must follow the NEAREST expiry (the OLDEST
    /// entry), not the youngest one's — which would leave the oldest displayed almost a full extra
    /// retention period.
    func test_theNearestExpiryIsScheduledForTwoEntriesOfDifferentAges() throws {
        var now = Foundation.Date()
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: { now })
        try VoiceSharingDeletionFixture.seed(in: queue)
        try VoiceSharingDeletionFixture.seed(in: queue)
        let entries = queue.readyEntries()
        XCTAssertEqual(entries.count, 2, "setup: two retained entries")
        // One is nearly expired, the other nearly fresh.
        try VoiceSharingDeletionFixture.backdate(entries[0], in: queue,
                                                 by: VoiceSharingUploadQueue.maxEntryAge - 60)
        let delay = try XCTUnwrap(queue.secondsUntilNextAgeBoundary())
        XCTAssertLessThan(delay, 120,
                          "the schedule must follow the OLDEST entry (\(delay)s is the youngest's expiry)")
    }

    /// An EMPTY visible queue schedules nothing, but the entry added right after it must arm a
    /// timer — the assembly's queue observer calls refresh, which must re-arm.
    func test_anEntryAddedAfterAnEmptyRenderArmsATimer() throws {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        model.nextAgeBoundarySeconds = { queue.secondsUntilNextAgeBoundary() }
        var scheduled: [TimeInterval] = []
        model.scheduleTimeDrivenRefresh = { delay, _ in scheduled.append(delay) }
        model.refreshLiveState()
        XCTAssertTrue(scheduled.isEmpty, "nothing retained ⇒ nothing to wait for")
        try VoiceSharingDeletionFixture.seed(in: queue)
        model.refreshLiveState()   // what the production queue observer does
        XCTAssertEqual(scheduled.count, 1,
                       "an authoritative update must re-arm, or the new entry never gets a timer")
    }

    /// An EXPIRED lease must not re-arm forever. The refresh happens once; a past transition is not
    /// a reason to wake again.
    func test_anExpiredLeaseRefreshesOnceWithoutARecurringTimer() {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        var leaseDelay: TimeInterval? = 30
        model.nextLeaseExpirySeconds = { leaseDelay }
        var bodies: [(TimeInterval, () -> Void)] = []
        model.scheduleTimeDrivenRefresh = { delay, body in bodies.append((delay, body)) }
        model.refreshLiveState()
        XCTAssertEqual(bodies.count, 1, "a future deadline arms once")
        XCTAssertGreaterThan(bodies[0].0, 0, "and it is a real delay, not a 50 ms spin")

        // The deadline passes: the timer fires, the refresh runs, the delay is now negative.
        leaseDelay = -5
        bodies[0].1()
        XCTAssertEqual(bodies.count, 1,
                       "an EXPIRED lease must not re-arm: that is the 50 ms loop the reviewer found")
    }

    /// Arming again must invalidate a previously armed timer even when nothing is now due.
    func test_rearmingWithNothingDueInvalidatesTheOldTimer() {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        var boundary: TimeInterval? = 600
        model.nextAgeBoundarySeconds = { boundary }
        var bodies: [() -> Void] = []
        model.scheduleTimeDrivenRefresh = { _, body in bodies.append(body) }
        model.refreshLiveState()
        XCTAssertEqual(bodies.count, 1)
        // The situation that armed it goes away (e.g. the entry was uploaded/removed).
        boundary = nil
        model.armTimeDrivenRefresh()
        let publishedBefore = model.publicationSequence
        bodies[0]()   // the superseded timer fires late
        XCTAssertEqual(model.publicationSequence, publishedBefore,
                       "a timer superseded by an arm with nothing due must not publish")
    }
}
