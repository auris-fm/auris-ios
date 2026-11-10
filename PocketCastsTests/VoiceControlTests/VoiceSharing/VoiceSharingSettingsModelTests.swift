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
    private var queue: VoiceSharingQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vssettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingQueue(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func model(permitted: Bool = false,
                       queue: VoiceSharingQueue? = nil) -> VoiceSharingSettingsModel {
        VoiceSharingSettingsModel(queue: queue ?? self.queue,
                                  isCollectionPermitted: { permitted },
                                  isAccountEnrolled: { nil },
                                  isLocallyOptedIn: { nil },
                                  coherenceAccount: { "account-a" })
    }

    /// The surface's availability is a BUILD-CONFIGURATION fact, so the assertion has to match the
    /// condition the source is compiled under (`#if STAGING`) rather than assert one fixed value.
    /// The earlier version hard-coded `false` and failed whenever the tests were built in the
    /// configuration where the surface is intentionally ON. What must hold in BOTH configurations:
    /// the model reports exactly what the build compiled, and nothing else can flip it.
    /// Enabling the surface in a shipped build remains an owner decision.
    func test_surfaceIsCompiledOff() async {
        #if STAGING
        XCTAssertTrue(VoiceSharingSettingsModel.surfaceEnabled,
                      "a STAGING build compiles the surface ON")
        #else
        XCTAssertFalse(VoiceSharingSettingsModel.surfaceEnabled,
                       "a non-STAGING build compiles the surface OFF")
        #endif
        XCTAssertEqual(model().isSurfaceEnabled, VoiceSharingSettingsModel.surfaceEnabled,
                       "the model reports exactly what the build compiled — no runtime override")
    }

    /// No settings control may enable collection: the reported value is exactly the live policy's.
    func test_reportedPermissionIsOnlyEverTheLivePolicy() async {
        let denyModel = model(permitted: false)
        let denyStatus = await denyModel.status()
        XCTAssertFalse(denyStatus.collectionPermitted)
        let allowModel = model(permitted: true)
        let allowStatus = await allowModel.status()
        XCTAssertTrue(allowStatus.collectionPermitted)
        _ = await allowModel.deletePendingRecordingsOnThisDevice()
        let afterDelete = await allowModel.status()
        XCTAssertTrue(afterDelete.collectionPermitted)
    }

    /// An empty, readable queue reports a KNOWN zero — the only case where zero is honest.
    func test_emptyQueueReportsKnownZero() async {
        let reported = await model().status()
        guard case .knownReady(let count) = reported.storage else {
            return XCTFail("an empty root with no intent is known")
        }
        XCTAssertEqual(count, 0)
    }

    /// An unlistable root is unknown, never a zero count: "could not look" and "there is nothing"
    /// are different claims, and only one of them is true here.
    func test_anUnlistableRootRendersUnknownNotEmpty() async throws {
        let otherRoot = root.appendingPathComponent("unlistable-owner")
        // A FILE where a directory is expected: enumeration cannot succeed.
        try Data("not a directory".utf8).write(to: otherRoot)
        let unlistable = VoiceSharingQueue(root: otherRoot)
        let unlistableStatus = await model(queue: unlistable).status()
        XCTAssertEqual(unlistableStatus.storage, .unknown,
                       "a root that cannot be listed is unknown, not an empty device")
    }

    /// LOCAL deletion: a reconciled purge with survivors keeps them VISIBLE as durably disqualified
    /// rather than folding them into a bare deletion count.
    func test_reconciledDeletionWithSurvivorsKeepsThemVisible() async throws {
        // Build one ready entry, then make entry removal fail while keeping the marker durable.
        let sink = await VoiceSharingSettingsFixture.makeEntry(in: queue, root: root)
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
        let refusing = VoiceSharingQueue(root: root, fileManager: fm)
        let result = await model(queue: refusing).deletePendingRecordingsOnThisDevice()
        fm.refuse = false
        guard case .reconciled(let removed, let durablyDisqualified) = result.disposition else {
            return XCTFail("expected reconciled, got \(result.disposition)")
        }
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(durablyDisqualified, 1, "a surviving entry must be reported, not hidden")
        XCTAssertFalse(result.isFullyResolvedLocally,
                       "a recording still on the device means the deletion is not resolved")
    }

    /// AN UNREADABLE STORE IS A REFUSAL, NOT "Removed 0".
    ///
    /// `count()` returns 0 when the folder cannot be listed, so before this control an unlistable
    /// queue produced `.reconciled(removed: 0, ...)` — the surface then told the user "Removed 0
    /// recordings from this device", which reads as a successful purge of an empty device. The truth
    /// is that nothing could be enumerated and nothing was proven. The queue already exposes
    /// `isReadable` for exactly this distinction; the delete path simply was not consulting it.
    func test_unreadableQueueReportsRefusalRatherThanRemovingZero() async throws {
        _ = await VoiceSharingSettingsFixture.makeEntry(in: queue, root: root)
        // A folder that cannot be enumerated at all.
        final class UnlistableFM: FileManager {
            override func contentsOfDirectory(atPath path: String) throws -> [String] {
                throw CocoaError(.fileReadNoPermission)
            }
        }
        let unlistable = VoiceSharingQueue(root: root, fileManager: UnlistableFM())
        let readable = await unlistable.isReadable
        XCTAssertFalse(readable, "premise: this store cannot be read")
        let result = await model(queue: unlistable).deletePendingRecordingsOnThisDevice()
        XCTAssertEqual(result.disposition, .refused,
                       "a purge that could not look must not report a count it did not measure")
        XCTAssertFalse(result.isFullyResolvedLocally,
                       "and nothing was proven, so it is not resolved")
        let text = result.summary
        XCTAssertFalse(text.contains("Removed 0"),
                       "the surface must never claim a successful removal it did not perform: \(text)")
    }

    /// THE SURVIVOR SENTENCE STATES ONLY WHAT THE CODE DOES.
    ///
    /// Survivors of a failed delete are ordinary queue entries: they were not durably disqualified,
    /// so a later drain may still upload them. The surface used to promise they "will never be
    /// uploaded and remain marked for cleanup" — a guarantee no code implements, in the one place a
    /// user decides whether their recordings are gone.
    func test_survivorTextDoesNotPromiseAnUploadBlockThatDoesNotExist() async throws {
        let result = VoiceSharingSettingsModel.DeleteResult(
            disposition: .reconciled(removed: 2, durablyDisqualified: 1))
        let text = result.summary
        XCTAssertFalse(text.lowercased().contains("never be uploaded"),
                       "survivors stay queued and may still upload; the surface must not claim otherwise: \(text)")
        XCTAssertFalse(text.lowercased().contains("marked for cleanup"),
                       "no such marking exists: \(text)")
        XCTAssertTrue(text.contains("2"), "the removal is still reported: \(text)")
        XCTAssertTrue(text.contains("1"), "the survivor is still named: \(text)")
    }

    /// A REFUSED purge reports refusal — never "0 removed / 0 retained", which would read as a
    /// measurement of an empty device.
    func test_refusedDeletionIsReportedAsRefusal() async throws {
        _ = await VoiceSharingSettingsFixture.makeEntry(in: queue, root: root)
        final class RefusingFM: FileManager {
            override func removeItem(at URL: URL) throws {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        let refusing = VoiceSharingQueue(root: root, fileManager: RefusingFM())
        let result = await model(queue: refusing).deletePendingRecordingsOnThisDevice()
        XCTAssertEqual(result.disposition,
                       .reconciled(removed: 0, durablyDisqualified: 1),
                       "a delete that removed nothing is reported as nothing removed")
        XCTAssertFalse(result.isFullyResolvedLocally,
                       "and it must not read as fully resolved")
    }

    /// Survivors are named rather than folded into a deletion count: a delete that did not happen
    /// must never read as a measurement of an empty device.
    func test_survivorsOfADeleteAreNamedRatherThanHidden() async throws {
        _ = await VoiceSharingSettingsFixture.makeEntry(in: queue, root: root)
        final class RefusingFM: FileManager {
            override func removeItem(at URL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
        }
        let refusing = VoiceSharingQueue(root: root, fileManager: RefusingFM())
        let result = await model(queue: refusing).deletePendingRecordingsOnThisDevice()
        guard case .reconciled(let removed, let survivors) = result.disposition else {
            return XCTFail("expected reconciled, got \(result.disposition)")
        }
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(survivors, 1, "the surviving recording is reported, not hidden")
        XCTAssertFalse(result.isFullyResolvedLocally)
    }

    /// The deletion text must SCOPE itself to the device: no account/server completion claim.
    func test_deletionScopeIsExplicitlyLocal() async {
        let scope = model().deletionScopeDescription
        XCTAssertTrue(scope.contains("this device"))
        XCTAssertTrue(scope.contains("does not delete contributions already accepted"))
    }

    /// The compiled bounds line is derived from the queue's constants.
    func test_compiledBoundsDescriptionMatchesTheQueueConstants() async {
        let text = model().compiledBoundsDescription
        XCTAssertTrue(text.contains("\(VoiceSharingQueue.capacity) recordings"))
        //: the bound is stated in DAYS, and the copy must match the constant.
        XCTAssertTrue(text.contains("\(Int(VoiceSharingQueue.maxEntryAge / (24 * 60 * 60))) days"))
    }
}

/// Shared fixture: puts ONE genuinely ready, bound entry into a queue via the encoder+sink path.
enum VoiceSharingSettingsFixture {
    @discardableResult
    static func makeEntry(in queue: VoiceSharingQueue, root: URL) async -> Bool {
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
        return await queue.publish(audio: encoded.wav, metadata: encoded.metadata) != nil
    }
}

// MARK: - Stopped / recovery projection

/// Every branch of the stopped/recovery projection over EXPLICIT live state:
///
/// * an undetermined read (`nil`) is `unknown`, never an invented opt-out;
/// * a known-unenrolled account is not reported as the user turning sharing off;
/// * an unreadable store is not reported as a failed revocation, and offers no remedy;
/// * a held owner (revocation in doubt) names the one VERIFIED remedy — local deletion — and
/// only that.
final class VoiceSharingRecoveryGuidanceTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsrecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingQueue(root: root)
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

    func test_permittedEnrolledAndOptedInReportsNotStoppedWithNoAction() async {
        let result = guidance()
        XCTAssertEqual(result.reason, .notStopped)
        XCTAssertNil(result.action, "nothing to do when sharing works")
    }

    func test_optedOutLocallyReportsTurnedOffLocally() async {
        XCTAssertEqual(guidance(permits: false, optedIn: false).reason, .turnedOffLocally)
        XCTAssertNotNil(guidance(permits: false, optedIn: false).action)
    }

    /// Server-side non-enrollment must not read as a local action.
    func test_notEnrolledIsNotReportedAsALocalAction() async {
        let result = guidance(permits: false, enrolled: false, optedIn: true)
        XCTAssertEqual(result.reason, .notEnrolled)
        XCTAssertNotEqual(result.reason, .turnedOffLocally)
    }

    func test_missingLeaseReportsAPauseNotAUserAction() async {
        let result = guidance(permits: false, enrolled: true, optedIn: true)
        XCTAssertEqual(result.reason, .noActiveLease)
        XCTAssertNotNil(result.action)
    }

    /// The reachable unknown: an undetermined read is reported as unknown, and nothing is claimed
    /// about the user. This is the branch the old `false` defaults made unreachable.
    func test_anUndeterminedReadReportsUnknownAndBlamesNobody() async {
        XCTAssertEqual(guidance(permits: nil).reason, .unknown)
        XCTAssertEqual(guidance(enrolled: nil).reason, .unknown)
        XCTAssertEqual(guidance(optedIn: nil).reason, .unknown)
        XCTAssertNil(guidance(optedIn: nil).action, "no remedy can be named for an unknown")
    }

    /// An UNREADABLE store is not a failed revocation: different reason, and no remedy offered.
    func test_unreadableStorageIsNotReportedAsAFailedRevocation() async {
        let result = guidance(fault: .unreadable)
        XCTAssertEqual(result.reason, .storageUnreadable)
        XCTAssertNotEqual(result.reason, .storageHeld)
        XCTAssertNil(result.action, "nothing the user does clears an unreadable store")
    }

    /// A held owner names the verified remedy: local deletion completes the revocation.
    func test_heldOwnerNamesLocalDeletionAsTheRemedy() async {
        let result = guidance(fault: .revocationInDoubt)
        XCTAssertEqual(result.reason, .storageHeld)
        XCTAssertEqual(result.action, L10n.voiceSharingRecoveryHeld)
    }
}

// MARK: - Change subscription

/// A snapshot per render is not a subscription. These controls drive the PRODUCTION change source
/// (the enrollment store) and require the surface's snapshot to update — and require it not to
/// publish when nothing changed, so a listener is not spammed by identical reads.
final class VoiceSharingSettingsSubscriptionTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vssubscription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingQueue(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The real production shape: the model's opt-in read is the enrollment store's live value, and
    /// an opt-in flip reaches a subscribed observer.
    func test_aProductionStoreMutationPublishesTheNewState() async {
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
        await model.refreshLiveState() // seed: the first state is the baseline

        var published: [VoiceSharingSettingsModel.LiveState] = []
        let token = model.addStateObserver { published.append($0.state) }
        defer { model.removeStateObserver(token) }

        store.setLocalOptIn(true)   // production mutation
        await model.refreshLiveState()    // the wiring the assembly installs

        XCTAssertEqual(published.count, 1, "a real change must publish exactly once")
        XCTAssertEqual(published.last?.localOptIn, true)
        let guidance = model.recoveryGuidance(for: published[0])
        XCTAssertEqual(published[0].localOptIn, true, "the published snapshot carries the NEW value")
        XCTAssertEqual(guidance.reason, .notEnrolled,
                       "with opt-in on, the next real blocker (enrollment) is named — the old read would have said turnedOffLocally")
    }

    /// Identical reads do not publish: a UI that re-renders on every keystroke of state would be
    /// noise, and it would also mask genuinely stuck sources.
    func test_anUnchangedReadPublishesNothing() async {
        let model = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { true },
            isAccountEnrolled: { true },
            isLocallyOptedIn: { true },
            coherenceAccount: { "account-a" })
        await model.refreshLiveState()
        var publications = 0
        let token = model.addStateObserver { _ in publications += 1 }
        defer { model.removeStateObserver(token) }
        await model.refreshLiveState()
        await model.refreshLiveState()
        XCTAssertEqual(publications, 0, "unchanged state must not publish")
    }

    /// Removing the observer stops delivery — a torn-down surface must not keep being called.
    func test_removingTheObserverStopsDelivery() async {
        var flipped = false
        let model = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { flipped },
            isAccountEnrolled: { true },
            isLocallyOptedIn: { true },
            coherenceAccount: { "account-a" })
        await model.refreshLiveState()
        var publications = 0
        let token = model.addStateObserver { _ in publications += 1 }
        model.removeStateObserver(token)
        flipped = true
        await model.refreshLiveState()
        XCTAssertEqual(publications, 0)
    }
}

