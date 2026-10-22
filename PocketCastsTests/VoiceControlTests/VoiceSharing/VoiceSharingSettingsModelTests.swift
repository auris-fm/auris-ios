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
                                  isCollectionPermitted: { permitted })
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

    /// Reviewer f92ff117: unknown coverage must render as UNKNOWN, never as a zero count.
    func test_unknownCoverageRendersUnknownNotEmpty() throws {
        // A durable revocation intent the queue could not retire → owner held.
        try Data([0x01]).write(to: root.appendingPathComponent("revocation.intent"))
        let heldQueue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(model(queue: heldQueue).status().storage, .unknown)

        // Independently: an unlistable root is also unknown, not zero.
        let unlistable = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
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