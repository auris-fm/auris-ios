import CryptoKit
import XCTest
@testable import podcasts

/// The real boundary control: collector event → encoder → QUEUE → ready entry, plus tamper
/// negatives proving a corrupted entry never serves. The queue here is the production type with
/// its production recovery/readiness authority — not a stub.
final class VoiceSharingContributionSinkTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingUploadQueue!
    private let samples: [Float] = [0, 0.25, -0.5, 0.99, -1, 0.5]
    private var enabled = true

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
    }

    override func tearDownWithError() throws {
        drain()
        lastSink = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func event() -> VoiceSharingCollector.SegmentEvent {
        .init(
            kind: .completed, captureID: UUID(),
            enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: samples, isGateControl: false)
    }

    private var provenance: VoiceSharingContributionEncoder.Provenance {
        .init(
            platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
            models: .init(
                vad: .init(id: "vad-1", version: "1"), wakeword: .init(id: "wake-1", version: "1"),
                asr: .init(id: "asr-1", version: "1"), translation: nil,
                router: .init(id: "router-1", version: "1")),
            conversionVersion: "v1")
    }

    private var observations: [String: VoiceSharingContributionEncoder.StageOutcome] {
        [
            "wake": .init(state: "completed"),
            "bleed": .init(state: "not_run", reason: "no_playback_reference"),
            "asr": .init(state: "not_run", reason: "local_only_action"),
            "translation": .init(state: "not_run", reason: "no_text"),
            "routing": .init(state: "not_run", reason: "no_candidates"),
            "execution": .init(state: "not_run", reason: "client_refused"),
        ]
    }

    func test_gateClosedBetweenPrepareAndFinalizeDiscardsTheUnreadyEntry() throws {
        // Reviewer 5357d089: the gate must be re-checked after prepare — consent loss during the
        // queue transaction must not publish. The gate flips closed on its THIRD read (encode,
        // prepare, finalize), so the entry exists but must never become ready.
        var calls = 0
        let sink = VoiceSharingContributionSink(
            queue: queue,
            isEnabled: {
                calls += 1
                return calls <= 2
            },
            encoderProvenance: { [self] in provenance },
            observations: { [self] in observations })
        lastSink = sink
        sink.handle(event())
        // DRAIN, then assert: the worker must have FINISHED the full transaction (including the
        // post-prepare revocation check), not merely "not started yet" — an early-empty poll
        // would mask a mutant that skips the check entirely.
        drain()
        let leftover = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(leftover.count, 0,
                       "revocation between prepare and finalize must discard the unready entry")
    }

    /// Spec delta 736d3180 through the REAL producer→durable-record path: a collector event enters
    /// the contribution sink with `observation_unavailable` + `state: "unknown"` on one stage, and the
    /// resulting entry must be durably ready in the production queue (not merely encodable).
    func test_anUnobservedStageReachesTheDurableQueueAsAReadyEntry() throws {
        var claims = observations
        claims["asr"] = .init(state: "unknown", reason: "observation_unavailable")
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { [self] in enabled },
            encoderProvenance: { [self] in provenance }, observations: { [self] in claims })
        lastSink = sink
        sink.handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.count, 1,
                       "an unobserved stage must not stop the record reaching the durable queue")
    }

    /// The pairing rule must hold on the SAME path: `observation_unavailable` paired with a known
    /// outcome is refused before anything becomes ready, so a non-claim can never be stored as if it
    /// described a real outcome.
    func test_thePairingRuleIsEnforcedOnTheDurableQueuePathToo() throws {
        var claims = observations
        claims["asr"] = .init(state: "failed", reason: "observation_unavailable")
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { [self] in enabled },
            encoderProvenance: { [self] in provenance }, observations: { [self] in claims })
        lastSink = sink
        sink.handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.count, 0, "the refused pair must never become a ready entry")
        let leftover = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(leftover.count, 0, "no unready residue may survive the refusal")
    }

    func test_purgeAllRemovesEveryEntryAndRootBookkeeping() throws {
        makeSink().handle(event())
        makeSink().handle(event())
        for _ in 0..<100 {
            if case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
                ready.count == 2 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.count, 2)
        let result = queue.purgeAll()
        XCTAssertEqual(result, .reconciled(removed: 2, retained: 0))
        let leftover = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(leftover.count, 0, "no entry or bookkeeping survives consent revocation")
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known after purge")
        }
        XCTAssertEqual(after.count, 0)
    }

    /// Last sink instance used by the current test — the drain seam needs it.
    /// Last sink instance used by the current test — the drain seam needs it.
    private var lastSink: VoiceSharingContributionSink?

    func test_pendingBoundHoldsWhileWorkerIsBlocked() {
        // Reviewer 5b1ba089: the bound must be enforced BEFORE enqueue (the serialized worker
        // block can never see more than one). Block the worker, submit max+5, assert exactly
        // max accepted.
        let sink = makeSink()
        let blocked = XCTestExpectation(description: "worker blocked")
        let release = NSCondition()
        var inside = false
        var proceed = false
        sink.testingWorkerGate = {
            release.lock()
            guard !inside else { release.unlock(); return }
            inside = true
            release.signal()
            while !proceed { release.wait() }
            release.unlock()
        }
        // Submit ONE event so the worker actually runs and blocks inside the gate; wait until it
        // is verifiably stalled, THEN submit the rest so the bound is exercised against a
        // provably blocked worker.
        sink.handle(event())
        release.lock()
        while !inside { release.wait() }
        release.unlock()
        blocked.fulfill()
        for _ in 1..<VoiceSharingContributionSink.maxPendingEvents {
            sink.handle(event())
        }
        // These 5 arrive with the worker still blocked and all 16 slots held: refused at ENQUEUE.
        for _ in 0..<5 {
            sink.handle(event())
        }
        // While the worker is blocked, 20 closures are queued; only 15 more slots exist, so the
        // last 5 submissions must have been refused at ENQUEUE time.
        release.lock(); proceed = true; release.signal(); release.unlock()
        sink.waitForIdleForTesting()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.count, VoiceSharingContributionSink.maxPendingEvents,
                       "the bound, not the queue's own limits, must cap pending events")
    }

    func test_eventQueuedUnderSupersededAuthorizationNeverPublishes() {
        // Prior-epoch binding: capture the event while the gate is open at generation 0, revoke
        // BEFORE the worker processes it (worker blocked), then release. The stale-authorization
        // event must never publish even though the gate boolean still reads true.
        let sink = makeSink()
        let blockedInWorker = XCTestExpectation(description: "blocked")
        var releaseGate = false
        let cond = NSCondition()
        sink.testingWorkerGate = {
            cond.lock()
            while !releaseGate { cond.wait() }
            cond.unlock()
            blockedInWorker.fulfill()
        }
        sink.handle(event()) // enqueued, generation 0
        sink.noteRevocation() // generation 1 — BEFORE processing
        cond.lock(); releaseGate = true; cond.broadcast(); cond.unlock()
        wait(for: [blockedInWorker], timeout: 5)
        sink.waitForIdleForTesting()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.count, 0,
                       "a queued event from a superseded authorization must never publish")
    }

    func test_purgeDisqualifiesEntriesWhoseRemovalFails() throws {
        makeSink().handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
              let name = ready.first?.name else { return XCTFail("expected one ready entry") }
        // Deterministic, DAMAGE-FREE removal failure: the injected fileManager refuses removal of
        // the ENTRY directory (real storage would fail mid-recursion and partially delete
        // children, which would make any "still complete" assertion vacuous).
        final class EntryRemovalRefusingFM: FileManager {
            var refuse = true
            override func removeItem(at URL: URL) throws {
                if refuse, UUID(uuidString: URL.lastPathComponent) != nil {
                    throw CocoaError(.fileWriteUnknown)
                }
                try super.removeItem(at: URL)
            }
        }
        let refusingFM = EntryRemovalRefusingFM()
        let refusingQueue = VoiceSharingUploadQueue(
            rootDirectory: root, fileManager: refusingFM, clock: Date.init)
        refusingFM.refuse = true
        let result = refusingQueue.purgeAll()
        refusingFM.refuse = false // allow tearDown cleanup
        XCTAssertEqual(result, .reconciled(removed: 0, retained: 1),
                       "a removal failure is retained-but-durably-disqualified, never collapsed")
        // NON-VACUITY: the retained entry is structurally COMPLETE — the ONLY reason it cannot
        // serve is the durable disqualification marker written by the purge.
        let entryDir = root.appendingPathComponent(name)
        let contents = try FileManager.default.contentsOfDirectory(atPath: entryDir.path)
        XCTAssertEqual(
            contents.filter { ["audio.wav", "metadata.json", "created.at", "ready.marker"].contains($0) }.count,
            4, "the retained entry must be structurally complete — otherwise this control proves nothing")
        XCTAssertEqual(contents.filter { $0.hasPrefix("publication.failed") }.count, 1,
                       "the disqualification marker must be durably present")
        // The query on a FRESH queue (production recovery authority) must not serve it.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        guard case .known(let after) = fresh.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known after purge")
        }
        XCTAssertEqual(after.count, 0, "a disqualified retained entry never serves")
    }

    /// Reviewer 70e5fc58 (1): `handle` must return PROMPTLY on the audio caller even while a
    /// publication transaction is stalled in encode/fsync. The control stalls the worker inside
    /// the publication lock, then measures `handle`'s return time from the caller thread.
    func test_handleReturnsPromptlyWhilePublicationIsStalled() {
        let sink = makeSink()
        let entered = XCTestExpectation(description: "publication started")
        let release = NSCondition()
        var stalled = false
        var proceed = false
        sink.testingWorkerGate = {
            release.lock()
            stalled = true
            release.signal()
            while !proceed { release.wait() }
            release.unlock()
            entered.fulfill()
        }
        sink.handle(event())
        // Wait until the worker is verifiably INSIDE the publication gate (predicate, not a
        // racy fulfill-before-lock: a lost broadcast would hang the worker forever).
        release.lock()
        while !stalled { release.wait() }
        release.unlock()
        // Worker is now stalled inside the publication path (holding publicationLock). A caller
        // submission must still return immediately: the slot lock is separate and short.
        let start = Date()
        for _ in 0..<5 { sink.handle(event()) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0,
                          "handle must not wait on the publication lock (audio caller latency)")
        release.lock(); proceed = true; release.signal(); release.unlock()
        sink.waitForIdleForTesting()
    }

    /// Reviewer 70e5fc58 (2): the REAL assembly path invalidates authorization. Off→on and an
    /// account transition must reach the sink's generation, so an event queued under the old
    /// authorization never publishes after the gate reads true again.
    func test_gateLostThroughCoordinatorRegistrySupersedesQueuedEvents() throws {
        let coordinator = VoiceSharingCoordinator.shared
        let baseline = coordinator.gateLostHandlerCountForTesting
        let sink = makeSink()
        let subscription = coordinator.registerGateLostHandler { sink.noteRevocation() }
        defer { _ = subscription }
        XCTAssertEqual(coordinator.gateLostHandlerCountForTesting, baseline + 1,
                       "the production registry must actually hold the handler")
        let release = NSCondition()
        var inside = false
        var proceed = false
        sink.testingWorkerGate = {
            release.lock()
            inside = true
            release.signal()
            while !proceed { release.wait() }
            release.unlock()
        }
        sink.handle(event()) // queued under the CURRENT authorization
        release.lock()
        while !inside { release.wait() }
        release.unlock()
        // Off: the coordinator fires EVERY registered handler — the production signal the assembly
        // installs. Nothing here calls noteRevocation directly.
        coordinator.fireGateLostHandlersForTesting()
        // On again: the live gate reads true, so only the captured generation can stop publication.
        release.lock(); proceed = true; release.signal(); release.unlock()
        sink.waitForIdleForTesting()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.count, 0,
                       "off→on must not republish an event authorized in the previous epoch")
    }

    /// Reviewer 70e5fc58 (3): a disqualification whose MARKER cannot be confirmed durable must not
    /// be claimed. The purge holds the owner and leaves the entry untouched.
    func test_unconfirmedDisqualificationHoldsOwnerAndClaimsNothing() throws {
        makeSink().handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
              let name = ready.first?.name else { return XCTFail("expected one ready entry") }
        // Marker byte-sync fails (a directory barrier alone does NOT persist a file's bytes).
        var syncCalls = 0
        let failingFileSyncQueue = VoiceSharingUploadQueue(
            rootDirectory: root,
            clock: Date.init,
            synchronizer: { path, isDirectory in
                syncCalls += 1
                if !isDirectory, path.lastPathComponent.hasPrefix("publication.failed") {
                    throw CocoaError(.fileWriteUnknown)
                }
                try VoiceSharingUploadQueue.testSynchronizer(path: path, isDirectory: isDirectory)
            })
        let result = failingFileSyncQueue.purgeAll()
        guard case .held(let removed, let retained) = result else {
            return XCTFail("an unconfirmed marker must HOLD the owner, got \(result)")
        }
        XCTAssertEqual(removed, 0, "nothing may be deleted without a confirmed disqualification")
        XCTAssertEqual(retained, 1, "the survivor is reported as retained, never as disqualified")
        // The entry is untouched and STILL structurally complete.
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(name).path)
        XCTAssertEqual(
            contents.filter { ["audio.wav", "metadata.json", "created.at", "ready.marker"].contains($0) }.count,
            4, "an unconfirmable disqualification must not damage the entry")
        // The owner-wide hold blocks serving AND admission.
        guard case .revocationHeld = failingFileSyncQueue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("the owner-wide hold must block serving after an unconfirmed purge")
        }
        XCTAssertFalse(failingFileSyncQueue.hasAdmissionAllowance(forBytes: 1_000))
    }

    /// Reviewer 35e67a87: a FRESH queue must not serve an unmarked survivor after a revocation
    /// that could not durably disqualify it. The intent is on disk, so restart cannot forget it.
    func test_freshQueueHoldsAfterUnconfirmedDisqualification() throws {
        makeSink().handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
              let name = ready.first?.name else { return XCTFail("expected one ready entry") }
        // Marker file-sync fails → disqualification unconfirmed, entry left intact and unmarked.
        let failingFileSyncQueue = VoiceSharingUploadQueue(
            rootDirectory: root,
            clock: Date.init,
            synchronizer: { path, isDirectory in
                if !isDirectory, path.lastPathComponent.hasPrefix("publication.failed") {
                    throw CocoaError(.fileWriteUnknown)
                }
                try VoiceSharingUploadQueue.testSynchronizer(path: path, isDirectory: isDirectory)
            })
        guard case .held = failingFileSyncQueue.purgeAll() else {
            return XCTFail("expected a held outcome")
        }
        // The unmarked entry is still structurally complete — nothing removed it.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(name).path)
                .filter { ["audio.wav", "metadata.json", "created.at", "ready.marker"].contains($0) }.count,
            4)
        // A FRESH queue (production restart) must honor the durable intent in EVERY authority.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        guard case .revocationHeld = fresh.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a fresh queue must not serve after an unconfirmed revocation")
        }
        XCTAssertEqual(fresh.readyEntries().count, 0, "legacy serving path must honor the hold too")
        XCTAssertFalse(fresh.hasAdmissionAllowance(forBytes: 1_000), "preflight must refuse")
        XCTAssertThrowsError(try fresh.prepare(metadata: Data("{}".utf8), audio: Data([0, 0]))) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable,
                           "the AUTHORITATIVE admission path must refuse")
        }
    }

    /// Reviewer 35e67a87: a REFUSED listing (root unreadable/overflowing) must set the hold — a
    /// purge that could not see the root has not revoked anything, and must not leave the owner
    /// admitting once the I/O failure clears.
    func test_refusedListingHoldsOwnerUntilReconciled() throws {
        makeSink().handle(event())
        drain()
        var failListing = true
        let refusingListQueue = VoiceSharingUploadQueue(
            rootDirectory: root,
            clock: Date.init,
            listDirectoryBounded: { url, keys, limit in
                if failListing { throw CocoaError(.fileReadNoPermission) }
                return try VoiceSharingUploadQueue.testBoundedListing(url, keys, limit)
            })
        guard case .refused = refusingListQueue.purgeAll() else {
            return XCTFail("an unlistable root must refuse, never report success")
        }
        // The I/O failure now clears — the hold must NOT clear with it.
        failListing = false
        guard case .revocationHeld = refusingListQueue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a refused listing must leave the owner held")
        }
        XCTAssertFalse(refusingListQueue.hasAdmissionAllowance(forBytes: 1_000))
        XCTAssertEqual(refusingListQueue.readyEntries().count, 0)
        // A FRESH queue sees the durable intent and stays held.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        guard case .revocationHeld = fresh.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("the refused-listing intent must survive restart")
        }
        // Only a RECONCILED purge clears it.
        guard case .reconciled = fresh.purgeAll() else { return XCTFail("expected reconciliation") }
        guard case .known(let after) = fresh.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a reconciled purge releases the hold")
        }
        XCTAssertEqual(after.count, 0, "the entry was removed by the reconciled purge")
    }

    /// Reviewer 2d7cb2c9 (1): a RECURSIVE removal that deletes publication.failed before failing
    /// on another child must not be treated as durably disqualified. The owner stays held, and a
    /// fresh queue refuses to serve the survivor.
    func test_partialDeletionOfMarkerThenRemovalFailureKeepsOwnerHeld() throws {
        makeSink().handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
              let name = ready.first?.name else { return XCTFail("expected one ready entry") }
        // Remover that DELETES the marker (as a real recursive delete would) and THEN fails.
        final class PartialDeletingFM: FileManager {
            var tripped = false
            override func removeItem(at URL: URL) throws {
                if UUID(uuidString: URL.lastPathComponent) != nil, !tripped {
                    tripped = true
                    let marker = URL.appendingPathComponent("publication.failed")
                    try? super.removeItem(at: marker) // marker is gone ...
                    throw CocoaError(.fileWriteUnknown) // ... and now the entry removal fails
                }
                try super.removeItem(at: URL)
            }
        }
        let fm = PartialDeletingFM()
        let partialQueue = VoiceSharingUploadQueue(
            rootDirectory: root, fileManager: fm, clock: Date.init)
        let result = partialQueue.purgeAll()
        // The survivor must be RE-DISQUALIFIED (the purge rewrites the marker on the survivor), so
        // the outcome may reconcile — but never silently: the marker must be back on disk.
        guard case .reconciled(_, let retained) = result else {
            if case .held = result { /* also acceptable: owner held */ } else {
                return XCTFail("unexpected outcome \(result)")
            }
            XCTAssertTrue(false, "expected either reconciliation with a re-disqualified survivor or a hold")
            return
        }
        XCTAssertEqual(retained, 1)
        let markerPath = root.appendingPathComponent(name).appendingPathComponent("publication.failed").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath),
                      "the purge must RE-ESTABLISH durable disqualification on the survivor")
        // A fresh queue must refuse it, on disk evidence alone.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        guard case .known(let after) = fresh.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known on a clean root")
        }
        XCTAssertEqual(after.count, 0, "a survivor whose marker was destroyed must never serve")
    }

    /// Reviewer 2d7cb2c9 (2): intent discovery must not collapse "cannot determine" into "absent".
    /// An unstatable intent path keeps the owner held across fresh initialization.
    func test_unknownIntentDiscoveryHoldsOwnerAcrossFreshInitialization() throws {
        makeSink().handle(event())
        drain()
        // REAL POSIX couples intent-stat failure with an unreadable root (every downstream guard
        // would then mask the hold), so the discovery failure is injected ISOLATED: the root and
        // its surviving entry stay perfectly readable, and ONLY the intent lookup is unknown.
        // This is exactly the case `fileExists` collapses into absence.
        let fresh = VoiceSharingUploadQueue(
            rootDirectory: root, clock: Date.init,
            intentDiscovery: { _ in .failure })
        // The hold is real, but its ORIGIN is "cannot determine", not "a revocation failed":
        // the retry-hold discovery is unknown, so coverage is unknown (reviewer 8ae2b980).
        guard case .unknownCoverage = fresh.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("unknown intent discovery must HOLD the owner, never resume serving")
        }
        XCTAssertEqual(fresh.readyEntries().count, 0, "legacy path must not serve either")
        XCTAssertFalse(fresh.hasAdmissionAllowance(forBytes: 1_000))
        XCTAssertThrowsError(try fresh.prepare(metadata: Data("{}".utf8), audio: Data([0, 0])))
    }

    func test_sinkIgnoresStartAndCancellationBeforeEncodingButAcceptsTerminalForSameCapture() throws {
        var provenanceReads = 0
        let frozen = provenance
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { true },
            encoderProvenance: { provenanceReads += 1; return frozen })
        lastSink = sink
        let terminal = event()
        for kind in [VoiceSharingCollector.SignalKind.started, .cancelled] {
            sink.handle(.init(
                kind: kind, captureID: terminal.captureID,
                enrollmentEpoch: terminal.enrollmentEpoch, authorizationSession: terminal.authorizationSession,
                retainedSamples: samples.count, truncated: false, droppedSpans: [],
                originalSampleCount: samples.count, audio: samples, isGateControl: false))
        }
        // A gate-control record cannot contribute even if its kind is otherwise eligible.
        let control = VoiceSharingCollector.SegmentEvent(kind: .completed, captureID: terminal.captureID,
                        enrollmentEpoch: terminal.enrollmentEpoch, authorizationSession: terminal.authorizationSession,
                        retainedSamples: samples.count, truncated: false, droppedSpans: [],
                        originalSampleCount: samples.count, audio: samples, isGateControl: true)
        sink.handle(control)
        drain()
        XCTAssertEqual(provenanceReads, 0, "rejected signals must never reach the encoding prerequisite")
        XCTAssertEqual(queue.readyEntries().count, 0)
        sink.handle(terminal)
        let metadata = try readyMetadata()
        XCTAssertEqual(provenanceReads, 1)
        XCTAssertTrue(String(decoding: metadata, as: UTF8.self).contains(terminal.captureID.uuidString))
    }

    func test_wakeAndBleedRejectionsRemainRealAudioContributions() throws {
        let frozen = provenance
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { true }, encoderProvenance: { frozen })
        lastSink = sink
        for kind in [VoiceSharingCollector.SignalKind.rejectedWake, .rejectedBleed] {
            let contribution = VoiceSharingCollector.SegmentEvent(
                kind: kind, captureID: UUID(), enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
                retainedSamples: samples.count, truncated: false, droppedSpans: [],
                originalSampleCount: samples.count, audio: samples, isGateControl: false)
            sink.handle(contribution)
        }
        drain()
        let ready = queue.readyEntries()
        XCTAssertEqual(ready.count, 2)
        let expected = try VoiceSharingContributionEncoder.encode(
            event: event(), provenance: frozen, observations: [:]).wav
        for entry in ready {
            let dir = root.appendingPathComponent(entry.name)
            let audio = try Data(contentsOf: dir.appendingPathComponent("audio.wav"))
            let metadata = try Data(contentsOf: dir.appendingPathComponent("metadata.json"))
            XCTAssertEqual(audio, expected, "negative wake/bleed records retain the actual PCM conversion")
            _ = try VoiceSharingRecordBinding.bind(envelope: metadata, audio: audio)
        }
    }

    private final class OutcomeScheduler {
        var now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        var scheduled: [(DispatchTime, DispatchWorkItem)] = []

        func fire() {
            let batch = scheduled
            scheduled.removeAll()
            for (deadline, work) in batch {
                now = deadline
                work.perform()
            }
        }
    }

    private func deadlineCollector(_ scheduler: OutcomeScheduler,
                                   limit: VoiceSharingCollector.OutcomeWaitLimit? = .init(milliseconds: 25, ceilingMilliseconds: 100),
                                   sessionIdentity: @escaping () -> String? = { "sess-1" }) -> VoiceSharingCollector {
        let policy = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000), readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true })
        policy.identityBecameReadable()
        XCTAssertNotNil(policy.refreshAfterActivation(
            freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()))
        var state = VoiceSharingEnrollmentStore.State()
        state.localOptIn = true
        state.hasAuthoritativeProjection = true
        state.membership = VoiceSharingMembership(
            membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
            enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "synthetic", withdrawalState: .active)
        let frozenProvenance = provenance
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { [weak self] in self?.enabled ?? false },
            encoderProvenance: { frozenProvenance })
        lastSink = sink
        let collector = VoiceSharingCollector(
            policy: policy, captureAllowance: FiniteCaptureAdmission(), outcomeWaitLimit: limit,
            monotonicNow: { scheduler.now },
            scheduleOutcome: { scheduler.scheduled.append(($0, $1)) },
            membership: { state }, epochProvider: { "epoch-1" }, sessionIdentity: sessionIdentity,
            sink: { sink.handle($0) })
        collector.deliversSynchronouslyForTesting = true
        return collector
    }

    private func readyMetadata() throws -> Data {
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            throw NSError(domain: "unknown queue coverage", code: 1)
        }
        XCTAssertEqual(ready.count, 1)
        let entry = try XCTUnwrap(ready.first)
        let dir = root.appendingPathComponent(entry.name)
        let meta = try Data(contentsOf: dir.appendingPathComponent("metadata.json"))
        let audio = try Data(contentsOf: dir.appendingPathComponent("audio.wav"))
        _ = try VoiceSharingRecordBinding.bind(envelope: meta, audio: audio)
        return meta
    }

    func test_outcomeDeadlinePublishesReadyRecordBeforeDownstreamReturnsAndFencesLateCallbacks() throws {
        let scheduler = OutcomeScheduler()
        let collector = deadlineCollector(scheduler)
        let context = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: samples.count))
        collector.appendSamples(samples)
        // The real engine calls this before its first readiness/backend await, before speechCompleted.
        collector.segmentationEnded(context)
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertEqual(scheduler.scheduled.first?.0.uptimeNanoseconds, 1_025_000_000)
        drain()
        XCTAssertEqual(queue.readyEntries().count, 0)
        collector.engineReported(stage: "wake", outcome: .init(state: "completed"), context: context)
        scheduler.fire()
        let frozen = try readyMetadata()
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: frozen) as? [String: Any])
        let record = try XCTUnwrap(envelope["record"] as? [String: Any])
        let observations = try XCTUnwrap(record["observations"] as? [String: [String: Any]])
        XCTAssertEqual(observations["wake"]?["state"] as? String, "completed")
        XCTAssertEqual(observations["asr"]?["reason"] as? String, "outcome_wait_expired")
        collector.engineReported(stage: "asr", outcome: .init(state: "completed", text: "late"), context: context)
        collector.speechCompleted(samples, context: context, deferEmission: true)
        collector.finalizeDeferredCompletion(context: context)
        XCTAssertEqual(try readyMetadata(), frozen, "late downstream results cannot amend or duplicate the winner")
    }

    func test_normalFinalizationIsImmediateAndDoesNotInventDeadlineExpiry() throws {
        let scheduler = OutcomeScheduler()
        let collector = deadlineCollector(scheduler)
        let context = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: samples.count))
        collector.appendSamples(samples)
        collector.segmentationEnded(context)
        collector.speechCompleted(samples, context: context, deferEmission: true)
        collector.finalizeDeferredCompletion(context: context)
        let frozen = try readyMetadata()
        XCTAssertTrue(String(decoding: frozen, as: UTF8.self).contains("observation_unavailable"))
        XCTAssertFalse(String(decoding: frozen, as: UTF8.self).contains("outcome_wait_expired"))
        XCTAssertTrue(try XCTUnwrap(scheduler.scheduled.first).1.isCancelled)
        scheduler.fire()
        collector.engineReported(stage: "asr", outcome: .init(state: "completed", text: "late"), context: context)
        XCTAssertEqual(try readyMetadata(), frozen)
    }

    func test_revocationBeforeOutcomeDeadlineDisposesCaptureAndCannotPublish() throws {
        let scheduler = OutcomeScheduler()
        let collector = deadlineCollector(scheduler)
        let context = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: samples.count))
        collector.appendSamples(samples)
        collector.segmentationEnded(context)
        collector.gateLost()
        XCTAssertTrue(try XCTUnwrap(scheduler.scheduled.first).1.isCancelled)
        scheduler.fire()
        collector.speechCompleted(samples, context: context, deferEmission: true)
        collector.finalizeDeferredCompletion(context: context)
        drain()
        XCTAssertEqual(queue.readyEntries().count, 0)
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0)
    }

    func test_identityChangeWithoutGateLossRefusesDeadlineAndReleasesAudio() throws {
        let scheduler = OutcomeScheduler()
        var session = "sess-1"
        let collector = deadlineCollector(scheduler, sessionIdentity: { session })
        let context = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: samples.count))
        collector.appendSamples(samples)
        collector.segmentationEnded(context)
        XCTAssertFalse(try XCTUnwrap(scheduler.scheduled.first).1.isCancelled)
        session = "sess-2"
        scheduler.fire()
        drain()
        XCTAssertEqual(queue.readyEntries().count, 0)
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0)
        collector.speechCompleted(samples, context: context, deferEmission: true)
        collector.finalizeDeferredCompletion(context: context)
        drain()
        XCTAssertEqual(queue.readyEntries().count, 0)
    }

    func test_evictedAndDeallocatedOutcomeTimersCannotPublish() throws {
        let scheduler = OutcomeScheduler()
        var collector: VoiceSharingCollector? = deadlineCollector(scheduler)
        for _ in 0..<33 {
            let context = try XCTUnwrap(collector?.speechStarted(confirmationFrameSamples: samples.count))
            collector?.appendSamples(samples)
            collector?.segmentationEnded(context)
        }
        let evicted = scheduler.scheduled.filter { $0.1.isCancelled }
        XCTAssertFalse(evicted.isEmpty, "bounded ring eviction must retire a timer")
        for (_, work) in evicted { work.perform() }
        drain()
        XCTAssertEqual(queue.readyEntries().count, 0)
        weak var released = collector
        collector = nil
        XCTAssertNil(released, "scheduled work must not own the collector or its PCM")
        XCTAssertTrue(scheduler.scheduled.allSatisfy { $0.1.isCancelled })
        scheduler.fire()
        drain()
        XCTAssertEqual(queue.readyEntries().count, 0)
    }

    func test_missingOrInvalidOutcomeLimitClosesAdmissionBeforeRetainingAudio() {
        XCTAssertNil(VoiceSharingCollector.OutcomeWaitLimit(milliseconds: 0, ceilingMilliseconds: 100))
        XCTAssertNil(VoiceSharingCollector.OutcomeWaitLimit(milliseconds: -1, ceilingMilliseconds: 100))
        XCTAssertNil(VoiceSharingCollector.OutcomeWaitLimit(milliseconds: Int.max, ceilingMilliseconds: 100))
        XCTAssertNil(VoiceSharingCollector.OutcomeWaitLimit(milliseconds: 101, ceilingMilliseconds: 100))
        XCTAssertNil(VoiceSharingCollector.OutcomeWaitLimit(milliseconds: 25))
        let collector = deadlineCollector(OutcomeScheduler(), limit: nil)
        XCTAssertNil(collector.speechStarted(confirmationFrameSamples: samples.count))
        collector.appendSamples(samples)
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0)
        drain()
        XCTAssertEqual(queue.readyEntries().count, 0)
    }

    func test_dailyCaptureChargeSurvivesReadyQueueDrainAndRestart() throws {
        let policy = VoiceSharingPolicy(clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) }, isAccountEnrolled: { true })
        policy.identityBecameReadable()
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()))
        var state = VoiceSharingEnrollmentStore.State()
        state.localOptIn = true
        state.hasAuthoritativeProjection = true
        state.membership = VoiceSharingMembership(membershipRevision: "rev", plan: .pro,
            voiceSharingEnrolled: true, enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "synthetic", withdrawalState: .active)
        let limits = try XCTUnwrap(VoiceSharingCaptureLimits(dailyRecords: 1, dailyBytes: 100_000,
            compiledRecordsCeiling: 1, compiledBytesCeiling: 100_000, clipSamples: 16,
            metadataBytes: VoiceSharingUploadQueue.maxMetadataBytes, compiledClipSamples: 16,
            compiledMetadataBytes: VoiceSharingUploadQueue.maxMetadataBytes))
        let stamp = VoiceSharingCaptureStamp(session: "sess-1", epoch: "epoch-1", policyGeneration: policy.currentLeaseGeneration)
        let authority = try XCTUnwrap(VoiceSharingCaptureAuthorization(account: "synthetic", establishedWindow: "one", limits: limits, consent: stamp))
        let ledgerRoot = root.deletingLastPathComponent().appendingPathComponent("usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ledgerRoot) }
        XCTAssertTrue(VoiceSharingCaptureLedger(root: ledgerRoot).provision(.init(verifiedFirstProvisioningAccount: "synthetic", establishedWindow: "one")!))
        let owner = VoiceSharingCaptureAllowance(ledger: .init(root: ledgerRoot), currentAuthorization: { authority })
        owner.requestPreparation()
        owner.waitForPreparationForTesting()
        let sink = makeSink()
        let collector = VoiceSharingCollector(policy: policy, captureAllowance: owner,
            outcomeWaitLimit: .init(milliseconds: 25, ceilingMilliseconds: 100), membership: { state },
            epochProvider: { "epoch-1" }, sessionIdentity: { "sess-1" }, sink: { sink.handle($0) })
        collector.deliversSynchronouslyForTesting = true
        let context = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: 640))
        let pcm = [Float](repeating: 0.6, count: 640)
        collector.appendSamples(pcm)
        XCTAssertEqual(collector.retainedCopyForTesting, Array(pcm.prefix(16)))
        collector.speechCompleted(pcm, context: context)
        drain()
        let ready = queue.readyEntries()
        XCTAssertEqual(ready.count, 1)
        let entry = try XCTUnwrap(ready.first)
        let directory = root.appendingPathComponent(entry.name)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("audio.wav")).count, 44 + 32)
        XCTAssertLessThanOrEqual(try Data(contentsOf: directory.appendingPathComponent("metadata.json")).count, limits.metadataBytes)
        // Exercise the actual successful-drain removal boundary; delivery itself is outside this control.
        try queue.remove(entry)
        XCTAssertTrue(queue.readyEntries().isEmpty)
        owner.waitForPreparationForTesting()
        XCTAssertNil(collector.speechStarted(confirmationFrameSamples: 640))
        collector.appendSamples(pcm)
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0)
        XCTAssertFalse(VoiceSharingCaptureLedger(root: ledgerRoot).charge(authority))
        XCTAssertEqual(limits.reservationBytes, UInt64(44 + 32 + limits.metadataBytes))
    }

    private func drain() {
        lastSink?.waitForIdleForTesting()
    }

    private func makeSink() -> VoiceSharingContributionSink {
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { [weak self] in self?.enabled ?? false },
            encoderProvenance: { [weak self] in self!.provenance },
            observations: { [weak self] in self!.observations })
        lastSink = sink
        return sink
    }

    func test_completedEventBecomesAReadyDurableQueueEntry() throws {
        let sink = makeSink()
        let e = event()
        sink.handle(e)
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("the queue must report known coverage after a gated contribution")
        }
        XCTAssertEqual(ready.count, 1)
        // The persisted entry is EXACTLY the encoded record: digest match through the queue's
        // own bind authority.
        let dir = root.appendingPathComponent(ready[0].name)
        let audioData = try Data(contentsOf: dir.appendingPathComponent("audio.wav"))
        let meta = try Data(contentsOf: dir.appendingPathComponent("metadata.json"))
        let bound = try VoiceSharingRecordBinding.bind(envelope: meta, audio: audioData)
        XCTAssertEqual(bound.captureID, e.captureID.uuidString)
        XCTAssertEqual(bound.audioSHA256,
                       SHA256.hash(data: audioData).map { String(format: "%02x", $0) }.joined())
    }

    func test_disabledGateProducesNoQueueEntry() throws {
        enabled = false
        makeSink().handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.count, 0, "a disabled gate must not mint upload work")
    }

    func test_reEnablingTheGateResumesCollection() throws {
        enabled = false
        makeSink().handle(event())
        drain()
        enabled = true
        makeSink().handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.count, 1, "collection resumes when the gate reopens")
    }

    func test_tamperedPersistedAudioNeverServes() throws {
        let sink = makeSink()
        sink.handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        // TAMPER the persisted audio after finalization.
        let audioURL = root.appendingPathComponent(ready[0].name).appendingPathComponent("audio.wav")
        var data = try Data(contentsOf: audioURL)
        data[VoiceSharingRecordBinding.wavHeaderBytes + 2] ^= 0xFF
        try data.write(to: audioURL)
        // The queue's own authority refuses: the entry disappears from readiness (fresh query,
        // same production recovery path a relaunch would take).
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known after tamper")
        }
        XCTAssertEqual(after.count, 0, "a digest-mismatched entry must never be ready upload work")
    }

    func test_malformedStageClaimFailsAtTheSinkWithoutSideEffects() throws {
        // A claim bind() will refuse (non-enumerated reason): the sink drops the event, logs,
        // and the queue stays EMPTY — no partial entry survives a failed encode.
        var bad = observations
        bad["wake"] = .init(state: "failed", reason: "definitely-not-enumerated")
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { true },
            encoderProvenance: { [weak self] in self!.provenance },
            observations: { bad })
        lastSink = sink
        sink.handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0,
                       "a failed encode leaves nothing behind — no partial queue entry")
        XCTAssertEqual(ready.count, 0)
    }
}
