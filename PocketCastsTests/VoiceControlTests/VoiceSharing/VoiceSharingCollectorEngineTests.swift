#if canImport(CryptoKit)
import CryptoKit
#endif
import XCTest
@testable import podcasts

/// Drives the REAL `VoiceAsrEngine` → `NativeVadSegmenter` subscription rather than a hand-built segmenter,
/// because the reviewer's condition for production collection was that final proof goes through the production
/// engine path. Everything here is constructed the way `VoiceControlService` constructs it; only the backend,
/// wake detector and audio source are stubs so the test is deterministic without model files.
final class VoiceSharingCollectorEngineTests: XCTestCase {

    private var recordLock = NSLock()
    private var events: [VoiceSharingCollector.SegmentEvent] = []
    private var storeState = VoiceSharingEnrollmentStore.State()
    private var epoch: String? = "epoch-1"
    private var utteranceUnderTest: [Float] = []

    override func setUp() {
        super.setUp()
        events = []
        storeState = VoiceSharingEnrollmentStore.State()
        epoch = "epoch-1"
    }

    private func openGate(enrolled: Bool) -> VoiceSharingPolicy {
        let policy = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { [weak self] in self?.storeState.effectiveEnrolled ?? false }
        )
        storeState.localOptIn = enrolled
        storeState.hasAuthoritativeProjection = enrolled
        if !enrolled { storeState.membership = .unavailable }
        if enrolled {
            storeState.membership = VoiceSharingMembership(
                membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09", withdrawalState: .active
            )
        }
        policy.identityBecameReadable()
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true,
                                                      fetchToken: policy.tokenForFetchStart()),
                        "premise: activation should install a lease")
        return policy
    }

    private func makeCollector(_ policy: VoiceSharingPolicy) -> VoiceSharingCollector {
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { "gen-A" },
            sink: { [weak self] e in self?.record(e) }
        )
        collector.deliversSynchronouslyForTesting = true
        return collector
    }

    /// Engine wired exactly as the service wires it, minus models and the real microphone. The segmenter gets
    /// a short silence timeout because its timeout is measured with `Date()` — production defaults to 500 ms,
    /// and waiting that long per emitted utterance would make the suite slow for no added coverage.
    private func makeEngine(collector: VoiceSharingCollector,
                            wake: WakeWordDetectorProtocol,
                            backend: EngineStubBackend,
                            silenceTimeoutMs: Int = 60) -> VoiceAsrEngine {
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(silenceTimeoutMs: silenceTimeoutMs),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: wake,
            gracePeriodSignal: GracePeriodSignal(),
            translationStage: nil
        )
        engine.contributionCollector = collector
        backend.engine = engine
        return engine
    }

    /// THE scheduling control for the synchronous freeze: utterance A's Task is created but its body is
    /// HELD BACK by a gate; while it is parked, A closes and B opens. When A's body finally runs it must
    /// complete under A's frozen identity — attributed to A, never refused as foreign and never adopted
    /// by B. The freeze happens in `beginUtteranceProcessing` BEFORE Task creation, so holding the body
    /// back cannot change what A carries; a mutant that moves the read inside the body deterministically
    /// picks up B instead.
    func test_queuedUtteranceBodyRunningLate_completesUnderItsOwnFrozenContext() async {
        let policy = openGate(enrolled: true)
        let collector = makeCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)

        // A is the open capture when its utterance processing begins.
        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctxA = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: A open")
        }

        let bodyHeld = DispatchSemaphore(value: 0)
        let releaseBody = DispatchSemaphore(value: 0)
        let task = engine.beginUtteranceProcessing([Float](repeating: 0.01, count: 40 * 16)) {
            bodyHeld.signal()
            releaseBody.wait()
        }

        // The body is parked; meanwhile A's segment closes and B opens. Whatever "current" means now, it
        // is B — A's fate must already have been sealed.
        XCTAssertEqual(bodyHeld.wait(timeout: .now() + 2), .success, "premise: A's body is held")
        collector.segmentationEnded(ctxA)
        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctxB = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: B open")
        }
        XCTAssertNotEqual(ctxA.id, ctxB.id)

        releaseBody.signal()
        _ = await task.value

        let got = snapshot()
        // Wake-negative utterance → A's late body reports rejectedWake. Under A, not under B.
        let aRejects = got.filter { $0.kind == .rejectedWake && $0.captureID == ctxA.id }
        let observed = got.map { "\($0.kind):\($0.captureID)" }
        XCTAssertEqual(aRejects.count, 1,
                       "A's late body completes under A's frozen identity; got \(observed)")
        let bTouchedByA = got.contains { $0.captureID == ctxB.id && $0.kind != .started }
        XCTAssertFalse(bTouchedByA,
                       "B must be untouched by A's late body (B's own .started aside); got \(observed)")
        XCTAssertEqual(collector.currentCaptureContextForTesting?.id, ctxB.id, "B remains open")
    }

    /// Discriminates the freeze mutant AT the production path: the onUtterance closure installed by
    /// engine.start() (not a test-driven beginUtteranceProcessing call). A's body is held by the
    /// engine-level gate while A closes and B opens; the freeze must already have happened synchronously
    /// inside the closure — a mutant that moves the read into the Task body deterministically picks up B.
    func test_startInstalledOnUtteranceClosure_freezesContextSynchronously() async {
        let policy = openGate(enrolled: true)
        let collector = makeCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        XCTAssertTrue(engine.start(), "premise: engine started with stubbed capture")

        let bodyHeld = DispatchSemaphore(value: 0)
        let releaseBody = DispatchSemaphore(value: 0)
        engine.utteranceBodyGateForTesting = {
            bodyHeld.signal()
            releaseBody.wait()
        }

        // Segment A through the REAL capture callback: speech, then enough silence for the 60 ms timeout
        // to emit the utterance through the start()-installed closure.
        backend.emitSpeech(level: 0.6, totalSamples: 5 * 160)
        backend.emitSilence(totalSamples: 20 * 160)
        XCTAssertEqual(bodyHeld.wait(timeout: .now() + 2), .success,
                       "premise: A's Task body is held by the engine gate")
        // The closure already DETACHED A at the synchronous endpoint — read A's identity from the
        // recorded start event instead of the (now nil) current capture.
        let starts = snapshot().filter { $0.kind == .started }
        guard let ctxAID = starts.first?.captureID else {
            releaseBody.signal()
            return XCTFail("premise: A's start recorded")
        }

        // While A's body is parked: B opens. A stays completed-awaiting-outcome.
        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctxB = collector.currentCaptureContextForTesting else {
            releaseBody.signal()
            return XCTFail("premise: B open")
        }
        XCTAssertNotEqual(ctxAID, ctxB.id)

        releaseBody.signal()
        // Wait for A's body to finish reporting.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let kinds = recordedKinds()
            if kinds.contains(.rejectedWake) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        engine.utteranceBodyGateForTesting = nil
        engine.stop()

        let got = snapshot().filter { $0.kind != .started && $0.kind != .cancelled }
        let aRejects = got.filter { $0.kind == .rejectedWake && $0.captureID == ctxAID }
        XCTAssertEqual(aRejects.count, 1,
                       "the start()-installed closure froze A synchronously; A's late body reports under A")
        let bTouched = got.contains { $0.captureID == ctxB.id }
        let observed = got.map { "\($0.kind):\($0.captureID)" }
        XCTAssertFalse(bTouched, "B untouched by A's late body; got \(observed)")
    }

    // MARK: - Production path: start/stop own the subscription

    /// `start()` must attach the three observation hooks to the segmenter the pipeline already drives, and
    /// `stop()` must release any partial it holds. Asserted through the engine's public lifecycle rather than
    /// by poking at the segmenter, which is private.
    func test_engineStartAttachesHooksAndStopReleasesThePartial() {
        let policy = openGate(enrolled: true)
        XCTAssertTrue(policy.permitsCollection, "premise: gate open")
        XCTAssertTrue(storeState.effectiveEnrolled, "premise: membership enrolled")

        let collector = makeCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)

        // Drive frames through the segmenter the same way `capture.onSamples` does in production: the engine
        // installs that closure inside start(), so we invoke whatever it installed.
        XCTAssertTrue(engine.start(), "premise: the engine should start with a stubbed capture")
        backend.emitSpeech(level: 0.6, totalSamples: 5 * 160)

        var kinds = recordedKinds()
        XCTAssertTrue(kinds.contains(.started),
                      "the engine's onSpeechStarted hook must reach the collector; got \(kinds)")
        XCTAssertEqual(collector.currentCaptureIDForTesting != nil, true,
                       "and the collector should hold an open capture while speech continues")

        // Closing listening releases it — through stop(), not a manual cancel.
        engine.stop()
        kinds = recordedKinds()
        XCTAssertEqual(kinds.last, .cancelled, "engine.stop() must cancel the open capture")
        XCTAssertNil(collector.currentCaptureIDForTesting, "and leave nothing dangling across a restart")
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0, "released means the buffer is actually gone")
    }

    /// An idle stop (no speech was ever open) must NOT be reported as a discarded example.
    func test_idleStop_producesNoCancellationEvent() {
        let policy = openGate(enrolled: true)
        let collector = makeCollector(policy)
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: EngineStubBackend())
        XCTAssertTrue(engine.start())

        engine.stop()
        XCTAssertEqual(recordedKinds(), [], "stopping an idle pipeline is not a rejected utterance")
    }

    // MARK: - Rejection branches observed inside the engine

    /// Wake-negative segments are collectable per spec, and observing them must add NO ASR/router/action work.
    /// The proof: recognition still returns at the wake branch, so no transcript reaches the router.
    func test_wakeNegativeBranch_isObserved_andRecognitionPathIsUnchanged() async {
        let policy = openGate(enrolled: true)
        let collector = makeCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)

        var routed: [String] = []
        engine.onRoutingInput = { input, _ in routed.append(input.routerTranscript) }
        XCTAssertTrue(engine.start())

        // Real pipeline: speech, then silence long enough for the segmenter to emit an utterance, which the
        // engine routes into its own wake branch. Nothing here calls processUtterance by hand.
        await backend.emitSpeechThenSilence(level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let kinds = recordedKinds()
        XCTAssertTrue(kinds.contains(.rejectedWake),
                      "wake-negative must be observed as its own decision; got \(kinds)")
        XCTAssertFalse(kinds.contains(.completed), "a wake-rejected segment must never look like a completed one")
        XCTAssertEqual(routed, [], "control: recognizing the rejection added no routing work")
        XCTAssertEqual(backend.transcribeCalls, 0, "and no extra ASR either")
        engine.stop()
    }

    /// Bleed rejection is the other collectable branch. It requires an exposed-speaker route, which the engine
    /// reads from `isExposedSpeakerRoute`; the stub backend sets up the call so the branch is reachable.
    func test_bleedBranch_notifiesWithObservedDecision_whenRouteIsExposed() async {
        let policy = openGate(enrolled: true)
        let collector = makeCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        XCTAssertTrue(engine.start())
        engine.isExposedSpeakerRouteForTesting = true
        // The filter correlates mic against playback and requires a peak at a NON-ZERO lag — identical arrays
        // peak at delay 0, which it treats as "no evidence of echo". So build the mic frame as the playback
        // tail shifted by 8 samples, which is what speaker bleed actually looks like.
        let playback = stride(from: Float(-0.6), through: 0.6, by: 0.001).map { $0 }
        engine.playbackBufferForTesting = playback
        utteranceUnderTest = Array(repeating: 0, count: 8) + playback

        // Open a capture first so the rejection has a frozen identity to attach its decision to — captured
        // SYNCHRONOUSLY, exactly as the production onUtterance closure does before creating its Task.
        backend.emitSpeech(level: 0.6, totalSamples: 5 * 160)
        let frozen = collector.currentCaptureContextForTesting
        await engine.processUtterance(utteranceUnderTest, frozenContext: frozen)

        let kinds = recordedKinds()
        XCTAssertTrue(kinds.contains(.rejectedBleed),
                      "bleed-rejected audio stays collectable and keeps its observed label; got \(kinds)")
        XCTAssertFalse(kinds.contains(.completed))
        XCTAssertEqual(backend.transcribeCalls, 0, "bleed drop still performs no ASR")
        engine.stop()
    }

    /// With the gate closed, the production path must retain nothing at all — including across a full
    /// utterance that runs through both rejection branches.
    func test_closedGate_producesZeroContributionThroughTheRealEngine() async {
        let policy = openGate(enrolled: false)
        XCTAssertFalse(policy.permitsCollection || storeState.effectiveEnrolled,
                       "premise: membership is unknown/off, so the gate is closed")

        let collector = makeCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        XCTAssertTrue(engine.start())

        backend.emitSpeech(level: 0.6, totalSamples: 5 * 160)
        let frozen = collector.currentCaptureContextForTesting
        await engine.processUtterance([Float](repeating: 0.6, count: 40 * 16), frozenContext: frozen)
        engine.stop()

        XCTAssertEqual(recordedKinds(), [], "no contribution work may be produced while the gate is closed")
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0, "and no PCM may be held for it")
    }

    /// Handoff must not run contribution work on the audio thread. A sink that blocks is exactly what a slow
    /// uploader or a stalled queue looks like in production, so this control drives the collector from a
    /// dedicated thread and asserts delivery happened SOMEWHERE ELSE. Without it, an implementation that calls
    /// the sink inline would pass every timing-based check while freezing capture callbacks whenever the
    /// consumer stalls.
    func test_sinkRunsOnADifferentThreadThanTheProducer() {
        let policy = openGate(enrolled: true)
        var deliveredOnMainThread = [Bool]()
        var deliveredFromAudioQueue = [Bool]()
        let lock = NSLock()
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { "gen-A" },
            sink: { _ in
                let rec = Thread.isMainThread
                // Identify the producer thread by a thread dictionary marker set below.
                let fromProducer = (Thread.current.threadDictionary["producer-marker"] as? Bool) == true
                lock.lock(); deliveredOnMainThread.append(rec); deliveredFromAudioQueue.append(fromProducer); lock.unlock()
            }
        )

        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.current.threadDictionary["producer-marker"] = true
            XCTAssertTrue(policy.permitsCollection, "premise: gate open")
            collector.speechStarted(confirmationFrameSamples: 320)
            collector.appendSamples([Float](repeating: 1, count: 640), reportedTotal: 640)
            collector.speechCompleted([Float](repeating: 1, count: 640),
                                      context: collector.currentCaptureContextForTesting)
            // libdispatch pools pthreads: this thread's marker must not leak into a later
            // workQueue hop running on the same pooled pthread.
            Thread.current.threadDictionary.removeObject(forKey: "producer-marker")
            sem.signal()
        }
        XCTAssertEqual(sem.wait(timeout: .now() + 5), .success, "producer should finish")
        // Give the drain hops a chance to land before reading, then confirm the queue emptied.
        XCTAssertTrue(collector.waitForDrain(timeout: 5), "queued events should be delivered")

        lock.lock(); let mainFlags = deliveredOnMainThread; let producerFlags = deliveredFromAudioQueue; lock.unlock()
        XCTAssertFalse(mainFlags.isEmpty, "sink should have been invoked at all")
        XCTAssertFalse(producerFlags.contains(true),
                       "no event may be delivered on the producer thread — that would block capture")
    }

    // MARK: - Helpers

    /// The COMPLETION events (the ones carrying what the engine observed), not the `started` event.
    private func collectedCompletions() -> [VoiceSharingCollector.SegmentEvent] {
        snapshot().filter { $0.kind == .completed }
    }

    private func snapshot() -> [VoiceSharingCollector.SegmentEvent] {
        recordLock.lock(); defer { recordLock.unlock() }
        return events
    }

    private func recordedKinds() -> [VoiceSharingCollector.SignalKind] {
        recordLock.lock(); defer { recordLock.unlock() }
        return events.map(\.kind)
    }

    private func record(_ e: VoiceSharingCollector.SegmentEvent) {
        recordLock.lock(); events.append(e); recordLock.unlock()
    }
}

