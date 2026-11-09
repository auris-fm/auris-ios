//
// VoiceSharingGateLossScopeControls.swift
// PocketCastsTests
//
// THE foreground drain was being cancelled by its own refresh (, live build measurement).
//
// Measured on the installed app: a foreground transition logged all three gates open and, 1 ms
// later, `gate lost (temporary) — durable queue RETAINED`, which calls `uploadTrigger?.stop()`.
// The membership-store observer fired that fan-out on every notification, so the ordinary
// projection refresh the foreground itself triggers cancelled the drain it had just started. 32
// retained recordings could never drain.
//
// These controls pin the corrected rule: the fan-out is for a CONSENT loss or an
// ACCOUNT replacement. A benign same-account projection must not stop anything.
//

import XCTest
import PocketCastsServer

@testable import podcasts

final class VoiceSharingGateLossScopeControls: XCTestCase {
    private var root: URL!
    private var store: VoiceSharingEnrollmentStore!
    private var previousUserId: String?
    private var previousEmail: String?

    override func setUp() {
        super.setUp()
        // SAVE the globals: this control drives the real store against a live
        // session, so it must put the user's account back exactly as it found it, not nil it.
        previousUserId = ServerSettings.userId
        previousEmail = ServerSettings.syncingEmail()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GateLossScope-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ServerSettings.userId = "acct-1"
        store = VoiceSharingEnrollmentStore(
            defaults: UserDefaults(suiteName: "GateLossScope-\(UUID().uuidString)")!,
            accountScopeProvider: { [weak self] in
                self?.consumeScopeSeam()
                return ServerSettings.userId ?? "signed-out"
            },
            sessionIdentityProvider: { ServerSettings.userId })
    }