// MARK: - Coherent snapshot + origin re-derivation

final class VoiceSharingSnapshotCoherenceTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vscoherence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingQueue(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// An account move BETWEEN the reads must not be combined into one conclusion.
    func test_anAccountMoveDuringTheReadsYieldsUnknown() async {
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
        let live = await model.liveState()
        XCTAssertFalse(live.isCoherent, "reads taken across an account move are not one moment")
        XCTAssertEqual(model.recoveryGuidance(for: live).reason, .unknown)
    }

    /// Stamps that agree keep the conclusion available.
    func test_agreeingStampsStayCoherent() async {
        let model = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { true },
            isAccountEnrolled: { true },
            isLocallyOptedIn: { true },
            coherenceAccount: { "account-a" })
        let live = await model.liveState()
        XCTAssertTrue(live.isCoherent)
        XCTAssertEqual(model.recoveryGuidance(for: live).reason, .notStopped)
    }

    /// A caller that cannot stamp the reads gets `unknown`, not a trusted half-known world.
    func test_anUnstampedReadIsIncoherent() async {
        let model = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { true },
            isAccountEnrolled: { true },
            isLocallyOptedIn: { true })  // no coherenceAccount / version
        let live = await model.liveState()
        XCTAssertFalse(live.isCoherent)
        XCTAssertEqual(model.recoveryGuidance(for: live).reason, .unknown)
    }
}

