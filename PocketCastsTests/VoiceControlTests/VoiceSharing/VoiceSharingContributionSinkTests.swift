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
            conversionVersion: 1)
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
        XCTAssertEqual(result?.removed, 2)
        XCTAssertEqual(result?.retainedDisqualified, 0)
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
        var firstBlock = true
        sink.testingWorkerGate = {
            guard firstBlock else { return }
            firstBlock = false
            blocked.fulfill()
            release.lock()
            release.wait()
            release.unlock()
        }
        for _ in 0..<(VoiceSharingContributionSink.maxPendingEvents + 5) {
            sink.handle(event())
        }
        // While the worker is blocked, 20 closures are queued; only 15 more slots exist, so the
        // last 5 submissions must have been refused at ENQUEUE time.
        release.lock(); release.broadcast(); release.unlock()
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
        XCTAssertEqual(result?.removed, 0)
        XCTAssertEqual(result?.retainedDisqualified, 1,
                       "a removal failure must be reported, never collapsed into success")
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