    override func tearDown() {
        ServerSettings.userId = previousUserId
        ServerSettings.setSyncingEmail(email: previousEmail)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Drives the coordinator's PRODUCTION observer path by mutating the store, which is what the
    /// live app does when a projection lands. The control never calls the fan-out directly, so a
    /// regression in the observer's predicate is visible here.
    func test_aBenignSameAccountProjectionDoesNotStopTheDrain() async throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        var fanOuts = 0
        let subscription = coordinator.registerGateLostHandler { fanOuts += 1 }
        defer { _ = subscription }

        // Premise: consent is held, so any fan-out here is BY DEFINITION spurious.
        XCTAssertTrue(store.consentAllowsCollection, "premise: consent is held before the refresh")

        // THE benign event: a same-account projection refresh that changes nothing about consent —
        // exactly what a foreground refresh applies.
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-2", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        XCTAssertEqual(fanOuts, 0,
                       "a benign same-account projection must NOT fan out — that fan-out stops the "
                           + "drain the same foreground event started")
        XCTAssertTrue(store.consentAllowsCollection, "consent is still held after the refresh")
    }

    /// THE positive control: the same observation must be able to SEE a real loss. Without this,
    /// the zero above would pass even if the fan-out were gutted entirely.
    func test_bAWithdrawalStillFansOut() async throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        var fanOuts = 0
        let subscription = coordinator.registerGateLostHandler { fanOuts += 1 }
        defer { _ = subscription }

        // The SAME path: an authoritative projection, this time carrying a withdrawal.
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-2", plan: .free, voiceSharingEnrolled: false,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .withdrawn),
            readUnder: try XCTUnwrap(store.projectionToken()))

        XCTAssertEqual(fanOuts, 1, "a withdrawal MUST fan out — the observation is able to fail")
        XCTAssertFalse(store.consentAllowsCollection, "premise: consent is gone")
    }

    /// ACCOUNT replacement between two OPTED-IN accounts must still cancel: the
    /// consent predicate alone cannot see it, because both accounts hold consent. This is the
    /// control for the SCOPE half of the rule — without it, narrowing to consent truth alone would
    /// silently leak the old owner's in-flight work into the new account.
    ///
    /// The swap deliberately does not go through `transitionToAccount(signedIn: false)`: that
    /// re-initialises the snapshot and drops consent, so the CONSENT check would fire and the scope
    /// check would never be exercised. Here account 2 is already signed in and already opted in, and
    /// only the account scope moves — consent reads `true` on both sides of the event.
    func test_cAccountReplacementBetweenTwoOptedInAccountsStillFansOut() async throws {
        let defaults = UserDefaults(suiteName: "GateLossScope-\(UUID().uuidString)")!
        var scope = "acct-1"
        // Account 2's state must exist under its own scope before the swap, so the replacement does
        // not look like a consent change: it is purely a change of WHICH owner the snapshot is for.
        store = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { scope },
            sessionIdentityProvider: { scope })
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))
        XCTAssertTrue(store.consentAllowsCollection, "premise: account 1 holds consent")

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        var fanOuts = 0
        let subscription = coordinator.registerGateLostHandler { fanOuts += 1 }
        defer { _ = subscription }

        // ACCOUNT 2 was already opted in under its own scope, then the session moves to it.
        let accountTwo = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-2" },
            sessionIdentityProvider: { "acct-2" })
        accountTwo.transitionToAccount(signedIn: true)
        accountTwo.setLocalOptIn(true)
        accountTwo.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-2", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-2", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(accountTwo.projectionToken()))

        scope = "acct-2"
        store.transitionToAccount(signedIn: true)

        XCTAssertTrue(store.consentAllowsCollection,
                      "both accounts hold consent, which is exactly why scope must be checked")
        XCTAssertGreaterThan(fanOuts, 0,
                             "an account replacement must fan out even when both accounts opt in — "
                                 + "the consent predicate alone cannot see it")
    }

    /// THE assembled-PATH control, WITH the drain genuinely suspended mid-FLIGHT (
    /// #3). Calling `triggerDrainIfPermitted()` and immediately applying the projection only proves
    /// that SCHEDULED work is cancelled. Here the REAL drain is suspended in credential acquisition —
    /// after admission, inside the transfer path — the benign projection lands there, and only then
    /// is it released. The upload must still reach the wire. That is the interleaving the live
    /// defect produced.
    func test_eASuspendedDrainSurvivesABenignProjectionAndReachesTheWire() async throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        _ = try makeReadyEntry(queue)
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let wire = GateLossWire()
        // SUSPEND the real drain inside credential acquisition: the token provider is
        // consulted by the transport after the drain has been admitted and has begun, so this is
        // genuinely inside the transfer path — not the pre-entry gate, which ran before drainOnce.
        let reached = XCTestExpectation(description: "drain reached credential acquisition")
        let released = GateFlag()
        // A bounded spin on a flag: an expectation may only be awaited once, and a hard sleep would
        // hide a real hang behind a timeout.
        let gate = {
            reached.fulfill()
            let deadline = Date().addingTimeInterval(10)
            while !released.isSet && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        }
        let trigger = VoiceControlAssembly().makeVoiceSharingUploadTrigger(
            queue: queue,
            isAuthorized: { self.store.consentAllowsCollection },
            currentIdentity: {
                VoiceSharingUploadIdentity(
                    accountScope: ServerSettings.userId ?? "signed-out", enrollmentEpoch: "epoch-1")
            },
            baseURLProvider: { "https://unit.test" },
            tokenProvider: GateLossTokens(onAcquire: gate),
            session: wire.session)
        let subscription = coordinator.registerGateLostHandler {
            // THE production handler'S EFFECT: this is the call that cancelled the live drain.
            trigger.stop()
        }
        defer { _ = subscription }
        await coordinator.settleObservedWork()

        wire.reset()
        trigger.triggerDrainIfPermitted()
        await fulfillment(of: [reached], timeout: 10)

        // THE benign projection lands while the drain is suspended mid-TRANSFER-SEQUENCE.
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-2", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))
        released.set()
        await trigger.awaitDrainCompletionForTesting()

        XCTAssertEqual(wire.uploadRequests, 1,
                       "a drain suspended mid-flight must survive a benign projection and reach the wire")
        XCTAssertTrue(store.consentAllowsCollection, "premise: consent never left")
    }

    /// THE contrast the same control needs: actual loss must stop work that
    /// is ALREADY suspended mid-flight, not merely prevent it from being scheduled. Without this,
    /// `test_e` passing would also be satisfied by a trigger that ignores `stop()` entirely.
    func test_fActualLossStopsASuspendedDrainBeforeTheWire() async throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        _ = try makeReadyEntry(queue)
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let wire = GateLossWire()
        // SUSPEND the real drain inside credential acquisition: the token provider is
        // consulted by the transport after the drain has been admitted and has begun, so this is
        // genuinely inside the transfer path — not the pre-entry gate, which ran before drainOnce.
        let reached = XCTestExpectation(description: "drain reached credential acquisition")
        let released = GateFlag()
        // A bounded spin on a flag: an expectation may only be awaited once, and a hard sleep would
        // hide a real hang behind a timeout.
        let gate = {
            reached.fulfill()
            let deadline = Date().addingTimeInterval(10)
            while !released.isSet && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        }
        let trigger = VoiceControlAssembly().makeVoiceSharingUploadTrigger(
            queue: queue,
            isAuthorized: { self.store.consentAllowsCollection },
            currentIdentity: {
                VoiceSharingUploadIdentity(
                    accountScope: ServerSettings.userId ?? "signed-out", enrollmentEpoch: "epoch-1")
            },
            baseURLProvider: { "https://unit.test" },
            tokenProvider: GateLossTokens(onAcquire: gate),
            session: wire.session)
        let subscription = coordinator.registerGateLostHandler {
            trigger.stop()
        }
        defer { _ = subscription }
        await coordinator.settleObservedWork()


        wire.reset()
        trigger.triggerDrainIfPermitted()
        await fulfillment(of: [reached], timeout: 10)

        // CAPTURE the drive

        // TASK before withdrawing. `stop()` clears the stored task and the
        // in-flight flags, so the completion seam can return before the cancelled acquisition has
        // actually resumed and finished — which would make this control assert zero on work that was
        // still running. Holding the task itself and awaiting it after release closes that.
        let drainTask = trigger.drainTaskForTesting

        // A REAL withdrawal, delivered through the production observer path.
        store.setLocalOptIn(false)
        released.set()
        await drainTask?.value

        XCTAssertEqual(wire.uploadRequests, 0,
                       "a genuine consent loss must stop a drain that was already in flight")
        XCTAssertFalse(store.consentAllowsCollection, "premise: consent really left")
    }

    /// THE initialisation gap, DRIVEN with two threads and
    /// NO REENTRANT store call. A withdrawal is issued on a second thread while a coordinator is
    /// being constructed on this one — the reader/registrar window the old code left open. The loss
    /// must be reported exactly once whichever side wins, because the baseline and the subscription
    /// are now taken atomically and the withdrawal is a transition like any other.
    ///
    /// Nothing here mutates the store from inside a lock-held provider: that reenters the store's
    /// non-recursive lock and deadlocks, which is what my previous attempt did and why it was
    /// discarded rather than kept.
    func test_gAWithdrawalRacingConstructionIsStillReported() throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))
        XCTAssertTrue(store.consentAllowsCollection, "premise: consent starts permitted")

        // THE racer stays live through construction and past subscription, so a withdrawal is
        // certain to land inside the reader/registrar window AND while the handler is registered.
        // Stopping it at construction time (my first attempt) raced the opposite way and produced a
        // bare zero that proved nothing.
        let started = DispatchSemaphore(value: 0)
        let stopRacer = GateFlag()
        let racer = Thread {
            started.signal()
            while !stopRacer.isSet {
                self.store.setLocalOptIn(true)
                self.store.setLocalOptIn(false)
            }
        }
        racer.start()
        started.wait()

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let counter = FanOutCounter()
        let subscription = coordinator.registerGateLostHandler { counter.count += 1 }
        defer { _ = subscription }
        // Let several withdrawal cycles run against a live subscription before stopping.
        Thread.sleep(forTimeInterval: 0.05)
        stopRacer.set()
        // Join the racer before asserting, so the count is final rather than still moving.
        while !racer.isFinished { Thread.sleep(forTimeInterval: 0.01) }

        XCTAssertFalse(store.consentAllowsCollection, "premise: consent really left")
        XCTAssertGreaterThanOrEqual(counter.count, 1,
                                    "a withdrawal racing construction must be reported, not absorbed")
    }

    /// THE lost-OPT-OUT window, DETERMINISTICALLY.
    ///
    /// The old mutators released the state lock and only THEN captured the snapshot, so an opt-out
    /// that paused there could be overtaken by an opt-in: both captures then read "permitted" and
    /// the loss was never announced. This control halts the opt-out EXACTLY inside its mutation —
    /// `accountScopeProvider` is invoked there under the store's own lock — lets a competing opt-in
    /// and opt-out complete on another thread, then releases it. Every withdrawal must be announced
    /// exactly once, however the two interleave.
    ///
    /// The competitor runs on ITS own thread and is awaited. Issuing it from inside the provider
    /// would re-enter the store's non-recursive lock and deadlock — the failure my earlier attempt
    /// produced, which is why this design avoids it entirely.
    func test_iAWithdrawalOvertakenByAnotherMutationIsStillReported() throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let counter = FanOutCounter()
        let subscription = coordinator.registerGateLostHandler { counter.count += 1 }
        defer { _ = subscription }

        // ARM the seam: the next scope read (i.e. the opt-out below, mid-mutation) halts until
        // the competing mutations have landed.
        let paused = GateExpectation()
        let resume = GateFlag()
        armScopeSeam { 
            paused.signal()
            let deadline = Date().addingTimeInterval(10)
            while !resume.isSet && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        }

        let optOut = Thread { self.store.setLocalOptIn(false) }
        optOut.start()
        XCTAssertEqual(paused.wait(timeout: .now() + 10), .success,
                       "premise: the opt-out reached its mutation")

        // COMPETING mutations, on this thread, while the opt-out is held mid-flight.
        store.setLocalOptIn(true)
        store.setLocalOptIn(false)
        resume.set()
        while !optOut.isFinished { Thread.sleep(forTimeInterval: 0.01) }

        XCTAssertFalse(store.consentAllowsCollection, "premise: consent really left")
        XCTAssertGreaterThanOrEqual(counter.count, 1,
                                    "a withdrawal overtaken by other mutations must still be reported")
    }

    /// SUBSCRIPTION while history is still blocked. An existing observer holds
    /// the drainer; a new coordinator subscribes during that time and must see only its own
    /// baseline and later transitions — never pre-subscription history, which would replay as fresh
    /// consent changes and could cancel work the newcomer had only just started.
    func test_jANewSubscriberNeverReceivesPreSubscriptionHistory() throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        // A blocker registered first takes the drainer and stops mid-delivery, so history piles up
        // behind it: a withdrawal and a re-opt-in that the newcomer must never be shown.
        let insideBlocker = GateExpectation()
        let releaseBlocker = GateFlag()
        let blocker = store.addObserver { transition in
            guard transition.state.localOptIn else { return }
            insideBlocker.signal()
            let deadline = Date().addingTimeInterval(10)
            while !releaseBlocker.isSet && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        }
        defer { store.removeObserver(blocker) }

        // THE withdrawal is made durable before the newcomer exists, so the newcomer's baseline is
        // the post-loss state and it has no loss of its own to report. The blocker is released only
        // afterwards, which is when the queued history would be replayed to it.
        store.setLocalOptIn(false)
        store.setLocalOptIn(true)
        XCTAssertEqual(insideBlocker.wait(timeout: .now() + 10), .success,
                       "premise: the blocker holds the drainer")

        // THE newcomer subscribes while delivery is blocked.
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        let counter = FanOutCounter()
        let subscription = coordinator.registerGateLostHandler { counter.count += 1 }
        defer { _ = subscription }

        releaseBlocker.set()
        // Settle: nothing more changes, so any further fan-out would come from replayed history.
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(counter.count, 0,
                       "a subscriber must never be shown history from before it registered")
    }

    /// THE drainer handoff, ON TWO real threads.
    ///
    /// The bug: the drainer checked the queue empty, unlocked, then cleared ownership. An enqueue
    /// landing in that gap saw a live drainer, left its transition for it, and was stranded until
    /// the next unrelated mutation. A single-threaded control cannot enter that gap at all — my
    /// first attempt was green against the bug, so it proved nothing.
    ///
    /// Here a producer mutates continuously from another thread while a consumer subscribes and
    /// counts. Every mutation must eventually be delivered: after the producer stops, the last
    /// transition counted must equal the last sequence the store produced. A stranded transition
    /// leaves the count short.
    func test_kNoTransitionIsStrandedByTheDrainerHandoff() throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)

        let deliveredLock = NSLock()
        let settledSequence = IntBox()
        var delivered = 0
        var lastSequence = -1
        let id = store.addObserver { transition in
            deliveredLock.lock()
            delivered += 1
            lastSequence = max(lastSequence, transition.sequence)
            deliveredLock.unlock()
        }
        defer { store.removeObserver(id) }

        // A PRODUCER on another thread, mutating across the drainer's handoff windows.
        let toggleBox = ToggleBox()
        let stop = GateFlag()
        let producer = Thread {
            while !stop.isSet {
                self.store.setLocalOptIn(toggleBox.flip())
            }
        }
        producer.start()
        Thread.sleep(forTimeInterval: 0.4)
        stop.set()
        while !producer.isFinished { Thread.sleep(forTimeInterval: 0.01) }

        // One final mutation after the producer stops: the store must be idle, so a stranded
        // transition stayed stranded rather than being swept up by a later one.
        deliveredLock.lock()
        let seen = lastSequence
        deliveredLock.unlock()
        settledSequence.value = seen
        checkQuiescent(seen: seen, box: settledSequence)
    }

    private final class IntBox {
        private let lock = NSLock()
        private var stored = -1
        var value: Int {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private final class ToggleBox {
        private let lock = NSLock()
        private var value = false
        func flip() -> Bool { lock.lock(); defer { lock.unlock() }; value.toggle(); return value }
    }

    /// After the producer stops, nothing new is generated — so the last sequence that reached the
    /// subscriber must be the last one the store produced.
    private func checkQuiescent(seen: Int, box: IntBox) {
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(seen, box.value,
                       "delivery was still moving after the producer stopped — a transition was stranded")
    }

    /// THE event that motivated the narrowing, AT THE store: two consecutive benign projections
    /// must not be observable as a loss at all — the coordinator's predicate is only meaningful if
    /// the stream it reads is itself honest about ordering and ownership.
    func test_hConsecutiveBenignProjectionsLeaveConsentTruthPermitted() throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        for revision in ["rev-1", "rev-2", "rev-3"] {
            store.apply(
                authoritative: VoiceSharingMembership(
                    membershipRevision: revision, plan: .free, voiceSharingEnrolled: true,
                    enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                    withdrawalState: .active),
                readUnder: try XCTUnwrap(store.projectionToken()))
            XCTAssertTrue(store.consentAllowsCollection, "benign projection \(revision) lost consent")
        }
    }

    private var seamAction: (() -> Void)?

    /// Arms a one-shot action to run inside the store's mutation, via its scope provider.
    private func armScopeSeam(_ action: @escaping () -> Void) { seamAction = action }

    /// Runs (once) the armed seam action, if any.
    func consumeScopeSeam() {
        guard let action = seamAction else { return }
        seamAction = nil
        action()
    }

    private final class GateExpectation {
        private let semaphore = DispatchSemaphore(value: 0)
        func signal() { semaphore.signal() }
        func wait(timeout: DispatchTime) -> DispatchTimeoutResult { semaphore.wait(timeout: timeout) }
    }

    /// A bounded handoff between a test thread and a drain held inside its own task.
    private final class GateFlag {
        private let lock = NSLock()
        private var set_ = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set_ }
        func set() { lock.lock(); set_ = true; lock.unlock() }
    }

    private final class FanOutCounter { var count = 0 }

    /// A SIGNED-OUT transition is a real loss and must still fan out.
    func test_dSignOutStillFansOut() async throws {
        store.transitionToAccount(signedIn: true)
        store.setLocalOptIn(true)
        store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken()))

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store)
        var fanOuts = 0
        let subscription = coordinator.registerGateLostHandler { fanOuts += 1 }
        defer { _ = subscription }

        store.transitionToAccount(signedIn: false)

        XCTAssertGreaterThan(fanOuts, 0, "sign-out must fan out")
        XCTAssertFalse(store.consentAllowsCollection, "premise: consent is gone")
    }

    private func makeReadyEntry(_ queue: VoiceSharingUploadQueue) throws
        -> VoiceSharingUploadQueue.Entry
    {
        let samples: [Float] = [0, 0.25, -0.5, 0.5]
        let event = VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(),
            enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: samples, isGateControl: false)
        let provenance = VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
            models: .init(vad: nil, wakeword: nil, asr: nil, translation: nil, router: nil),
            conversionVersion: "v1")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event, provenance: provenance, observations: [:])
        let entry = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
        try queue.finalize(entry)
        return entry
    }
}

