#if canImport(CryptoKit)
import CryptoKit
#endif
import PocketCastsUtils
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

    /// This class's tests are enrolled by default (this class drives the REAL engine and asserts on
    /// the contribution that reaches the sink). Controls that need the gate CLOSED call
    /// `openGate(enrolled: false)`.
    override func setUpWithError() throws {
        try super.setUpWithError()
        openGate(enrolled: true)
    }

    /// SIMPLIFIED contract: the collector's admission decision is the shared consent
    /// closure, not a policy/lease object. The store state these controls set is PROVENANCE stamped on
    /// the emitted record, so it is still established here exactly as before.
    private func openGate(enrolled: Bool) -> Void {
        // The ADMISSION decision is the consent closure, which these controls open and close directly;
        // the store state below is provenance stamped on the record. Setting only the store left the
        // closure closed, so every capture in this class was refused at `speechStarted`.
        engineTestGateOpen = enrolled
        storeState.localOptIn = enrolled
        storeState.hasAuthoritativeProjection = enrolled
        if !enrolled { storeState.membership = .unavailable }
        if enrolled {
            storeState.membership = VoiceSharingMembership(
                membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09", withdrawalState: .active
            )
        }
    }


    /// The store state the collector reads at EMISSION time. Opening the gate publishes this
    /// generation, because an emission made against a RESET store is refused as a foreign capture —
    /// which is exactly what an unbridged `openGate` produced.
    /// The admission decision these controls open and close.
    private var engineTestGateOpen = false

    private func makeCollector() -> VoiceSharingCollector {
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { [weak self] in self?.engineTestGateOpen ?? false },
            outcomeWaitLimit: .init(milliseconds: 60_000, ceilingMilliseconds: 60_000),
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
    /// HELD back by a gate; while it is parked, A closes and B opens. When A's body finally runs it must
    /// complete under A's frozen identity — attributed to A, never refused as foreign and never adopted
    /// by B. The freeze happens in `beginUtteranceProcessing` before Task creation, so holding the body
    /// back cannot change what A carries; a mutant that moves the read inside the body deterministically
    /// picks up B instead.
    func test_queuedUtteranceBodyRunningLate_completesUnderItsOwnFrozenContext() async {
        openGate(enrolled: true)
        let collector = makeCollector()
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
        openGate(enrolled: true)
        let collector = makeCollector()
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

    /// Closed capture admission must preserve the borrowed slice across the actual engine callback.
    /// Comparing addresses kills Array(newSamples), even when the collector subsequently retains zero.
    /// ("Actual upload usage"): there is NO capture allowance anymore. The
    /// former "missing allowance" test asserted refusal; its replacement asserts the NEW
    /// contract — with no allowance authority composed at all, the consented capture IS
    /// admitted (samples retained, capture live) while the engine still hands the segmenter
    /// PCM by reference and the natural recognition segment is preserved.
    func test_noAllowanceAuthorityComposedCaptureStillAdmitsAndPreservesNaturalRecognitionSegment() {
        openGate(enrolled: true)
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { true }, outcomeWaitLimit: .init(milliseconds: 60_000, ceilingMilliseconds: 60_000),
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { "epoch-1" }, sessionIdentity: { "gen-A" }, sink: { _ in }
        )
        let segmenter = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 2)
        let engine = VoiceAsrEngine(capture: AdmissionSilentCapture(), segmenter: segmenter,
            backend: EngineStubBackend(), signalFilter: SignalFilter(), wakeWordDetector: NotDetectedWake(),
            gracePeriodSignal: GracePeriodSignal(), translationStage: nil)
        engine.contributionCollector = collector
        XCTAssertTrue(engine.start())
        defer { engine.stop() }
        var expectedAddress: UInt?
        var observedSlices = 0
        collector.borrowedSampleAddressForTesting = { address in
            observedSlices += 1
            XCTAssertNotNil(address)
            XCTAssertEqual(address, expectedAddress, "engine copied PCM before admission")
        }
        let installed = segmenter.onSpeechAccumulated
        segmenter.onSpeechAccumulated = { samples, total in
            samples.withUnsafeBufferPointer { buffer in
                expectedAddress = buffer.baseAddress.map { UInt(bitPattern: $0) }
                installed?(samples, total)
            }
        }
        var recognizedSegments: [[Float]] = []
        // Observe the ordinary natural-end segment, without scheduling a backend task.
        segmenter.onUtterance = { samples, _ in recognizedSegments.append(samples) }
        let speech = [Float](repeating: 0.8, count: 320)
        let silence = [Float](repeating: 0, count: 320)
        segmenter.process(speech)
        segmenter.process(speech)
        segmenter.process(silence)
        XCTAssertGreaterThan(observedSlices, 0)
        XCTAssertEqual(recognizedSegments, [speech + speech + silence])
        XCTAssertNotEqual(collector.retainedSampleCountForTesting, 0,
            "no allowance exists to refuse admission: the consented capture is retained")
        XCTAssertNotNil(collector.currentCaptureIDForTesting,
            "no allowance exists to refuse admission: a capture is live")
    }

    /// removed the allowance ledger, so there is no storage barrier that can
    /// hold capture writes. The property worth pinning now is its successor: a LIVE consented
    /// capture (samples retained) does not stall the segmenter — recognition completes while
    /// the capture is being retained.
    func test_liveCaptureRetentionDoesNotStallRecognition() throws {
        openGate(enrolled: true)
        let collector = VoiceSharingCollector(isCollectionPermitted: { true }, outcomeWaitLimit: .init(milliseconds: 60_000, ceilingMilliseconds: 60_000),
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { "epoch-1" }, sessionIdentity: { "gen-A" }, sink: { _ in })
        let segmenter = NativeVadSegmenter(threshold: 0.5, silenceTimeoutMs: -1, minSpeechFrames: 2)
        let engine = VoiceAsrEngine(capture: AdmissionSilentCapture(), segmenter: segmenter,
            backend: EngineStubBackend(), signalFilter: SignalFilter(), wakeWordDetector: NotDetectedWake(),
            gracePeriodSignal: GracePeriodSignal(), translationStage: nil)
        engine.contributionCollector = collector
        XCTAssertTrue(engine.start())
        defer { engine.stop() }
        let progressed = DispatchSemaphore(value: 0)
        var ordinarySamples = 0
        segmenter.onUtterance = { samples, _ in
            ordinarySamples = samples.count
            progressed.signal()
        }
        DispatchQueue.global().async {
            segmenter.process([Float](repeating: 0.8, count: 320))
            segmenter.process([Float](repeating: 0.8, count: 320))
            segmenter.process([Float](repeating: 0, count: 320))
        }
        XCTAssertEqual(progressed.wait(timeout: .now() + 3), .success, "recognition completed while a capture was live")
        XCTAssertEqual(ordinarySamples, 960)
        XCTAssertNotEqual(collector.retainedSampleCountForTesting, 0,
            "the consented capture is retained; nothing staged blocks recognition")
    }

    // MARK: - Production path: start/stop own the subscription

    /// `start()` must attach the three observation hooks to the segmenter the pipeline already drives, and
    /// `stop()` must release any partial it holds. Asserted through the engine's public lifecycle rather than
    /// by poking at the segmenter, which is private.
    func test_engineStartAttachesHooksAndStopReleasesThePartial() {
        openGate(enrolled: true)
        XCTAssertTrue(self.storeState.effectiveEnrolled, "premise: consent allows collection")
        XCTAssertTrue(storeState.effectiveEnrolled, "premise: membership enrolled")

        let collector = makeCollector()
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

    /// An idle stop (no speech was ever open) must not be reported as a discarded example.
    func test_idleStop_producesNoCancellationEvent() {
        openGate(enrolled: true)
        let collector = makeCollector()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: EngineStubBackend())
        XCTAssertTrue(engine.start())

        engine.stop()
        XCTAssertEqual(recordedKinds(), [], "stopping an idle pipeline is not a rejected utterance")
    }

    // MARK: - Rejection branches observed inside the engine

    /// Wake-negative segments are collectable per spec, and observing them must add NO ASR/router/action work.
    /// The proof: recognition still returns at the wake branch, so no transcript reaches the router.
    func test_wakeNegativeBranch_isObserved_andRecognitionPathIsUnchanged() async {
        openGate(enrolled: true)
        let collector = makeCollector()
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)

        var routed: [String] = []
        engine.onRoutingInputWithContext = { input, _ in routed.append(input.routerTranscript); return true }
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
        openGate(enrolled: true)
        let collector = makeCollector()
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        XCTAssertTrue(engine.start())
        engine.isExposedSpeakerRouteForTesting = true
        // Main compares equal, fully covered capture/reference windows; identical PCM proves the bleed premise.
        let playback = stride(from: Float(-0.6), through: 0.6, by: 0.001).map { $0 }
        let echoReference = PlaybackEchoReference()
        echoReference.append(playback)
        echoReference.recordRenderPosition(PlaybackRenderAnchor(renderedFrames: Double(playback.count), sourceSampleRate: 16000, hostTime: 0))
        engine.setEchoReference(echoReference)
        utteranceUnderTest = playback

        // Open a capture first so the rejection has a frozen identity to attach its decision to — captured
        // SYNCHRONOUSLY, exactly as the production onUtterance closure does before creating its Task.
        backend.emitSpeech(level: 0.6, totalSamples: 5 * 160)
        let frozen = collector.currentCaptureContextForTesting
        await engine.processUtterance(utteranceUnderTest, capturedAt: 0, frozenContext: frozen)

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
        engineTestGateOpen = false
        XCTAssertFalse(engineTestGateOpen,
                       "premise: the consent gate is closed")

        let collector = makeCollector()
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
    /// dedicated thread and asserts delivery happened SOMEWHERE else. Without it, an implementation that calls
    /// the sink inline would pass every timing-based check while freezing capture callbacks whenever the
    /// consumer stalls.
    func test_sinkRunsOnADifferentThreadThanTheProducer() {
        openGate(enrolled: true)
        var deliveredOnMainThread = [Bool]()
        var deliveredFromAudioQueue = [Bool]()
        let lock = NSLock()
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { true }, outcomeWaitLimit: .init(milliseconds: 60_000, ceilingMilliseconds: 60_000),
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
            XCTAssertTrue(self.storeState.effectiveEnrolled, "premise: consent allows collection")
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

    /// / incident: a REFUSED segment must name its reason. The simulator
    /// stopped producing captures at 10:00:21Z and the log said nothing — the decision had to be
    /// inferred from absence, which is not evidence anyone can act on. This control drives the
    /// production refusal and requires its fixed reason line, AND requires the collector's own
    /// counters to show the segment was SEEN but not EMITTED.
    /// finding 3: `capturesEmittedCount` counts each CONTRIBUTION once — a
    /// completed segment and a REJECTED one (wake or bleed) are both recorded contributions that
    /// reach the sink, so both count; `.started` and a cancellation are not contributions and must
    /// not move the counter. Red on a7c500657, which counted `.completed` only and silently
    /// under-counted every rejected segment.
    func test_theEmittedCounterCountsCompletedAndRejectedContributionsOnceEach() throws {
        var delivered: [VoiceSharingCollector.SignalKind] = []
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { true },
            membership: { VoiceSharingEnrollmentStore.State() },
            epochProvider: { "test-epoch" },
            sessionIdentity: { "sess-1" },
            sink: { event in delivered.append(event.kind) })
        collector.deliversSynchronouslyForTesting = true

        // A STARTED segment is not a contribution: it must not count.
        let started = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: 1600))
        XCTAssertEqual(collector.capturesEmittedCount, 0, "a start is not a contribution")
        // Withdraw it so the rejected controls below start from a clean capture slot.
        collector.speechCancelled()
        XCTAssertEqual(collector.capturesEmittedCount, 0, "a cancellation is not a contribution")

        // A WAKE rejection is recorded: exactly one contribution.
        let wake = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: 1600))
        collector.segmentRejected(kind: .rejectedWake, samples: 1600, context: wake)
        XCTAssertEqual(collector.capturesEmittedCount, 1, "a wake rejection is one contribution")

        // A BLEED rejection likewise.
        let bleed = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: 1600))
        collector.segmentRejected(kind: .rejectedBleed, samples: 1600, context: bleed)
        XCTAssertEqual(collector.capturesEmittedCount, 2, "a bleed rejection is one contribution")

        XCTAssertEqual(delivered.filter { $0 == .rejectedWake || $0 == .rejectedBleed },
                       [.rejectedWake, .rejectedBleed],
                       "premise: both rejections really reached the sink")
        XCTAssertEqual(collector.segmentsSeenCount, 3,
                       "three segments were seen; two became contributions")
        _ = started
    }

    func test_aRefusedSegmentProducesItsReasonLineAndLeavesTheCountersMoved() async throws {
        var permitted = true
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { permitted },
            membership: { VoiceSharingEnrollmentStore.State() },
            epochProvider: { "test-epoch" },
            sessionIdentity: { "sess-1" },
            sink: { _ in })
        collector.deliversSynchronouslyForTesting = true
        XCTAssertEqual(collector.segmentsSeenCount, 0)
        XCTAssertEqual(collector.capturesEmittedCount, 0)

        // ADMITTED segment: seen AND emitted.
        XCTAssertNotNil(collector.speechStarted(confirmationFrameSamples: 1600))
        collector.appendSamples([0, 0.5, -0.5, 0.25], reportedTotal: 4)
        collector.segmentationEnded(collector.currentCaptureContextForTesting)
        collector.finalizeDeferredCompletion(context: nil)
        XCTAssertEqual(collector.segmentsSeenCount, 1, "the admitted segment is counted as seen")

        // REFUSED segment: the consent gate moves, and the refusal must name itself.
        permitted = false
        let before = await FileLog.shared.logFileAsString()
        XCTAssertNil(collector.speechStarted(confirmationFrameSamples: 1600),
                     "premise: a closed gate refuses the capture")
        let after = await FileLog.shared.logFileAsString()
        XCTAssertEqual(collector.segmentsSeenCount, 2,
                       "a refused segment is still SEEN — that is the whole point of the counter")
        XCTAssertTrue(after.count > before.count,
                      "a refusal must write a reason line, not fail silently")
        let added = String(after.dropFirst(before.count))
        XCTAssertTrue(added.contains("capture refused reason=collection-not-permitted"),
                      "the refusal names its reason; got: \(added)")
        XCTAssertTrue(added.contains("capture decisions segments="),
                      "the running seen-vs-emitted counters are reported alongside the decision")
    }
}