// MARK: - Stubs

/// Backend stand-in that also gives the test a handle on the engine's capture callback and the bleed verdict,
/// neither of which is otherwise reachable without a real audio session or playback tap.
/// The FULL production chain, at the boundary it actually covers (review 9cf20d7a): real
/// `VoiceAsrEngine` → real segmenter → real collector → the REAL `VoiceSharingContributionSink` → the
/// REAL durable queue. `VoiceSharingCollectorEngineTests` stops at the collector's event callback;
/// `VoiceSharingContributionSinkTests` starts at a hand-built event. This joins them with bounded
/// fixtures instead of microphone capture.
///
/// WHAT THIS DOES NOT PROVE: the stage observation (wake/bleed/asr/…) is supplied by the sink's
/// `observations` closure, i.e. by the TEST — the engine does not produce these claims, so these
/// controls say nothing about observation PROVENANCE from live recognition. They prove the transport
/// from a real engine-produced capture event to a durable record, and that a record the validator
/// refuses never becomes ready. Live observation provenance remains an open gap.
final class VoiceSharingEndToEndEngineToDurableQueueTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingUploadQueue!
    private var storeState = VoiceSharingEnrollmentStore.State()
    /// Events the collector emitted, for the association controls that inspect it directly.
    private var collectedEvents: [VoiceSharingCollector.SegmentEvent] = []
    private let collectedLock = NSLock()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-vs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        storeState = VoiceSharingEnrollmentStore.State()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A collector wired to record what it emits (no sink) — for observation-association controls.
    private func makeRecordingCollector(_ policy: VoiceSharingPolicy) -> VoiceSharingCollector {
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { "epoch-1" },
            sessionIdentity: { "gen-A" },
            sink: { [weak self] event in
                guard let self else { return }
                self.collectedLock.lock()
                self.collectedEvents.append(event)
                self.collectedLock.unlock()
            })
        collector.deliversSynchronouslyForTesting = true
        return collector
    }

    /// The COMPLETION events (the ones carrying what the engine observed), not the `started` event.
    private func collectedCompletions() -> [VoiceSharingCollector.SegmentEvent] {
        snapshot().filter { $0.kind == .completed }
    }

    private func snapshot() -> [VoiceSharingCollector.SegmentEvent] {
        collectedLock.lock(); defer { collectedLock.unlock() }
        return collectedEvents
    }

    private func makeEngine(
        collector: VoiceSharingCollector, wake: WakeWordDetectorProtocol, backend: EngineStubBackend
    ) -> VoiceAsrEngine {
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(silenceTimeoutMs: 60),
            backend: backend, signalFilter: SignalFilter(),
            wakeWordDetector: wake, gracePeriodSignal: GracePeriodSignal(),
            translationStage: nil)
        engine.contributionCollector = collector
        backend.engine = engine
        engine.start()
        return engine
    }

    /// A LATE FINALIZE MAY NOT RESURRECT A DISQUALIFIED CAPTURE (review 859dac4c). Finalize promotes a
    /// terminal capture into a completed record, so it must refuse everything the normal late-outcome path
    /// refuses: a capture whose epoch/session no longer match, and one that can never contribute.
    func test_aLateFinalizeCannotPublishADisqualifiedOrForeignCapture() async throws {
        let policy = openGate(enrolled: true)
        let collector = makeRecordingCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        _ = engine

        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctxA = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: A open")
        }
        collector.segmentationEnded(ctxA)
        collector.speechCompleted([Float](repeating: 0.01, count: 640), context: ctxA,
                                  deferEmission: true)
        XCTAssertFalse(snapshot().contains { (event: VoiceSharingCollector.SegmentEvent) in
            event.captureID == ctxA.id && event.kind == .completed
        }, "premise: A's completion is deferred, not emitted")

        // The gate CLOSES before the engine finalizes (the real withdrawal lever): a capture that was
        // eligible when it was captured must not be published by a finalize that arrives afterwards.
        storeState.localOptIn = false
        collector.finalizeDeferredCompletion(context: ctxA)

        let emitted = snapshot().filter { (event: VoiceSharingCollector.SegmentEvent) in
            event.captureID == ctxA.id && event.kind == .completed
        }
        XCTAssertTrue(emitted.isEmpty,
                      "a capture whose session moved on must not become a completed record on late finalize")
    }

    /// A NAMED CANCELLATION FOR A STALE CAPTURE MUST CONSUME NOTHING (review bb404153). Capture A is
    /// cancelled and its deferred entry consumed; capture B is deferred and live. A second cancellation
    /// still naming A describes a capture that no longer exists — falling back to "most recent" would
    /// consume B, which nobody cancelled.
    func test_aStaleNamedCancellationConsumesNothingEvenWithALiveDeferredSuccessor() async throws {
        let policy = openGate(enrolled: true)
        let collector = makeRecordingCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        _ = engine

        func deferCapture() -> VoiceSharingCollector.CaptureContext? {
            collector.speechStarted(confirmationFrameSamples: 320)
            guard let ctx = collector.currentCaptureContextForTesting else { return nil }
            collector.segmentationEnded(ctx)
            collector.speechCompleted([Float](repeating: 0.01, count: 640), context: ctx,
                                      deferEmission: true)
            return ctx
        }
        guard let ctxA = deferCapture() else { return XCTFail("premise: A") }
        collector.speechCancelled(context: ctxA)          // A consumed
        guard let ctxB = deferCapture() else { return XCTFail("premise: B") }

        collector.speechCancelled(context: ctxA)          // stale: A is gone, B is untouched
        // An UNKNOWN capture id, carrying the live epoch/session so only the identity is wrong.
        collector.speechCancelled(
            context: VoiceSharingCollector.CaptureContext(
                id: UUID(), epoch: ctxB.epoch, session: ctxB.session))

        collector.finalizeDeferredCompletion(context: ctxB)
        let completedIDs = Set(snapshot()
            .filter { (event: VoiceSharingCollector.SegmentEvent) in event.kind == .completed }
            .map(\.captureID))
        XCTAssertEqual(completedIDs, Set([ctxB.id]),
                       "a stale named cancellation must not consume a live capture; "
                           + "completed=\(completedIDs)")
        let cancelledIDs = snapshot()
            .filter { (event: VoiceSharingCollector.SegmentEvent) in event.kind == .cancelled }
            .map(\.captureID)
        XCTAssertFalse(cancelledIDs.contains(ctxB.id),
                       "B was never cancelled; cancelled=\(cancelledIDs)")
    }

    /// A-DEFERRED / B-OPEN (review d3c39ae5). A completed with deferred emission, then B started. A
    /// cancellation now belongs to B — it is the capture that is still open. Consuming A instead would
    /// discard a finished capture that was never cancelled and leave B live and filable.
    func test_aCancellationWhileASuccessorIsOpenConsumesTheSuccessorNotTheDeferredPredecessor() async throws {
        let policy = openGate(enrolled: true)
        let collector = makeRecordingCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        _ = engine

        // A: starts, closes, completion deferred.
        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctxA = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: A open")
        }
        collector.segmentationEnded(ctxA)
        collector.speechCompleted([Float](repeating: 0.01, count: 640), context: ctxA,
                                  deferEmission: true)
        // B: starts and is still open when the cancellation arrives.
        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctxB = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: B open")
        }
        XCTAssertNotEqual(ctxA.id, ctxB.id)

        collector.speechCancelled()

        // A must survive the cancel and publish when the engine finalizes it.
        collector.finalizeDeferredCompletion(context: ctxA)
        let completedIDs = Set(snapshot()
            .filter { (event: VoiceSharingCollector.SegmentEvent) in event.kind == .completed }
            .map(\.captureID))
        XCTAssertEqual(completedIDs, Set([ctxA.id]),
                       "the deferred predecessor was never cancelled and must still publish; "
                           + "completed=\(completedIDs)")
        // And B is the capture that was cancelled.
        let cancelledIDs = Set(snapshot()
            .filter { (event: VoiceSharingCollector.SegmentEvent) in event.kind == .cancelled }
            .map(\.captureID))
        XCTAssertEqual(cancelledIDs, Set([ctxB.id]),
                       "the OPEN capture is the owner of the cancellation; cancelled=\(cancelledIDs)")
    }

    /// CANCELLATION MUST BIND THE INTENDED CAPTURE, NEVER DICTIONARY ORDER (review 15900665). The ring is
    /// UUID-keyed, so a hash-order lookup satisfies any SINGLE arrangement by luck — proved by mutation,
    /// where the same control passed 3 runs in 5. The binding is therefore asserted from both sides in one
    /// run: the named capture must be consumed AND every other deferred capture must remain publishable.
    func test_aNamedCancelBindsItsOwnCaptureAndLeavesTheOthersPublishable() async throws {
        // DETERMINISTIC BY CONSTRUCTION, not by repetition (spec 85cec5b7, reviewer 15900665). The old
        // version ran 12 independent trials because a hash-ordered implementation could pass one
        // arrangement by luck. Repeating a scenario whose ORDER is fixed only lowers the odds — it does
        // not remove the randomness. So this control instead fixes the arrangement that EXPOSES binding:
        // the named capture is never the most recent deferred entry (a fourth is deferred after it), so
        // a recency-fallback implementation must miss, not pass by coincidence. Cancelling by name at
        // every position in the finalize sequence covers when the cancel lands.
        let orderings: [(label: String, cancelAt: Int)] = [
            ("cancel first", 0),
            ("cancel in the middle", 1),
            ("cancel last", 2),
        ]

        for ordering in orderings {
            let policy = openGate(enrolled: true)
            let collector = makeRecordingCollector(policy)
            let backend = EngineStubBackend()
            let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
            _ = engine

            func deferCapture() -> VoiceSharingCollector.CaptureContext? {
                collector.speechStarted(confirmationFrameSamples: 320)
                guard let ctx = collector.currentCaptureContextForTesting else { return nil }
                collector.segmentationEnded(ctx)
                collector.speechCompleted([Float](repeating: 0.01, count: 640), context: ctx,
                                          deferEmission: true)
                return ctx
            }
            guard let first = deferCapture(), let target = deferCapture(),
                let third = deferCapture(), let latest = deferCapture() else {
                return XCTFail("premise: four deferred captures")
            }
            let survivors = [first, third, latest]
            XCTAssertEqual(Set((survivors + [target]).map(\.id)).count, 4,
                           "distinct captures")

            // Cancel `target` BY NAME at the chosen point. It is never the most recent deferred entry
            // (`latest` always is), so a recency-fallback implementation consumes the WRONG capture.
            var steps: [() -> Void] = survivors.map { ctx in
                { collector.finalizeDeferredCompletion(context: ctx) }
            }
            steps.insert({ collector.speechCancelled(context: target) }, at: ordering.cancelAt)
            for step in steps { step() }

            let completedIDs = Set(snapshot()
                .filter { (event: VoiceSharingCollector.SegmentEvent) in event.kind == .completed }
                .map(\.captureID))
            XCTAssertEqual(completedIDs, Set(survivors.map(\.id)),
                           "the named cancel must consume exactly its own capture; "
                               + "completed=\(completedIDs.sorted())")
            XCTAssertFalse(completedIDs.contains(target.id),
                           "the cancelled capture must never publish")
            collectedLock.lock(); collectedEvents = []; collectedLock.unlock()
        }
    }

    /// A CANCELLED CAPTURE CANNOT BE REVIVED BY A LATE FINALIZE (review 859dac4c). The capture is deferred
    /// first, so it is genuinely ring-resident, and the cancel arrives while the engine still owes its
    /// finalize. The entry must be consumed, not promoted to a completed record.
    func test_aCancelledDeferredCaptureCannotBeRevivedByFinalize() async throws {
        let policy = openGate(enrolled: true)
        let collector = makeRecordingCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        _ = engine

        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctx = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: open")
        }
        collector.segmentationEnded(ctx)
        collector.speechCompleted([Float](repeating: 0.01, count: 640), context: ctx,
                                  deferEmission: true)
        // The withdrawal/cancel path consumes the deferred capture as a non-contribution.
        collector.speechCancelled()
        collector.finalizeDeferredCompletion(context: ctx)

        let completed = snapshot().filter { (event: VoiceSharingCollector.SegmentEvent) in
            event.captureID == ctx.id && event.kind == .completed
        }
        XCTAssertTrue(completed.isEmpty,
                      "a consumed (cancelled) deferred capture must never become a completed record")
    }

    private func openGate(enrolled: Bool) -> VoiceSharingPolicy {
        let policy = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { [weak self] in self?.storeState.effectiveEnrolled ?? false })
        storeState.localOptIn = enrolled
        storeState.hasAuthoritativeProjection = enrolled
        if !enrolled { storeState.membership = .unavailable }
        if enrolled {
            storeState.membership = VoiceSharingMembership(
                membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09",
                withdrawalState: .active)
        }
        policy.identityBecameReadable()
        _ = policy.refreshAfterActivation(
            freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart())
        return policy
    }

    private var provenance: VoiceSharingContributionEncoder.Provenance {
        .init(
            platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "gen-A",
            models: .init(
                vad: .init(id: "vad-1", version: "1"), wakeword: .init(id: "wake-1", version: "1"),
                asr: .init(id: "asr-1", version: "1"), translation: nil,
                router: .init(id: "router-1", version: "1")),
            conversionVersion: "v1")
    }

    /// Claims with an explicitly UNOBSERVED ASR stage, so the delta-736d3180 pair is what reaches the
    /// queue at the end of the real pipeline.
    private var claims: [String: VoiceSharingContributionEncoder.StageOutcome] {
        [
            "wake": .init(state: "completed"),
            "bleed": .init(state: "not_run", reason: "no_playback_reference"),
            "asr": .init(state: "unknown", reason: "observation_unavailable"),
            "translation": .init(state: "not_run", reason: "no_text"),
            "routing": .init(state: "not_run", reason: "no_candidates"),
            "execution": .init(state: "not_run", reason: "client_refused"),
        ]
    }

    /// ENGINE DETECTOR ERROR → DURABLE RECORD (spec 9578b16, reviewer 6c3fed9b). The detector reports a
    /// real failure; that outcome must reach a READY durable record as the exact wake+failed/detector_error
    /// pairing. Before the pairing rule existed the binding refused this and the record never existed —
    /// a real engine failure was silently unpublishable.
    func test_theRealEnginePipelinePublishesADetectorErrorAsWakeFailed() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
        let chain = makeChain(policy: openGate(enrolled: true), wake: ErroringWake(), claims: { claims })
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let ready = waitForReadyEntries(1)
        XCTAssertGreaterThanOrEqual(ready.count, 1,
                                    "a detector failure must still produce a durable record")
        guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        var carried = false
        for entry in entries {
            let metadataURL = entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            let wake = ((envelope?["record"] as? [String: Any])?["observations"]
                as? [String: Any])?["wake"] as? [String: Any]
            if wake?["state"] as? String == "failed" {
                XCTAssertEqual(wake?["reason"] as? String, "detector_error",
                               "a real detector failure is preserved as itself, not as unknown")
                carried = true
                break
            }
        }
        XCTAssertTrue(carried, "no durable record carried the detector's failure")
    }

    /// NORMAL ASR → DURABLE RECORD (review 6fe6d773). A SUCCESSFUL recognition must be publishable: the
    /// stored record must carry the transcript the recogniser actually returned. Reporting `completed`
    /// with no text made the sink overwrite the caller's text and the binding refuse it, so a successful
    /// capture produced no record at all.
    func test_aSuccessfulRecognitionPublishesItsTranscriptIntoTheDurableRecord() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
        let chain = makeChain(policy: openGate(enrolled: true), wake: DetectedWake(), claims: { claims })
        chain.backend.stubTranscript = "play the latest episode"
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = waitForReadyEntries(1)

        guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage(),
            !entries.isEmpty else {
            return XCTFail("a successful recognition must produce a durable record")
        }
        var transcripts: [String] = []
        for entry in entries {
            let metadataURL = entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            let asr = ((envelope?["record"] as? [String: Any])?["observations"]
                as? [String: Any])?["asr"] as? [String: Any]
            guard asr?["state"] as? String == "completed" else { continue }
            if let text = asr?["text"] as? String { transcripts.append(text) }
        }
        XCTAssertTrue(transcripts.contains("play the latest episode"),
                      "the record must carry the recogniser's own transcript; got \(transcripts) "
                          + "(transcribe calls: \(chain.backend.transcribeCalls), "
                          + "entries: \(entries.count))")
    }

    /// THE EMITTED BYTES, not the builder (spec c6f3bdf7): an empty recognition must reach the durable
    /// record as asr/completed/empty_result with neither text nor router_input present.
    func test_anEmptyRecognitionReachesTheDurableRecordAsCompletedEmptyResult() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
        let chain = makeChain(policy: openGate(enrolled: true), wake: DetectedWake(), claims: { claims })
        chain.backend.stubTranscript = ""
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = waitForReadyEntries(1)

        guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage(),
            !entries.isEmpty else { return XCTFail("a durable record is required") }
        var sawEmptyResult = false
        for entry in entries {
            let metadataURL = entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            guard let asr = ((envelope?["record"] as? [String: Any])?["observations"]
                as? [String: Any])?["asr"] as? [String: Any] else {
                XCTFail("entry \(entry.name) has no asr stage; transcribeCalls=\(chain.backend.transcribeCalls)")
                continue
            }
            guard asr["reason"] as? String == "empty_result" else { continue }
            XCTAssertEqual(asr["state"] as? String, "completed")
            XCTAssertNil(asr["text"], "an empty result carries no transcript")
            XCTAssertFalse(asr.keys.contains("router_input"),
                           "no router input can exist for a capture that produced no text")
            sawEmptyResult = true
        }
        XCTAssertTrue(sawEmptyResult, "the emitted record must carry the asr stage")
    }

    /// PRODUCER BINDING (spec 78480a17): asr `source_language` and `router_input` are stated by the
    /// RECOGNISER at its own report site — the language it detected, and the exact text handed onward
    /// as the command input. Asserted on the DURABLE record through the real engine path.
    func test_theRecogniserStatesItsLanguageAndRouterInputOnTheDurableRecord() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-vs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let localClaims = claims
        let chain = makeChain(policy: openGate(enrolled: true), wake: DetectedWake(), claims: { localClaims })
        chain.backend.stubTranscript = "play the latest episode"
        chain.backend.stubLanguage = "en"
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = waitForReadyEntries(1)

        guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage(),
            !entries.isEmpty else { return XCTFail("a record is required") }
        var asr: [String: Any]?
        for entry in entries {
            let metadataURL = entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            if let stage = ((envelope?["record"] as? [String: Any])?["observations"]
                as? [String: Any])?["asr"] as? [String: Any] {
                asr = stage
            }
        }
        guard let asr else { return XCTFail("the record must state the asr stage") }
        XCTAssertEqual(asr["state"] as? String, "completed")
        XCTAssertEqual(asr["source_language"] as? String, "en",
                       "the recogniser's own language fact must reach the record")
        let routerInput = try XCTUnwrap(asr["router_input"] as? String,
                                        "router_input must be present, not absent")
        XCTAssertEqual(routerInput, "play the latest episode",
                       "router_input is the exact text handed onward as the command input")
    }

    /// REVIEW 5f42fb0c: same-stage re-reports must NOT carry a generic merge across state changes —
    /// a completed report must not inherit a previous reason, an empty_result must not inherit
    /// previous text/router_input, and ONLY routing's classification facts survive to settlement.
    /// Each case binds the ENCODED record, so a contradiction is a schema refusal, not just a
    /// dictionary mismatch.
    func test_sameStageReReportsCarryOnlyIntendedFactsAcrossTransitions() throws {
        let policy = openGate(enrolled: true)
        let collector = makeRecordingCollector(policy)
        func makeCase() -> VoiceSharingCollector.CaptureContext {
            collector.speechStarted(confirmationFrameSamples: 320)
            guard let ctx = collector.currentCaptureContextForTesting else {
                fatalError("premise: an open capture")
            }
            return ctx
        }
        func encodedObservations(_ ctx: VoiceSharingCollector.CaptureContext) throws
            -> [String: Any] {
            collector.segmentationEnded(ctx)
            collector.speechCompleted([Float](repeating: 0.01, count: 640), context: ctx)
            let completed = collectedEvents.first {
                $0.captureID == ctx.id && $0.kind == .completed
            }
            let provenance = VoiceSharingContributionEncoder.Provenance(
                platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
                models: VoiceSharingContributionEncoder.Models(
                    vad: .init(id: "vad-1", version: "1"),
                    wakeword: .init(id: "wake-1", version: "1"),
                    asr: .init(id: "asr-1", version: "1"), translation: nil,
                    router: .init(id: "router-1", version: "1")),
                conversionVersion: "v1")
            let encoded = try VoiceSharingContributionEncoder.encode(
                event: completed!, provenance: provenance,
                observations: completed!.reportedStages)
            let envelope = try JSONSerialization.jsonObject(
                with: encoded.metadataEnvelope, options: []) as? [String: Any]
            _ = try VoiceSharingRecordBinding.bind(
                envelope: encoded.metadataEnvelope, audio: encoded.wav)
            return ((envelope!["record"] as! [String: Any])["observations"] as! [String: Any])
        }

        do { // failed → completed: the failure reason must NOT leak into the success.
            let ctx = makeCase()
            collector.engineReported(stage: "asr",
                outcome: .init(state: "failed", reason: "provider_error"), context: ctx)
            collector.engineReported(stage: "asr",
                outcome: .init(state: "completed", text: "pause",
                               sourceLanguage: "en", routerInput: "pause"), context: ctx)
            let asr = try encodedObservations(ctx)["asr"] as! [String: Any]
            XCTAssertNil(asr["reason"], "a completed stage must not inherit a failed report's reason")
            XCTAssertEqual(asr["text"] as? String, "pause")
        }
        collectedEvents.removeAll()

        do { // completed-with-text → empty_result: text/router_input must NOT leak (the binding
             // refuses a carrying empty_result, which is exactly why inheritance is dangerous).
            let ctx = makeCase()
            collector.engineReported(stage: "asr",
                outcome: .init(state: "completed", text: "pause",
                               sourceLanguage: "en", routerInput: "pause"), context: ctx)
            collector.engineReported(stage: "asr",
                outcome: .init(state: "completed",
                               reason: VoiceSharingRecordBinding.emptyResultReasonForEngine),
                context: ctx)
            let asr = try encodedObservations(ctx)["asr"] as! [String: Any]
            XCTAssertNil(asr["text"], "empty_result must not inherit previous text")
            XCTAssertNil(asr["router_input"], "empty_result must not inherit previous router_input")
            XCTAssertEqual(asr["reason"] as? String,
                           VoiceSharingRecordBinding.emptyResultReasonForEngine)
        }
        collectedEvents.removeAll()

        do { // classification → settlement: ONLY the classification facts survive, and the
             // disposition reaches its terminal value.
            let ctx = makeCase()
            collector.engineReported(stage: "routing",
                outcome: .init(state: "completed", routingDisposition: "pending",
                               predictedIntent: "playback.pause", predictedTool: "playback"),
                context: ctx)
            collector.engineReported(stage: "routing",
                outcome: .init(state: "completed", routingDisposition: "executed"), context: ctx)
            let routing = try encodedObservations(ctx)["routing"] as! [String: Any]
            XCTAssertEqual(routing["execution_disposition"] as? String, "executed")
            XCTAssertEqual(routing["predicted_intent"] as? String, "playback.pause")
            XCTAssertEqual(routing["predicted_tool"] as? String, "playback")
            XCTAssertNil(routing["reason"])
        }
        collectedEvents.removeAll()

        // A FAILED settlement is still about the classified action (the GG binding asserts a failed
        // turn names its classification), so the names carry; a NOT_RUN settlement means the router
        // declined — carrying names would invent a classification that never happened.
        do {
            let ctx = makeCase()
            collector.engineReported(stage: "routing",
                outcome: .init(state: "completed", routingDisposition: "pending",
                               predictedIntent: "playback.pause", predictedTool: "playback"),
                context: ctx)
            collector.engineReported(stage: "routing",
                outcome: .init(state: "failed", reason: "no_candidates",
                               routingDisposition: "failed"), context: ctx)
            let routing = try encodedObservations(ctx)["routing"] as! [String: Any]
            XCTAssertEqual(routing["execution_disposition"] as? String, "failed")
            XCTAssertEqual(routing["predicted_intent"] as? String, "playback.pause",
                           "a failed settlement is about the classified action: names carry")
            XCTAssertEqual(routing["predicted_tool"] as? String, "playback")
            XCTAssertEqual(routing["reason"] as? String, "no_candidates")
        }
        collectedEvents.removeAll()
        do {
            let ctx = makeCase()
            collector.engineReported(stage: "routing",
                outcome: .init(state: "completed", routingDisposition: "pending",
                               predictedIntent: "playback.pause", predictedTool: "playback"),
                context: ctx)
            collector.engineReported(stage: "routing",
                outcome: .init(state: "not_run", reason: "low_confidence",
                               routingDisposition: "not_run"), context: ctx)
            let routing = try encodedObservations(ctx)["routing"] as! [String: Any]
            XCTAssertEqual(routing["execution_disposition"] as? String, "not_run")
            XCTAssertNil(routing["predicted_intent"],
                         "a not_run settlement must not carry classification intent")
            XCTAssertNil(routing["predicted_tool"],
                         "a not_run settlement must not carry classification tool")
            XCTAssertEqual(routing["reason"] as? String, "low_confidence")
        }
    }

    /// THE THREE TRANSLATION SKIPS ARE DISTINCT FACTS (spec delta 4d10275f). Collapsing them into
    /// `observation_unavailable` threw away what the engine actually knew. Each must reach the durable
    /// record under its own reason, and none may borrow `source_language_target_language`.
    func test_eachTranslationSkipReachesTheDurableRecordUnderItsOwnReason() async throws {
        let cases: [(label: String, language: String?, expected: String)] = [
            ("no detected language", nil, "source_language_unavailable"),
            ("backend handles translation", "fr", "backend_handles_translation"),
            ("no translator stage", "de", "translator_unavailable"),
        ]
        for testCase in cases {
            // Fresh storage per case so each sees only its own record.
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("e2e-vs-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
            let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
            let chain = makeChain(policy: openGate(enrolled: true), wake: DetectedWake(), claims: { claims })
            chain.backend.stubTranscript = "bonjour"
            chain.backend.stubLanguage = testCase.language
            // The backend only claims it translates for the middle case.
            chain.backend.stubCanTranslate = testCase.label == "backend handles translation"
            chain.engine.listeningMode = .continuous
            await chain.backend.emitSpeechThenSilence(
                level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
            _ = waitForReadyEntries(1)

            guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage(),
                !entries.isEmpty else { return XCTFail("\(testCase.label): a record is required") }
            var found: [String: Any]?
            for entry in entries {
                let metadataURL = entry.root.appendingPathComponent(entry.name)
                    .appendingPathComponent("metadata.json")
                let envelope = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
                if let translation = ((envelope?["record"] as? [String: Any])?["observations"]
                    as? [String: Any])?["translation"] as? [String: Any] {
                    found = translation
                }
            }
            guard let translation = found else {
                return XCTFail("\(testCase.label): the record must state the translation stage")
            }
            XCTAssertEqual(translation["state"] as? String, "not_run",
                           "\(testCase.label): a skip is not_run")
            XCTAssertEqual(translation["reason"] as? String, testCase.expected,
                           "\(testCase.label): the skip must keep its own reason")
            XCTAssertNotEqual(translation["reason"] as? String, "source_language_target_language",
                              "\(testCase.label): a skip must not assert source equals target")
        }
    }

    /// ROUTING AND EXECUTION OBSERVATIONS BIND AND ATTRIBUTE (the two stages that were caller-supplied).
    ///
    /// SCOPE, STATED PLAINLY: this drives the COLLECTOR with the same StageOutcome payloads the service now
    /// reports from its decision sites, and asserts they reach the durable record and displace a caller's
    /// unknown claim. It does NOT prove `handleRoutingInput` reaches each branch — that path needs the LFM
    /// router model, which this suite does not load. Do not read it as branch coverage.
    func test_routingAndExecutionObservationsBindAndAttributeToTheirCapture() async throws {
        let cases: [(label: String, routing: VoiceSharingContributionEncoder.StageOutcome)] = [
            ("intent selected", .init(state: "completed", routingDisposition: "pending")),
            ("no intent", .init(state: "completed", routingDisposition: "not_run")),
            ("dialog question", .init(state: "completed", routingDisposition: "pending")),
            ("not routed", .init(state: "not_run", reason: "no_candidates")),
        ]
        for testCase in cases {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("e2e-vs-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
            let unknownClaims: [String: VoiceSharingContributionEncoder.StageOutcome] = [
                "wake": .init(state: "completed"),
                "bleed": .init(state: "unknown", reason: "observation_unavailable"),
                "asr": .init(state: "completed", text: "play the latest episode"),
                "translation": .init(state: "unknown", reason: "observation_unavailable"),
                "routing": .init(state: "unknown", reason: "observation_unavailable"),
                "execution": .init(state: "unknown", reason: "observation_unavailable"),
            ]
            // Wake POSITIVE: with a negative wake the engine strips the wake window, the remaining text is
            // empty, and it returns before routing ever runs — so routing could not be observed at all.
            let chain = makeChain(policy: openGate(enrolled: true), wake: DetectedWake(),
                                  claims: { unknownClaims })
            chain.engine.listeningMode = .continuous
            // Stand where the SERVICE stands. The engine hands the frozen context to the routing
            // consumer and does NOT finalize; the consumer reports routing, then finalizes — so the
            // record still exists when the observation arrives. The consumer runs on the engine's own
            // task, so the test records the context there and finalizes through the same collector.
            var decisionContext: VoiceSharingCollector.CaptureContext?
            chain.engine.onRoutingInput = { _, context in
                decisionContext = context
                chain.engine.contributionCollector?.engineReported(
                    stage: "routing", outcome: testCase.routing, context: context)
                chain.engine.contributionCollector?.finalizeDeferredCompletion(context: context)
            }
            chain.backend.stubTranscript = "play the latest episode"
            await chain.backend.emitSpeechThenSilence(
                level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
            // The consumer runs synchronously inside the engine's outcome task; wait for it.
            let deadline = Date().addingTimeInterval(5)
            while decisionContext == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard decisionContext != nil else {
                return XCTFail("\(testCase.label): routing must receive the frozen capture")
            }
            _ = waitForReadyEntries(1)

            guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage(),
                !entries.isEmpty else { return XCTFail("\(testCase.label): a record is required") }
            var sawRouting = false
            for entry in entries {
                let metadataURL = entry.root.appendingPathComponent(entry.name)
                    .appendingPathComponent("metadata.json")
                guard let envelope = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: metadataURL), options: []) as? [String: Any],
                    let observations = (envelope["record"] as? [String: Any])?["observations"]
                        as? [String: Any],
                    let routing = observations["routing"] as? [String: Any],
                    routing["state"] as? String != "unknown" else { continue }
                sawRouting = true
                XCTAssertEqual(routing["state"] as? String, testCase.routing.state,
                               "\(testCase.label): the observed routing state must replace the claim")
                XCTAssertEqual(routing["execution_disposition"] as? String,
                               testCase.routing.routingDisposition,
                               "\(testCase.label): the router's own verdict must survive")
            }
            if !sawRouting {
                let dump = entries.compactMap { entry -> String? in
                    let u = entry.root.appendingPathComponent(entry.name).appendingPathComponent("metadata.json")
                    guard let e = try? JSONSerialization.jsonObject(with: Data(contentsOf: u), options: []) as? [String: Any],
                        let o = (e["record"] as? [String: Any])?["observations"] as? [String: Any] else { return nil }
                    return o.map { "\($0.key)=\((($0.value as? [String: Any])?["state"] as? String) ?? "?")/\((($0.value as? [String: Any])?["decision"] as? String) ?? "-")" }.sorted().joined(separator: " ")
                }
                XCTFail("\(testCase.label): routing must be observed; records=\(dump)")
            }
        }
    }

    /// COLLECTOR-LEVEL PROBE: an engine report made while the capture is open must ride the event that
    /// the DEFERRED finalize emits. This isolates the merge from the engine and the sink.
    func test_anEngineReportMadeWhileOpenRidesTheDeferredCompletionEvent() async {
        let policy = openGate(enrolled: true)
        let collector = makeRecordingCollector(policy)
        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctx = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: open capture")
        }
        collector.engineReported(
            stage: "wake",
            outcome: .init(state: "completed", reason: nil, decision: "no_wake_detected"),
            context: ctx)
        collector.segmentationEnded(ctx)
        collector.speechCompleted([Float](repeating: 0.01, count: 640), context: ctx,
                                  deferEmission: true)
        collector.finalizeDeferredCompletion(context: ctx)
        let events = snapshot()
        guard let completed = events.first(where: { $0.kind == .completed }) else {
            return XCTFail("premise: a completed event; got \(events.map(\.kind))")
        }
        let wake = completed.reportedStages["wake"]
        XCTAssertEqual(wake?.state, "completed", "the open-capture report must ride the event")
        XCTAssertEqual(wake?.decision, "no_wake_detected")
        XCTAssertNil(wake?.reason, "a completed stage carries no reason")
    }

    /// AN OBSERVED NEGATIVE WAKE MUST NOT BE LOST (spec 94073918). Sink merge must not let a caller's
    /// unknown claim displace the engine's real `completed` wake, and validation must not relabel the
    /// observed no-wake decision — the negative stays in the decision field while the reason is omitted.
    func test_anObservedNegativeWakeReachesTheDurableRecordAsCompletedWithItsDecision() async throws {
        // The caller claims NOTHING is known about wake; the detector really ran and found no wake.
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = [
            "wake": .init(state: "unknown", reason: "observation_unavailable"),
            "bleed": .init(state: "unknown", reason: "observation_unavailable"),
            "asr": .init(state: "unknown", reason: "observation_unavailable"),
            "translation": .init(state: "unknown", reason: "observation_unavailable"),
            "routing": .init(state: "unknown", reason: "observation_unavailable"),
            "execution": .init(state: "unknown", reason: "observation_unavailable"),
        ]
        let chain = makeChain(policy: openGate(enrolled: true), wake: NotDetectedWake(), claims: { claims })
        chain.backend.stubTranscript = "play the latest episode"
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = waitForReadyEntries(1)

        guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage(),
            !entries.isEmpty else { return XCTFail("an observed negative wake must still publish a record") }
        // A capture produces TWO records by design: a `started` event at segment start, before any engine
        // observation exists, and the completion carrying what the engine actually decided. The COMPLETION
        // is what must state the observed negative; asserting the started record would demand that a
        // pre-observation publish know the future.
        var completionBlocks: [[String: Any]] = []
        for entry in entries {
            let metadataURL = entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            guard let record = envelope?["record"] as? [String: Any],
                let wake = (record["observations"] as? [String: Any])?["wake"] as? [String: Any]
            else { continue }
            // Only the completed capture states an observed wake; the started record still says unknown.
            if wake["state"] as? String == "completed" { completionBlocks.append(wake) }
        }
        guard let wake = completionBlocks.first else {
            return XCTFail("no completion stated the observed wake; " + diagnostic(entries, chain))
        }
        XCTAssertEqual(wake["state"] as? String, "completed",
                       "the engine's observed wake outcome must replace the caller's unknown claim")
        XCTAssertEqual(wake["decision"] as? String, "no_wake_detected",
                       "the OBSERVED negative decision must survive validation, not be relabelled")
        XCTAssertNil(wake["reason"],
                     "a completed stage carries no reason; the negative lives in decision")
    }

    /// THE PERSISTED ENVELOPE, WITH A RECOMPUTED DIGEST (review 2f8e5d90). Validating an observations
    /// dictionary proves the observation rule; it does not prove a REAL record carrying the contradiction
    /// is refused when it comes back through `bind`. Each envelope is re-sealed with the PRODUCTION
    /// canonicalizer, so the refusal cannot be a stale-digest artifact.
    func test_aPersistedEnvelopeCarryingANullEmptyResultFieldIsRefusedForThatReason() throws {
        let observations: [String: VoiceSharingContributionEncoder.StageOutcome] = [
            "wake": .init(state: "completed"),
            "bleed": .init(state: "unknown", reason: "observation_unavailable"),
            "asr": .init(state: "completed", reason: "empty_result"),
            "translation": .init(state: "unknown", reason: "observation_unavailable"),
            "routing": .init(state: "unknown", reason: "observation_unavailable"),
            "execution": .init(state: "unknown", reason: "observation_unavailable"),
        ]
        let encoded = try encodeEmptyResultRecord()
        let base = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded.recordJSON) as? [String: Any])

        func refuse(_ label: String, text: Any?, routerInput: Any?, mentioning fragment: String) throws {
            var object = base
            var block = try XCTUnwrap((object["observations"] as? [String: Any])?["asr"] as? [String: Any])
            if let text { block["text"] = text }
            if let routerInput { block["router_input"] = routerInput }
            var all = try XCTUnwrap(object["observations"] as? [String: Any])
            all["asr"] = block
            object["observations"] = all
            let sealed = try rescaled(object)
            do {
                _ = try VoiceSharingRecordBinding.bind(envelope: sealed, audio: encoded.wav)
                XCTFail("\(label): expected refusal")
            } catch let error as VoiceSharingRecordBinding.BindingError {
                guard case .invalidField(let path, let message) = error else {
                    return XCTFail("\(label): expected invalidField, got \(error)")
                }
                XCTAssertTrue(path.hasPrefix("observations.asr"),
                              "\(label): refusal must be about the asr stage; got \(path)")
                XCTAssertTrue((path + message).localizedCaseInsensitiveContains(fragment),
                              "\(label): cause must be named (\(fragment)); got \(path): \(message)")
            }
        }
        try refuse("text null", text: NSNull(), routerInput: nil, mentioning: "text")
        try refuse("router_input null", text: nil, routerInput: NSNull(), mentioning: "router_input")
    }

    /// A real encoder fixture whose ASR stage is completed/empty_result — the one legal completed reason.
    private func encodeEmptyResultRecord() throws -> VoiceSharingContributionEncoder.Encoded {
        let observations: [String: VoiceSharingContributionEncoder.StageOutcome] = [
            "wake": .init(state: "completed"),
            "bleed": .init(state: "unknown", reason: "observation_unavailable"),
            "asr": .init(state: "completed", reason: "empty_result"),
            "translation": .init(state: "unknown", reason: "observation_unavailable"),
            "routing": .init(state: "unknown", reason: "observation_unavailable"),
            "execution": .init(state: "unknown", reason: "observation_unavailable"),
        ]
        let samples = (0..<16_000).map { Float(sin(Double($0) * 0.01)) * 0.4 }
        let event = VoiceSharingCollector.SegmentEvent(
            kind: .completed,
            captureID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: samples, isGateControl: false)
        let provenance = VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
            models: VoiceSharingContributionEncoder.Models(
                vad: .init(id: "vad-1", version: "1"), wakeword: .init(id: "wake-1", version: "1"),
                asr: .init(id: "asr-1", version: "1"), translation: nil,
                router: .init(id: "router-1", version: "1")),
            conversionVersion: "v1")
        return try VoiceSharingContributionEncoder.encode(
            event: event, provenance: provenance, observations: observations)
    }

    /// The RECORD object of that fixture, for mutation.
    private func encodedRecordWithEmptyResult() throws -> [String: Any] {
        let encoded = try encodeEmptyResultRecord()
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded.recordJSON) as? [String: Any])
    }

    /// Re-seals with the PRODUCTION canonicalizer so the digest binds the mutated bytes.
    private func rescaled(_ record: [String: Any]) throws -> Data {
        var digest = ""
        #if canImport(CryptoKit)
        digest = SHA256.hash(data: try VoiceSharingRecordBinding.canonicalizeForTesting(record))
            .map { String(format: "%02x", $0) }.joined()
        #endif
        let envelope: [String: Any] = ["record": record, "record_sha256": digest]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    /// FINDING a7dfe013 #3: the capture handed to the routing consumer must always be RELEASED, or it
    /// stays ring-resident forever and never publishes. Drives the REAL engine: the consumer reports
    /// (or a stopped turn cancels) and releases. Asserts a COMPLETION record exists in both cases.
    func test_aDeferredCaptureIsReleasedByTheConsumerEvenWhenTheTurnIsAbandoned() async throws {
        for abandoned in [true, false] {
            let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
            let chain = makeChain(policy: openGate(enrolled: true), wake: DetectedWake(),
                                  claims: { claims })
            chain.backend.stubTranscript = "play the latest episode"
            chain.engine.listeningMode = .continuous
            var released = false
            chain.engine.onRoutingInput = { _, context in
                chain.engine.contributionCollector?.engineReported(
                    stage: "execution",
                    outcome: VoiceSharingContributionEncoder.StageOutcome(
                        state: abandoned ? "cancelled" : "completed",
                        reason: abandoned ? "cancelled_by_user" : nil),
                    context: context)
                chain.engine.contributionCollector?.finalizeDeferredCompletion(context: context)
                released = true
            }
            await chain.backend.emitSpeechThenSilence(
                level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
            let deadline = Date().addingTimeInterval(5)
            while !released, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(released, "\(abandoned): the consumer must be handed the capture")

            // A RELEASE is what makes a completion publish; a capture left owned never reaches here.
            _ = waitForReadyEntries(1)
            guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage(),
                !entries.isEmpty else {
                return XCTFail("\(abandoned): a released capture must publish a record")
            }
            var states: [String] = []
            for entry in entries {
                let metadataURL = entry.root.appendingPathComponent(entry.name)
                    .appendingPathComponent("metadata.json")
                let envelope = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
                if let execution = ((envelope?["record"] as? [String: Any])?["observations"]
                    as? [String: Any])?["execution"] as? [String: Any],
                   let state = execution["state"] as? String {
                    states.append(state)
                }
            }
            XCTAssertTrue(states.contains(abandoned ? "cancelled" : "completed"),
                          "\(abandoned): the published record must carry the consumer's outcome, "
                              + "got \(states)")
        }
    }

    /// FINDING a7dfe013 #2: a returned `VoiceResponse` does not establish success. `.earcon(.error)` is
    /// a FAILED action and `.silent`/`.confirmRequired` refuse to act. Drives the PRODUCTION classifier
    /// helper the service uses, so an optimistic "completed on return" cannot pass this.
    func test_anExecutorResultIsInterpretedByWhatItSaysNotByReturning() {
        typealias Outcome = VoiceSharingContributionEncoder.StageOutcome
        let cases: [(String, VoiceResponse, String, String?)] = [
            // Only the executor's own failure verdict concludes anything (spec 012b19dd). Every other
            // response is a PRESENTATION choice and leaves execution unobserved.
            ("error tone", .earcon(.error), "failed", "action_failed"),
            ("confirmation needed", .earcon(.confirmRequired), "unknown", "observation_unavailable"),
            ("silent", .silent, "unknown", "observation_unavailable"),
            ("spoken answer", .spoken("playing"), "unknown", "observation_unavailable"),
            ("success tone", .earcon(.success), "unknown", "observation_unavailable"),
            ("combined", .combined(earcon: .success, spokenText: "done"), "unknown",
             "observation_unavailable"),
        ]
        for (label, response, state, reason) in cases {
            let outcome: Outcome = VoiceControlService.executionOutcomeForTesting(response)
            XCTAssertEqual(outcome.state, state, "\(label): wrong state")
            XCTAssertEqual(outcome.reason, reason, "\(label): wrong reason")
            // The routing disposition must AGREE with the execution outcome; a pending disposition
            // left behind would say the turn was still undecided after it finished.
            let disposition = VoiceControlService.settledDispositionForTesting(outcome)
            let expectedDisposition = state == "failed" ? "failed"
                : (state == "unknown" ? "pending" : "refused")
            XCTAssertEqual(disposition, expectedDisposition,
                           "\(label): disposition must follow what was actually observed")
        }
    }

    /// REVIEW 59841fbc #1: an explicit `reason: null` on a completed stage is still a carded reason. The
    /// first f8 implementation tested the VALUE (`!(reason is NSNull)`) and let exactly the payload f8
    /// forbids through — the same null-is-not-absence mistake made once before on asr.text.
    func test_aCompletedStageCarryingAnExplicitNullReasonIsStillRefused() throws {
        let stages = ["wake", "bleed", "asr", "translation", "routing", "execution"]
        for stage in stages {
            var all: [String: Any] = [:]
            for name in stages {
                all[name] = ["state": "unknown", "reason": "observation_unavailable"]
            }
            var block: [String: Any] = ["state": "completed"]
            block["reason"] = NSNull()
            if stage == "asr" { block["text"] = "hello" }
            all[stage] = block
            do {
                try VoiceSharingRecordBinding.validateObservationsForTesting(all)
                XCTFail("\(stage): an explicit null reason must not pass f8")
            } catch let error as VoiceSharingRecordBinding.BindingError {
                guard case .invalidField(let path, let message) = error else {
                    return XCTFail("\(stage): expected invalidField, got \(error)")
                }
                XCTAssertEqual(path, "observations.\(stage).reason")
                XCTAssertTrue(message.contains("carries no reason"),
                              "\(stage): refusal must state the rule, got \(message)")
            }
        }
    }

    /// A TRANSLATION SKIP REASON IS A DECISION NOT TO RUN (spec 4d10275f, review b5fb69ef). Each of the
    /// three is valid ONLY on translation/not_run; on any other stage, or with failed/cancelled/unknown/
    /// completed, it would claim a skip and a non-skip at once.
    func test_translationSkipReasonsAreValidOnlyWithTranslationNotRun() throws {
        let skipReasons = ["source_language_unavailable", "backend_handles_translation",
                           "translator_unavailable"]
        let stages = ["wake", "bleed", "asr", "translation", "routing", "execution"]
        func payload(stage: String, state: String, reason: String) -> [String: Any] {
            var all: [String: Any] = [:]
            for name in stages {
                all[name] = ["state": "unknown", "reason": "observation_unavailable"]
            }
            var block: [String: Any] = ["state": state, "reason": reason]
            if stage == "asr" && state == "completed" { block["text"] = "hello" }
            all[stage] = block
            return all
        }
        // ACCEPTED FIRST: the one legal combination must bind, or the refusals below prove nothing.
        for reason in skipReasons {
            XCTAssertNoThrow(
                try VoiceSharingRecordBinding.validateObservationsForTesting(
                    payload(stage: "translation", state: "not_run", reason: reason)),
                "translation/not_run/\(reason) is the legal pairing")
        }
        // REFUSED: right reason, wrong stage — and right stage, wrong state.
        for stage in stages where stage != "translation" {
            for reason in skipReasons {
                do {
                    try VoiceSharingRecordBinding.validateObservationsForTesting(
                        payload(stage: stage, state: "not_run", reason: reason))
                    XCTFail("\(stage)/not_run/\(reason): skip reasons are translation-only")
                } catch let error as VoiceSharingRecordBinding.BindingError {
                    guard case .invalidField(let path, let message) = error else {
                        return XCTFail("\(stage): expected invalidField, got \(error)")
                    }
                    XCTAssertEqual(path, "observations.\(stage).reason")
                    XCTAssertTrue(message.contains("valid only on the translation stage"),
                                  "\(stage): refusal must state the stage rule, got \(message)")
                }
            }
        }
        for state in ["failed", "cancelled", "unknown"] {
            for reason in skipReasons {
                do {
                    try VoiceSharingRecordBinding.validateObservationsForTesting(
                        payload(stage: "translation", state: state, reason: reason))
                    XCTFail("translation/\(state)/\(reason): a skip requires not_run")
                } catch let error as VoiceSharingRecordBinding.BindingError {
                    guard case .invalidField(_, let message) = error else {
                        return XCTFail("translation/\(state): expected invalidField, got \(error)")
                    }
                    XCTAssertTrue(message.contains("requires state not_run"),
                                  "translation/\(state): refusal must state the state rule, got \(message)")
                }
            }
        }
        // RE-SEALED PERSISTED ENVELOPE: translation/failed carrying a skip reason.
        let record = try encodedRecordWithEmptyResult()
        var mutated = record
        var all = try XCTUnwrap(mutated["observations"] as? [String: Any])
        all["translation"] = ["state": "failed", "reason": "translator_unavailable"]
        mutated["observations"] = all
        do {
            _ = try VoiceSharingRecordBinding.bind(envelope: try rescaled(mutated), audio: Data())
            XCTFail("a persisted translation/failed carrying a skip reason must be refused")
        } catch let error as VoiceSharingRecordBinding.BindingError {
            guard case .invalidField(let path, let message) = error else {
                return XCTFail("expected invalidField from the persisted envelope, got \(error)")
            }
            XCTAssertEqual(path, "observations.translation.reason")
            XCTAssertTrue(message.contains("requires state not_run"), "got \(message)")
        }
    }

    /// SPEC DELTA f8 ON EVERY STAGE (review b5fb69ef): a completed stage carries NO reason. Only exact
    /// asr/completed/empty_result may, where the reason IS the result. Asserted on the raw observations
    /// AND on a re-sealed persisted envelope, so the rule is proven where records actually come back.
    func test_aCompletedStageCarriesNoReasonOnEveryStage() throws {
        let stages = ["wake", "bleed", "asr", "translation", "routing", "execution"]
        // Each stage's own first enumerated reason, used as the "carries a reason" payload.
        let reasons: [String: String] = [
            "wake": "below_threshold",
            "bleed": "no_playback_reference",
            "asr": "local_only_action",
            "translation": "no_text",
            "routing": "no_candidates",
            "execution": "client_refused",
        ]
        func observations(completedStage: String, reason: String, text: String? = nil) -> [String: Any] {
            var all: [String: Any] = [:]
            for stage in stages {
                all[stage] = ["state": "unknown", "reason": "observation_unavailable"]
            }
            var block: [String: Any] = ["state": "completed", "reason": reason]
            if let text { block["text"] = text }
            all[completedStage] = block
            return all
        }
        for stage in stages {
            let payload = observations(completedStage: stage, reason: reasons[stage]!,
                                       text: stage == "asr" ? "hello" : nil)
            do {
                try VoiceSharingRecordBinding.validateObservationsForTesting(payload)
                XCTFail("\(stage): a completed stage must not carry a reason")
            } catch let error as VoiceSharingRecordBinding.BindingError {
                guard case .invalidField(let path, let message) = error else {
                    return XCTFail("\(stage): expected invalidField, got \(error)")
                }
                XCTAssertEqual(path, "observations.\(stage).reason",
                               "the refusal must name the offending stage")
                XCTAssertTrue(message.contains("a completed stage carries no reason"),
                              "\(stage): refusal must state the rule, got \(message)")
            }
        }
        // RE-SEALED PERSISTED ENVELOPE: the same contradiction coming back through `bind`.
        let record = try encodedRecordWithEmptyResult()
        var mutated = record
        var all = try XCTUnwrap(mutated["observations"] as? [String: Any])
        var wake = try XCTUnwrap(all["wake"] as? [String: Any])
        wake["state"] = "completed"
        wake["reason"] = "below_threshold"
        all["wake"] = wake
        mutated["observations"] = all
        let sealed = try rescaled(mutated)
        do {
            _ = try VoiceSharingRecordBinding.bind(envelope: sealed, audio: Data())
            XCTFail("a persisted record with a completed stage carrying a reason must be refused")
        } catch let error as VoiceSharingRecordBinding.BindingError {
            guard case .invalidField(let path, _) = error else {
                return XCTFail("expected invalidField from the persisted envelope, got \(error)")
            }
            XCTAssertEqual(path, "observations.wake.reason")
        }
    }

    /// `empty_result` DESCRIBES ONE THING ONLY (spec delta c6f3bdf7): a recognition that succeeded and
    /// produced nothing usable. Every contradictory combination is refused, because each one asserts
    /// something the capture cannot have done — a text alongside "no text", a router input from a command
    /// that could not exist, a failure dressed as a success.
    func test_emptyResultIsRefusedOnEveryContradictoryCombination() throws {
        func stage(_ overrides: [String: Any], stageName: String = "asr") -> [String: Any] {
            var base: [String: Any] = ["state": "completed", "reason": "empty_result"]
            for (k, v) in overrides { base[k] = v }
            // Every stage is required by the record; the others are honest `unknown` non-claims so the
            // refusal under test can only come from the ASR arrangement.
            var all: [String: Any] = [:]
            for other in ["wake", "bleed", "asr", "translation", "routing", "execution"] {
                all[other] = ["state": "unknown", "reason": "observation_unavailable"]
            }
            all[stageName] = base
            return all
        }
        // The valid one must actually be accepted, or the negatives prove nothing about the rule.
        do {
            try VoiceSharingRecordBinding.validateObservationsForTesting(stage([:]))
        } catch {
            return XCTFail("premise: empty_result on asr/completed must be accepted; got \(error)")
        }

        let refused: [(String, [String: Any], String)] = [
            ("text present", stage(["text": "hello"]), "text"),
            ("router_input present", stage(["router_input": ["intent": "track.play"]]), "router_input"),
            // ABSENT IS NOT NULL (review 2f8e5d90): an explicit null states the key exists and is empty,
            // which is not what empty_result declares.
            ("text null", stage(["text": NSNull()]), "text"),
            ("router_input null", stage(["router_input": NSNull()]), "router_input"),
            ("state failed", stage(["state": "failed"]), "completed"),
            ("state cancelled", stage(["state": "cancelled"]), "completed"),
            ("state not_run", stage(["state": "not_run"]), "completed"),
            ("wrong stage", stage([:], stageName: "routing"), "asr"),
            ("wrong stage execution", stage([:], stageName: "execution"), "asr"),
            ("wrong stage translation", stage([:], stageName: "translation"), "asr"),
        ]
        for (label, observations, expectedFragment) in refused {
            assertRefused(label, observations, containing: expectedFragment)
        }
    }

    /// Proves the REFUSAL IS ABOUT `empty_result`, not about the arrangement in general: the same payload
    /// with the reason removed (or replaced) must be refused or accepted for a DIFFERENT stated cause, so a
    /// control here cannot pass merely because the harness rejects this shape regardless.
    private func assertRefused(_ label: String, _ observations: [String: Any],
                               containing fragment: String) {
        do {
            _ = try VoiceSharingRecordBinding.validateObservationsForTesting(observations)
            XCTFail("\(label): expected refusal")
        } catch let error as VoiceSharingRecordBinding.BindingError {
            XCTAssertTrue("\(error)".localizedCaseInsensitiveContains(fragment),
                          "\(label): refusal must name the cause (\(fragment)); got \(error)")
        } catch {
            XCTFail("\(label): unexpected error \(error)")
        }
    }

    /// WAKE-ONLY IS A SUCCESSFUL RECOGNITION (spec 406c247e, review 859dac4c pt1). The recogniser returns
    /// just the wake phrase; after the wake window is removed the command text is empty. The ASR STAGE must
    /// still report the recogniser's own transcript as completed — stripping the wake phrase is the command
    /// input's job, and calling this a wake rejection or a provider error is a fabrication.
    func test_aWakeOnlyTranscriptIsPublishedAsCompletedAsrWithItsRawText() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
        let chain = makeChain(policy: openGate(enrolled: true), wake: DetectedWake(), claims: { claims })
        // Exactly the wake phrase: removing the wake window leaves nothing for the command path.
        chain.backend.stubTranscript = "hey auris"
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = waitForReadyEntries(1)

        guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage(),
            !entries.isEmpty else { return XCTFail("a durable record is required") }
        var asrBlocks: [[String: Any]] = []
        for entry in entries {
            let metadataURL = entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            if let asr = ((envelope?["record"] as? [String: Any])?["observations"]
                as? [String: Any])?["asr"] as? [String: Any] {
                asrBlocks.append(asr)
            }
        }
        XCTAssertFalse(asrBlocks.isEmpty, "the record must state the ASR stage")
        // Records for a segment the wake gate REJECTED never reach ASR; only the accepted capture's record
        // can carry the transcript. Assert on that one.
        let completed = asrBlocks.filter { $0["state"] as? String == "completed" }
        guard !completed.isEmpty else {
            return XCTFail("no record published the wake-only transcript; saw "
                + "\(asrBlocks.compactMap { $0["state"] as? String }); "
                + "transcribe calls: \(chain.backend.transcribeCalls); entries: \(entries.count); "
                + "wake states: \(wakeStates(entries))")
        }
        for asr in completed {
            XCTAssertEqual(asr["state"] as? String, "completed",
                           "a wake-only capture is a successful recognition, not a rejection")
            XCTAssertEqual(asr["text"] as? String, "hey auris",
                           "the stage carries the recogniser's own transcript")
            XCTAssertNil(asr["reason"],
                         "a completed ASR carries no reason; a reason here would assert a failure")
        }
    }

    /// The caller claims wake was never attempted; the detector actually RAN and failed. For the SAME
    /// capture, the engine's observation must win — a claim may not narrate over a real observation.
    func test_aCallerClaimCannotHideTheDetectorsFailure() async throws {
        var claims = claims
        claims["wake"] = .init(state: "not_run", reason: "detector_disabled")
        let chain = makeChain(policy: openGate(enrolled: true), wake: ErroringWake(), claims: { claims })
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = waitForReadyEntries(1)
        guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        // Group by capture: the question is what a SINGLE capture's record says, not what some unrelated
        // record in the same run says. The harness can close more than one segment.
        var byCapture: [String: [String: Any]] = [:]
        for entry in entries {
            let metadataURL = entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            let record = envelope?["record"] as? [String: Any]
            guard let capture = record?["capture_id"] as? String else { continue }
            byCapture[capture] = (record?["observations"] as? [String: Any])?["wake"] as? [String: Any]
        }
        let failedCaptures = byCapture.filter { $0.value["state"] as? String == "failed" }
        XCTAssertFalse(failedCaptures.isEmpty,
                       "the detector's real failure must reach a record; got \(byCapture)")
        for (capture, wake) in failedCaptures {
            XCTAssertEqual(wake["reason"] as? String, "detector_error",
                           "capture \(capture) reported the failure as something else")
        }
        // The claim may not stand in for the observation: no capture may publish the caller's
        // `not_run` for a stage the engine reported, because the merge makes the engine's word final.
        let claimedAsNotRun = byCapture.filter {
            $0.value["state"] as? String == "not_run"
                && $0.value["reason"] as? String == "detector_disabled"
        }
        XCTAssertTrue(claimedAsNotRun.isEmpty,
                      "the caller's not_run claim survived into a record despite a real observation: "
                          + "\(claimedAsNotRun)")
    }

    /// NO-WAKE FORWARDING (reviewer 7c6e628e): in grace/continuous the gate FORWARDS a negative segment
    /// instead of dropping it. The detector still ran and still reported no wake, so the record must carry
    /// `no_wake_detected` — the two gate decisions must not disagree about the same observation.
    func test_aForwardedNegativeSegmentStillReportsNoWakeDetected() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
        let chain = makeChain(policy: openGate(enrolled: true), wake: NotDetectedWake(), claims: { claims })
        chain.engine.listeningMode = .continuous
        // Open the grace window through the PRODUCTION entry point, not a test seam.
        chain.grace.onWakeWordDetected()
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = waitForReadyEntries(1)
        guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        // The negative verdict lives in `decision`, not `reason` (spec 94073918): a completed stage
        // carries no reason, so a reason-shaped assertion here would be asserting a refused payload.
        var decisions: [String?] = []
        for entry in entries {
            let metadataURL = entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            let wake = ((envelope?["record"] as? [String: Any])?["observations"]
                as? [String: Any])?["wake"] as? [String: Any]
            if wake?["state"] as? String == "completed" {
                decisions.append(wake?["decision"] as? String)
                XCTAssertNil(wake?["reason"], "a completed wake stage must not carry a reason")
            }
        }
        XCTAssertTrue(decisions.contains("no_wake_detected"),
                      "a forwarded negative segment observed no wake; got \(decisions)")
    }

    /// OBSERVATION ASSOCIATION, STALE CONTEXT (reviewer 7c6e628e): a report that belongs to capture A must
    /// never be attached to B, even though "current" is B at the moment it arrives. The collector keys the
    /// report by the CONTEXT it carries, and a context whose capture is already emitted is refused, so a
    /// late report can neither adopt a successor nor amend a record that has left.
    func test_aStaleContextReportNeverLandsOnTheSuccessorCapture() async {
        let policy = openGate(enrolled: true)
        let collector = makeRecordingCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        _ = engine

        // A opens, then closes and is EMITTED. B opens afterwards.
        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctxA = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: A open")
        }
        collector.segmentationEnded(ctxA)
        collector.speechCompleted([Float](repeating: 0.01, count: 640), context: ctxA)
        let afterA = snapshot()
        guard afterA.contains(where: { $0.captureID == ctxA.id && $0.kind == .completed }) else {
            return XCTFail("premise: A emitted its completion; got \(afterA.map { "\($0.kind)" })")
        }

        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctxB = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: B open")
        }
        XCTAssertNotEqual(ctxA.id, ctxB.id)

        // A's detector report arrives LATE — while B is the current capture.
        collector.engineReported(
            stage: "wake",
            outcome: VoiceSharingContributionEncoder.StageOutcome(
                state: "failed", reason: "detector_error"),
            context: ctxA)

        // B must now close and emit, so anything the stale report attached to B becomes visible. Without
        // this the assertion would inspect only B's `.started` and pass vacuously.
        collector.segmentationEnded(ctxB)
        collector.speechCompleted([Float](repeating: 0.01, count: 640), context: ctxB)

        // Nothing about A's report may appear under B.
        let bEvents = snapshot().filter { (event: VoiceSharingCollector.SegmentEvent) in
            event.captureID == ctxB.id
        }
        let stagesUnderB: [String] = bEvents.flatMap { (event: VoiceSharingCollector.SegmentEvent) -> [String] in
            Array(event.reportedStages.keys)
        }
        XCTAssertTrue(stagesUnderB.isEmpty,
                      "a stale report must not be adopted by the successor; B observed \(stagesUnderB)")
        // And A's already-emitted record was not silently amended.
        let aEmitted = snapshot().filter { (event: VoiceSharingCollector.SegmentEvent) in
            event.captureID == ctxA.id && event.kind == .completed
        }
        XCTAssertEqual(aEmitted.count, 1, "A emitted exactly one completion")
        XCTAssertTrue((aEmitted.first?.reportedStages ?? [:]).isEmpty,
                      "an emitted record is immutable; A's late report must be dropped, not merged")
    }

    /// OBSERVATION ASSOCIATION, POST-SEGMENTATION RING (reviewer 7c6e628e): the engine's decision can land
    /// AFTER the segmenter closed the capture but BEFORE the completion event is emitted. The report must
    /// ride that event. This drives the two collector calls in that exact order, so the ring carrier — not
    /// the open-capture carrier — is what is exercised.
    func test_aReportLandingAfterSegmentationRidesTheEmittedEvent() async {
        let policy = openGate(enrolled: true)
        let collector = makeRecordingCollector(policy)
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        _ = engine

        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctx = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: open")
        }
        collector.segmentationEnded(ctx)
        // Ring-resident and not yet emitted. `current` is already cleared at this point.
        XCTAssertFalse(snapshot().contains { (event: VoiceSharingCollector.SegmentEvent) in
            event.captureID == ctx.id && event.kind == .completed
        }, "premise: nothing emitted yet")

        collector.engineReported(
            stage: "wake",
            outcome: VoiceSharingContributionEncoder.StageOutcome(
                state: "failed", reason: "detector_error"),
            context: ctx)
        collector.speechCompleted([Float](repeating: 0.01, count: 640), context: ctx)

        let completed = snapshot().first { (event: VoiceSharingCollector.SegmentEvent) in
            event.captureID == ctx.id && event.kind == .completed
        }
        guard let completed else { return XCTFail("the completion was never emitted") }
        XCTAssertEqual(completed.reportedStages["wake"]?.state, "failed",
                       "a post-segmentation report must ride the emitted event")
        XCTAssertEqual(completed.reportedStages["wake"]?.reason, "detector_error")
    }

    private func makeChain(
        policy: VoiceSharingPolicy,
        wake: WakeWordDetectorProtocol = DetectedWake(),
        claims: @escaping () -> [String: VoiceSharingContributionEncoder.StageOutcome]
    ) -> (engine: VoiceAsrEngine, sink: VoiceSharingContributionSink,
          backend: EngineStubBackend, grace: GracePeriodSignal) {
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { policy.permitsCollection },
            encoderProvenance: { [self] in provenance }, observations: claims)
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { "epoch-1" },
            sessionIdentity: { "gen-A" },
            sink: { event in sink.handle(event) })
        collector.deliversSynchronouslyForTesting = true
        let backend = EngineStubBackend()
        let grace = GracePeriodSignal()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(silenceTimeoutMs: 60),
            backend: backend, signalFilter: SignalFilter(),
            wakeWordDetector: wake, gracePeriodSignal: grace,
            translationStage: nil)
        engine.contributionCollector = collector
        backend.engine = engine
        engine.start()
        return (engine: engine, sink: sink, backend: backend, grace: grace)
    }

    private func diagnostic(
        _ entries: [VoiceSharingUploadQueue.Entry],
        _ chain: (engine: VoiceAsrEngine, sink: VoiceSharingContributionSink,
                  backend: EngineStubBackend, grace: GracePeriodSignal)
    ) -> String {
        let states: [String] = entries.map { entry in
            let u = entry.root.appendingPathComponent(entry.name).appendingPathComponent("metadata.json")
            guard let e = try? JSONSerialization.jsonObject(with: Data(contentsOf: u), options: []) as? [String: Any],
                let o = ((e["record"] as? [String: Any])?["observations"] as? [String: Any]) else {
                return "no-record"
            }
            let cid = ((e["record"] as? [String: Any])?["capture_id"] as? String) ?? "?"
            let wakeDecision = (o["wake"] as? [String: Any])?["decision"] as? String ?? "-"
            return "\(cid.prefix(8)) wake=\(wakeDecision) "
                + o.map { "\($0.key):\((($0.value as? [String: Any])?["state"] as? String) ?? "?")" }
                .sorted().joined(separator: ",")
        }
        return "entries=\(entries.count) transcribe=\(chain.backend.transcribeCalls) states=\(states)"
    }

    private func wakeStates(_ entries: [VoiceSharingUploadQueue.Entry]) -> [String] {
        entries.compactMap { entry in
            let metadataURL = entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("metadata.json")
            guard let envelope = try? JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any],
                let wake = ((envelope["record"] as? [String: Any])?["observations"]
                    as? [String: Any])?["wake"] as? [String: Any] else { return nil }
            return "\(wake["state"] as? String ?? "?")/\(wake["reason"] as? String ?? "-")"
        }
    }

    private func waitForReadyEntries(_ count: Int, timeout: TimeInterval = 5) -> [Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .known(let ready) = queue.readyEntriesReportingUnknownCoverage(),
                ready.count >= count { return ready }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() { return ready }
        return []
    }

    /// THE control: speech driven through the real engine's capture callback becomes a durable ready
    /// entry, and the record inside it carries the unknown/observation_unavailable pair.
    func test_theRealEnginePipelineReachesTheDurableQueueWithTheUnobservedPair() async throws {
        let policy = openGate(enrolled: true)
        // The caller claims wake was NOT run. The engine, however, delivers real speech frames for this
        // capture and reports so — the record must carry the ENGINE's observation, not the caller's claim.
        // This is the provenance control: a claim cannot overwrite a real observation.
        let chain = makeChain(policy: policy, claims: { [self] in
            var callerClaims = claims
            callerClaims["wake"] = .init(state: "not_run", reason: "no_wake_detected")
            return callerClaims
        })
        // A wake-triggered continuous capture: speech, then the silence that closes the utterance (the
        // segmenter ends a segment on silence — without it nothing is ever emitted).
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let ready = waitForReadyEntries(1)
        XCTAssertGreaterThanOrEqual(ready.count, 1,
                       "the real engine's observer must produce a durable ready entry, not just a callback")
        // ANTI-VACUITY: the entry must be produced by a real capture, and its record must actually carry
        // the unknown/observation_unavailable pair — not merely "some entry exists".
        guard case .known(let entries) = queue.readyEntriesReportingUnknownCoverage(),
            !entries.isEmpty else { return XCTFail("a ready entry is required") }
        // The pipeline can emit more than one record (a segment the wake rejected, then a completed one).
        // Inspect the one that carried the engine's wake report.
        var examined: [String: Any]?
        for entry in entries {
            let metadataURL = entry.root.appendingPathComponent(entry.name)
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            let candidate = (envelope?["record"] as? [String: Any])?["observations"] as? [String: Any]
            if (candidate?["wake"] as? [String: Any])?["state"] as? String == "completed" {
                examined = candidate
                break
            }
        }
        guard let observations = examined else {
            return XCTFail("no ready record carried the engine's wake observation "
                + "(entries: \(entries.count))")
        }
        // The stub recogniser returned NOTHING. Spec delta c6f3bdf7: that is a SUCCESSFUL recognition with
        // nothing usable in it, so the engine's own report replaces the caller's claim — completed with
        // `empty_result`, and no text (there was none) and no router input (no command could proceed).
        let asr = observations["asr"] as? [String: Any]
        XCTAssertEqual(asr?["state"] as? String, "completed",
                       "an empty recognition is a result, not an absence of observation")
        XCTAssertEqual(asr?["reason"] as? String, "empty_result")
        XCTAssertNil(asr?["text"], "an empty result carries no transcript")
        // PROVENANCE (review c48461e6): the caller said wake=not_run; the engine delivered frames for this
        // capture, so the stored record must say completed. If the sink ignored `reportedStages`, this
        // would read not_run and the assertion would fail.
        let wake = observations["wake"] as? [String: Any]
        XCTAssertEqual(wake?["state"] as? String, "completed",
                       "an engine-reported observation must override a caller's claim")
    }

    /// The refusal half on the SAME chain: with the pairing broken, the pipeline reaches the sink and the
    /// sink drops it — nothing becomes ready. This is what makes the positive control above meaningful:
    /// an entry appearing is not automatic.
    func test_theRealEnginePipelineDropsTheRecordWhenThePairingIsBroken() async throws {
        let policy = openGate(enrolled: true)
        let chain = makeChain(policy: policy, claims: { [self] in
            var broken = self.claims
            // Break a stage the ENGINE DOES NOT report, so the caller's claim is what reaches the sink and
            // the pairing rule is genuinely the thing refusing it (the engine now reports asr itself).
            broken["translation"] = .init(state: "failed", reason: "observation_unavailable")
            return broken
        })
        chain.engine.listeningMode = .continuous
        // ANTI-VACUITY (review 9cf20d7a): a marker the SINK itself sets when its worker actually runs
        // on the event. Waiting a fixed interval would pass even if nothing was ever processed.
        let processed = XCTestExpectation(description: "the sink worker processed the event")
        chain.sink.testingWorkerGate = { processed.fulfill() }
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        wait(for: [processed], timeout: 5)
        chain.sink.waitForIdleForTesting()
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.count, 0,
                       "a record the validator refuses must never become ready, even from the real engine")
    }
}