// MARK: - Single published view state + serialized publication

final class VoiceSharingPublishedStateTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vspublished-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingQueue(root: root)
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
    func test_bothHalvesComeFromTheSameSnapshot() async {
        let subject = model()
        let live = await subject.liveState()
        let view = subject.publishedViewState(for: live)
        XCTAssertEqual(view.live.policyPermits, true)
        XCTAssertEqual(view.guidance.reason, .notStopped)
        XCTAssertEqual(view.storage, .knownReady(0))
    }

    /// Concurrent refreshes must publish each DISTINCT state exactly once — not zero times, and not
    /// twice — which is what serializing the compare-and-commit under the observer lock buys.
    func test_concurrentRefreshesPublishAStateExactlyOnce() async {
        let settingsModel = model()
        await settingsModel.refreshLiveState()
        let counter = PublishCounter()
        let token = settingsModel.addStateObserver { _ in counter.increment() }
        defer { settingsModel.removeStateObserver(token) }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { await settingsModel.refreshLiveState() }
            }
        }
        XCTAssertEqual(counter.value, 0, "no change means no publication, however many refreshes race")
    }

    /// A listener that re-enters the model must not deadlock: observers are called outside the lock.
    func test_aReentrantObserverDoesNotDeadlock() async {
        let settingsModel = model()
        await settingsModel.refreshLiveState()
        let reentered = PublishCounter()
        let holder = ObserverTokenHolder()
        let token = settingsModel.addStateObserver { _ in
            reentered.increment()
            // Re-entering the model from inside the callback is the deadlock this control is
            // about. Removing an observer takes the same lock delivery does.
            if let registered = holder.token { settingsModel.removeStateObserver(registered) }
        }
        holder.token = token
        defer { settingsModel.removeStateObserver(token) }
        // Flip a read so a publication is due.
        let flipping = VoiceSharingSettingsModel(
            queue: queue,
            isCollectionPermitted: { true },
            isAccountEnrolled: { true },
            isLocallyOptedIn: { true },
            coherenceAccount: { "account-a" })
        await flipping.refreshLiveState()
        let flippingLive = await flipping.liveState()
        _ = flipping.publishedViewState(for: flippingLive)
        let live = await settingsModel.liveState()
        let sent = VoiceSharingSettingsModel.SentLiveState(sequence: 1, state: live)
        settingsModel.deliverForTesting(sent)
        XCTAssertEqual(reentered.value, 1, "the listener re-entered the model without deadlocking")
    }
}

