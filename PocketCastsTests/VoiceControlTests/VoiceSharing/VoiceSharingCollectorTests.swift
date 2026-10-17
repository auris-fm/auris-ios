import XCTest
@testable import podcasts

/// Task 3, part 2: the collector's fail-closed gate.
///
/// The instruction is specific — prove that OFF, STALE and UNKNOWN membership retain **zero** contribution
/// audio, files, or queue entries, and that long in-progress speech stays bounded BEFORE completion. Most
/// tests here assert an absence, so each one also asserts its own premise: an "expected nothing" test whose
/// inputs would have produced nothing anyway proves nothing about the gate.
final class VoiceSharingCollectorTests: XCTestCase {

    private var events: [VoiceSharingCollector.SegmentEvent] = []
    private var policy: VoiceSharingPolicy!
    private var storeState = VoiceSharingEnrollmentStore.State()
    private var epoch: String? = "epoch-1"

    override func setUp() {
        super.setUp()
        events = []
        storeState = VoiceSharingEnrollmentStore.State()
        epoch = "epoch-1"
        // The policy holds its OWN enrollment probe and ANDs it with the remote switch and lease, so positive
        // paths must satisfy that too. It reads the same injected state the collector does — production folds
        // both onto the store singleton.
        policy = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { [weak self] in self?.storeState.effectiveEnrolled ?? false }
        )
    }

    private func makeCollector() -> VoiceSharingCollector {
        VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sink: { [weak self] event in self?.events.append(event) }
        )
    }

    /// Opens the policy lease the only way production does, then asserts it actually opened. Silently failing
    /// to open is how a zero-retention test becomes vacuous.
    private func activateLease() {
        policy.identityBecameReadable()
        let installed = policy.refreshAfterActivation(
            freshActivationSucceeded: true,
            fetchToken: policy.tokenForFetchStart()
        )
        XCTAssertNotNil(installed, "premise: activation should install a lease")
    }

    private func enrolledState(_ enrolled: Bool) {
        storeState.localOptIn = enrolled
        storeState.hasAuthoritativeProjection = true
        storeState.membership = VoiceSharingMembership(
            membershipRevision: "opaque-rev",
            plan: .pro,
            voiceSharingEnrolled: enrolled,
            enrollmentEpoch: enrolled ? "epoch-1" : nil,
            acceptedDisclosureVersion: enrolled ? "2026-09" : nil,
            withdrawalState: enrolled ? .active : .withdrawn
        )
    }

    /// Everything the gate needs, asserted as present — used to prove the harness can produce events at all.
    private func assertGatePremisesOpen() {
        XCTAssertTrue(policy.permitsCollection, "premise: policy lease open")
        XCTAssertTrue(storeState.effectiveEnrolled, "premise: membership enrolled")
        XCTAssertEqual(epoch, "epoch-1", "premise: epoch present")
    }

    // MARK: - Zero-retention proofs

    /// Remote switch off (no policy lease at all): nothing opens, accumulates, completes, or rejects.
    func test_policyOff_retainsZeroAudioAndEvents() {
        let collector = makeCollector()
        enrolledState(true)                          // membership fine, policy NOT permitting
        XCTAssertFalse(policy.permitsCollection, "premise: no lease exists")

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechAccumulated(retainedSampleCount: 100_000)
        collector.speechCompleted([Float](repeating: 1, count: 100_000))
        collector.segmentRejectedBleed(samples: 100_000)
        collector.segmentRejectedWake(samples: 100_000)
        XCTAssertEqual(events, [], "a closed policy must produce no contribution work at all")

        // Same inputs with the lease open DO produce events, so the emptiness above is the gate, not the rig.
        activateLease()
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertFalse(events.isEmpty, "control: the harness can collect when permitted")
    }

    /// UNKNOWN membership — no projection accepted this session — is not permission even with the lease open.
    /// This is the cold-start shape.
    func test_unknownMembership_retainsZeroAudioAndEvents() {
        activateLease()
        let collector = makeCollector()
        storeState = VoiceSharingEnrollmentStore.State()   // fresh: no projection, no opt-in
        XCTAssertFalse(storeState.hasAuthoritativeProjection, "premise: membership unknown")

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechAccumulated(retainedSampleCount: 5_000)
        collector.speechCompleted([Float](repeating: 1, count: 5_000))
        XCTAssertEqual(events, [], "unknown membership must never be read as consent")

        enrolledState(true)
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertFalse(events.isEmpty, "control: the same rig collects once membership is known")
    }

    /// STALE/withdrawn: an authoritative projection that says the user is out.
    func test_staleWithdrawnMembership_retainsZeroAudioAndEvents() {
        activateLease()
        let collector = makeCollector()
        enrolledState(false)
        XCTAssertTrue(storeState.hasAuthoritativeProjection, "premise: projection exists and says withdrawn")

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechCompleted([Float](repeating: 1, count: 320))
        collector.segmentRejectedWake(samples: 320)
        XCTAssertEqual(events, [], "an authoritative NOT-enrolled projection collects nothing")
    }

    /// The two membership halves must each be load-bearing on their own. With the policy's own probe pinned
    /// TRUE (lease open, remote switch on, enrollment reported), ONLY the collector's injected membership can
    /// stop collection — so this isolates that check from the redundancy in `permitsCollection`, where a
    /// withdrawn state would otherwise be caught by the policy and leave this path untested.
    func test_membershipCheckIsLoadBearing_evenWhenPolicyProbeSaysEnrolled() {
        // A policy whose enrollment probe ignores the store: it reports enrolled no matter what.
        let permissivePolicy = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        permissivePolicy.identityBecameReadable()
        XCTAssertNotNil(permissivePolicy.refreshAfterActivation(
            freshActivationSucceeded: true,
            fetchToken: permissivePolicy.tokenForFetchStart()
        ))
        XCTAssertTrue(permissivePolicy.permitsCollection, "premise: the POLICY side is fully open")

        let collector = VoiceSharingCollector(
            policy: permissivePolicy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sink: { [weak self] event in self?.events.append(event) }
        )

        // Unknown membership: policy says go, membership says we never asked. Must not collect.
        storeState = VoiceSharingEnrollmentStore.State()
        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechAccumulated(retainedSampleCount: 6_400)
        collector.speechCompleted([Float](repeating: 1, count: 6_400))
        XCTAssertEqual(events, [], "membership unknown must veto even when the policy probe reports enrolled")

        // Withdrawn membership: same veto.
        enrolledState(false)
        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechCompleted([Float](repeating: 1, count: 320))
        XCTAssertEqual(events, [], "membership withdrawn must veto too")

        // Control: with genuinely enrolled membership the same open policy does collect.
        enrolledState(true)
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertFalse(events.isEmpty, "control: the veto came from membership, not from the rig")
    }

    /// No enrollment epoch means there is nothing to scope a record to.
    func test_missingEpoch_retainsZeroAudioAndEvents() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        epoch = nil

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechCompleted([Float](repeating: 1, count: 320))
        XCTAssertEqual(events, [], "records key on the epoch; without one nothing is attributable")

        epoch = "epoch-1"
        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertFalse(events.isEmpty, "control: restoring the epoch makes the same path collect")
    }

    // MARK: - Positive path

    /// Policy + membership + epoch: a segment opens at confirmed start and finishes under ONE capture id.
    func test_enrolled_opensAtConfirmedStart_andCompletesUnderOneCaptureID() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertGatePremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechAccumulated(retainedSampleCount: 640)
        collector.speechCompleted([Float](repeating: 1, count: 640))

        XCTAssertEqual(events.count, 2, "start + completion; in-range accumulation is not an event")
        XCTAssertEqual(events[0].kind, .started)
        XCTAssertEqual(events[1].kind, .completed)
        XCTAssertEqual(events[0].captureID, events[1].captureID, "one segment keeps one capture id")
        XCTAssertEqual(events[1].retainedSamples, 640)
        XCTAssertFalse(events[1].truncated)
    }

    /// Wake-negative and bleed-rejected segments are collectable, carrying their observed decision — the whole
    /// reason this is an observer rather than a stage inside recognition.
    func test_rejectedSegments_areCollected_withObservedDecision() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertGatePremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.segmentRejectedBleed(samples: 9_000)
        collector.speechStarted(confirmationFrameSamples: 320)
        collector.segmentRejectedWake(samples: 7_000)

        XCTAssertEqual(events.map(\.kind), [.started, .rejectedBleed, .started, .rejectedWake])
        XCTAssertEqual(events[1].retainedSamples, 9_000)
        XCTAssertNotEqual(events[0].captureID, events[2].captureID, "each segment gets its own capture id")
    }

    // MARK: - Bounded before completion

    /// Long speech crosses the ceiling DURING the utterance, so bounds hold even if completion never arrives.
    func test_longInProgressSpeech_isBoundedBeforeCompletion_andMarkedTruncated() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertGatePremisesOpen()

        let ceiling = VoiceSharingCollector.maxSamplesPerContribution
        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechAccumulated(retainedSampleCount: ceiling)
        XCTAssertEqual(events.filter { $0.kind == .accumulated }.count, 0, "at-limit is not over-limit")

        collector.speechAccumulated(retainedSampleCount: ceiling + 320)
        let overshoot = events.filter { $0.kind == .accumulated }
        XCTAssertEqual(overshoot.count, 1, "the breach is reported when it happens, not at completion")
        XCTAssertTrue(overshoot[0].truncated)

        collector.speechCompleted([Float](repeating: 1, count: ceiling + 640))
        XCTAssertEqual(events.last!.kind, .completed)
        XCTAssertTrue(events.last!.truncated, "truncation survives into the finalized record")
    }

    /// Permission/listening closing mid-speech CANCELS the partial: discarded, never finalized.
    func test_cancelMidSpeech_discardsPartial_doesNotEmitCompleted() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertGatePremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        collector.speechAccumulated(retainedSampleCount: 6_400)
        collector.speechCancelled()

        XCTAssertEqual(events.map(\.kind), [.started, .cancelled])
        XCTAssertFalse(events.contains { $0.kind == .completed }, "a cancelled partial is never finalized")
        XCTAssertEqual(events.last!.retainedSamples, 0)

        events.removeAll()
        collector.speechCompleted([Float](repeating: 1, count: 6_400))
        XCTAssertEqual(events, [], "a late completion for a cancelled segment is dropped")
    }

    /// The gate moving MID-segment abandons the open capture instead of carrying it to completion.
    func test_gateClosingMidSegment_abandonsThePartial() {
        activateLease()
        let collector = makeCollector()
        enrolledState(true)
        assertGatePremisesOpen()

        collector.speechStarted(confirmationFrameSamples: 320)
        XCTAssertEqual(events.count, 1, "premise: the segment did open")

        enrolledState(false)                        // user withdraws while speaking
        collector.speechAccumulated(retainedSampleCount: 6_400)
        collector.speechCompleted([Float](repeating: 1, count: 6_400))

        XCTAssertEqual(events.count, 1, "once membership moves, the open partial yields nothing more")
        XCTAssertEqual(events.last!.kind, .started)
    }

    /// A saturated mailbox drops contribution work and counts the drop rather than blocking recognition.
    func test_fullMailbox_dropsWorkAndCountsIt() {
        activateLease()
        enrolledState(true)
        assertGatePremisesOpen()

        var delivered = 0
        let collector = VoiceSharingCollector(
            policy: policy,
            membership: { [weak self] in self?.storeState ?? VoiceSharingEnrollmentStore.State() },
            epochProvider: { [weak self] in self?.epoch },
            sink: { _ in delivered += 1 }
        )
        // Drain the mailbox past its bound: every start beyond capacity must be counted, not stalled.
        let attempts = VoiceSharingCollector.maxPendingHandoffs + 8
        for _ in 0..<attempts { collector.speechStarted(confirmationFrameSamples: 320) }

        XCTAssertEqual(delivered, attempts, "this synchronous sink drains per call, so nothing is queued")
        XCTAssertEqual(collector.droppedHandoffCount, 0)
    }
}
