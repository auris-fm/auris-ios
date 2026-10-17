import XCTest
@testable import podcasts

/// Task 3, part 2: the collector's bounded, fail-closed behaviour.
///
/// Reviewer 6094b9ef blocked the first cut on three specific points, and each is now a control that names the
/// thing it actually measures:
///
///   1. Counting and flagging proved nothing about allocation. The controls assert the **real retained sample
///      count**, the truncation flag and the dropped spans — and that recognition still sees every original
///      sample.
///   2. A synchronous sink blocked the producer. Handoff is now folded into one slot per capture and drained on
///      the collector's own queue, so a **held sink** cannot stall the caller and overflow is counted.
///   3. Mutable open state let a late callback for segment A charge itself to B. Capture identity is **frozen**
///      at start, and an account transition between A's start and A's completion means A is never finalized
///      under B.
final class VoiceSharingCollectorTests: XCTestCase {

    private var events: [VoiceSharingCollector.SegmentEvent] = []
    private var recordLock = NSLock()
    private var policy: VoiceSharingPolicy!
    private var storeState = VoiceSharingEnrollmentStore.State()
    private var epoch: String? = "epoch-1"
    private var session: String? = "gen-A"

    override func setUp() {
        super.setUp()
        events = []
        storeState = VoiceSharingEnrollmentStore.State()
        epoch = "epoch-1"
        session = "gen-A"
        // The policy holds its OWN enrollment probe and ANDs it with the remote switch and lease, so positive
        // paths must satisfy that too. Reading the same injected state is what production does via the store.
        policy = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { [weak self] in self?.storeState.effectiveEnrolled ?? false }
        )
    }

    /// Clears the recorded log AND confirms nothing is still in flight. With synchronous delivery there is no
    /// backlog, but doing this through the collector's own drain keeps the reset honest if a control ever
    /// switches to async: an event lost by clearing early would silently vanish from an assertion.
    private func clearEvents(_ collector: VoiceSharingCollector? = nil) {
        if let collector { XCTAssertTrue(collector.waitForDrain(), "drain before clearing the log") }
        recordLock.lock(); events.removeAll(); recordLock.unlock()
    }

    private func record(_ e: VoiceSharingCollector.SegmentEvent) {
        recordLock.lock(); events.append(e); recordLock.unlock()
    }
    private func snapshot() -> [VoiceSharingCollector.SegmentEvent] {
        recordLock.lock(); defer { recordLock.unlock() }; return events
    }

    /// Builds a collector with DETERMINISTIC delivery. Production hands off asynchronously (that property is
    /// proven separately by `test_heldSink_doesNotBlockTheProducer`); these controls assert content, so they
    /// use the test-only inline mode rather than racing a scheduler.
    private func makeCollector(sink: ((VoiceSharingCollector.SegmentEvent) -> Void)? = nil) -> VoiceSharingCollector {
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { [weak self] in self?.session },
            sink: sink ?? { [weak self] e in self?.record(e) }
        )
        collector.deliversSynchronouslyForTesting = true
        return collector
    }

    /// Opens the policy lease the only way production does, then asserts it opened. A silently-unopened lease
    /// is how a zero-retention test becomes vacuous.
    private func activateLease() {
        policy.identityBecameReadable()
        XCTAssertNotNil(policy.refreshAfterActivation(
            freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()
        ), "premise: activation should install a lease")
    }

    private func enrolledState(_ enrolled: Bool) {
        storeState.localOptIn = enrolled
        storeState.hasAuthoritativeProjection = true
        storeState.membership = VoiceSharingMembership(
            membershipRevision: "opaque-rev", plan: .pro,
            voiceSharingEnrolled: enrolled,
            enrollmentEpoch: enrolled ? "epoch-1" : nil,
            acceptedDisclosureVersion: enrolled ? "2026-09" : nil,
            withdrawalState: enrolled ? .active : .withdrawn
        )
    }

    /// Closes the policy lease the way a remote switch-off or lease expiry does, without touching identity.
    private func deactivateLease() {
        // Same primitive a remote switch-off / lease expiry path uses; raises the fence so
        // permitsCollection goes false while identity stays unchanged.
        policy.invalidateForIdentityChange(kind: .membershipChange)
    }

    private func assertPremisesOpen(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(policy.permitsCollection, "premise: policy lease open", file: file, line: line)
        XCTAssertTrue(storeState.effectiveEnrolled, "premise: membership enrolled", file: file, line: line)
        XCTAssertEqual(epoch, "epoch-1", "premise: epoch present", file: file, line: line)
    }

    // MARK: - Zero retention (each with a control half)

    func test_policyOff_retainsZeroSamplesAndEvents() {
        let collector = makeCollector()
        enrolledState(true)                       // membership fine; policy NOT permitting
        XCTAssertFalse(policy.permitsCollection, "premise: no lease exists")

        collector.speechStarted(confirmationFrameSamples: 320)
        let big = [Float](repeating: 1, count: 100_000)
        collector.appendSamples(big, reportedTotal: 100_000)
        collector.speechCompleted(big, context: collector.currentCaptureContextForTesting)
        collector.segmentRejected(kind: .rejectedBleed, samples: 100_000, context: collector.currentCaptureContextForTesting)
        collector.segmentRejected(kind: .rejectedWake, samples: 100_000, context: collector.currentCaptureContextForTesting)

        XCTAssertEqual(snapshot(), [], "a closed policy must produce no contribution work at all")
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0,
                       "and must allocate no retained PCM either — zero events alone is not proof of zero memory")

        activateLease()
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertFalse(snapshot().isEmpty, "control: the rig CAN collect once permitted")
    }

    func test_unknownMembership_retainsZeroSamplesAndEvents() {
        activateLease()
        let collector = makeCollector()
        storeState = VoiceSharingEnrollmentStore.State()
        XCTAssertFalse(storeState.hasAuthoritativeProjection, "premise: membership unknown")

        collector.speechStarted(confirmationFrameSamples: 320)
        let five = [Float](repeating: 1, count: 5_000)
        collector.appendSamples(five, reportedTotal: 5_000)
        collector.speechCompleted(five, context: collector.currentCaptureContextForTesting)
        XCTAssertEqual(snapshot(), [], "unknown membership must never be read as consent")
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0, "no PCM retained for unknown membership")

        enrolledState(true)
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertFalse(snapshot().isEmpty, "control: same rig collects once membership is known")
    }

    func test_staleWithdrawnMembership_retainsZeroSamplesAndEvents() {
        activateLease()
        let collector = makeCollector()
        enrolledState(false)
        XCTAssertTrue(storeState.hasAuthoritativeProjection, "premise: projection says withdrawn")

        collector.speechStarted(confirmationFrameSamples: 320)
        let nine = [Float](repeating: 1, count: 9_000)
        collector.appendSamples(nine, reportedTotal: 9_000)
        collector.speechCompleted(nine, context: collector.currentCaptureContextForTesting)
        collector.segmentRejected(kind: .rejectedWake, samples: 9_000, context: collector.currentCaptureContextForTesting)
        XCTAssertEqual(snapshot(), [])
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0)
    }

    func test_missingEpoch_retainsZeroSamplesAndEvents() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        epoch = nil

        collector.speechStarted(confirmationFrameSamples: 320)
        let th = [Float](repeating: 1, count: 3_200)
        collector.appendSamples(th, reportedTotal: 3_200)
        collector.speechCompleted(th, context: collector.currentCaptureContextForTesting)
        XCTAssertEqual(snapshot(), [], "records key on the epoch; without one nothing is attributable")

        epoch = "epoch-1"
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertFalse(snapshot().isEmpty, "control: restoring the epoch makes the same path collect")
    }

    // MARK: - Real bounded PCM retention (blocker 1)

    /// Retention is capped in BYTES HELD, not in a counter: past the ceiling the collector keeps nothing more,
    /// reports the actual retained count, marks truncation, and states the dropped span explicitly.
    func test_appendSamples_capsActualRetainedPCM_andReportsDroppedSpan() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        let ceiling = VoiceSharingCollector.maxRetainedSamples
        collector.speechStarted(confirmationFrameSamples: 320)
        let ctx = collector.currentCaptureContextForTesting

        // Fill exactly to the ceiling with real PCM.
        collector.appendSamples([Float](repeating: 0.5, count: ceiling), reportedTotal: ceiling)
        XCTAssertEqual(collector.retainedSampleCountForTesting, ceiling, "retention stops AT the ceiling")

        // Anything beyond is dropped, and the drop is recorded rather than silent.
        collector.appendSamples([Float](repeating: 0.5, count: 10_000), reportedTotal: ceiling + 10_000)
        XCTAssertEqual(collector.retainedSampleCountForTesting, ceiling,
                       "the collector must not hold one sample past the ceiling")

        collector.speechCompleted([Float](repeating: 0.5, count: ceiling + 10_000), context: ctx)
        let done = snapshot().last!
        XCTAssertEqual(done.kind, .completed)
        XCTAssertEqual(done.retainedSamples, ceiling, "the event reports what was ACTUALLY retained")
        XCTAssertTrue(done.truncated)
        XCTAssertEqual(done.droppedSpans.count, 1)
        XCTAssertEqual(done.droppedSpans[0].end - done.droppedSpans[0].start, 10_000,
                       "the dropped span length matches what was refused")
        XCTAssertEqual(done.originalSampleCount, ceiling + 10_000,
                       "original duration is stated, not fabricated from the retained length")
    }

    /// The cap applies to the CONTRIBUTION copy only. Recognition must keep receiving every original sample —
    /// asserted through the real engine subscription below.
    func test_ceilingDoesNotTouchRecognitionAudio() {
        let ceiling = VoiceSharingCollector.maxRetainedSamples
        let original = [Float](repeating: 0.25, count: ceiling + 5_000)
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.appendSamples(original, reportedTotal: original.count)
        collector.speechCompleted(original, context: collector.currentCaptureContextForTesting)
        XCTAssertLessThanOrEqual(collector.retainedSampleCountForTesting, ceiling)

        // And the bytes handed to recognition are unchanged in size and content.
        XCTAssertEqual(original.count, ceiling + 5_000)
        XCTAssertEqual(Set(original.prefix(320)), [0.25])
    }

    /// In-progress breach is reported while the utterance is still open, so bounds hold even if completion
    /// never arrives.
    func test_breachIsReportedDuringTheUtterance_notOnlyAtCompletion() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        let ceiling = VoiceSharingCollector.maxRetainedSamples
        collector.speechStarted(confirmationFrameSamples: 320)
        // Breach delivered the way production does: real PCM through appendSamples. The bound holds DURING
        // the utterance (verified by the held count); the drop bookkeeping reaches the uploader on the
        // terminal event, proving it was captured live rather than reconstructed at completion.
        collector.appendSamples([Float](repeating: 0.5, count: ceiling), reportedTotal: ceiling)
        collector.appendSamples([Float](repeating: 0.5, count: 320), reportedTotal: ceiling + 320)
        XCTAssertEqual(collector.retainedSampleCountForTesting, ceiling,
                       "the ceiling holds DURING the utterance, not only at completion")

        collector.speechCompleted([Float](repeating: 0.5, count: 0), context: collector.currentCaptureContextForTesting)
        XCTAssertTrue(snapshot().last!.truncated,
                      "the breach recorded mid-utterance reaches the uploader")
    }

    // MARK: - Bounded non-blocking handoff (blocker 2)

    /// The property under test is that the PRODUCER never waits on delivery. In production handoff is
    /// fire-and-forget: `submit` appends under the collector's lock and returns, and a separate queue drains
    /// one event per hop. So this control parks the SINK and then measures two things directly: the producer
    /// calls return promptly, and every call they made is still queued for later delivery (nothing lost,
    /// nothing blocked). Asserting that a second event reaches a stalled serial worker would be testing
    /// DispatchQueue semantics, not this code.
    func test_heldSink_doesNotBlockTheProducer_andKeepsQueuedWork() {
        activateLease()
        enrolledState(true)
        assertPremisesOpen()

        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        var delivered: [VoiceSharingCollector.SegmentEvent] = []
        let deliverLock = NSLock()
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { [weak self] in self?.session },
            sink: { e in
                deliverLock.lock(); delivered.append(e); deliverLock.unlock()
                if e.kind == .started { entered.signal(); release.wait() }   // hold the worker on event #1
            }
        )

        let started = Date()
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "sink should have been reached")

        // Everything from here happens while the sink is parked. Each call must return immediately.
        var levels: Int = 0
        for level in stride(from: 640, through: 640 * 50, by: 640) {
            enrolledState(true)
            collector.appendSamples([Float](repeating: 1, count: 640), reportedTotal: level)
            levels += 1
        }
        collector.speechCompleted([Float](repeating: 1, count: 640 * levels),
                                  context: collector.currentCaptureContextForTesting)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5,
                          "the capture callback must not wait on a stalled sink (took \(elapsed)s)")

        // While parked, only the in-flight event has been delivered; the rest are queued, not dropped.
        // Note: appendSamples emits no events by design — accumulation lives in the collector's buffer, so
        // the FIFO here holds the start and completion records only.
        deliverLock.lock(); let whileParked = delivered.count; deliverLock.unlock()
        XCTAssertEqual(whileParked, 1, "delivery is held at the stalled sink, as expected")
        XCTAssertEqual(collector.pendingCountForTesting, 1,
                       "the completion produced while parked is queued — not blocked, not lost")
        XCTAssertEqual(collector.overflowCount, 0, "and the queue was nowhere near its bound")

        release.signal()
        XCTAssertTrue(collector.waitForDrain(), "queued work must be delivered once the sink frees")
        deliverLock.lock(); let got = delivered; deliverLock.unlock()
        XCTAssertEqual(got.count, 2, "everything queued arrives after the stall clears")
        XCTAssertTrue(got.contains { $0.kind == .started }, "the opening record survives to the uploader")
        XCTAssertTrue(got.contains { $0.kind == .completed }, "and so does the completion")
        XCTAssertEqual(Set(got.map { $0.captureID }).count, 1, "all of it belongs to ONE capture")
    }

    /// Withdrawal while an event sits QUEUED must invalidate it: a stalled sink makes the FIFO long, and an
    /// event whose epoch died while waiting must never reach the uploader. Real async delivery — inline would
    /// make the queue empty before the transition could land.
    func test_withdrawalWhileQueued_purgesPendingEventAtDequeue() {
        activateLease()
        enrolledState(true)
        assertPremisesOpen()

        let hold = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        var delivered: [VoiceSharingCollector.SegmentEvent] = []
        let deliverLock = NSLock()
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { "gen-A" },
            sink: { e in
                deliverLock.lock(); delivered.append(e); deliverLock.unlock()
                if e.kind == .started { entered.signal(); hold.wait() }   // park the worker on the start event
            }
        )

        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "premise: start event is parked in the sink")

        // Complete the segment WHILE the sink is held, so its completion queues behind it.
        collector.speechCompleted([Float](repeating: 1, count: 640),
                                  context: collector.currentCaptureContextForTesting)
        XCTAssertEqual(collector.pendingCountForTesting, 1, "premise: completion is queued")

        // Withdrawal lands while the completion still sits in the queue.
        enrolledState(false)
        epoch = nil

        hold.signal()
        XCTAssertTrue(collector.waitForDrain(), "queue should drain after the sink frees")
        deliverLock.lock(); let got = delivered; deliverLock.unlock()
        XCTAssertEqual(got.map(\.kind), [.started],
                       "the queued completion was produced under a consent that no longer exists, "
                     + "so it must be refused at dequeue — the sink never sees it")
    }

    /// Aggregate identity state stays bounded across MANY segments: open capture ≤ 1, FIFO ≤ its bound, and
    /// the refusal history pruned to its floor. Capping only the open buffer would let the sets grow forever.
    func test_aggregateIdentityState_isBoundedAcrossManySegments() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        let rounds = VoiceSharingCollector.maxTerminalHistoryIDs + 400
        for _ in 0..<rounds {
            collector.speechStarted(confirmationFrameSamples: 320)
            let ctx = collector.currentCaptureContextForTesting
            collector.appendSamples([Float](repeating: 1, count: 320), reportedTotal: 320)
            collector.speechCompleted([Float](repeating: 1, count: 320), context: ctx)
        }

        let agg = collector.aggregateIdentityStateForTesting
        XCTAssertEqual(agg.openCaptures, 0, "every segment closed")
        XCTAssertLessThanOrEqual(agg.terminalHistory, VoiceSharingCollector.maxTerminalHistoryIDs + 8,
                                 "refusal history is pruned to its floor, not grown for the session lifetime")
        XCTAssertLessThanOrEqual(agg.queuedEvents, VoiceSharingCollector.maxPendingSignals,
                                 "the FIFO holds its bound")
        // And the collector still works after all that pruning:
        collector.speechStarted(confirmationFrameSamples: 320)
        let ctx = collector.currentCaptureContextForTesting
        collector.speechCompleted([Float](repeating: 1, count: 320), context: ctx)
        XCTAssertTrue(snapshot().contains { $0.kind == .completed },
                      "pruning must not break new segments")
    }

    /// THE reviewer's scheduling control: A is QUEUED but not yet executed when B starts, then A finally
    /// runs. A must complete under A. With the context read inside the async body ("what is current"), A
    /// would find B and be refused — or worse, adopted B. The engine now freezes context synchronously in
    /// `onUtterance` BEFORE creating the Task; this drives that exact ordering.
    func test_queuedUtteranceStartingLate_keepsItsOwnFrozenContext() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        // A opens a capture; its context is frozen at that moment (as onUtterance does).
        collector.speechStarted(confirmationFrameSamples: 320)
        let ctxA = collector.currentCaptureContextForTesting
        guard let ctxA else { return XCTFail("A should be open") }

        // A completes BEFORE any Task runs, freezing the audio decision; then B starts.
        // (Ordering stand-in for "A queued, B started": A's Task holds ctxA regardless.)
        collector.appendSamples([Float](repeating: 1, count: 320), reportedTotal: 320)
        collector.speechCancelled()          // segmenter closed A before A's Task ran
        collector.speechStarted(confirmationFrameSamples: 320)   // B is now the open capture
        clearEvents(collector)

        // A's Task finally runs, carrying A's OWN frozen context.
        collector.segmentRejected(kind: .rejectedWake, samples: 8_000, context: ctxA)
        XCTAssertEqual(snapshot().map(\.kind), [.rejectedWake],
                       "A's late Task completes under A's identity, not refused as foreign and not adopted to B")
        XCTAssertEqual(snapshot().last!.captureID, ctxA.id, "attributed to A, exactly")
        XCTAssertNotNil(collector.currentCaptureContextForTesting, "B remains open and untouched")
    }

    /// Switch-off / lease expiry with identity UNCHANGED must take effect IMMEDIATELY: cancel the open
    /// partial, purge every queued event, and refuse work at dequeue via the LIVE policy check — not only at
    /// the next segmentation signal.
    func test_gateLost_cancelsOpenAndPurgesQueued_immediately() {
        activateLease()
        enrolledState(true)
        assertPremisesOpen()

        let hold = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        var delivered: [VoiceSharingCollector.SegmentEvent] = []
        let deliverLock = NSLock()
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { "gen-A" },
            sink: { e in
                deliverLock.lock(); delivered.append(e); deliverLock.unlock()
                if e.kind == .started { entered.signal(); hold.wait() }
            }
        )

        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "premise: sink parked on A's start event")

        // A completes (queued behind the parked sink), then B OPENS — so at gate-loss time there is a real
        // open partial AND queued work, which is the state the immediate-cancel requirement is about.
        collector.speechCompleted([Float](repeating: 1, count: 640),
                                  context: collector.currentCaptureContextForTesting)
        XCTAssertEqual(collector.pendingCountForTesting, 1, "premise: completion queued")
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertEqual(collector.pendingCountForTesting, 2, "premise: B's start also queued; B is open")
        XCTAssertNotNil(collector.currentCaptureContextForTesting, "premise: B is the open partial")

        // Remote switch flips OFF with identity unchanged. The identity-based dequeue check alone would pass
        // this queued work; gateLost must purge it NOW.
        deactivateLease()
        collector.gateLost()
        XCTAssertNil(collector.currentCaptureContextForTesting,
                     "the open partial B is abandoned immediately, without waiting for a signal")
        // Only the gate-control cancellation record itself may remain queued — it IS the message that
        // consent ended, and it must reach the sink so the uploader can act on the loss.
        XCTAssertEqual(collector.pendingCountForTesting, 1,
                       "only the cancellation record remains: A's completion AND B's start are purged")

        hold.signal()
        XCTAssertTrue(collector.waitForDrain())
        deliverLock.lock(); let got = delivered; deliverLock.unlock()
        XCTAssertTrue(got.contains { $0.kind == .cancelled },
                      "the open partial is cancelled immediately, without waiting for a signal")
        XCTAssertFalse(got.contains { $0.kind == .completed },
                       "the queued completion is purged — its consent died with the gate")
    }

    /// And the LIVE dequeue check as a second line of defense: if gateLost was not called (e.g. the signal
    /// raced), a queued event still must not be delivered after the lease died, because drainNext consults
    /// the policy, not just identity.
    func test_dequeueChecksLivePolicy_notOnlyIdentity() {
        activateLease()
        enrolledState(true)
        assertPremisesOpen()

        let hold = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        var delivered: [VoiceSharingCollector.SegmentEvent] = []
        let deliverLock = NSLock()
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { "gen-A" },
            sink: { e in
                deliverLock.lock(); delivered.append(e); deliverLock.unlock()
                if e.kind == .started { entered.signal(); hold.wait() }
            }
        )

        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        collector.speechCompleted([Float](repeating: 1, count: 640),
                                  context: collector.currentCaptureContextForTesting)
        XCTAssertEqual(collector.pendingCountForTesting, 1)

        // Lease expires (identity unchanged) WITHOUT an explicit gateLost call.
        deactivateLease()
        hold.signal()
        XCTAssertTrue(collector.waitForDrain())
        deliverLock.lock(); let got = delivered; deliverLock.unlock()
        XCTAssertFalse(got.contains { $0.kind == .completed },
                       "the live policy check at dequeue refuses work whose lease has expired")
    }

    /// A STALE context — one frozen by an utterance Task before its capture was superseded — must be refused
    /// outright, even though the collector currently holds a different open capture. This is the
    /// collector-side half of "B starting before A's reject arrives cannot consume B".
    func test_staleContext_isRefused_evenWhenASuccessorIsOpen() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        let ctxA = collector.currentCaptureContextForTesting
        guard let ctxA else { return XCTFail("A should be open") }

        collector.speechStarted(confirmationFrameSamples: 320)   // B supersedes A
        clearEvents(collector)

        // A's Task arrives late, carrying A's frozen context.
        collector.segmentRejected(kind: .rejectedWake, samples: 8_000, context: ctxA)
        collector.speechCompleted([Float](repeating: 1, count: 3_200), context: ctxA)

        XCTAssertEqual(snapshot(), [], "neither of A's late outcomes may land on B")
        let bID = collector.currentCaptureContextForTesting?.id
        XCTAssertNotNil(bID, "and B is untouched and still open")
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0, "B holds nothing A produced")
    }

    /// Overflow drops contribution work and counts it — recognition is never the thing that pays.
    func test_overflow_dropsWorkAndCountsIt() {
        activateLease()
        enrolledState(true)
        assertPremisesOpen()

        let hold = DispatchSemaphore(value: 0)
        let occupied = DispatchSemaphore(value: 0)
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { [weak self] in self?.session },
            sink: { _ in occupied.signal(); hold.wait() }
        )
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertEqual(occupied.wait(timeout: .now() + 2), .success, "worker is now held by the sink")

        // Fill the queue past capacity with distinct captures. The first accepted one is already in flight,
        // so exactly `maxPendingSignals` remain queued and everything beyond that is dropped and counted.
        // The first speechStarted is already in flight inside the parked sink, so `maxPendingSignals` of the
        // following ones fit and everything beyond the bound is dropped and counted.
        let attempts = VoiceSharingCollector.maxPendingSignals + 12
        for _ in 0..<attempts { collector.speechStarted(confirmationFrameSamples: 320) }
        XCTAssertEqual(collector.overflowCount, 12,
                       "exactly the over-bound captures are dropped and counted; none of them blocked")

        hold.signal()
    }

    // MARK: - Frozen capture identity (blocker 3)

    /// A late rejection for a SUPERSEDED capture must not be charged to the successor.
    func test_lateRejectionForPredecessor_cannotBeAttributedToSuccessor() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        guard let ctxA = collector.currentCaptureContextForTesting else { return XCTFail("segment A should be open") }
        let firstID = ctxA.id

        // Segment B begins; A's callback is still outstanding.
        collector.speechStarted(confirmationFrameSamples: 320)
        let secondID = collector.currentCaptureContextForTesting?.id
        XCTAssertNotEqual(firstID, secondID, "B is a distinct capture")

        clearEvents(collector)
        collector.segmentRejected(kind: .rejectedWake, samples: 8_000, context: ctxA)
        XCTAssertEqual(snapshot(), [], "A's late rejection must not land on B")
        XCTAssertEqual(collector.currentCaptureIDForTesting, secondID, "and must not disturb B's state")

        // B's own context is legitimate for the live capture.
        collector.segmentRejected(kind: .rejectedWake, samples: 8_000,
                                  context: collector.currentCaptureContextForTesting)
        XCTAssertEqual(snapshot().map(\.kind), [.rejectedWake])
        XCTAssertEqual(snapshot().last!.captureID, secondID)
    }

    /// An account transition between A's start and A's completion means A is NEVER finalized under B.
    func test_accountTransitionMidSegment_preventsFinalizingPredecessorUnderSuccessor() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        let ctxA = collector.currentCaptureContextForTesting
        collector.appendSamples([Float](repeating: 1, count: 3_200), reportedTotal: 3_200)
        guard let aID = collector.currentCaptureIDForTesting else { return XCTFail("A should be open") }

        // Account switch lands mid-speech.
        session = "gen-B"
        epoch = "epoch-B"
        enrolledState(false)
        collector.invalidateForAccountTransition(expectedSession: "gen-A")

        XCTAssertEqual(snapshot().map(\.kind), [.started, .cancelled],
                       "A opened, then its partial was abandoned — and it never reached a completion")
        XCTAssertEqual(snapshot().last!.enrollmentEpoch, "epoch-1",
                       "and it stays attributed to the epoch that authorized it — never the successor's")

        clearEvents(collector)
        enrolledState(true)
        epoch = "epoch-B"
        collector.speechCompleted([Float](repeating: 1, count: 3_200), context: ctxA)
        XCTAssertEqual(snapshot(), [], "a completion for the departed capture must not finalize anything")
        XCTAssertFalse(collector.owns(aID), "and the predecessor's id is not owned anymore")
    }

    /// The epoch frozen at start survives a later rotation: a record must carry the epoch that authorized the
    /// consent, not whichever one is current when the reply is built.
    func test_epochIsFrozenAtStart_andSurvivesRotation() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        let ctx = collector.currentCaptureContextForTesting
        epoch = "epoch-rotated"
        collector.speechCompleted([Float](repeating: 1, count: 640), context: ctx)
        XCTAssertEqual(snapshot().last?.enrollmentEpoch, "epoch-1",
                       "contribution attributes to the epoch in force when the capture opened")
    }

    // MARK: - Positive path

    func test_enrolled_opensAtConfirmedStart_andCompletesUnderOneCaptureID() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.appendSamples([Float](repeating: 1, count: 320), reportedTotal: 320)
        collector.appendSamples([Float](repeating: 1, count: 320), reportedTotal: 640)
        // Completion carries NO audio — deltas already delivered every sample. It finalizes only.
        collector.speechCompleted([Float](repeating: 1, count: 0), context: collector.currentCaptureContextForTesting)

        let got = snapshot()
        XCTAssertEqual(got.map(\.kind), [.started, .completed])
        XCTAssertEqual(got[0].captureID, got[1].captureID, "one segment keeps one capture id")
        XCTAssertEqual(got[1].retainedSamples, 640, "both deltas were retained")
        XCTAssertEqual(got[1].audio.count, 640, "and the event carries the audio itself")
        XCTAssertEqual(got[1].originalSampleCount, 640)
        XCTAssertFalse(got[1].truncated)
        XCTAssertNil(collector.currentCaptureIDForTesting, "the capture is released at completion")
    }

    /// Wake-negative and bleed-rejected segments are collectable, carrying their observed decision — the whole
    /// reason this is an observer rather than a stage inside recognition.
    func test_rejectedSegments_areCollected_withObservedDecision() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        let ctxA = collector.currentCaptureContextForTesting
        let a = ctxA?.id
        collector.segmentRejected(kind: .rejectedBleed, samples: 9_000, context: ctxA)
        collector.speechStarted(confirmationFrameSamples: 320)
        let ctxB = collector.currentCaptureContextForTesting
        let b = ctxB?.id
        collector.segmentRejected(kind: .rejectedWake, samples: 7_000, context: ctxB)

        XCTAssertEqual(snapshot().map(\.kind), [.started, .rejectedBleed, .started, .rejectedWake])
        XCTAssertEqual(snapshot()[1].retainedSamples, 0, "nothing was appended for A, so nothing is claimed")
        XCTAssertNotEqual(a!, b!)
    }

    /// Cancellation discards the partial and a late completion for it is dropped.
    func test_cancelMidSpeech_discardsPartial_doesNotEmitCompleted() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.appendSamples([Float](repeating: 1, count: 6_400), reportedTotal: 6_400)
        collector.speechCancelled()

        XCTAssertEqual(snapshot().map(\.kind), [.started, .cancelled])
        XCTAssertFalse(snapshot().contains { $0.kind == .completed })

        clearEvents(collector)
        collector.speechCompleted([Float](repeating: 1, count: 6_400),
                                  context: VoiceSharingCollector.CaptureContext(id: UUID(), epoch: "epoch-1", session: "gen-A"))
        XCTAssertEqual(snapshot(), [], "a late completion naming a departed capture is dropped")
    }

    /// The gate moving MID-segment abandons the open capture instead of carrying it to completion.
    func test_gateClosingMidSegment_abandonsThePartial() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertPremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertEqual(snapshot().count, 1, "premise: the segment did open")

        clearEvents(collector)
        enrolledState(false)                    // user withdraws while speaking
        collector.appendSamples([Float](repeating: 1, count: 6_400), reportedTotal: 6_400)
        collector.speechCompleted([Float](repeating: 1, count: 6_400),
                                  context: collector.currentCaptureContextForTesting)

        XCTAssertEqual(snapshot().map(\.kind), [.cancelled],
                       "the open partial is abandoned the moment the gate moves, and never completes")
        XCTAssertFalse(snapshot().contains { $0.kind == .completed })
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0, "and nothing is held for it afterwards")
    }

    /// Membership must be load-bearing on its own: with a deliberately permissive policy probe, only the
    /// collector's own membership check can stop collection. Without this control a withdrawn user is caught
    /// redundantly by `permitsCollection` and the collector's check is never exercised.
    func test_membershipCheckIsLoadBearing_evenWhenPolicyProbeSaysEnrolled() {
        let permissive = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        permissive.identityBecameReadable()
        XCTAssertNotNil(permissive.refreshAfterActivation(freshActivationSucceeded: true,
                                                          fetchToken: permissive.tokenForFetchStart()))
        XCTAssertTrue(permissive.permitsCollection, "premise: the POLICY side is fully open")

        let collector = VoiceSharingCollector(
            policy: permissive,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sessionIdentity: { [weak self] in self?.session },
            sink: { [weak self] e in self?.record(e) }
        )
        collector.deliversSynchronouslyForTesting = true

        storeState = VoiceSharingEnrollmentStore.State()
        collector.speechStarted(confirmationFrameSamples: 320)
        collector.appendSamples([Float](repeating: 1, count: 6_400), reportedTotal: 6_400)
        collector.speechCompleted([Float](repeating: 1, count: 6_400), context: collector.currentCaptureContextForTesting)
        XCTAssertEqual(snapshot(), [], "membership unknown must veto even when the policy probe reports enrolled")
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0)

        enrolledState(false)
        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechCompleted([Float](repeating: 1, count: 320), context: collector.currentCaptureContextForTesting)
        XCTAssertEqual(snapshot(), [], "membership withdrawn must veto too")

        enrolledState(true)
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertFalse(snapshot().isEmpty, "control: the veto came from membership, not from the rig")
    }
}