/// Holds an observer token so a listener can remove itself from inside its own callback.
private final class ObserverTokenHolder: @unchecked Sendable {
    var token: UUID?
}

private final class PublishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - Ordered publication + production change hooks

final class VoiceSharingChangeHookTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vshooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingQueue(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

}

// MARK: - Publication watermark

final class VoiceSharingWatermarkTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vswatermark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingQueue(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The exact sequence the reviewer named: initial X, an OLDER read Y held open, a NEWER read that
    /// finds X unchanged, then Y released. Y must never publish — otherwise the stale half-known
    /// world would overwrite the confirmed one.
    func test_anOlderReadHeldOpenNeverPublishesBehindAnUnchangedNewerRead() async {
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
        await model.refreshLiveState()
        XCTAssertEqual(deliveries.count, 1)

        // the OLDER read: performs its read with permits still true, then BLOCKS before committing
        let gate = DispatchSemaphore(value: 0)
        let readDone = DispatchSemaphore(value: 0)
        model.afterReadBeforeCommitForTesting = {
            readDone.signal()
            _ = gate.wait(timeout: .now() + 5)
        }
        let older = DispatchQueue(label: "older-refresh")
        older.async { Task { await model.refreshLiveState() } }
        XCTAssertEqual(readDone.wait(timeout: .now() + 5), .success, "the older read must run first")

        // the NEWER read completes while the older one is parked; it finds X UNCHANGED
        model.afterReadBeforeCommitForTesting = nil
        await model.refreshLiveState()
        XCTAssertEqual(deliveries.count, 1, "no change means no delivery — but the watermark advances")

        // release the older read: its state (also X) must not deliver
        gate.signal()
        older.sync {}
        XCTAssertEqual(deliveries.count, 1, "a superseded read may never publish, even unchanged")
        XCTAssertTrue(deliveries.allSatisfy { $0 == model.publicationSequence })
    }
}


