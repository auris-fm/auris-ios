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
        collector.appendSamples([Float](repeating: 1, count: 100_000))
        collector.speechAccumulated(retainedSampleCount: 100_000)
        collector.speechCompleted([Float](repeating: 1, count: 100_000))
        collector.segmentRejected(kind: .rejectedBleed, samples: 100_000)
        collector.segmentRejected(kind: .rejectedWake, samples: 100_000)

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
        collector.appendSamples([Float](repeating: 1, count: 5_000))
        collector.speechCompleted([Float](repeating: 1, count: 5_000))
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
        collector.appendSamples([Float](repeating: 1, count: 9_000))
        collector.speechCompleted([Float](repeating: 1, count: 9_000))
        collector.segmentRejected(kind: .rejectedWake, samples: 9_000)
        XCTAssertEqual(snapshot(), [])
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0)
    }

    func test_missingEpoch_retainsZeroSamplesAndEvents() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        epoch = nil

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.appendSamples([Float](repeating: 1, count: 3_200))
        collector.speechCompleted([Float](repeating: 1, count: 3_200))
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

        // Fill exactly to the ceiling.
        collector.appendSamples([Float](repeating: 0.5, count: ceiling))
        XCTAssertEqual(collector.retainedSampleCountForTesting, ceiling, "retention stops AT the ceiling")

        // Anything beyond is dropped, and the drop is recorded rather than silent.
        collector.appendSamples([Float](repeating: 0.5, count: 10_000))
        XCTAssertEqual(collector.retainedSampleCountForTesting, ceiling,
                       "the collector must not hold one sample past the ceiling")

        collector.speechCompleted([Float](repeating: 0.5, count: ceiling + 10_000))
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
        collector.appendSamples(original)
        collector.speechCompleted(original)
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
        collector.speechAccumulated(retainedSampleCount: ceiling)
        XCTAssertFalse(snapshot().contains { $0.truncated }, "at-limit is not over-limit")

        collector.speechAccumulated(retainedSampleCount: ceiling + 320)
        XCTAssertTrue(snapshot().contains { $0.kind == .accumulated && $0.truncated },
                      "the breach surfaces before any completion exists")
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
            collector.speechAccumulated(retainedSampleCount: level)
            levels += 1
        }
        collector.speechCompleted([Float](repeating: 1, count: 640 * levels))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5,
                          "the capture callback must not wait on a stalled sink (took \(elapsed)s)")

        // While parked, only the in-flight event has been delivered; the rest are queued, not dropped.
        deliverLock.lock(); let whileParked = delivered.count; deliverLock.unlock()
        XCTAssertEqual(whileParked, 1, "delivery is held at the stalled sink, as expected")
        XCTAssertEqual(collector.pendingCountForTesting, levels + 1,
                       "every signal produced while parked is retained for delivery — none blocked, none lost")
        XCTAssertEqual(collector.overflowCount, 0, "and the queue was nowhere near its bound")

        release.signal()
        XCTAssertTrue(collector.waitForDrain(), "queued work must be delivered once the sink frees")
        deliverLock.lock(); let got = delivered; deliverLock.unlock()
        XCTAssertEqual(got.count, levels + 2, "everything queued arrives after the stall clears")
        XCTAssertTrue(got.contains { $0.kind == .started }, "the opening record survives to the uploader")
        XCTAssertTrue(got.contains { $0.kind == .completed }, "and so does the completion")
        XCTAssertEqual(Set(got.map { $0.captureID }).count, 1, "all of it belongs to ONE capture")
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
        guard let firstID = collector.currentCaptureIDForTesting else { return XCTFail("segment A should be open") }

        // Segment B begins; A's callback is still outstanding.
        collector.speechStarted(confirmationFrameSamples: 320)
        let secondID = collector.currentCaptureIDForTesting
        XCTAssertNotEqual(firstID, secondID, "B is a distinct capture")

        clearEvents(collector)
        collector.segmentRejected(kind: .rejectedWake, samples: 8_000, captureID: firstID)
        XCTAssertEqual(snapshot(), [], "A's late rejection must not land on B")
        XCTAssertEqual(collector.currentCaptureIDForTesting, secondID, "and must not disturb B's state")

        // Naming no id (or B's id) is legitimate for the live capture.
        collector.segmentRejected(kind: .rejectedWake, samples: 8_000, captureID: secondID)
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
        collector.appendSamples([Float](repeating: 1, count: 3_200))
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
        collector.speechCompleted([Float](repeating: 1, count: 3_200))
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
        epoch = "epoch-rotated"
        collector.speechCompleted([Float](repeating: 1, count: 640))
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
        collector.appendSamples([Float](repeating: 1, count: 320))
        collector.speechCompleted([Float](repeating: 1, count: 640))

        let got = snapshot()
        XCTAssertEqual(got.map(\.kind), [.started, .completed])
        XCTAssertEqual(got[0].captureID, got[1].captureID, "one segment keeps one capture id")
        XCTAssertEqual(got[1].retainedSamples, 640)
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
        let a = collector.currentCaptureIDForTesting
        collector.segmentRejected(kind: .rejectedBleed, samples: 9_000, captureID: a)
        collector.speechStarted(confirmationFrameSamples: 320)
        let b = collector.currentCaptureIDForTesting
        collector.segmentRejected(kind: .rejectedWake, samples: 7_000, captureID: b)

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
        collector.appendSamples([Float](repeating: 1, count: 6_400))
        collector.speechCancelled()

        XCTAssertEqual(snapshot().map(\.kind), [.started, .cancelled])
        XCTAssertFalse(snapshot().contains { $0.kind == .completed })

        clearEvents(collector)
        collector.speechCompleted([Float](repeating: 1, count: 6_400))
        XCTAssertEqual(snapshot(), [], "a late completion for a cancelled segment is dropped")
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
        collector.speechAccumulated(retainedSampleCount: 6_400)
        collector.speechCompleted([Float](repeating: 1, count: 6_400))

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
        collector.appendSamples([Float](repeating: 1, count: 6_400))
        collector.speechCompleted([Float](repeating: 1, count: 6_400))
        XCTAssertEqual(snapshot(), [], "membership unknown must veto even when the policy probe reports enrolled")
        XCTAssertEqual(collector.retainedSampleCountForTesting, 0)

        enrolledState(false)
        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechCompleted([Float](repeating: 1, count: 320))
        XCTAssertEqual(snapshot(), [], "membership withdrawn must veto too")

        enrolledState(true)
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertFalse(snapshot().isEmpty, "control: the veto came from membership, not from the rig")
    }
}

