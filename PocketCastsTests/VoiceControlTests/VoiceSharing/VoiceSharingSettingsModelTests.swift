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
        let token = model.addStateObserver { published.append($0) }
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