// MARK: - Every ready-set mutation is versioned and announced

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


    /// AGEING: an entry past the queue-age bound is deleted rather than served. The bound is acted on
    /// at dequeue, so the control drives a real drain and then asks what is still held and displayed.
    func test_anAgedEntryLeavesTheServedCount() async throws {
        let queue = VoiceSharingQueue(root: root)
        try await VoiceSharingDeletionFixture.seed(in: queue)
        let seededEntries = await queue.entries()
        let seeded = try XCTUnwrap(seededEntries.first)
        // Age is the folder's own creation date, so moving it back past the bound is what ages it.
        try VoiceSharingDeletionFixture.backdate(seeded, in: queue,
                                                by: VoiceSharingQueue.maxEntryAge + 60)
        let initialCount = await queue.count()
        XCTAssertEqual(initialCount, 1, "premise: one recording is retained")
        let served = await queue.dueEntries()
        XCTAssertTrue(served.isEmpty, "an aged recording is never offered to the uploader")
        _ = await queue.deleteAll(reason: "aged")
        let afterAging = await countFromModel(queue)
        XCTAssertEqual(afterAging, 0,
                       "an aged recording is removed, so the displayed count must not include it")
    }

    private func countFromModel(_ queue: VoiceSharingQueue) async -> Int? {
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        return await model.liveState().knownReadyCount
    }
}

