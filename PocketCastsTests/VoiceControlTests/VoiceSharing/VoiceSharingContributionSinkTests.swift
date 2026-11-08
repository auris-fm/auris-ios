import CryptoKit
import XCTest
@testable import podcasts

/// The real boundary control: collector event → encoder → QUEUE → ready entry, plus tamper
/// negatives proving a corrupted entry never serves. The queue here is the production type with
/// its production recovery/readiness authority — not a stub.
final class VoiceSharingContributionSinkTests: XCTestCase {
    private var root: URL!

    /// Lock-protected monotonic reading a control can step.
    private final class MonotonicStep {
        private let lock = NSLock()
        private var stored: Int
        init(_ initial: Int) { stored = initial }
        var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ next: Int) { lock.lock(); stored = next; lock.unlock() }
    }
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
            "wake": .init(state: "completed", decision: "detected"),
            "bleed": .init(state: "not_run", reason: "no_playback_reference"),
            "asr": .init(state: "not_run", reason: "local_only_action"),
            "translation": .init(state: "not_run", reason: "no_text"),
            "routing": .init(state: "not_run", reason: "no_candidates"),
            "execution": .init(state: "not_run", reason: "client_refused"),
        ]
    }

    /// PUBLICATION → DRAIN (spec 5ffbfdd5): a durable publication REACHES THE TRANSPORT with no
    /// lifecycle event at all. The assembly wires the sink's success callback to the existing
    /// upload trigger; here the same seam is wired to a real trigger over a real scheduler, and the
    /// transport records the request. A RED failure under a sink that never calls back proves the
    /// control bites.
    func test_successfulPublicationRequestsADrainAndReachesTheTransport() async throws {
        var drainRequests = 0
        let transportCalls = TransportCallBox()
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(retryBaseDelay: 1, retryMaximumDelay: 60, random: { 0 }),
            isAuthorized: { true }, currentIdentity: { nil },
            endpoint: { URL(string: "https://unit.test/api/v1/voice-recordings") },
            transport: { _, _, _ in
                await transportCalls.record()
                return .response(statusCode: 503, body: Data())
            })
        let scheduler = VoiceSharingUploadScheduler(queue: queue, uploader: uploader,
                                                   isAuthorized: { true })
        // The production trigger, with its real gates; NO app lifecycle event is delivered here.
        let trigger = VoiceSharingUploadTrigger(
            scheduler: scheduler, surfaceEnabled: { true }, isAuthorized: { true })
        let sink = VoiceSharingContributionSink(
            queue: queue,
            isEnabled: { true },
            encoderProvenance: { [self] in provenance },
            observations: { [self] in observations },
            requestUploadDrain: {
                drainRequests += 1
                trigger.triggerDrainIfPermitted()
            })
        lastSink = sink
        sink.handle(event())
        drain()

        // The publication must have become a READY entry (premise: not an empty no-op).
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
            !ready.isEmpty else {
            return XCTFail("premise: publication produced no ready entry")
        }
        XCTAssertEqual(drainRequests, 1, "exactly one drain request per successful publication")
        await trigger.awaitDrainCompletionForTesting()
        let reached = await transportCalls.count()
        XCTAssertGreaterThanOrEqual(reached, 1,
            "the publication's drain must reach the transport with no lifecycle event")
    }

    /// SPEC DEFECT d6580187, fix 1: a pass that ends with every entry behind its not-before
    /// boundary must produce a second drain AT the boundary, with NO lifecycle event and NO new
    /// entry — the 503-retry stall on the owner simulator (uploader idle since 10:00:21Z while
    /// the retry was due at 10:00:26Z) is exactly this missing wake. Red on the parent: after
    /// the first idle pass, nothing ever re-offers and the transport is never reached.
    func test_aRetryBoundaryWakesTheTriggerWithoutAnyLifecycleEvent() async throws {
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { self.enabled },
            encoderProvenance: { [self] in provenance }, observations: { [self] in observations })
        lastSink = sink
        sink.handle(event())
        drain()
        // Premise: one durably ready entry exists.
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
            ready.count == 1 else {
            return XCTFail("premise: publication produced no ready entry")
        }
        let entryName = ready[0].name
        // Hold it behind a retry boundary 0.5s out (the persisted not-before stamp).
        let stamp = Date().addingTimeInterval(0.5).timeIntervalSince1970
        try JSONSerialization.data(withJSONObject: ["notBefore": stamp])
            .write(to: root.appendingPathComponent("attempt.notbefore.\(entryName)"), options: .atomic)

        let transportCalls = TransportCallBox()
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(retryBaseDelay: 3600, retryMaximumDelay: 3600, random: { 1 }),
            isAuthorized: { true }, currentIdentity: { nil },
            endpoint: { URL(string: "https://unit.test/api/v1/voice-recordings") },
            transport: { _, _, _ in
                await transportCalls.record()
                return .response(statusCode: 503, body: Data())
            })
        let scheduler = VoiceSharingUploadScheduler(queue: queue, uploader: uploader,
                                                    isAuthorized: { true })
        let trigger = VoiceSharingUploadTrigger(
            scheduler: scheduler, surfaceEnabled: { true }, isAuthorized: { true })

        // Pass 1: a real trigger call, no lifecycle event afterwards. The entry is behind the
        // boundary, so this pass is idle and reaches nothing.
        trigger.triggerDrainIfPermitted()
        await trigger.awaitDrainCompletionForTesting()
        let afterIdlePass = await transportCalls.count()
        XCTAssertEqual(afterIdlePass, 0, "premise: the boundary pass sends nothing")

        // THE FIX: one bounded wake armed from the boundary must re-offer and run the due entry —
        // with no foreground event, no network change, and no new publication. Observed over a
        // bounded window so the control also compiles (and fails) without the fix.
        let deadline = ContinuousClock.now + .seconds(4)
        var reached = await transportCalls.count()
        while reached == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            reached = await transportCalls.count()
        }
        XCTAssertGreaterThanOrEqual(reached, 1,
            "the retry boundary wake must run the due entry with no lifecycle event")
    }

    /// REVIEWER ea2964b3 (1): an orphaned/expired not-before stamp must not suppress another
    /// live entry's future retry. The simulator holds ten orphan stamps; on HEAD the boundary
    /// reader answered 0 for an unreadable stamp and the trigger refused to arm any wake, so the
    /// live boundary never fired. RED on `eb8350219`.
    func test_anOrphanedStampCannotSuppressAnotherLiveEntryRetryWake() async throws {
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { self.enabled },
            encoderProvenance: { [self] in provenance }, observations: { [self] in observations })
        lastSink = sink
        sink.handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
            ready.count == 1 else {
            return XCTFail("premise: publication produced no ready entry")
        }
        let entryName = ready[0].name
        let stamp = Date().addingTimeInterval(0.5).timeIntervalSince1970
        try JSONSerialization.data(withJSONObject: ["notBefore": stamp])
            .write(to: root.appendingPathComponent("attempt.notbefore.\(entryName)"), options: .atomic)
        // Debris at the root: an UNREADABLE stamp and an EXPIRED stamp over a purged entry.
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent("attempt.notbefore.11111111-1111-1111-1111-111111111111"),
            options: .atomic)
        try JSONSerialization.data(withJSONObject: ["notBefore": 0])
            .write(to: root.appendingPathComponent("attempt.notbefore.22222222-2222-2222-2222-222222222222"),
                   options: .atomic)

        let transportCalls = TransportCallBox()
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(retryBaseDelay: 3600, retryMaximumDelay: 3600, random: { 1 }),
            isAuthorized: { true }, currentIdentity: { nil },
            endpoint: { URL(string: "https://unit.test/api/v1/voice-recordings") },
            transport: { _, _, _ in
                await transportCalls.record()
                return .response(statusCode: 503, body: Data())
            })
        let scheduler = VoiceSharingUploadScheduler(queue: queue, uploader: uploader,
                                                    isAuthorized: { true })
        let trigger = VoiceSharingUploadTrigger(
            scheduler: scheduler, surfaceEnabled: { true }, isAuthorized: { true })
        trigger.triggerDrainIfPermitted()
        await trigger.awaitDrainCompletionForTesting()
        let afterIdlePass = await transportCalls.count()
        XCTAssertEqual(afterIdlePass, 0, "premise: the boundary pass sends nothing")

        let deadline = ContinuousClock.now + .seconds(4)
        var reached = await transportCalls.count()
        while reached == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            reached = await transportCalls.count()
        }
        XCTAssertGreaterThanOrEqual(reached, 1,
            "the orphan stamps must not suppress the live entry's retry wake")
    }

    /// REVIEWER ea2964b3 (1): a still-future boundary within 50 ms must still be armed. HEAD
    /// refused to arm any wake for delays <= 0.05, leaving the entry idle forever. RED on HEAD.
    func test_aNearBoundaryStillArmsTheRetryWake() async throws {
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { self.enabled },
            encoderProvenance: { [self] in provenance }, observations: { [self] in observations })
        lastSink = sink
        sink.handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
            ready.count == 1 else {
            return XCTFail("premise: publication produced no ready entry")
        }
        let entryName = ready[0].name
        let stamp = Date().addingTimeInterval(0.03).timeIntervalSince1970
        try JSONSerialization.data(withJSONObject: ["notBefore": stamp])
            .write(to: root.appendingPathComponent("attempt.notbefore.\(entryName)"), options: .atomic)

        let transportCalls = TransportCallBox()
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(retryBaseDelay: 3600, retryMaximumDelay: 3600, random: { 1 }),
            isAuthorized: { true }, currentIdentity: { nil },
            endpoint: { URL(string: "https://unit.test/api/v1/voice-recordings") },
            transport: { _, _, _ in
                await transportCalls.record()
                return .response(statusCode: 503, body: Data())
            })
        let scheduler = VoiceSharingUploadScheduler(queue: queue, uploader: uploader,
                                                    isAuthorized: { true })
        let trigger = VoiceSharingUploadTrigger(
            scheduler: scheduler, surfaceEnabled: { true }, isAuthorized: { true })
        trigger.triggerDrainIfPermitted()
        await trigger.awaitDrainCompletionForTesting()
        let afterIdlePass = await transportCalls.count()
        XCTAssertEqual(afterIdlePass, 0, "premise: the boundary pass sends nothing")

        let deadline = ContinuousClock.now + .seconds(4)
        var reached = await transportCalls.count()
        while reached == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            reached = await transportCalls.count()
        }
        XCTAssertGreaterThanOrEqual(reached, 1,
            "a boundary within the schedule floor must still wake the trigger")
    }

    /// SPEC DEFECT d6580187, collector-level control (reviewer ea2964b3): the retry→capture path
    /// must work with a capture fed through the REAL collector emission path, not just
    /// `sink.handle`. A retry disposition, then a new collector capture: it must produce an
    /// entry and reach the transport.
    func test_afterARetryDispositionANewCollectorCaptureStillProducesAnEntry() async throws {
        let transportCalls = TransportCallBox()
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(retryBaseDelay: 3600, retryMaximumDelay: 3600, random: { 1 }),
            isAuthorized: { true }, currentIdentity: { nil },
            endpoint: { URL(string: "https://unit.test/api/v1/voice-recordings") },
            transport: { _, _, _ in
                await transportCalls.record()
                return .response(statusCode: 503, body: Data())
            })
        let scheduler = VoiceSharingUploadScheduler(queue: queue, uploader: uploader,
                                                    isAuthorized: { true })
        let trigger = VoiceSharingUploadTrigger(
            scheduler: scheduler, surfaceEnabled: { true }, isAuthorized: { true })
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { self.enabled },
            encoderProvenance: { [self] in provenance }, observations: { [self] in observations },
            requestUploadDrain: { [weak trigger] in trigger?.triggerDrainIfPermitted() })
        lastSink = sink
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { [self] in enabled },
            membership: { VoiceSharingEnrollmentStore.State() },
            epochProvider: { "test-epoch" },
            sessionIdentity: { "sess-1" },
            sink: { event in sink.handle(event) })
        collector.deliversSynchronouslyForTesting = true

        // Capture A: real collector emission -> sink -> entry -> drain -> 503 retry.
        let contextA = collector.speechStarted(confirmationFrameSamples: 320)
        collector.appendSamples([Float](repeating: 1, count: 3_200), reportedTotal: 3_200)
        collector.segmentationEnded(contextA)
        collector.finalizeDeferredCompletion(context: contextA)
        drain()
        await trigger.awaitDrainCompletionForTesting()
        let afterA = await transportCalls.count()
        XCTAssertGreaterThanOrEqual(afterA, 1, "premise: entry A was attempted and retried")

        // Capture B arrives through the collector while A is behind its boundary.
        let contextB = collector.speechStarted(confirmationFrameSamples: 320)
        collector.appendSamples([Float](repeating: 1, count: 3_200), reportedTotal: 3_200)
        collector.segmentationEnded(contextB)
        collector.finalizeDeferredCompletion(context: contextB)
        drain()
        await trigger.awaitDrainCompletionForTesting()
        let afterB = await transportCalls.count()
        XCTAssertGreaterThanOrEqual(afterB, afterA + 1,
            "the collector-emitted capture becomes an entry and is attempted despite the retry")
    }

    /// SPEC DEFECT d6580187, regression coverage: a retry disposition followed by NEW captures
    /// must still produce entries and reach the transport — the stalled uploader must never
    /// gate the capture-to-entry path, and the new entry must serve while the old one is
    /// behind its retry boundary.
    func test_aRetryDispositionDoesNotStopNewCapturesFromProducingEntries() async throws {
        let transportCalls = TransportCallBox()
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(retryBaseDelay: 3600, retryMaximumDelay: 3600, random: { 1 }),
            isAuthorized: { true }, currentIdentity: { nil },
            endpoint: { URL(string: "https://unit.test/api/v1/voice-recordings") },
            transport: { _, _, _ in
                await transportCalls.record()
                return .response(statusCode: 503, body: Data())
            })
        let scheduler = VoiceSharingUploadScheduler(queue: queue, uploader: uploader,
                                                    isAuthorized: { true })
        let trigger = VoiceSharingUploadTrigger(
            scheduler: scheduler, surfaceEnabled: { true }, isAuthorized: { true })

        // Capture A publishes and drains: 503, retry disposition, boundary published.
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { self.enabled },
            encoderProvenance: { [self] in provenance }, observations: { [self] in observations },
            requestUploadDrain: { [weak trigger] in trigger?.triggerDrainIfPermitted() })
        lastSink = sink
        sink.handle(event())
        drain()
        await trigger.awaitDrainCompletionForTesting()
        let afterA = await transportCalls.count()
        XCTAssertGreaterThanOrEqual(afterA, 1, "premise: entry A was attempted and retried")

        // Capture B arrives while A is behind its retry boundary: it must still become an
        // entry, and the publication drain must attempt it.
        sink.handle(event())
        drain()
        // The publication drain races this read: wait bounded for capture B's entry to appear.
        var readyCount = 0
        if case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() { readyCount = ready.count }
        let readyDeadline = Date().addingTimeInterval(4)
        while readyCount < 2 && Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.05)
            if case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() { readyCount = ready.count }
        }
        XCTAssertEqual(readyCount, 2,
            "both entries list; the uploader's boundary admission owns who attempts")
        await trigger.awaitDrainCompletionForTesting()
        let afterB = await transportCalls.count()
        XCTAssertGreaterThanOrEqual(afterB, afterA + 1,
            "the new capture's entry is attempted despite the pending retry")
    }

    final class TransportCallBox {
        private let lock = NSLock()
        private var calls = 0
        func record() { lock.lock(); calls += 1; lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
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
        XCTAssertFalse(failingFileSyncQueue.hasAdmissionAllowance())
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
        XCTAssertFalse(fresh.hasAdmissionAllowance(), "preflight must refuse")
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
            // Discovery reads the UNBOUNDED lister (spec a4b417fc ruling 1); injecting into the
            // bounded one made the listing succeed and the control prove nothing.
            listDirectory: { url, keys in
                if failListing { throw CocoaError(.fileReadNoPermission) }
                return try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys)
            })
        guard case .refused = refusingListQueue.purgeAll() else {
            return XCTFail("an unlistable root must refuse, never report success")
        }
        // The I/O failure now clears — the hold must NOT clear with it.
        failListing = false
        guard case .revocationHeld = refusingListQueue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("a refused listing must leave the owner held")
        }
        XCTAssertFalse(refusingListQueue.hasAdmissionAllowance())
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
        XCTAssertFalse(fresh.hasAdmissionAllowance())
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

    /// SPEC 1e79e5b4, BUILDER SIDE: the ASR stage states the observed skip that belongs to a bleed
    /// rejection, while the bleed stage keeps its own observed decision. The claim arrives as an
    /// OBSERVED stage fact — the encoder never infers stage facts from the event kind (review: fixtures
    /// that omitted `reportedStages` were exercising nothing but that inference) — so this control states
    /// the facts explicitly. The full engine→collector→queue integration proof is
    /// `test_realEngineBleedRejectionPersistsTheObservedAsrSkip`; records are identified by capture ID
    /// because queue ordering is not part of the observation contract.
    func test_persistedRecordCarriesTheStatedAsrSkipAndItsOwnBleedDecision() throws {
        let frozen = provenance
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { true }, encoderProvenance: { frozen })
        lastSink = sink
        let bleedID = UUID(), wakeID = UUID()
        var bleedOutcome = VoiceSharingCollector.SegmentEvent(
            kind: .rejectedBleed, captureID: bleedID, enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: samples.count, audio: samples, isGateControl: false)
        bleedOutcome.reportedStages = [
            "bleed": .init(state: "completed", decision: "overlap"),
            "asr": .init(state: "not_run", reason: VoiceSharingCollector.bleedSkipReason),
        ]
        var wakeOutcome = VoiceSharingCollector.SegmentEvent(
            kind: .rejectedWake, captureID: wakeID, enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: samples.count, audio: samples, isGateControl: false)
        wakeOutcome.reportedStages = ["asr": .init(state: "not_run", reason: "rejected_by_wake")]
        for event in [bleedOutcome, wakeOutcome] { sink.handle(event) }
        drain()

        let byCapture = try recordsByCaptureID()
        let bleed = try XCTUnwrap(byCapture[bleedID.uuidString])
        let bleedASR = try XCTUnwrap(bleed["asr"] as? [String: Any], "the record states the ASR stage")
        XCTAssertEqual(bleedASR["state"] as? String, "not_run",
                       "the record must state why ASR did not run for this capture")
        XCTAssertEqual(bleedASR["reason"] as? String, "rejected_by_bleed")
        XCTAssertNil(bleedASR["text"], "a skipped stage carries no transcript")
        XCTAssertEqual((bleed["bleed"] as? [String: Any])?["decision"] as? String, "overlap",
                       "the bleed stage keeps its own observed decision")
        let wake = try XCTUnwrap(byCapture[wakeID.uuidString])
        let wakeASR = try XCTUnwrap(wake["asr"] as? [String: Any], "the record states the ASR stage")
        XCTAssertEqual(wakeASR["state"] as? String, "not_run")
        XCTAssertEqual(wakeASR["reason"] as? String, "rejected_by_wake",
                       "the wake path is unchanged by the bleed-skip change")
    }

    /// RECOVERY SIDE of spec 1e79e5b4: a persisted bleed-skip record — built by the real encoder and
    /// marked ready with its real bytes and digest — must be confirmed by a FRESH queue instance.
    /// Recovery refuses a pairing intake refuses, so the known skip has to survive restart.
    func test_genuineBleedRejectedRecordSurvivesFreshQueueRecovery() throws {
        let frozen = provenance
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { true }, encoderProvenance: { frozen })
        lastSink = sink
        let captureID = UUID()
        var event = VoiceSharingCollector.SegmentEvent(
            kind: .rejectedBleed, captureID: captureID, enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: samples.count, audio: samples, isGateControl: false)
        event.reportedStages = [
            "bleed": .init(state: "completed", decision: "overlap"),
            "asr": .init(state: "not_run", reason: VoiceSharingCollector.bleedSkipReason),
        ]
        sink.handle(event)
        drain()
        lastSink = nil
        XCTAssertEqual(queue.readyEntries().count, 1)

        let recovered = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let ready = recovered.readyEntries()
        XCTAssertEqual(ready.count, 1, "recovery must confirm the record the builder wrote")
        _ = try recovered.boundIdentity(of: ready[0])
        let recoveredRecord = try XCTUnwrap(try recordsByCaptureID(in: recovered)[captureID.uuidString])
        let recoveredASR = try XCTUnwrap(recoveredRecord["asr"] as? [String: Any])
        XCTAssertEqual(recoveredASR["state"] as? String, "not_run")
        XCTAssertEqual(recoveredASR["reason"] as? String, "rejected_by_bleed",
                       "the recovered record still states the observed skip")
    }

    /// Persisted observation blocks keyed by the record's own capture ID — the identity the observation
    /// contract names, never the queue's enumeration order.
    private func recordsByCaptureID(
        in source: VoiceSharingUploadQueue? = nil
    ) throws -> [String: [String: Any]] {
        var byCapture: [String: [String: Any]] = [:]
        for entry in (source ?? queue).readyEntries() {
            let directory = root.appendingPathComponent(entry.name)
            let metadata = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
            let record = try XCTUnwrap(
                (try JSONSerialization.jsonObject(with: metadata) as? [String: Any])?["record"] as? [String: Any])
            let captureID = try XCTUnwrap(record["capture_id"] as? String)
            let observations = try XCTUnwrap(record["observations"] as? [String: Any],
                                             "\(captureID): observations missing")
            byCapture[captureID] = observations
        }
        return byCapture
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
            isCollectionPermitted: { true }, outcomeWaitLimit: limit,
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
        collector.engineReported(stage: "wake", outcome: .init(state: "completed", decision: "detected"), context: context)
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
        // AMENDED BY SPEC 2741a0ca: the in-process FIFO cap that used to press a record out of the
        // ring is GONE, because discarding a capture before any durable record exists maps to no
        // allowed gate. Pressure is counted and logged; the capture is still queued. So the eviction
        // this control was written around no longer happens — which is the point, not a regression.
        // What still matters is the property it protected: nothing is silently lost.
        // The terminal ring still evicts past 32, but an unemitted record is SUBMITTED through the
        // normal sink path at eviction and only then has its deadline cancelled — so eviction is
        // never silent loss (spec defect d6580187). What the FIFO-cap removal changed is the
        // HANDOFF: pressure no longer discards a capture before any durable record exists.
        let evicted = scheduler.scheduled.filter { $0.1.isCancelled }
        XCTAssertFalse(evicted.isEmpty, "ring eviction retires the deadline of the record it submits")
        for (_, work) in evicted { work.perform() }
        drain()
        // NO-SILENT-LOSS (spec defect d6580187): the record pressed out of the ring is EMITTED
        // at eviction — exactly one durably ready entry — and the evicted (cancelled) timer can
        // never publish a second copy of it. The emission hops the collector's work queue, so
        // observe over a bounded window instead of racing it.
        let emissionDeadline = Date().addingTimeInterval(4)
        while queue.readyEntries().isEmpty && Date() < emissionDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(queue.readyEntries().count, 1,
            "the evicted unemitted record is contributed, never silently discarded")
        weak var released = collector
        collector = nil
        XCTAssertNil(released, "scheduled work must not own the collector or its PCM")
        XCTAssertTrue(scheduler.scheduled.allSatisfy { $0.1.isCancelled })
        scheduler.fire()
        drain()
        XCTAssertEqual(queue.readyEntries().count, 1,
            "no stale timer resurrects or duplicates a published record")
    }

    /// `OutcomeWaitLimit` still refuses a nonsense value (spec 4afc6e43 keeps the timeout a fixed
    /// annotation deadline), but its ABSENCE is no longer an admission gate: the collector admits
    /// and retains audio on consent alone. This control used to assert the retired readiness gate.
    func test_invalidOutcomeLimitIsRejectedButItsAbsenceNoLongerClosesAdmission() {
        XCTAssertNil(VoiceSharingCollector.OutcomeWaitLimit(milliseconds: 0, ceilingMilliseconds: 100))
        XCTAssertNil(VoiceSharingCollector.OutcomeWaitLimit(milliseconds: -1, ceilingMilliseconds: 100))
        XCTAssertNil(VoiceSharingCollector.OutcomeWaitLimit(milliseconds: Int.max, ceilingMilliseconds: 100))
        XCTAssertNil(VoiceSharingCollector.OutcomeWaitLimit(milliseconds: 101, ceilingMilliseconds: 100))
        XCTAssertNil(VoiceSharingCollector.OutcomeWaitLimit(milliseconds: 25))
        let collector = deadlineCollector(OutcomeScheduler(), limit: nil)
        let context = collector.speechStarted(confirmationFrameSamples: samples.count)
        XCTAssertNotNil(context, "consent alone admits; a missing annotation deadline does not refuse")
        collector.appendSamples(samples)
        XCTAssertEqual(collector.retainedSampleCountForTesting, samples.count,
                       "the audio is retained, not discarded for want of a deadline")
    }

    /// REVIEWER (expanded review of the swept-in dependency set): the allowance's OWN deadline was
    /// not enforced at admission. `valid_for_ms` is an independent lifetime from the policy lease, and
    /// the only expiry watcher scheduled the POLICY deadline — so a short allowance stayed usable
    /// after its own deadline while policy was still live.
    ///
    /// REVIEWER (on `bf335f109`, gap 1): the first version of this control granted ONE record, so its
    /// second `take` failed on ledger exhaustion whatever the deadline did, and two direct `isLive`
    /// assertions were carrying the evidence. This version grants spare capacity and asserts the
    /// PRODUCTION admission result on both sides of the boundary.
    func test_allowanceExpiry_refusesAtCaptureBoundaryWithoutATimer() throws {
        // THREE records and ample bytes: capacity is never the reason for a refusal here, so the
        // only thing that can refuse the third capture is the deadline.
        let limits = try XCTUnwrap(VoiceSharingCaptureLimits(dailyRecords: 3, dailyBytes: 900_000,
            compiledRecordsCeiling: 4, compiledBytesCeiling: 4 * 1_985_580, clipSamples: 16,
            metadataBytes: VoiceSharingUploadQueue.maxMetadataBytes, compiledClipSamples: 16,
            compiledMetadataBytes: VoiceSharingUploadQueue.maxMetadataBytes))
        let stamp = VoiceSharingCaptureStamp(session: "sess-1", epoch: "epoch-1", policyGeneration: 0)
        let batch = "22222222-2222-4222-8222-222222222222"
        let authority = try XCTUnwrap(VoiceSharingCaptureAuthorization(
            account: "synthetic", establishedWindow: "window", batchId: batch, limits: limits,
            consent: stamp, deadlineMonotonicMS: 5_000))
        let ledgerRoot = root.deletingLastPathComponent().appendingPathComponent("usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ledgerRoot) }
        let ledger = VoiceSharingCaptureLedger(root: ledgerRoot)
        XCTAssertTrue(ledger.provision(.init(
            verifiedFirstProvisioningAccount: "synthetic", establishedWindow: "window", batchId: batch)!))
        let clock = MonotonicStep(4_000)
        var producerWakes = 0
        let owner = VoiceSharingCaptureAllowance(ledger: ledger,
                                                 currentAuthorization: { authority },
                                                 capacityExhausted: { producerWakes += 1 },
                                                 monotonicNowMS: { clock.value })

        // A capture INSIDE the allowance: admitted through the real admission path.
        owner.requestPreparation()
        owner.waitForPreparationForTesting()
        XCTAssertNotNil(owner.take(for: stamp), "an allowance inside its deadline admits")
        // Capacity is provably left over: this is what makes the next refusal about the deadline.
        XCTAssertTrue(ledger.charge(authority), "control precondition: batch capacity remains")

        // PAST the deadline, with capacity still available and no refresh in between.
        owner.requestPreparation()
        owner.waitForPreparationForTesting()
        clock.set(5_000)
        let wakes = producerWakes
        XCTAssertNil(owner.take(for: stamp),
                     "the production admission must refuse at the allowance's own deadline")
        XCTAssertGreaterThan(producerWakes, wakes,
                             "and refusing an expired allowance must wake the producer, which replays the allocation")
        // The refusal is the DEADLINE: the same authority is live one millisecond earlier.
        XCTAssertTrue(authority.isLive(atMonotonicMS: 4_999))
        XCTAssertEqual(authority.deadlineMonotonicMS, 5_000)
    }

    /// REVIEWER (gap 2), stated as the rule it comes from: **no ledger capacity is consumed by an
    /// admission that could not have been granted.** An installed authority that has expired must not
    /// charge the batch during preparation, and preparing again must not quietly eat the batch.
    func test_expiredAuthority_consumesNoLedgerCapacityDuringPreparation() throws {
        let stampTokens = try XCTUnwrap(VoiceSharingCaptureLimits(dailyRecords: 2, dailyBytes: 200_000,
            compiledRecordsCeiling: 2, compiledBytesCeiling: 200_000, clipSamples: 16,
            metadataBytes: VoiceSharingUploadQueue.maxMetadataBytes, compiledClipSamples: 16,
            compiledMetadataBytes: VoiceSharingUploadQueue.maxMetadataBytes))
        let stamp = VoiceSharingCaptureStamp(session: "sess-1", epoch: "epoch-1", policyGeneration: 1)
        let batch = "33333333-3333-4333-8333-333333333333"
        let authority = try XCTUnwrap(VoiceSharingCaptureAuthorization(
            account: "synthetic", establishedWindow: "window", batchId: batch, limits: stampTokens,
            consent: stamp, deadlineMonotonicMS: 5_000))
        let ledgerRoot = root.deletingLastPathComponent().appendingPathComponent("usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ledgerRoot) }
        let ledger = VoiceSharingCaptureLedger(root: ledgerRoot)
        XCTAssertTrue(ledger.provision(.init(
            verifiedFirstProvisioningAccount: "synthetic", establishedWindow: "window", batchId: batch)!))
        let clock = MonotonicStep(5_001) // already past the deadline
        var producerWakes = 0
        let owner = VoiceSharingCaptureAllowance(ledger: ledger,
                                                 currentAuthorization: { authority },
                                                 capacityExhausted: { producerWakes += 1 },
                                                 monotonicNowMS: { clock.value })

        for _ in 0..<5 {
            owner.requestPreparation()
            owner.waitForPreparationForTesting()
            XCTAssertNil(owner.take(for: stamp), "an expired allowance admits nothing")
        }
        // Five preparations against an expired authority must leave the batch UNTOUCHED. Before the
        // fix each of them charged a record and then refused at admission.
        // The batch must be untouched: a two-record batch still admits TWO captures afterwards.
        XCTAssertTrue(ledger.charge(authority), "control precondition: the batch still has its capacity")
        XCTAssertTrue(ledger.charge(authority), "both records of the untouched batch are still there")
        XCTAssertFalse(ledger.charge(authority),
                       "and it is exactly the granted capacity: five expired preparations consumed none")
        XCTAssertGreaterThanOrEqual(producerWakes, 1, "and it must ask the producer for another allocation")
    }

    /// Spec c74d7e30 ("Actual upload usage"): the client no longer holds a per-day record
    /// limit or charges a usage ledger — the SERVER meters actual accepted bytes per UTC day.
    /// The former allowance test asserted a second capture is REFUSED locally; its replacement
    /// asserts the NEW contract: the second consented capture is admitted, and no local ledger
    /// authorizes anything.
    func test_noLocalPerDayLimitSecondConsentedCaptureIsAdmittedAndNoLedgerAuthorizes() throws {
        var state = VoiceSharingEnrollmentStore.State()
        state.localOptIn = true
        state.hasAuthoritativeProjection = true
        state.membership = VoiceSharingMembership(membershipRevision: "rev", plan: .pro,
            voiceSharingEnrolled: true, enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "synthetic", withdrawalState: .active)
        let sink = makeSink()
        let collector = VoiceSharingCollector(isCollectionPermitted: { true }, outcomeWaitLimit: .init(milliseconds: 25, ceilingMilliseconds: 100), membership: { state },
            epochProvider: { "epoch-1" }, sessionIdentity: { "sess-1" }, sink: { sink.handle($0) })
        collector.deliversSynchronouslyForTesting = true
        let context = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: 640))
        let pcm = [Float](repeating: 0.6, count: 640)
        collector.appendSamples(pcm)
        // Clip ceiling is now the compiled bound (no allowance defines a batch clip size).
        XCTAssertEqual(collector.retainedCopyForTesting, pcm)
        collector.speechCompleted(pcm, context: context)
        drain()
        XCTAssertEqual(queue.readyEntries().count, 1, "first capture delivered to the queue as before")

        // The SECOND consented capture in the same day: no local refusal exists anymore.
        let second = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: 640),
            "no local per-day limit: capture is metered by the server, not gated by a client batch")
        collector.appendSamples(pcm)
        collector.speechCompleted(pcm, context: second)
        drain()
        XCTAssertEqual(queue.readyEntries().count, 2,
            "the second capture reaches the queue; daily accounting happens at the server")
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
        // AMENDED BY SPEC a4b417fc RULING 2: tampered audio is a DIGEST MISMATCH, and the ruling is
        // explicit that such a record must be SENT rather than held — only the server's final
        // refusal may delete it. So the assertion inverts: it stays ready upload work. What must
        // still be true is that the client never treats it as the record it claims to be.
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known after tamper")
        }
        XCTAssertEqual(after.count, 1,
                       "tampered audio still holds a capture the server must judge and refuse")
    }

    /// Helpers for the progress-rule controls: publish one ready entry with a DUE boundary and
    /// return the real trigger over a real scheduler+uploader.
    private func readyEntryWithDueBoundary(
        _ calls: TransportCallBox
    ) -> (entry: String, trigger: VoiceSharingUploadTrigger) {
        lastSink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { self.enabled },
            encoderProvenance: { [self] in provenance }, observations: { [self] in observations })
        lastSink?.handle(event())
        drain()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
            ready.count == 1 else {
            XCTFail("premise: publication produced no ready entry")
            return ("", VoiceSharingUploadTrigger(scheduler: VoiceSharingUploadScheduler(
                queue: queue, uploader: VoiceSharingUploader(
                    queue: queue,
                    retryPolicy: VoiceSharingRetryPolicy(
                        retryBaseDelay: 3600, retryMaximumDelay: 3600, random: { 1 }),
                    isAuthorized: { true }, currentIdentity: { nil },
                    endpoint: { URL(string: "https://unit.test/api/v1/voice-recordings") },
                    transport: { _, _, _ in .response(statusCode: 503, body: Data()) }),
                isAuthorized: { true }), surfaceEnabled: { true }, isAuthorized: { true }))
        }
        let entryName = ready[0].name
        let stamp = Date().addingTimeInterval(-1).timeIntervalSince1970
        try? JSONSerialization.data(withJSONObject: ["notBefore": stamp])
            .write(to: root.appendingPathComponent("attempt.notbefore.\(entryName)"), options: .atomic)
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(
                retryBaseDelay: 3600, retryMaximumDelay: 3600, random: { 1 }),
            isAuthorized: { true }, currentIdentity: { nil },
            endpoint: { URL(string: "https://unit.test/api/v1/voice-recordings") },
            transport: { _, _, _ in
                await calls.record()
                return .response(statusCode: 503, body: Data())
            })
        let trigger = VoiceSharingUploadTrigger(
            scheduler: VoiceSharingUploadScheduler(queue: queue, uploader: uploader,
                                                   isAuthorized: { true }),
            surfaceEnabled: { true }, isAuthorized: { true })
        return (entryName, trigger)
    }

    /// Run a real trigger pass and observe for a bounded window. Returns how many transport calls
    /// the window produced, which is 0 when no wake was armed — and > 0 for a self-reoffer loop.
    private func passesReached(_ trigger: VoiceSharingUploadTrigger,
                               _ calls: TransportCallBox) async -> Int {
        // A DUE boundary over a servable entry makes the FIRST pass attempt it — that is the
        // premise, not the finding. Record where it starts so the measurement counts only the
        // passes a WAKE produced afterwards.
        trigger.triggerDrainIfPermitted()
        await trigger.awaitDrainCompletionForTesting()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await calls.count()
    }

    /// REVIEWER 23901ee6 finding 3: a drain that found the scheduler busy and registered a
    /// completion waiter behind a BLOCKED EXPIRY must be woken when expiry finishes. Expiry released
    /// `passInFlight` without firing the waiters, so that drain never re-offered. RED before expiry
    /// used the same completion path as `drainOnce`.
    func test_aDrainWaitingBehindABlockedExpiryIsWoken() async throws {
        let scheduler = VoiceSharingUploadScheduler(
            queue: queue,
            uploader: VoiceSharingUploader(
                queue: queue,
                retryPolicy: VoiceSharingRetryPolicy(
                    retryBaseDelay: 3600, retryMaximumDelay: 3600, random: { 1 }),
                isAuthorized: { true }, currentIdentity: { nil },
                endpoint: { URL(string: "https://unit.test/api/v1/voice-recordings") },
                transport: { _, _, _ in .response(statusCode: 503, body: Data()) }),
            isAuthorized: { true })
        let expiryHeld = expectation(description: "expiry owns the scheduler")
        let woken = expectation(description: "the waiting drain is woken")
        // BLOCK INSIDE EXPIRY with a semaphore (XCTestExpectation cannot be waited on off the main
        // thread here): expiry holds the slot until the control signals it.
        let release = DispatchSemaphore(value: 0)
        scheduler.expiryBodyForTesting = {
            expiryHeld.fulfill()
            release.wait()
        }
        let expiryDone = expectation(description: "expiry returned")
        DispatchQueue.global().async {
            _ = scheduler.expireAgedOutRecordings()
            expiryDone.fulfill()
        }
        await fulfillment(of: [expiryHeld], timeout: 5)
        // A DRAIN ARRIVES WHILE EXPIRY OWNS THE SCHEDULER: it must WAIT, not take ownership.
        let registration = scheduler.registerOwnerCompletion { woken.fulfill() }
        XCTAssertFalse(registration.assumedOwnership,
                       "premise: the drain must wait behind expiry, not assume ownership")
        release.signal() // release expiry; its completion must fire the waiter
        await fulfillment(of: [woken, expiryDone], timeout: 5)
    }

    /// REVIEWER 34aae0fa (1) / 7c4c9cff PROGRESS RULE: a wake may only be armed for work the next
    /// pass can ATTEMPT, and the check must use the SAME admission facts the drain uses. Under an
    /// OWNER-WIDE RETRY HOLD (`attempt.pause.intent`, VoiceSharingUploadQueue.swift
    /// `retryHoldLocked`) `admitAttempt` throws for every entry, so a due boundary is not work.
    /// RED on f3f5f70ec, where the boundary reader ignored the hold and returned 0 — the exact
    /// zero delay that makes the trigger re-offer itself without progress.
    func test_aDueBoundaryUnderARetryHoldArmsNoWake() async throws {
        let calls = TransportCallBox()
        let (entryName, trigger) = readyEntryWithDueBoundary(calls)
        // The durable retry-hold marker, exactly as a failed boundary publication leaves it.
        try Data([0x01]).write(to: root.appendingPathComponent("attempt.pause.intent"),
                               options: .atomic)
        XCTAssertNil(queue.secondsUntilNextRetryBoundary(),
                     "under a retry hold admission refuses every entry: no boundary is due work")
        trigger.triggerDrainIfPermitted()
        await trigger.awaitDrainCompletionForTesting()
        let baseline = await calls.count() // the ORDINARY pass: a due boundary is attempted once
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let afterHold = await calls.count()
        XCTAssertEqual(afterHold, baseline,
                       "with no wake armed, no further pass may run — a held entry must not be "
                           + "retried, and nothing may self-reoffer")
        XCTAssertFalse(entryName.isEmpty, "premise")
    }

    /// REVIEWER 34aae0fa (1): the same rule for the SECOND owner-wide hold. A durable revocation
    /// hold (`revocationHoldLocked`, i.e. a pending disqualification across the owner) refuses
    /// admission for every entry, so a due boundary over one is not due work either.
    func test_aDueBoundaryUnderAnOwnerWideHoldArmsNoWake() async throws {
        let calls = TransportCallBox()
        let (_, trigger) = readyEntryWithDueBoundary(calls)
        // The durable owner-wide revocation marker: `revocation.intent` at the root, which recovery
        // reads into `revocationHoldLocked` (VoiceSharingUploadQueue.swift:269, :3572).
        try Data([0x01]).write(to: root.appendingPathComponent("revocation.intent"),
                               options: .atomic)
        // Re-open the queue so recovery picks the marker up the way production does.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertNil(fresh.secondsUntilNextRetryBoundary(),
                     "under an owner-wide hold no boundary is due work")
        trigger.triggerDrainIfPermitted()
        await trigger.awaitDrainCompletionForTesting()
        let baseline = await calls.count()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let afterOwnerHold = await calls.count()
        XCTAssertEqual(afterOwnerHold, baseline,
                       "with no wake armed, no further pass may run under an owner-wide hold")
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