/// Counts upload-route requests only, so "reached the wire" means the contribution POST and not
/// the token call that precedes it.
private final class GateLossWire: URLProtocol {
    static let lock = NSLock()
    static var uploads = 0

    var uploadRequests: Int { GateLossWire.lock.lock(); defer { GateLossWire.lock.unlock() }; return GateLossWire.uploads }
    func reset() { GateLossWire.lock.lock(); GateLossWire.uploads = 0; GateLossWire.lock.unlock() }

    var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GateLossWire.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let bearer = request.value(forHTTPHeaderField: "Authorization")?
            .replacingOccurrences(of: "Bearer ", with: "")
        var status = 200
        var body: [String: Any] = [:]
        if path == CloudAuthTokenProvider.tokenPath {
            body = ["access_token": "tok-\(bearer ?? "none")", "refresh_token": "chain",
                    "expires_in": 900, "token_type": "Bearer"]
        } else if path == VoiceSharingUploadTransport.uploadPath {
            GateLossWire.lock.lock(); GateLossWire.uploads += 1; GateLossWire.lock.unlock()
            // A refusal, so acceptance is not this control's subject: only the wire is.
            status = 503
        } else if path == VoiceSharingAccountClient.projectionPath {
            body = ["schema_version": 1, "membership_revision": "rev-1", "plan": "free",
                    "voice_sharing_enrolled": true, "enrollment_epoch": "epoch-1",
                    "accepted_disclosure_version": "voice-sharing-v1", "withdrawal_state": "active"]
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A token provider that hands back a fixed credential without a network round trip, so the control
/// measures the upload path rather than its auth preamble.
private final class GateLossTokens: CloudTokenProviding {
    private let onAcquire: (() -> Void)?
    init(onAcquire: (() -> Void)? = nil) { self.onAcquire = onAcquire }

    func token() async -> String? {
        // CREDENTIAL acquisition happens inside the drain, after admission — the seam the assembled
        // control uses to suspend real transfer work rather than merely scheduled work.
        onAcquire?()
        return "tok-acct-1"
    }
    func prepare() async {}
    func handleUnauthorized(rejectedToken: String?) async {}
}