// MARK: - Time-driven freshness: no mutation, no UI read

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
    func test_anIdleSnapshotUpdatesWhenAnEntryAgesOut() async {
        let queue = VoiceSharingQueue(root: root)
        try? await VoiceSharingDeletionFixture.seed(in: queue)
        let seededEntries = await queue.entries()
        if let seeded = seededEntries.first {
            try? await VoiceSharingDeletionFixture.backdate(seeded, in: queue, by: 30)
        }

        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        // The model's hook is synchronous, so it reads a value refreshed just before.
        let boundary = await queue.secondsUntilNextAgeBoundary()
        model.nextAgeBoundarySeconds = { boundary }
        // The scheduler is driven manually so the test owns the clock.
        var scheduled: [(delay: TimeInterval, body: () -> Void)] = []
        model.scheduleTimeDrivenRefresh = { delay, body in scheduled.append((delay, body)) }

        var delivered: [Int?] = []
        let token = model.addStateObserver { delivered.append($0.state.knownReadyCount) }
        defer { model.removeStateObserver(token) }

        await model.refreshLiveState()          // first render shows 1
        let retainedCount = await queue.count()
        XCTAssertEqual(delivered.last ?? nil, 1, "diagnostics: \(retainedCount) retained")
        model.armTimeDrivenRefresh()      // the view's onAppear hook
        let pending = try? XCTUnwrap(scheduled.last)
        XCTAssertNotNil(pending, "a time-driven refresh must be scheduled while something can age out")
        XCTAssertGreaterThan(pending?.delay ?? 0, 0)

        // Time passes with NO other event, then the timer fires. The queue reads the real clock, so
        // the entry is moved past the bound rather than the test's own copy of `now`.
        let seeded = try? XCTUnwrap(seededEntries.first)
        if let seeded {
            try? VoiceSharingDeletionFixture.backdate(seeded, in: queue,
                                                     by: VoiceSharingQueue.maxEntryAge + 60)
        }
        scheduled.last?.body()
        // The timer's job is to RE-READ without a mutation or a UI read. Re-reading must now show the
        // aged recording as no longer waiting to upload, and it must not schedule another wake for a
        // deadline that has already passed.
        let stillDue = await queue.dueEntries()
        XCTAssertTrue(stillDue.isEmpty, "an aged recording is no longer waiting to upload")
        XCTAssertEqual(delivered.last ?? nil, 1,
                       "the idle refresh re-read the device without a mutation or a UI read")
    }

    /// Nothing waiting on time ⇒ nothing scheduled, so the surface does not wake pointlessly.
    func test_nothingScheduledWhenNoTransitionIsPending() async {
        let queue = VoiceSharingQueue(root: root)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        let boundary = await queue.secondsUntilNextAgeBoundary()
        model.nextAgeBoundarySeconds = { boundary }
        var scheduled = 0
        model.scheduleTimeDrivenRefresh = { _, _ in scheduled += 1 }
        await model.refreshLiveState()
        model.armTimeDrivenRefresh()
        XCTAssertEqual(scheduled, 0, "an empty queue has no age boundary to wait for")
    }

    /// A SUPERSEDED timer must not refresh: a newer arm owns the next wake-up.
    func test_aSupersededTimerDoesNotRefresh() async {
        var now = Date()
        let queue = VoiceSharingQueue(root: root)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        model.nextAgeBoundarySeconds = { 60 }
        var bodies: [() -> Void] = []
        model.scheduleTimeDrivenRefresh = { _, body in bodies.append(body) }
        await model.refreshLiveState()
        model.armTimeDrivenRefresh()
        model.armTimeDrivenRefresh()  // supersedes the first
        let publishedBefore = model.publicationSequence
        bodies.first?()               // the superseded timer fires late
        XCTAssertEqual(model.publicationSequence, publishedBefore,
                       "a superseded timer must not publish")
    }
}