final class EngineStubBackend: AsrBackend {
    weak var engine: VoiceAsrEngine?
    private(set) var transcribeCalls = 0

    var requiredModel: ModelSpec { ModelSpec(id: "stub", files: [], targetDir: "stub") }
    /// The detected language the stub reports; nil models a recogniser that cannot say.
    var stubLanguage: String?
    /// Whether the stub backend claims it translates natively.
    var stubCanTranslate = false
    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["en"], canTranslateToEnglish: stubCanTranslate,
                        requiresHardwareAccel: false)
    }
    func ensureReady() async -> Result<Void, Error> { .success(()) }
    /// The transcript this stub returns; a real recogniser returns text.
    var stubTranscript = ""
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        transcribeCalls += 1
        return AsrResult(text: stubTranscript, detectedLanguage: stubLanguage)
    }
    func release() {}

    /// Feeds frames exactly the way `capture.onSamples` does in production: one callback per audio buffer,
    /// which is why the segmenter sees many small calls rather than one giant array.
    func emitSpeech(level: Float, totalSamples: Int, chunkSamples: Int = 160) {
        guard let feed = engine?.captureCallbackForTesting else { return }
        var fed = 0
        while fed < totalSamples {
            let n = min(chunkSamples, totalSamples - fed)
            feed([Float](repeating: level, count: n))
            fed += n
        }
    }

    /// Speech followed by silence, so the segmenter times out and emits a real utterance through
    /// `onUtterance` → the engine's own `processUtterance`. Silence uses wall-clock waiting because the
    /// segmenter measures it with `Date()`; the timeout is short to keep the suite fast.
    func emitSpeechThenSilence(level: Float, speechSamples: Int, silenceSamples: Int,
                               chunkSamples: Int = 160) async {
        emitSpeech(level: level, totalSamples: speechSamples, chunkSamples: chunkSamples)
        emitSilence(totalSamples: silenceSamples, chunkSamples: chunkSamples)
        // Give the Task that processUtterance is dispatched onto a chance to run.
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    func emitSilence(totalSamples: Int, chunkSamples: Int = 160) {
        guard let feed = engine?.captureCallbackForTesting else { return }
        var fed = 0
        while fed < totalSamples {
            let n = min(chunkSamples, totalSamples - fed)
            feed([Float](repeating: 0.0001, count: n))
            fed += n
            // Wall-clock advance between chunks, since the segmenter compares Date() values rather than sample
            // counts. With the short test timeout this stays fast.
            if fed % 320 == 0 { Thread.sleep(forTimeInterval: 0.02) }
        }
    }
}

/// Detects every utterance, so the engine forwards the segment and a COMPLETED record is emitted — the
/// path on which an engine-reported wake observation can be compared against a caller's claim.
private final class DetectedWake: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        .detected(confidence: 0.95, completionSample: 1600)
    }
    func release() {}
}

/// The detector reports a real FAILURE (`error(code:)`) — the outcome the wake binding must accept.
private final class ErroringWake: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult { .error(code: "model_load_failed") }
    func release() {}
}

private final class NotDetectedWake: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult { .notDetected(confidence: 0.05) }
    func release() {}
}