// MARK: - Stubs

/// Backend stand-in that also gives the test a handle on the engine's capture callback and the bleed verdict,
/// neither of which is otherwise reachable without a real audio session or playback tap.
/// The FULL production chain, at the boundary it actually covers: real
/// `VoiceAsrEngine` → real segmenter → real collector → the REAL `VoiceSharingDirectSink` → the
/// REAL durable queue. `VoiceSharingCollectorEngineTests` stops at the collector's event callback;
/// `VoiceSharingQueueTests` starts at a hand-built event. This joins them with bounded
/// fixtures instead of microphone capture.
///
/// WHAT this does not prove: the stage observation (wake/bleed/asr/…) is supplied by the sink's
/// `observations` closure, i.e. by the TEST — the engine does not produce these claims, so these
/// controls say nothing about observation PROVENANCE from live recognition. They prove the transport
/// from a real engine-produced capture event to a durable record, and that a record the validator
/// refuses never becomes ready. Live observation provenance remains an open gap.
final class VoiceSharingEndToEndEngineToDurableQueueTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingQueue!
    private var storeState = VoiceSharingEnrollmentStore.State()
    /// The live session source, as production reads it.
    private var engineStoreSession = "gen-A"
    /// The sink the current chain writes through, so a wait can drain its worker queue.
    private var sinkUnderTest: VoiceSharingDirectSink?
    /// The admission decision these controls open and close.
    private var engineTestGateOpen = false
    /// Events the collector emitted, for the association controls that inspect it directly.
    private var collectedEvents: [VoiceSharingCollector.SegmentEvent] = []
    private let collectedLock = NSLock()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-vs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingQueue(root: root)
        storeState = VoiceSharingEnrollmentStore.State()
        engineTestGateOpen = true
        engineStoreSession = "gen-A"
        openGate(enrolled: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A collector wired to record what it emits (no sink) — for observation-association controls.
    private func makeRecordingCollector() -> VoiceSharingCollector {
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { [weak self] in self?.engineTestGateOpen ?? false },
            outcomeWaitLimit: .init(milliseconds: 60_000, ceilingMilliseconds: 60_000),
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { "epoch-1" },
            sessionIdentity: { [weak self] in self?.engineStoreSession ?? "gen-A" },
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

    /// A LATE finalize may not resurrect A DISQUALIFIED capture. Finalize promotes a
    /// terminal capture into a completed record, so it must refuse everything the normal late-outcome path
    /// refuses: a capture whose epoch/session no longer match, and one that can never contribute.
    func test_aLateFinalizeCannotPublishADisqualifiedOrForeignCapture() async throws {
        openGate(enrolled: true)
        let collector = makeRecordingCollector()
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
        openGate(enrolled: false)
        collector.finalizeDeferredCompletion(context: ctxA)

        let emitted = snapshot().filter { (event: VoiceSharingCollector.SegmentEvent) in
            event.captureID == ctxA.id && event.kind == .completed
        }
        XCTAssertTrue(emitted.isEmpty,
                      "a capture whose session moved on must not become a completed record on late finalize")
    }

    /// A NAMED cancellation for A STALE capture must consume nothing. Capture A is
    /// cancelled and its deferred entry consumed; capture B is deferred and live. A second cancellation
    /// still naming A describes a capture that no longer exists — falling back to "most recent" would
    /// consume B, which nobody cancelled.
    func test_aStaleNamedCancellationConsumesNothingEvenWithALiveDeferredSuccessor() async throws {
        openGate(enrolled: true)
        let collector = makeRecordingCollector()
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

    /// A-DEFERRED / B-OPEN. A completed with deferred emission, then B started. A
    /// cancellation now belongs to B — it is the capture that is still open. Consuming A instead would
    /// discard a finished capture that was never cancelled and leave B live and filable.
    func test_aCancellationWhileASuccessorIsOpenConsumesTheSuccessorNotTheDeferredPredecessor() async throws {
        openGate(enrolled: true)
        let collector = makeRecordingCollector()
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

    /// CANCELLATION must bind the intended capture, never dictionary order. The ring is
    /// UUID-keyed, so a hash-order lookup satisfies any SINGLE arrangement by luck — proved by mutation,
    /// where the same control passed 3 runs in 5. The binding is therefore asserted from both sides in one
    /// run: the named capture must be consumed AND every other deferred capture must remain publishable.
    func test_aNamedCancelBindsItsOwnCaptureAndLeavesTheOthersPublishable() async throws {
        // DETERMINISTIC by construction, not by repetition. The old
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
            openGate(enrolled: true)
            let collector = makeRecordingCollector()
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

    /// A CANCELLED capture cannot be revived by A LATE finalize. The capture is deferred
    /// first, so it is genuinely ring-resident, and the cancel arrives while the engine still owes its
    /// finalize. The entry must be consumed, not promoted to a completed record.
    func test_aCancelledDeferredCaptureCannotBeRevivedByFinalize() async throws {
        openGate(enrolled: true)
        let collector = makeRecordingCollector()
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

    private func openGate(enrolled: Bool) -> Void {
        engineStoreSession = enrolled ? "gen-1" : "gen-2"
        engineTestGateOpen = enrolled
        storeState.localOptIn = enrolled
        storeState.hasAuthoritativeProjection = enrolled
        if !enrolled { storeState.membership = .unavailable }
        if enrolled {
            storeState.membership = VoiceSharingMembership(
                membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09",
                withdrawalState: .active)
        }
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
    ///
    /// These are FALLBACKS for stages the engine does not report. `wake` is deliberately absent: the
    /// real producer reports that stage on every path, and a fallback here would stand in for a
    /// measurement the detector actually made.
    private var claims: [String: VoiceSharingContributionEncoder.StageOutcome] {
        [
            "bleed": .init(state: "not_run", reason: "no_playback_reference"),
            "asr": .init(state: "unknown", reason: "observation_unavailable"),
            "translation": .init(state: "not_run", reason: "no_text"),
            "routing": .init(state: "not_run", reason: "no_candidates"),
            "execution": .init(state: "not_run", reason: "client_refused"),
        ]
    }

    /// ENGINE detector error → DURABLE record. The detector reports a
    /// real failure; that outcome must reach a READY durable record as the exact wake+failed/detector_error
    /// pairing. Before the pairing rule existed the binding refused this and the record never existed —
    /// a real engine failure was silently unpublishable.
    func test_theRealEnginePipelinePublishesADetectorErrorAsWakeFailed() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
        let chain = makeChain(wake: ErroringWake(), claims: { claims })
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let ready = await waitForReadyEntries(1)
        XCTAssertGreaterThanOrEqual(ready.count, 1,
                                    "a detector failure must still produce a durable record")
        let entries = await queue.entries()
        if entries.isEmpty { return XCTFail("coverage known") }
        var carried = false
        for entry in entries {
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            let wake = (envelope?["observations"]
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

    /// NORMAL ASR → DURABLE record. A SUCCESSFUL recognition must be publishable: the
    /// stored record must carry the transcript the recogniser actually returned. Reporting `completed`
    /// with no text made the sink overwrite the caller's text and the binding refuse it, so a successful
    /// capture produced no record at all.
    func test_aSuccessfulRecognitionPublishesItsTranscriptIntoTheDurableRecord() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
        let chain = makeChain(wake: DetectedWake(), claims: { claims })
        chain.backend.stubTranscript = "play the latest episode"
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = await waitForReadyEntries(1)

        let entries = await queue.entries()
        if entries.isEmpty {
            return XCTFail("a successful recognition must produce a durable record")
        }
        var transcripts: [String] = []
        for entry in entries {
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            let asr = (envelope?["observations"]
                as? [String: Any])?["asr"] as? [String: Any]
            guard asr?["state"] as? String == "completed" else { continue }
            if let text = asr?["text"] as? String { transcripts.append(text) }
        }
        XCTAssertTrue(transcripts.contains("play the latest episode"),
                      "the record must carry the recogniser's own transcript; got \(transcripts) "
                          + "(transcribe calls: \(chain.backend.transcribeCalls), "
                          + "entries: \(entries.count))")
    }

    /// THE emitted bytes, not the builder: an empty recognition must reach the durable
    /// record as asr/completed/empty_result with neither text nor router_input present.
    func test_anEmptyRecognitionReachesTheDurableRecordAsCompletedEmptyResult() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
        let chain = makeChain(wake: DetectedWake(), claims: { claims })
        chain.backend.stubTranscript = ""
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = await waitForReadyEntries(1)

        let entries = await queue.entries()
        if entries.isEmpty { return XCTFail("a durable record is required") }
        var sawEmptyResult = false
        for entry in entries {
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            guard let asr = (envelope?["observations"]
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

    /// PRODUCER binding: asr `source_language` and `router_input` are stated by the
    /// RECOGNISER at its own report site — the language it detected, and the exact text handed onward
    /// as the command input. Asserted on the DURABLE record through the real engine path.
    func test_theRecogniserStatesItsLanguageAndRouterInputOnTheDurableRecord() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-vs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingQueue(root: root)
        let localClaims = claims
        let chain = makeChain(wake: DetectedWake(), claims: { localClaims })
        chain.backend.stubTranscript = "play the latest episode"
        chain.backend.stubLanguage = "en"
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = await waitForReadyEntries(1)

        let entries = await queue.entries()
        if entries.isEmpty { return XCTFail("a record is required") }
        var asr: [String: Any]?
        for entry in entries {
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            if let stage = (envelope?["observations"]
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

    ///: same-stage re-reports must not carry a generic merge across state changes —
    /// a completed report must not inherit a previous reason, an empty_result must not inherit
    /// previous text/router_input, and only routing's classification facts survive to settlement.
    /// Each case binds the ENCODED record, so a contradiction is a schema refusal, not just a
    /// dictionary mismatch.
    func test_sameStageReReportsCarryOnlyIntendedFactsAcrossTransitions() throws {
        openGate(enrolled: true)
        let collector = makeRecordingCollector()
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
            // `segmentationEnded` arms deferred completion, so the segment emits only here; without
            // this call the `.completed` event never exists and the unwrap below crashes (the crash
            // was previously masked because the runner restarts and reports the suite as passed).
            collector.finalizeDeferredCompletion(context: ctx)
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
            let record = try JSONSerialization.jsonObject(
                with: encoded.metadata, options: []) as! [String: Any]
            return (record["observations"] as! [String: Any])
        }

        do { // failed → completed: the failure reason must not leak into the success.
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

        do { // completed-with-text → empty_result: text/router_input must not leak (the binding
             // refuses a carrying empty_result, which is exactly why inheritance is dangerous).
            let ctx = makeCase()
            collector.engineReported(stage: "asr",
                outcome: .init(state: "completed", text: "pause",
                               sourceLanguage: "en", routerInput: "pause"), context: ctx)
            collector.engineReported(stage: "asr",
                outcome: .init(state: "completed",
                               reason: VoiceSharingContributionEncoder.emptyResultReason),
                context: ctx)
            let asr = try encodedObservations(ctx)["asr"] as! [String: Any]
            XCTAssertNil(asr["text"], "empty_result must not inherit previous text")
            XCTAssertNil(asr["router_input"], "empty_result must not inherit previous router_input")
            XCTAssertEqual(asr["reason"] as? String,
                           VoiceSharingContributionEncoder.emptyResultReason)
        }
        collectedEvents.removeAll()

        do { // classification → settlement: only the classification facts survive, and the
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

    /// THE three translation skips are distinct facts. Collapsing them into
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
            queue = VoiceSharingQueue(root: root)
            let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
            let chain = makeChain(wake: DetectedWake(), claims: { claims })
            chain.backend.stubTranscript = "bonjour"
            chain.backend.stubLanguage = testCase.language
            // The backend only claims it translates for the middle case.
            chain.backend.stubCanTranslate = testCase.label == "backend handles translation"
            chain.engine.listeningMode = .continuous
            await chain.backend.emitSpeechThenSilence(
                level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
            _ = await waitForReadyEntries(1)

            let entries = await queue.entries()
            if entries.isEmpty { return XCTFail("\(testCase.label): a record is required") }
            var found: [String: Any]?
            for entry in entries {
                let metadataURL = entry.url
                    .appendingPathComponent("metadata.json")
                let envelope = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
                if let translation = (envelope?["observations"]
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

    /// ROUTING and execution observations bind and attribute (the two stages that were caller-supplied).
    ///
    /// SCOPE, STATED plainly: this drives the COLLECTOR with the same StageOutcome payloads the service now
    /// reports from its decision sites, and asserts they reach the durable record and displace a caller's
    /// unknown claim. It does not prove `handleRoutingInput` reaches each branch — that path needs the LFM
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
            queue = VoiceSharingQueue(root: root)
            let unknownClaims: [String: VoiceSharingContributionEncoder.StageOutcome] = [
                "wake": .init(state: "completed", decision: "detected"),
                "bleed": .init(state: "unknown", reason: "observation_unavailable"),
                "asr": .init(state: "completed", text: "play the latest episode"),
                "translation": .init(state: "unknown", reason: "observation_unavailable"),
                "routing": .init(state: "unknown", reason: "observation_unavailable"),
                "execution": .init(state: "unknown", reason: "observation_unavailable"),
            ]
            // Wake POSITIVE: with a negative wake the engine strips the wake window, the remaining text is
            // empty, and it returns before routing ever runs — so routing could not be observed at all.
            let chain = makeChain(wake: DetectedWake(),
                                  claims: { unknownClaims })
            chain.engine.listeningMode = .continuous
            // Stand where the SERVICE stands. The engine hands the frozen context to the routing
            // consumer and does not finalize; the consumer reports routing, then finalizes — so the
            // record still exists when the observation arrives. The consumer runs on the engine's own
            // task, so the test records the context there and finalizes through the same collector.
            var decisionContext: VoiceSharingCollector.CaptureContext?
            chain.engine.onRoutingInputWithContext = { _, context in
                decisionContext = context
                chain.engine.contributionCollector?.engineReported(
                    stage: "routing", outcome: testCase.routing, context: context)
                chain.engine.contributionCollector?.finalizeDeferredCompletion(context: context)
                return true
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
            _ = await waitForReadyEntries(1)

            let entries = await queue.entries()
            if entries.isEmpty { return XCTFail("\(testCase.label): a record is required") }
            var sawRouting = false
            for entry in entries {
                let metadataURL = entry.url
                    .appendingPathComponent("metadata.json")
                guard let envelope = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: metadataURL), options: []) as? [String: Any],
                    let observations = envelope["observations"] as? [String: Any],
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
                    let u = entry.url.appendingPathComponent("metadata.json")
                    guard let e = try? JSONSerialization.jsonObject(with: Data(contentsOf: u), options: []) as? [String: Any],
                        let o = e["observations"] as? [String: Any] else { return nil }
                    return o.map { "\($0.key)=\((($0.value as? [String: Any])?["state"] as? String) ?? "?")/\((($0.value as? [String: Any])?["decision"] as? String) ?? "-")" }.sorted().joined(separator: " ")
                }
                XCTFail("\(testCase.label): routing must be observed; records=\(dump)")
            }
        }
    }

    /// THE actual producer byte matrix (clean-3dd disposition). SCOPE, stated exactly: the five
    /// f8 branch cases are driven through the REAL engine pipeline (DetectorWake, stub backend,
    /// the engine's own observation sites, and routing through the same consumer seam the service
    /// uses), so the exported metadata bytes are PRODUCER output — not the test-supplied
    /// observations of the encoder-fixture export. Each fixture is bind-verified with the
    /// production binding before it is written, and the key producer fact is asserted on the
    /// emitted bytes. The pinned worker intake acceptance itself runs on the host against the
    /// clean `3dd0c91d` pin (see helper-evidence/f8-parity).
    func test_exportActualProducerF8MatrixForPinnedWorkerIntake() async throws {
        struct MatrixCase {
            let name: String
            let transcript: String
            let language: String?
            let canTranslate: Bool
            let route: Bool
            let expectedKey: (stage: String, key: String, value: String)
        }
        let matrix: [MatrixCase] = [
            .init(name: "actual-f8-routing-executed", transcript: "pause", language: "en",
                  canTranslate: false, route: true,
                  expectedKey: ("routing", "execution_disposition", "executed")),
            .init(name: "actual-f8-empty-result", transcript: "", language: "en",
                  canTranslate: false, route: false,
                  expectedKey: ("asr", "reason", "empty_result")),
            .init(name: "actual-f8-translation-backend-handles", transcript: "bonjour",
                  language: "fr", canTranslate: true, route: false,
                  expectedKey: ("translation", "reason", "backend_handles_translation")),
            .init(name: "actual-f8-translation-source-unavailable", transcript: "bonjour",
                  language: nil, canTranslate: false, route: false,
                  expectedKey: ("translation", "reason", "source_language_unavailable")),
            .init(name: "actual-f8-translation-translator-unavailable", transcript: "öffne die App",
                  language: "de", canTranslate: false, route: false,
                  expectedKey: ("translation", "reason", "translator_unavailable")),
        ]
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auris-f8-producer-fixtures")
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        for matrixCase in matrix {
            // Fresh storage per case so each fixture is exactly one producer record.
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("e2e-vs-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            queue = VoiceSharingQueue(root: root)
            let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
            let chain = makeChain(wake: DetectedWake(),
                                  claims: { claims })
            chain.backend.stubTranscript = matrixCase.transcript
            chain.backend.stubLanguage = matrixCase.language
            chain.backend.stubCanTranslate = matrixCase.canTranslate
            var decisionContext: VoiceSharingCollector.CaptureContext?
            if matrixCase.route {
                // Stand where the SERVICE stands: the engine hands the frozen context to the
                // routing consumer; the consumer reports routing, then finalizes.
                chain.engine.onRoutingInputWithContext = { _, context in
                    decisionContext = context
                    chain.engine.contributionCollector?.engineReported(
                        stage: "routing",
                        outcome: .init(state: "completed", routingDisposition: "executed"),
                        context: context)
                    chain.engine.contributionCollector?
                        .finalizeDeferredCompletion(context: context)
                    return true
                }
            }
            chain.engine.listeningMode = .continuous
            await chain.backend.emitSpeechThenSilence(
                level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
            if matrixCase.route {
                let deadline = Date().addingTimeInterval(5)
                while decisionContext == nil, Date() < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                guard decisionContext != nil else {
                    return XCTFail("\(matrixCase.name): routing must receive the frozen capture")
                }
            }
            _ = await waitForReadyEntries(1)

            let entries = await queue.entries()
            guard !entries.isEmpty else {
                return XCTFail("\(matrixCase.name): a durable producer record is required")
            }
            // Find THE entry carrying this case's key producer fact, on the emitted bytes.
            var chosenEntry: VoiceSharingQueue.Entry?
            for entry in entries {
                let metadataURL = entry.url
                    .appendingPathComponent("metadata.json")
                guard let envelope = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: metadataURL), options: []) as? [String: Any],
                    let observations = envelope["observations"] as? [String: Any],
                    let stage = observations[matrixCase.expectedKey.stage] as? [String: Any],
                    stage[matrixCase.expectedKey.key] as? String == matrixCase.expectedKey.value
                else { continue }
                chosenEntry = entry
                break
            }
            guard let entry = chosenEntry else {
                return XCTFail("\(matrixCase.name): no durable record carried "
                    + "\(matrixCase.expectedKey.stage)/\(matrixCase.expectedKey.key)="
                    + "\(matrixCase.expectedKey.value); entries=\(entries.count)")
            }
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            let audioURL = entry.url
                .appendingPathComponent("audio.wav")
            let metadata = try Data(contentsOf: metadataURL)
            let audio = try Data(contentsOf: audioURL)
            // Plain JSON the server validates: nothing to bind and no digest to self-check.
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: metadata) as? [String: Any])
            let dir = base.appendingPathComponent(matrixCase.name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try metadata.write(to: dir.appendingPathComponent("metadata.json"))
            try audio.write(to: dir.appendingPathComponent("audio.wav"))
            let manifest: [String: String] = [
                "f8_case": matrixCase.name,
                "producer": "engine-pipeline",
            ]
            try JSONSerialization.data(
                withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
                .write(to: dir.appendingPathComponent("manifest.json"))
        }
    }

    /// COLLECTOR-LEVEL probe: an engine report made while the capture is open must ride the event that
    /// the DEFERRED finalize emits. This isolates the merge from the engine and the sink.
    func test_anEngineReportMadeWhileOpenRidesTheDeferredCompletionEvent() async {
        openGate(enrolled: true)
        let collector = makeRecordingCollector()
        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctx = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: open capture")
        }
        collector.engineReported(
            stage: "wake",
            outcome: .init(state: "completed", reason: nil, decision: "rejected"),
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
        XCTAssertEqual(wake?.decision, "rejected")
        XCTAssertNil(wake?.reason, "a completed stage carries no reason")
    }

    /// AN OBSERVED negative wake must not be lost. Sink merge must not let a caller's
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
        let chain = makeChain(wake: NotDetectedWake(), claims: { claims })
        chain.backend.stubTranscript = "play the latest episode"
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = await waitForReadyEntries(1)

        let entries = await queue.entries()
        if entries.isEmpty { return XCTFail("an observed negative wake must still publish a record") }
        // A capture produces TWO records by design: a `started` event at segment start, before any engine
        // observation exists, and the completion carrying what the engine actually decided. The COMPLETION
        // is what must state the observed negative; asserting the started record would demand that a
        // pre-observation publish know the future.
        var completionBlocks: [[String: Any]] = []
        for entry in entries {
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            guard let record = envelope,
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
        XCTAssertEqual(wake["decision"] as? String, "rejected",
                       "the OBSERVED negative decision must survive validation, not be relabelled; "
                           + "server validateWake permits only detected/rejected")
        XCTAssertNil(wake["reason"],
                     "a completed stage carries no reason; the negative lives in decision")
    }



    /// A real encoder fixture whose ASR stage is completed/empty_result — the one legal completed reason.
    private func encodeEmptyResultRecord() throws -> VoiceSharingContributionEncoder.Encoded {
        let observations: [String: VoiceSharingContributionEncoder.StageOutcome] = [
            "wake": .init(state: "completed", decision: "detected"),
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
            try JSONSerialization.jsonObject(with: encoded.metadata) as? [String: Any])
    }

    /// Serialises a mutated record. Plain JSON: there is no canonical form or digest to rebind.
    private func rescaled(_ record: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: record)
    }

    /// FINDING a7dfe013 #3: the capture handed to the routing consumer must always be RELEASED, or it
    /// stays ring-resident forever and never publishes. Drives the REAL engine: the consumer reports
    /// (or a stopped turn cancels) and releases. Asserts a COMPLETION record exists in both cases.
    func test_aDeferredCaptureIsReleasedByTheConsumerEvenWhenTheTurnIsAbandoned() async throws {
        for abandoned in [true, false] {
            let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
            let chain = makeChain(wake: DetectedWake(),
                                  claims: { claims })
            chain.backend.stubTranscript = "play the latest episode"
            chain.engine.listeningMode = .continuous
            var released = false
            chain.engine.onRoutingInputWithContext = { _, context in
                chain.engine.contributionCollector?.engineReported(
                    stage: "execution",
                    outcome: VoiceSharingContributionEncoder.StageOutcome(
                        state: abandoned ? "cancelled" : "completed",
                        reason: abandoned ? "cancelled_by_user" : nil),
                    context: context)
                chain.engine.contributionCollector?.finalizeDeferredCompletion(context: context)
                released = true
                return true
            }
            await chain.backend.emitSpeechThenSilence(
                level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
            let deadline = Date().addingTimeInterval(5)
            while !released, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(released, "\(abandoned): the consumer must be handed the capture")

            // A RELEASE is what makes a completion publish; a capture left owned never reaches here.
            _ = await waitForReadyEntries(1)
            let entries = await queue.entries()
            if entries.isEmpty {
                return XCTFail("\(abandoned): a released capture must publish a record")
            }
            var states: [String] = []
            for entry in entries {
                let metadataURL = entry.url
                    .appendingPathComponent("metadata.json")
                let envelope = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
                if let execution = (envelope?["observations"]
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

    /// SUPERSEDED control (spec: structured executor verdicts). The response classifier this
    /// control pinned (`executionOutcome(for:)`) is retired: the executor now reports its OWN
    /// structured verdict at its decision site (`VoiceIntentExecutor.executeWithVerdict`), and
    /// the successor controls live in VoiceIntentExecutorTests. The superseded mapping treated
    /// every non-error response as unobserved, discarding facts the executor knew.
    func test_anExecutorResultIsInterpretedByWhatItSaysNotByReturning() {
        typealias Outcome = VoiceSharingContributionEncoder.StageOutcome
        // The surviving invariant: a FAILED verdict must stay a failure, and the disposition
        // must agree with the outcome the record carries.
        let failed = Outcome(state: "failed", reason: "action_failed", outcome: "failed")
        XCTAssertEqual(VoiceControlService.settledDispositionForTesting(failed), "failed")
        let unknown = Outcome(state: "unknown", reason: "observation_unavailable")
        XCTAssertEqual(VoiceControlService.settledDispositionForTesting(unknown), "pending",
                       "an unobserved turn cannot claim a terminal disposition")
    }

    /// SERVER schema: the execution stage's wire outcome is the
    /// schema's OWN enum — {success, failure, refused, cancelled} — reached by a mapping DISTINCT
    /// from settledDisposition's routing tokens. An unobserved execution (unknown/not_run) states
    /// NO outcome at all rather than asserting a conclusion nothing observed.
    func test_theWireExecutionOutcomeIsADistinctVocabularyFromTheRoutingDisposition() {
        typealias Outcome = VoiceSharingContributionEncoder.StageOutcome
        func wire(_ state: String, reason: String? = nil) -> String? {
            VoiceSharingContributionEncoder.StageOutcome.wireExecutionOutcome(
                for: Outcome(state: state, reason: reason))
        }
        XCTAssertEqual(wire("completed"), "success")
        XCTAssertEqual(wire("failed"), "failure")
        XCTAssertEqual(wire("cancelled"), "cancelled")
        // SPEC alignment 553ec4a6 (same rule Android gets): a REFUSAL is state `failed` with
        // `client_refused` — the wire's `refused` — not a not_run.
        XCTAssertEqual(wire("failed", reason: "client_refused"), "refused")
        XCTAssertNil(wire("unknown"), "unobserved execution must not assert an outcome")
        XCTAssertNil(wire("not_run"), "a not_run stage observed no execution")
        // The routing disposition keeps its own vocabulary — the two mappings must not merge.
        let completed = Outcome(state: "completed", reason: nil)
        XCTAssertEqual(VoiceControlService.settledDispositionForTesting(completed), "executed")
        XCTAssertNotEqual(VoiceControlService.settledDispositionForTesting(completed),
                          VoiceSharingContributionEncoder.StageOutcome.wireExecutionOutcome(for: completed),
                          "routing disposition and wire outcome are different vocabularies")
    }

    /// #2: the collector's AUTOMATIC execution-outcome mapping, measured on
    /// DURABLE bytes through the production collector/sink/queue. The producer supplies NO outcome
    /// member at all — so deleting the collector's mapping makes this control fail. Covers the
    /// fixed mapping: completed/success, failed/failure,
    /// failed+client_refused/refused, cancelled/cancelled, and unknown with NO outcome member.
    func test_theCollectorMapsExecutionOutcomeOntoDurableBytesForEveryObservedState() async throws {
        let cases: [(label: String, state: String, reason: String?, expected: String?)] = [
            ("completed", "completed", nil, "success"),
            ("failed action", "failed", "action_failed", "failure"),
            ("refusal", "failed", "client_refused", "refused"),
            ("cancelled", "cancelled", "cancelled_by_user", "cancelled"),
            ("unobserved", "unknown", "observation_unavailable", nil),
        ]
        for (label, state, reason, expected) in cases {
            openGate(enrolled: true)
            let chain = makeChain(wake: DetectedWake(), claims: { [:] })
            chain.engine.listeningMode = .wakeWord
            // A recogniser that returns nothing never reaches routing, so the execution outcome would
            // have no producer site to be mapped from. The control needs a real transcript.
            chain.backend.stubTranscript = "play the next episode"
            var released = false
            chain.engine.onRoutingInputWithContext = { _, context in
                // THE producer states no outcome: the mapping must come from the collector.
                chain.engine.contributionCollector?.engineReported(
                    stage: "execution",
                    outcome: .init(state: state, reason: reason),
                    context: context)
                chain.engine.contributionCollector?.finalizeDeferredCompletion(context: context)
                released = true
                return true
            }
            let watermark = await recordWatermark()
            await chain.backend.emitSpeechThenSilence(
                level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
            let deadline = Date().addingTimeInterval(5)
            while !released, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(released, "\(label): the consumer must be handed the capture")
            _ = await waitForReadyEntries(1)
            let freshRecords = try await durableRecordsSince(watermark)
            let record = try XCTUnwrap(freshRecords.first, label)
            let exec = try XCTUnwrap(
                (record["observations"] as? [String: Any])?["execution"] as? [String: Any], label)
            if let expected {
                XCTAssertEqual(exec["outcome"] as? String, expected,
                               "\(label): the durable record must carry the mapped outcome; got \(String(describing: exec["outcome"]))")
                XCTAssertEqual(exec["reason"] as? String, reason,
                               "\(label): the observed reason is retained alongside the outcome")
            } else {
                XCTAssertFalse(exec.keys.contains("outcome"),
                               "\(label): an unobserved execution must state NO outcome member")
            }
        }
    }



    /// PRODUCTION chain for (review: a control must exercise the real path, not a hand-built
    /// event). Real engine bleed branch → real collector → REAL sink → REAL encoder → queue entry → read
    /// back from the persisted record. The ASR stage states the observed skip, the bleed stage keeps its own
    /// observed decision, no transcript is invented, and no recognition ran (the stub counts transcribe calls).
    func test_realEngineBleedRejectionPersistsTheObservedAsrSkip() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = [:]
        let chain = makeChain(wake: NotDetectedWake(), claims: { claims })
        let engine = chain.engine
        engine.isExposedSpeakerRouteForTesting = true
        // Use an equal, fully covered window under main's positional echo-reference contract.
        let playback = stride(from: Float(-0.6), through: 0.6, by: 0.001).map { $0 }
        let echoReference = PlaybackEchoReference()
        echoReference.append(playback)
        echoReference.recordRenderPosition(PlaybackRenderAnchor(renderedFrames: Double(playback.count), sourceSampleRate: 16000, hostTime: 0))
        engine.setEchoReference(echoReference)
        let utterance = playback
        chain.backend.emitSpeech(level: 0.6, totalSamples: 5 * 160)
        let frozen = chain.engine.contributionCollector?.currentCaptureContextForTesting
        await engine.processUtterance(utterance, capturedAt: 0, frozenContext: frozen)
        XCTAssertEqual(chain.backend.transcribeCalls, 0, "premise: bleed skip performs no recognition")

        // The queue persists asynchronously even under synchronous delivery; wait for the durable entry.
        let ready = await waitForReadyEntries(1)
        XCTAssertEqual(ready.count, 1, "the bleed-rejected segment remains a collectable record")
        // Identified by the record's OWN capture id, never by queue order.
        let expectedID = try XCTUnwrap(frozen?.id.uuidString)
        let record = try XCTUnwrap(ready.compactMap { entry -> [String: Any]? in
            let url = entry.url.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: url),
                let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                record["capture_id"] as? String == expectedID
            else { return nil }
            return record
        }.first, "the persisted record for capture \(expectedID) must exist")
        let observations = try XCTUnwrap(record["observations"] as? [String: Any])
        let asrBlock = try XCTUnwrap(observations["asr"] as? [String: Any])
        XCTAssertEqual(asrBlock["state"] as? String, "not_run",
                       "the persisted record states why recognition did not run")
        XCTAssertEqual(asrBlock["reason"] as? String, "rejected_by_bleed")
        XCTAssertNil(asrBlock["text"], "a skipped stage carries no transcript")
        let bleed = try XCTUnwrap(observations["bleed"] as? [String: Any])
        XCTAssertEqual(bleed["decision"] as? String, "overlap",
                       "the bleed stage keeps its own observed decision")
        // THE detector ran, SO THE stage is completed. Reporting
        // `unknown`/`no_playback_reference` would satisfy the schema's membership check while
        // asserting that no reference existed — the opposite of the overlap verdict observed here.
        XCTAssertEqual(bleed["state"] as? String, "completed",
                       "an observed verdict is a completed observation, not an unknown one")
        XCTAssertNil(bleed["reason"],
                     "a completed stage carries no reason; the skip reason belongs to ASR")
        engine.stop()
    }

    /// PRODUCTION chain for a WAKE rejection: real engine wake branch → real collector → REAL sink →
    /// REAL encoder → queue entry → read back from the persisted record.
    ///
    /// A segment that fails the wake word never reaches recognition, routing or the executor. Those
    /// stages did not merely go unreported — the app knows they did not run, so the record must say
    /// `not_run` with a reason. Leaving them as the encoder's default `unknown` /
    /// `observation_unavailable` claims the app could not tell, which understates what it knows and
    /// disagrees with what Android records for the same event.
    func test_realEngineWakeRejectionPersistsNotRunForEveryStageThatNeverRan() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = [:]
        let chain = makeChain(wake: NotDetectedWake(), claims: { claims })
        let engine = chain.engine
        chain.backend.emitSpeech(level: 0.6, totalSamples: 5 * 160)
        let frozen = chain.engine.contributionCollector?.currentCaptureContextForTesting
        await engine.processUtterance(Array(repeating: 0.6, count: 5 * 160), capturedAt: 0, frozenContext: frozen)
        XCTAssertEqual(chain.backend.transcribeCalls, 0,
                       "premise: a wake rejection performs no recognition, so ASR never ran")

        let ready = await waitForReadyEntries(1)
        XCTAssertEqual(ready.count, 1, "the wake-rejected segment remains a collectable record")
        let expectedID = try XCTUnwrap(frozen?.id.uuidString)
        let record = try XCTUnwrap(ready.compactMap { entry -> [String: Any]? in
            let url = entry.url.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: url),
                let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                record["capture_id"] as? String == expectedID
            else { return nil }
            return record
        }.first, "the persisted record for capture \(expectedID) must exist")

        let observations = try XCTUnwrap(record["observations"] as? [String: Any])
        // The detector RAN and rejected: its own measured values survive on a completed stage.
        let wake = try XCTUnwrap(observations["wake"] as? [String: Any])
        XCTAssertEqual(wake["state"] as? String, "completed")
        XCTAssertEqual(wake["decision"] as? String, "rejected")

        // Every stage downstream of the rejected wake is a KNOWN skip, not an unstated one.
        for (stage, reason) in [("asr", "rejected_by_wake"),
                                ("routing", "not_dispatched"),
                                ("execution", "not_dispatched")] {
            let block = try XCTUnwrap(observations[stage] as? [String: Any],
                                      "\(stage) must be present on a wake-rejected record")
            XCTAssertEqual(block["state"] as? String, "not_run",
                           "\(stage) did not run, and the app knows it: not_run, not unknown")
            XCTAssertEqual(block["reason"] as? String, reason,
                           "\(stage) names why it did not run")
            XCTAssertNil(block["text"], "a stage that did not run carries no transcript")
        }
        engine.stop()
    }

    /// WAKE-only is A SUCCESSFUL recognition. The recogniser returns
    /// just the wake phrase; after the wake window is removed the command text is empty. The ASR STAGE must
    /// still report the recogniser's own transcript as completed — stripping the wake phrase is the command
    /// input's job, and calling this a wake rejection or a provider error is a fabrication.
    func test_aWakeOnlyTranscriptIsPublishedAsCompletedAsrWithItsRawText() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
        let chain = makeChain(wake: DetectedWake(), claims: { claims })
        // Exactly the wake phrase: removing the wake window leaves nothing for the command path.
        chain.backend.stubTranscript = "hey auris"
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = await waitForReadyEntries(1)

        let entries = await queue.entries()
        if entries.isEmpty { return XCTFail("a durable record is required") }
        var asrBlocks: [[String: Any]] = []
        for entry in entries {
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            if let asr = (envelope?["observations"]
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
        let chain = makeChain(wake: ErroringWake(), claims: { claims })
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = await waitForReadyEntries(1)
        let entries = await queue.entries()
        if entries.isEmpty { return XCTFail("coverage known") }
        // Group by capture: the question is what a SINGLE capture's record says, not what some unrelated
        // record in the same run says. The harness can close more than one segment.
        var byCapture: [String: [String: Any]] = [:]
        for entry in entries {
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            let record = envelope
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

    /// NO-WAKE forwarding: in grace/continuous the gate FORWARDS a negative segment
    /// instead of dropping it. The detector still ran and still reported no wake, so the record must carry
    /// `no_wake_detected` — the two gate decisions must not disagree about the same observation.
    func test_aForwardedNegativeSegmentStillReportsNoWakeDetected() async throws {
        let claims: [String: VoiceSharingContributionEncoder.StageOutcome] = claims
        let chain = makeChain(wake: NotDetectedWake(), claims: { claims })
        chain.engine.listeningMode = .continuous
        // Open the grace window through the PRODUCTION entry point, not a test seam.
        chain.grace.onWakeWordDetected()
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)
        _ = await waitForReadyEntries(1)
        let entries = await queue.entries()
        if entries.isEmpty { return XCTFail("coverage known") }
        // The negative verdict lives in `decision`, not `reason`: a completed stage
        // carries no reason, so a reason-shaped assertion here would be asserting a refused payload.
        var decisions: [String?] = []
        for entry in entries {
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            let envelope = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            let wake = (envelope?["observations"]
                as? [String: Any])?["wake"] as? [String: Any]
            if wake?["state"] as? String == "completed" {
                decisions.append(wake?["decision"] as? String)
                XCTAssertNil(wake?["reason"], "a completed wake stage must not carry a reason")
            }
        }
        XCTAssertTrue(decisions.contains("rejected"),
                      "a forwarded negative segment observed no wake (schema value rejected); got \(decisions)")
    }

    /// OBSERVATION association, STALE context: a report that belongs to capture A must
    /// never be attached to B, even though "current" is B at the moment it arrives. The collector keys the
    /// report by the CONTEXT it carries, and a context whose capture is already emitted is refused, so a
    /// late report can neither adopt a successor nor amend a record that has left.
    func test_aStaleContextReportNeverLandsOnTheSuccessorCapture() async {
        openGate(enrolled: true)
        let collector = makeRecordingCollector()
        let backend = EngineStubBackend()
        let engine = makeEngine(collector: collector, wake: NotDetectedWake(), backend: backend)
        _ = engine

        // A opens, then closes and is EMITTED. B opens afterwards.
        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctxA = collector.currentCaptureContextForTesting else {
            return XCTFail("premise: A open")
        }
        collector.segmentationEnded(ctxA)
        collector.finalizeDeferredCompletion(context: ctxA)
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
        collector.finalizeDeferredCompletion(context: ctxB)

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

    /// OBSERVATION association, POST-SEGMENTATION ring: the engine's decision can land
    /// after the segmenter closed the capture but before the completion event is emitted. The report must
    /// ride that event. This drives the two collector calls in that exact order, so the ring carrier — not
    /// the open-capture carrier — is what is exercised.
    func test_aReportLandingAfterSegmentationRidesTheEmittedEvent() async {
        openGate(enrolled: true)
        let collector = makeRecordingCollector()
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
        // A segment the engine closed has downstream stages still to run, so it is RELEASED by
        // finalization rather than by a second `speechCompleted`.
        collector.finalizeDeferredCompletion(context: ctx)

        let completed = snapshot().first { (event: VoiceSharingCollector.SegmentEvent) in
            event.captureID == ctx.id && event.kind == .completed
        }
        guard let completed else { return XCTFail("the completion was never emitted") }
        XCTAssertEqual(completed.reportedStages["wake"]?.state, "failed",
                       "a post-segmentation report must ride the emitted event")
        XCTAssertEqual(completed.reportedStages["wake"]?.reason, "detector_error")
    }

    private func makeChain(
        wake: WakeWordDetectorProtocol = DetectedWake(),
        wakeThreshold: Float = 0.8,
        claims: @escaping () -> [String: VoiceSharingContributionEncoder.StageOutcome]
    ) -> (engine: VoiceAsrEngine, sink: VoiceSharingDirectSink,
          backend: EngineStubBackend, grace: GracePeriodSignal) {
        let sink = VoiceSharingDirectSink(
            queue: queue, isEnabled: { true },
            encoderProvenance: { [self] in provenance }, observations: claims,
            requestUploadDrain: {})
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { [weak self] in self?.engineTestGateOpen ?? false },
            outcomeWaitLimit: .init(milliseconds: 60_000, ceilingMilliseconds: 60_000),
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.storeState.membership.enrollmentEpoch },
            sessionIdentity: { [weak self] in self?.engineStoreSession ?? "gen-A" },
            sink: { event in Task { await sink.handle(event) } })
        collector.deliversSynchronouslyForTesting = true
        sinkUnderTest = sink
        let backend = EngineStubBackend()
        let grace = GracePeriodSignal()
        let engine = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(silenceTimeoutMs: 60),
            backend: backend, signalFilter: SignalFilter(),
            wakeWordDetector: wake, gracePeriodSignal: grace,
            wakeThreshold: wakeThreshold, translationStage: nil)
        engine.contributionCollector = collector
        backend.engine = engine
        // PRODUCTION wiring: the service hands the capture to its routing consumer as part of the turn
        // (the real consumer reports and finalizes). A chain with no consumer would leave every capture
        // deferred forever — which no real path does.
        engine.onRoutingInputWithContext = { [weak collector] _, context in
            collector?.engineReported(
                stage: "execution",
                outcome: .init(state: "completed", reason: nil), context: context)
            collector?.finalizeDeferredCompletion(context: context)
            return true
        }
        engine.start()
        return (engine: engine, sink: sink, backend: backend, grace: grace)
    }

    private func diagnostic(
        _ entries: [VoiceSharingQueue.Entry],
        _ chain: (engine: VoiceAsrEngine, sink: VoiceSharingDirectSink,
                  backend: EngineStubBackend, grace: GracePeriodSignal)
    ) -> String {
        let states: [String] = entries.map { entry in
            let u = entry.url.appendingPathComponent("metadata.json")
            guard let e = try? JSONSerialization.jsonObject(with: Data(contentsOf: u), options: []) as? [String: Any],
                let o = (e["observations"] as? [String: Any]) else {
                return "no-record"
            }
            let cid = (e["capture_id"] as? String) ?? "?"
            let wakeDecision = (o["wake"] as? [String: Any])?["decision"] as? String ?? "-"
            return "\(cid.prefix(8)) wake=\(wakeDecision) "
                + o.map { "\($0.key):\((($0.value as? [String: Any])?["state"] as? String) ?? "?")" }
                .sorted().joined(separator: ",")
        }
        return "entries=\(entries.count) transcribe=\(chain.backend.transcribeCalls) states=\(states)"
    }

    private func wakeStates(_ entries: [VoiceSharingQueue.Entry]) -> [String] {
        entries.compactMap { entry in
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            guard let envelope = try? JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any],
                let wake = (envelope["observations"] as? [String: Any])?["wake"] as? [String: Any] else {
                return nil
            }
            return "\(wake["state"] as? String ?? "?")/\(wake["reason"] as? String ?? "-")"
        }
    }

    private func waitForReadyEntries(_ count: Int, timeout: TimeInterval = 5) async -> [VoiceSharingQueue.Entry] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ready = await queue.entries()
            if ready.count >= count { return ready }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return await queue.entries()
    }

    /// THE control: speech driven through the real engine's capture callback becomes a durable ready
    /// entry, and the record inside it carries the unknown/observation_unavailable pair.
    func test_theRealEnginePipelineReachesTheDurableQueueWithTheUnobservedPair() async throws {
        openGate(enrolled: true)
        // The caller claims wake was not run. The engine, however, delivers real speech frames for this
        // capture and reports so — the record must carry the ENGINE's observation, not the caller's claim.
        // This is the provenance control: a claim cannot overwrite a real observation.
        let chain = makeChain(claims: { [self] in
            var callerClaims = claims
            callerClaims["wake"] = .init(state: "not_run", reason: "no_wake_detected")
            return callerClaims
        })
        // A wake-triggered continuous capture: speech, then the silence that closes the utterance (the
        // segmenter ends a segment on silence — without it nothing is ever emitted).
        chain.engine.listeningMode = .continuous
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let ready = await waitForReadyEntries(1)
        XCTAssertGreaterThanOrEqual(ready.count, 1,
                       "the real engine's observer must produce a durable ready entry, not just a callback")
        // ANTI-VACUITY: the entry must be produced by a real capture, and its record must actually carry
        // the unknown/observation_unavailable pair — not merely "some entry exists".
        let entries = await queue.entries()
        guard !entries.isEmpty else { return XCTFail("a ready entry is required") }
        // The pipeline can emit more than one record (a segment the wake rejected, then a completed one).
        // Inspect the one that carried the engine's wake report.
        var examined: [String: Any]?
        for entry in entries {
            let metadataURL = entry.url
                .appendingPathComponent("metadata.json")
            let record = try JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL), options: []) as? [String: Any]
            let candidate = record?["observations"] as? [String: Any]
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
        // PROVENANCE: the caller said wake=not_run; the engine delivered frames for this
        // capture, so the stored record must say completed. If the sink ignored `reportedStages`, this
        // would read not_run and the assertion would fail.
        let wake = observations["wake"] as? [String: Any]
        XCTAssertEqual(wake?["state"] as? String, "completed",
                       "an engine-reported observation must override a caller's claim")
    }
    // MARK: - PHASE 2 DURABLE output
    //
    // The controls above in `VoiceSharingProductionPathControls` stop at the emitted event. These do not:
    // every one drives the REAL engine's capture callback into the PRODUCTION sink, and then reads the
    // metadata bytes of a READY queue entry off disk, binds them through the production record binding,
    // and asserts on the decoded record. What is asserted is what a server would receive.
    //
    // Each control states which producer state it sets, and every one requires an entry to EXIST: a test
    // that silently examines nothing when the pipeline drops the capture would prove nothing.

    /// Reads every READY entry's `metadata.json` off disk and returns the decoded RECORD objects, keyed by
    /// capture id. Fails the calling control if the queue is not ready or an entry will not bind — an
    /// unbindable record is not a record the server would accept, so it cannot count as evidence.
    private func durableRecords(_ file: StaticString = #filePath, line: UInt = #line) async throws
        -> [String: [String: Any]] {
        let entries = await queue.entries()
        var records: [String: [String: Any]] = [:]
        for entry in entries {
            let directory = entry.url
            let metadata = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
            let audio = try Data(contentsOf: directory.appendingPathComponent("audio.wav"))
            _ = audio
            // Plain JSON: the metadata object IS the record the server validates.
            let record = try XCTUnwrap(
                JSONSerialization.jsonObject(with: metadata) as? [String: Any],
                "the entry's metadata is a JSON object", file: file, line: line)
            let captureID = try XCTUnwrap(record["capture_id"] as? String,
                                          "the record names its capture", file: file, line: line)
            records[captureID] = record
        }
        return records
    }

    /// Durable records that appeared after this control started looking.
    ///
    /// Identity is the only safe filter here. Other controls in this class publish synthetic records
    /// through the same queue, and several reuse ONE fixed capture UUID — so selecting "the record with
    /// asr reason X" silently picked a fixture whose `wake_required` is the default, which made a
    /// grace control fail while passing in isolation. Each control calls this once before driving audio,
    /// and only captures not already present are considered its own.
    private func recordWatermark() async -> Set<String> {
        Set(await queue.entries().map { $0.name })
    }

    private func durableRecordsSince(_ watermark: Set<String>, _ file: StaticString = #filePath,
                                     line: UInt = #line) async throws -> [[String: Any]] {
        let records = try await durableRecords(file, line: line)
        // Delivery reaches the sink on a task, so the record may land just after the engine returns.
        // Waiting here keeps a real gap (nothing ever arrives) failing the control below.
        var entries = await queue.entries()
        var fresh = Set(entries.map { $0.name }).subtracting(watermark)
        let deadline = Date().addingTimeInterval(5)
        while fresh.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            entries = await queue.entries()
            fresh = Set(entries.map { $0.name }).subtracting(watermark)
        }
        XCTAssertFalse(fresh.isEmpty,
                       "the capture this control drove must reach a durable entry", file: file, line: line)
        var mine: [[String: Any]] = []
        for entry in entries where fresh.contains(entry.name) {
            let directory = entry.url
            let metadata = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
            _ = try Data(contentsOf: directory.appendingPathComponent("audio.wav"))
            // Plain JSON: the record IS the metadata object, with no envelope around it.
            mine.append(try XCTUnwrap(
                JSONSerialization.jsonObject(with: metadata) as? [String: Any]))
        }
        XCTAssertFalse(mine.isEmpty, "a fresh entry decodes to a record", file: file, line: line)
        return mine
    }

    /// WAKE required, ON DISK. Wake-word mode with no grace: the speech that began needed a wake word, and
    /// the durable record says so at the root. The detector's measured score and threshold are asserted by
    /// VALUE (not merely present), so a swapped or scale-broken measurement fails here.
    func test_durableRecordSaysWakeRequiredWhenSpeechBeganWithoutGrace() async throws {
        openGate(enrolled: true)
        // A NON-DEFAULT threshold (the engine's default is 0.8): a record that echoed a constant, or the
        // default, would not match, so this distinguishes what the engine was actually configured with.
        let configuredThreshold: Float = 0.62
        let chain = makeChain(wake: DetectedWake(), wakeThreshold: configuredThreshold,
                              claims: { [self] in claims })
        chain.engine.listeningMode = .wakeWord
        let watermark = await recordWatermark()
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let freshRecords = try await durableRecordsSince(watermark)
        let record = try XCTUnwrap(freshRecords.first)
        XCTAssertEqual(record["wake_required"] as? Bool, true,
                       "wake-word mode without grace: the speech needed a wake word")
        let wake = try XCTUnwrap((record["observations"] as? [String: Any])?["wake"] as? [String: Any])
        // SERVER schema (GO review): the REAL producer states its wake decision on every completed
        // wake stage — not only the hand-built fixtures. A detected wake says "detected".
        XCTAssertEqual(wake["decision"] as? String, "detected",
                       "the engine's own completed wake stage must carry its decision")
        // The stub detector reports 0.95 confidence; the engine compares it to its own configured threshold.
        XCTAssertEqual(try XCTUnwrap(wake["score"] as? Double), 0.95, accuracy: 0.0001,
                       "the durable record carries the detector's MEASURED score")
        let threshold = try XCTUnwrap(wake["threshold"] as? Double,
                                      "the threshold the score was judged against is recorded with it")
        XCTAssertEqual(threshold, Double(configuredThreshold), accuracy: 0.0001,
                       "the durable record carries the threshold the engine was CONFIGURED with, not a constant")
    }

    /// GRACE, ON DISK. Same engine, same detector, grace active: no wake word was required, and the durable
    /// record says so. Paired with the control above, this is the both-states requirement measured on bytes
    /// rather than on an in-memory event.
    func test_durableRecordSaysWakeNotRequiredWhenSpeechBeganUnderGrace() async throws {
        openGate(enrolled: true)
        // A detector that did NOT fire: under grace the segment is forwarded anyway, and the record
        // must state the negative verdict the detector actually reached.
        let chain = makeChain(wake: NotDetectedWake(), claims: { [self] in claims })
        chain.engine.listeningMode = .wakeWord
        // The production entry that opens a window; the engine reads `isActive` at segment start.
        chain.grace.onWakeWordDetected()
        let watermark = await recordWatermark()
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let freshRecords = try await durableRecordsSince(watermark)
        let record = try XCTUnwrap(freshRecords.first)
        XCTAssertEqual(record["wake_required"] as? Bool, false,
                       "grace is active: the speech did not need a wake word")
        let graceWake = try XCTUnwrap((record["observations"] as? [String: Any])?["wake"] as? [String: Any],
                        "the detector still ran, so its measurement is still recorded")
        // The forwarded NEGATIVE wake is still a decision: the schema's "rejected".
        XCTAssertEqual(graceWake["decision"] as? String, "rejected",
                       "a forwarded negative wake is a rejected decision, stated by the real producer")
    }

    /// THE combined utterance, ON DISK: "Auris, <command>" in one breath. The wake word is part of the
    /// utterance, so the record must carry both the wake the detector measured AND the transcript the
    /// recogniser produced — the two facts a server needs to tell a command from a false trigger.
    func test_durableRecordCarriesBothTheWakeAndTheCommandFromOneUtterance() async throws {
        openGate(enrolled: true)
        let chain = makeChain(wake: DetectedWake(), claims: { [self] in claims })
        chain.engine.listeningMode = .wakeWord
        chain.backend.stubTranscript = "Auris play the news"
        chain.backend.stubLanguage = "en"
        let watermark = await recordWatermark()
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let commanded = try await durableRecordsSince(watermark).filter {
            let asr = ($0["observations"] as? [String: Any])?["asr"] as? [String: Any]
            return (asr?["text"] as? String)?.contains("play the news") == true
        }
        XCTAssertEqual(commanded.count, 1, "one durable record carries the recognised command")
        let record = try XCTUnwrap(commanded.first)
        // BOTH facts on the SAME record: the wake that let the utterance through, and the command in it.
        XCTAssertEqual(record["wake_required"] as? Bool, true)
        let wake = try XCTUnwrap((record["observations"] as? [String: Any])?["wake"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(wake["score"] as? Double), 0.95, accuracy: 0.0001)
        let asr = try XCTUnwrap((record["observations"] as? [String: Any])?["asr"] as? [String: Any])
        XCTAssertEqual(asr["state"] as? String, "completed")
        XCTAssertEqual(asr["text"] as? String, "Auris play the news",
                       "the command text reaches the durable record")
        XCTAssertEqual(asr["source_language"] as? String, "en")
    }

    /// GENUINELY empty, ON DISK. The recogniser heard speech and returned nothing but DID report a language.
    /// The durable record must be `completed`/`empty_result` with NO text, and must KEEP the language — the
    /// producer defect the reviewer found, asserted at the far end of the pipeline instead of at its source.
    func test_durableRecordForAnEmptyResultKeepsTheRecognizerLanguageAndNoText() async throws {
        openGate(enrolled: true)
        let chain = makeChain(wake: DetectedWake(), claims: { [self] in claims })
        chain.engine.listeningMode = .wakeWord
        chain.backend.stubTranscript = ""
        chain.backend.stubLanguage = "ja"
        let watermark = await recordWatermark()
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let freshRecords = try await durableRecordsSince(watermark)
        let record = try XCTUnwrap(freshRecords.first)
        let asr = try XCTUnwrap((record["observations"] as? [String: Any])?["asr"] as? [String: Any])
        XCTAssertEqual(asr["state"] as? String, "completed",
                       "an empty recognition is a result, not a missing observation")
        XCTAssertNil(asr["text"], "an empty result carries no transcript")
        XCTAssertEqual(asr["source_language"] as? String, "ja",
                       "the language the recogniser reported survives an empty transcript, on disk")
    }

    /// NON-CONTENT output, ON DISK. The recogniser returns punctuation only. That is not a command, so no
    /// router input may be recorded, but it IS a completed recognition and its language and text belong in
    /// the record. The server's contract for a non-content result is what is checked here, in bytes.
    func test_durableRecordForNonContentOutputRecordsNoCommandInput() async throws {
        openGate(enrolled: true)
        let chain = makeChain(wake: DetectedWake(), claims: { [self] in claims })
        chain.engine.listeningMode = .wakeWord
        chain.backend.stubTranscript = "?!"
        chain.backend.stubLanguage = "en"
        let watermark = await recordWatermark()
        await chain.backend.emitSpeechThenSilence(
            level: 0.6, speechSamples: 20 * 160, silenceSamples: 20 * 160)

        let matching = try await durableRecordsSince(watermark).filter {
            (($0["observations"] as? [String: Any])?["asr"] as? [String: Any])?["text"] as? String == "?!"
        }
        XCTAssertEqual(matching.count, 1, "the non-content transcription reaches exactly one durable record")
        let record = try XCTUnwrap(matching.first)
        let asr = try XCTUnwrap((record["observations"] as? [String: Any])?["asr"] as? [String: Any])
        XCTAssertEqual(asr["state"] as? String, "completed")
        XCTAssertNil(asr["router_input"],
                     "punctuation is not a command, so no router input may be recorded")
        XCTAssertEqual(asr["source_language"] as? String, "en")
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

/// Actual engine invocation callbacks → capture snapshot → canonical durable queue records.
final class VoiceSharingModelProvenanceTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingQueue!
    private var sink: VoiceSharingDirectSink!
    private let pcm = [Float](repeating: 0.1, count: 640)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("model-provenance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingQueue(root: root)
    }

    override func tearDownWithError() throws {
        sink = nil
        queue = nil
        try FileManager.default.removeItem(at: root)
    }

    private final class Scheduler {
        var now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        var work: [(DispatchTime, DispatchWorkItem)] = []
        func fire() {
            let pending = work
            work.removeAll()
            for (time, item) in pending { now = time; item.perform() }
        }
    }

    private func collector(_ scheduler: Scheduler = Scheduler()) -> VoiceSharingCollector {
        var membership = VoiceSharingEnrollmentStore.State()
        membership.localOptIn = true
        membership.hasAuthoritativeProjection = true
        membership.membership = VoiceSharingMembership(
            membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
            enrollmentEpoch: "epoch", acceptedDisclosureVersion: "synthetic", withdrawalState: .active)
        let latest = VoiceSharingContributionEncoder.ModelRef(id: "encode-time-global", version: "B")
        let provenance = VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "test", build: "1", captureSessionID: "session",
            models: .init(vad: latest, wakeword: latest, asr: latest, translation: latest, router: latest), conversionVersion: "v1")
        let sink = VoiceSharingDirectSink(
            queue: queue, isEnabled: { true }, encoderProvenance: { provenance },
            requestUploadDrain: {})
        self.sink = sink
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { true }, outcomeWaitLimit: .init(milliseconds: 25, ceilingMilliseconds: 100),
            monotonicNow: { scheduler.now }, scheduleOutcome: { scheduler.work.append(($0, $1)) },
            membership: { membership }, epochProvider: { "epoch" }, sessionIdentity: { "session" }, sink: { event in Task { await sink.handle(event) } })
        collector.deliversSynchronouslyForTesting = true
        return collector
    }

    private func begin(_ collector: VoiceSharingCollector) throws -> VoiceSharingCollector.CaptureContext {
        let context = try XCTUnwrap(collector.speechStarted(confirmationFrameSamples: pcm.count))
        collector.appendSamples(pcm, reportedTotal: pcm.count)
        collector.segmentationEnded(context)
        return context
    }

    /// Records currently on disk, after a bounded wait for the sink's own task to land. Delivery to
    /// the sink resumes on a task, so reading immediately races the write it was asked to perform.
    /// When a capture is named, the wait targets THAT record: a queue that already holds an earlier
    /// record is not proof this one has been written.
    private func records(awaiting capture: UUID? = nil) async throws -> [String: Data] {
        let deadline = Date().addingTimeInterval(2)
        var entries = await queue.entries()
        func hasTarget() -> Bool {
            guard let capture else { return !entries.isEmpty }
            return entries.contains { (try? Data(contentsOf: $0.metadataURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["capture_id"] as? String } == capture.uuidString }
        }
        while !hasTarget(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            entries = await queue.entries()
        }
        var records: [String: Data] = [:]
        for entry in entries {
            // A half-written folder is not a record yet.
            guard let data = try? Data(contentsOf: entry.metadataURL),
                  let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let captureID = record["capture_id"] as? String else { continue }
            XCTAssertNil(records.updateValue(data, forKey: captureID), "one immutable record per capture")
        }
        return records
    }

    private func models(_ data: Data) throws -> [String: Any] {
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(record["models"] as? [String: Any])
    }

    func test_heldEngineInvocationKeepsLoadedAAtDeadlineAndSuccessorUsesB() async throws {
        let scheduler = Scheduler()
        let collector = collector(scheduler)
        let entered = expectation(description: "A's actual ASR invocation is held")
        let backend = InvocationBackend(entered: entered)
        defer { backend.releaseHeld() }
        let engine = VoiceAsrEngine(capture: NativeAudioCapture(), segmenter: NativeVadSegmenter(),
                                    backend: backend, signalFilter: SignalFilter(), wakeWordDetector: IdentityWake(),
                                    gracePeriodSignal: GracePeriodSignal(), translationStage: nil)
        engine.contributionCollector = collector
        let a = try begin(collector)
        let pending = Task { await engine.processUtterance(pcm, frozenContext: a) }
        await fulfillment(of: [entered], timeout: 2)
        backend.replaceIdentity(.init(id: "asr", version: "B"))
        scheduler.fire()
        let heldRecords = try await records(awaiting: a.id)
        let whileHeld = heldRecords[a.id.uuidString]
        let b = try begin(collector)
        await engine.processUtterance(pcm, frozenContext: b)
        backend.releaseHeld()
        await pending.value
        let final = try await records(awaiting: b.id)
        let frozen = try XCTUnwrap(whileHeld, "deadline must publish while real engine work remains held")
        XCTAssertEqual(final[a.id.uuidString], frozen, "late A cannot rewrite or duplicate its deadline winner")
        XCTAssertEqual(final.count, 2)
        let aModels = try models(frozen)
        let bModels = try models(XCTUnwrap(final[b.id.uuidString]))
        XCTAssertEqual((aModels["asr"] as? [String: String])?["version"], "A")
        XCTAssertEqual((bModels["asr"] as? [String: String])?["version"], "B")
        XCTAssertEqual((aModels["translation"] as? [String: String])?["version"], "A")
        XCTAssertEqual((aModels["wakeword"] as? [String: String])?["version"], "wake-A")
        XCTAssertTrue(aModels["vad"] is NSNull, "unknown frontend cannot inherit an encode-time global")
        XCTAssertTrue(aModels["router"] is NSNull, "unused router remains null")
    }

    func test_conflictingAndUnknownInvocationsCannotBecomeASingleVersionClaim() async throws {
        let collector = collector()
        let invocations: [VoiceSharingContributionEncoder.ModelRef?] = [.init(id: "asr", version: "A"), nil]
        for first in invocations {
            let context = try begin(collector)
            collector.engineUsedModel(slot: "asr", reference: first, context: context)
            collector.engineUsedModel(slot: "asr", reference: .init(id: "asr", version: "B"), context: context)
            collector.engineUsedModel(slot: "asr", reference: first, context: context)
            collector.speechCompleted(pcm, context: context, deferEmission: true)
            collector.finalizeDeferredCompletion(context: context)
            let allRecords = try await records(awaiting: context.id)
            let data = try XCTUnwrap(allRecords[context.id.uuidString])
            let models = try models(data)
            XCTAssertTrue(models["asr"] is NSNull)
            XCTAssertTrue(models["translation"] is NSNull)
        }
    }

    func test_loadedAssetIdentityIsStableAcrossPathsAndChangesOnlyWithActualContent() async throws {
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        try Data("loaded-A".utf8).write(to: a)
        try Data("loaded-A".utf8).write(to: b)
        let result = await Task.detached {
            let first = LoadedModelAssets.load(id: "asr", assets: [("model.onnx", a)]) { !Thread.isMainThread }
            let same = LoadedModelAssets.load(id: "asr", assets: [("model.onnx", b)]) { true }
            try? Data("loaded-B".utf8).write(to: b)
            let next = LoadedModelAssets.load(id: "asr", assets: [("model.onnx", b)]) { true }
            return (first, same, next)
        }.value
        XCTAssertTrue(result.0.component)
        XCTAssertNotNil(result.0.identity)
        XCTAssertEqual(result.0.identity, result.1.identity, "absolute path is not part of content identity")
        XCTAssertNotEqual(result.0.identity, result.2.identity)
    }

    func test_mutatedOrUnreadableAssetsStayUnknownWithoutPreventingConstruction() async throws {
        let asset = root.appendingPathComponent("asset")
        try Data("before".utf8).write(to: asset)
        let result = await Task.detached {
            let mutated = LoadedModelAssets.load(id: "asr", assets: [("model.onnx", asset)]) {
                try? Data("after".utf8).write(to: asset)
                return "usable component"
            }
            let unknown = LoadedModelAssets.load(id: "asr", assets: [("missing.onnx", asset.appendingPathComponent("missing"))]) {
                "usable component"
            }
            return (mutated, unknown)
        }.value
        XCTAssertEqual(result.0.component, "usable component")
        XCTAssertEqual(result.1.component, "usable component")
        XCTAssertNil(result.0.identity)
        XCTAssertNil(result.1.identity)
    }

    func test_canaryTranslationClaimFollowsNativeDecoderLanguagePair() throws {
        XCTAssertEqual(getSherpaOnnxVersion(), "1.13.6", "task trace is pinned to the linked native runtime")
        for source in ["en", "de", "es", "fr"] {
            let config = sherpaOnnxOfflineCanaryModelConfig(srcLang: source, tgtLang: "en")
            XCTAssertEqual(String(cString: try XCTUnwrap(config.src_lang)), source)
            XCTAssertEqual(String(cString: try XCTUnwrap(config.tgt_lang)), "en")
            XCTAssertEqual(CanaryFlashBackend.performsTranslation(config), source != "en")
        }
    }

    func test_unloadedConcreteBackendsNeverClaimModelOrTranslationUse() async {
        let missing = root.appendingPathComponent("never-loaded").path
        let backends: [AsrBackend] = [SenseVoiceBackend(modelDir: missing), CanaryFlashBackend(modelDir: missing, srcLang: "de")]
        for backend in backends {
            let lock = NSLock()
            var reports: [(VoiceSharingContributionEncoder.ModelRef?, Bool)] = []
            let result = await backend.transcribe(samples: pcm, sampleRateHz: 16_000) { identity, translates in
                lock.withLock { reports.append((identity, translates)) }
            }
            let reported = lock.withLock { reports }
            XCTAssertEqual(reported.count, 1)
            XCTAssertNil(reported.first?.0)
            XCTAssertEqual(reported.first?.1, false)
            XCTAssertEqual(result.text, "")
        }
    }

    private final class InvocationBackend: AsrBackend {
        let capabilities = AsrCapabilities(languages: ["en"], canTranslateToEnglish: true, requiresHardwareAccel: false)
        let requiredModel = ModelSpec(id: "asr", files: [], targetDir: "unused")
        private let lock = NSLock()
        private var identity: VoiceSharingContributionEncoder.ModelRef? = .init(id: "asr", version: "A")
        private var calls = 0
        private var held: CheckedContinuation<AsrResult, Never>?
        private let entered: XCTestExpectation
        init(entered: XCTestExpectation) { self.entered = entered }
        func ensureReady() async -> Result<Void, Error> { .success(()) }
        func release() { releaseHeld() }
        func replaceIdentity(_ value: VoiceSharingContributionEncoder.ModelRef?) { lock.withLock { identity = value } }
        func releaseHeld() {
            let pending = lock.withLock { let value = held; held = nil; return value }
            pending?.resume(returning: .init(text: "", detectedLanguage: "de"))
        }
        func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
            await transcribe(samples: samples, sampleRateHz: sampleRateHz, modelUsed: { _, _ in })
        }
        func transcribe(samples: [Float], sampleRateHz: Int,
                        modelUsed: @escaping (VoiceSharingContributionEncoder.ModelRef?, Bool) -> Void) async -> AsrResult {
            let snapshot = lock.withLock { calls += 1; return (identity, calls == 1) }
            modelUsed(snapshot.0, true)
            if snapshot.1 {
                return await withCheckedContinuation { continuation in
                    lock.withLock { held = continuation }
                    entered.fulfill()
                }
            }
            return .init(text: "", detectedLanguage: "de")
        }
    }

    private final class IdentityWake: WakeWordDetectorProtocol {
        func detect(samples: [Float], sampleRate: Int) -> WakeWordResult { .detected(confidence: 0.95, completionSample: 0) }
        func detect(samples: [Float], sampleRate: Int,
                    modelUsed: (VoiceSharingContributionEncoder.ModelRef?) -> Void) -> WakeWordResult {
            modelUsed(.init(id: "auris", version: "wake-A"))
            return detect(samples: samples, sampleRate: sampleRate)
        }
        func release() {}
    }

}

private final class AdmissionSilentCapture: NativeAudioCapture {
    override func start() throws {}
    override func stop() {}
}