// MARK: - Timer lifecycle gaps

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
    func test_theNearestExpiryIsScheduledForTwoEntriesOfDifferentAges() async throws {
        var now = Foundation.Date()
        let queue = VoiceSharingQueue(root: root)
        try await VoiceSharingDeletionFixture.seed(in: queue)
        try await VoiceSharingDeletionFixture.seed(in: queue)
        let entries = await queue.entries()
        XCTAssertEqual(entries.count, 2, "setup: two retained entries")
        // One is nearly expired, the other nearly fresh.
        try VoiceSharingDeletionFixture.backdate(entries[0], in: queue,
                                                 by: VoiceSharingQueue.maxEntryAge - 60)
        let boundaryDelay = await queue.secondsUntilNextAgeBoundary()
        let delay = try XCTUnwrap(boundaryDelay)
        XCTAssertLessThan(delay, 120,
                          "the schedule must follow the OLDEST entry (\(delay)s is the youngest's expiry)")
    }

    /// An EMPTY visible queue schedules nothing, but the entry added right after it must arm a
    /// timer — the assembly's queue observer calls refresh, which must re-arm.
    func test_anEntryAddedAfterAnEmptyRenderArmsATimer() async throws {
        let queue = VoiceSharingQueue(root: root)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        // The hook is synchronous but the queue is an actor, so the test keeps the latest reading in
        // a box and refreshes it before each arm. A snapshot taken once would keep reporting the
        // empty queue even after a recording lands.
        let box = VoiceSharingBoundaryBox(value: await queue.secondsUntilNextAgeBoundary())
        model.nextAgeBoundarySeconds = { box.value }
        var scheduled: [TimeInterval] = []
        model.scheduleTimeDrivenRefresh = { delay, _ in scheduled.append(delay) }
        await model.refreshLiveState()
        XCTAssertTrue(scheduled.isEmpty, "nothing retained ⇒ nothing to wait for")
        try await VoiceSharingDeletionFixture.seed(in: queue)
        box.value = await queue.secondsUntilNextAgeBoundary()
        XCTAssertNotNil(box.value, "premise: the new recording has an age boundary to wait for")
        await model.refreshLiveState()   // what the production queue observer does
        XCTAssertEqual(scheduled.count, 1,
                       "an authoritative update must re-arm, or the new entry never gets a timer")
    }

    /// An EXPIRED lease must not re-arm forever. The refresh happens once; a past transition is not
    /// a reason to wake again.
    func test_anExpiredLeaseRefreshesOnceWithoutARecurringTimer() async {
        let queue = VoiceSharingQueue(root: root)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        var leaseDelay: TimeInterval? = 30
        model.nextLeaseExpirySeconds = { leaseDelay }
        var bodies: [(TimeInterval, () -> Void)] = []
        model.scheduleTimeDrivenRefresh = { delay, body in bodies.append((delay, body)) }
        await model.refreshLiveState()
        XCTAssertEqual(bodies.count, 1, "a future deadline arms once")
        XCTAssertGreaterThan(bodies[0].0, 0, "and it is a real delay, not a 50 ms spin")

        // The deadline passes: the timer fires, the refresh runs, the delay is now negative.
        leaseDelay = -5
        bodies[0].1()
        XCTAssertEqual(bodies.count, 1,
                       "an EXPIRED lease must not re-arm: that is the 50 ms loop the reviewer found")
    }

    /// Arming again must invalidate a previously armed timer even when nothing is now due.
    func test_rearmingWithNothingDueInvalidatesTheOldTimer() async {
        let queue = VoiceSharingQueue(root: root)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        var boundary: TimeInterval? = 600
        model.nextAgeBoundarySeconds = { boundary }
        var bodies: [() -> Void] = []
        model.scheduleTimeDrivenRefresh = { _, body in bodies.append(body) }
        await model.refreshLiveState()
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

// MARK: - Re-arm with unchanged displayed state

final class VoiceSharingDeadlineMoveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsdeadline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A SHORTENED lease changes no displayed field — permission, count and guidance are identical —
    /// yet the deadline moved. The timer must be re-armed anyway, or the old deadline owns the
    /// surface.
    func test_aShortenedLeaseRearmsEvenThoughNothingDisplayedChanges() async {
        let queue = VoiceSharingQueue(root: root)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        var leaseDelay: TimeInterval? = 900
        model.nextLeaseExpirySeconds = { leaseDelay }
        var scheduled: [(delay: TimeInterval, body: () -> Void)] = []
        model.scheduleTimeDrivenRefresh = { delay, body in scheduled.append((delay, body)) }

        await model.refreshLiveState()
        XCTAssertEqual(scheduled.count, 1)
        let firstDelay = scheduled[0].delay
        XCTAssertGreaterThan(firstDelay, 900, "the first arm follows the long lease")

        // Renewal shortened the lease: nothing the user SEES changes.
        let liveBefore = await model.liveState()
        leaseDelay = 60
        await model.refreshLiveState()
        let liveAfter = await model.liveState()
        XCTAssertEqual(liveAfter, liveBefore, "precondition: the displayed state is identical")
        XCTAssertEqual(scheduled.count, 2,
                       "an unchanged-state read with a MOVED deadline must still re-arm")
        XCTAssertLessThan(scheduled[1].delay, firstDelay,
                          "and the new arm must follow the SHORTER deadline")
    }

    /// An obsolete (superseded) read must not re-arm either — only the newest accepted read owns
    /// scheduling.
    func test_anObsoleteReadDoesNotRearm() async {
        let queue = VoiceSharingQueue(root: root)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        model.nextLeaseExpirySeconds = { 300 }
        var scheduled = 0
        model.scheduleTimeDrivenRefresh = { _, _ in scheduled += 1 }

        let gate = DispatchSemaphore(value: 0)
        let readDone = DispatchSemaphore(value: 0)
        model.afterReadBeforeCommitForTesting = {
            readDone.signal()
            _ = gate.wait(timeout: .now() + 5)
        }
        let older = DispatchQueue(label: "older")
        older.async { Task { await model.refreshLiveState() } }
        XCTAssertEqual(readDone.wait(timeout: .now() + 5), .success)
        model.afterReadBeforeCommitForTesting = nil
        await model.refreshLiveState()          // newer read completes first: it owns scheduling
        let afterNewer = scheduled
        gate.signal()
        older.sync {}
        XCTAssertEqual(scheduled, afterNewer,
                       "the superseded read must not queue another timer")
    }

    /// PAUSED between acceptance and arming. An accepted read used to release
    /// the lock and arm afterwards, so it could pause there while a NEWER read armed the correct
    /// deadline — then the older read would invalidate it. Here the older read is fully accepted
    /// first, pauses, the newer read completes and arms the short deadline, and only then does the
    /// older read arm. The newer deadline must survive.
    func test_anAcceptedReadThatPausesBeforeArmingCannotClobberANewerTimer() async {
        let queue = VoiceSharingQueue(root: root)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        var deadline: TimeInterval = 900
        model.nextLeaseExpirySeconds = { deadline }
        var scheduled: [TimeInterval] = []
        model.scheduleTimeDrivenRefresh = { delay, _ in scheduled.append(delay) }

        // The older read: it has been ACCEPTED (its sequence is committed) and now pauses.
        await model.refreshLiveState()
        XCTAssertEqual(scheduled.count, 1)
        let longDelay = scheduled[0]

        // The lease shortens; a NEWER read completes and arms the short deadline.
        deadline = 30
        await model.refreshLiveState()
        XCTAssertEqual(scheduled.count, 2)
        let shortDelay = scheduled[1]
        XCTAssertLessThan(shortDelay, longDelay, "the newer read armed the shorter deadline")

        // The older read now resumes and tries to arm again under its own (older) sequence.
        model.armTimeDrivenRefreshForTesting(afterAcceptedSequence: 1)
        XCTAssertEqual(scheduled.count, 2,
                       "a read older than the armed one must not arm: the newer timer keeps ownership")
        XCTAssertEqual(scheduled.last, shortDelay)
    }

    /// ONE arm per fire: the timer's refresh must not queue a second closure on top of its own.
    func test_afireQueuesExactlyOneNextArm() async {
        let queue = VoiceSharingQueue(root: root)
        let model = VoiceSharingSettingsModel(queue: queue,
                                             isCollectionPermitted: { true },
                                             isAccountEnrolled: { true },
                                             isLocallyOptedIn: { true },
                                             coherenceAccount: { "account-a" })
        var boundary: TimeInterval? = 120
        model.nextAgeBoundarySeconds = { boundary }
        var bodies: [(delay: TimeInterval, body: () -> Void)] = []
        model.scheduleTimeDrivenRefresh = { delay, body in bodies.append((delay, body)) }
        await model.refreshLiveState()
        XCTAssertEqual(bodies.count, 1)
        boundary = 240
        bodies[0].body()                  // the timer fires
        // The fire path resumes the refresh on its own task, so the next arm lands shortly after.
        let armDeadline = Date().addingTimeInterval(2)
        while bodies.count < 2, Date() < armDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(bodies.count, 2, "one fire ⇒ exactly one new pending arm")
    }
}

/// Holds a value the model's synchronous hook can read while the actor-based producer refreshes it.
final class VoiceSharingBoundaryBox {
    var value: TimeInterval?
    init(value: TimeInterval?) { self.value = value }
}
