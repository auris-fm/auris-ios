import XCTest
@testable import podcasts

/// STOP-IDENTITY controls (review 5295572f): confirmation must mean the ACTUAL owned output
/// quiescent — exactly the stopped identity, never a promotion onto a cancel-bumped identity
/// that was never physically stopped, and never a regression from a delayed stale delivery.
final class CloudAudioPlayerStopIdentityTests: XCTestCase {
    /// Withheld A stop, then B's cancel stops the engine: B's identity is confirmed EXACTLY.
    /// Delivering A's stale notification afterwards must neither regress the record nor
    /// promote anything; a waiter parked on an UNPERFORMED identity stays unconfirmed.
    func testStaleDelayedStopDoesNotPromoteOrRegressConfirmation() async throws {
        let player = CloudAudioPlayer()
        let delivery = DeliveryBox()
        await MainActor.run { player.setCapturedStopNotificationForTesting { _, deliver in
            delivery.store(deliver)
        } }
        // Turn A: audio + finish → the drain stop for identity N is withheld by the capture.
        player.enqueue(CloudAudioFrame(data: Self.silentFrames()))
        let drainEpoch = player.finish()
        // A's awaiter: parked on identity N while the stop is withheld.
        let waiter = Task { await player.awaitActualStop(after: drainEpoch, timeout: 5) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let confirmedWhileWithheld = await MainActor.run { player.confirmedStopEpoch() }
        XCTAssertEqual(confirmedWhileWithheld, 0,
                       "nothing is confirmed while the stop is withheld")
        // Turn B: cancel bumps the identity; the engine (empty) stops — the capture STILL holds
        // it, so B's confirmation is withheld too.
        let cancelEpoch = player.cancel()
        XCTAssertGreaterThan(cancelEpoch, drainEpoch, "the cancel allocated a fresh identity")
        try await Task.sleep(nanoseconds: 200_000_000)
        // Deliver the STALE A stop FIRST, while B's identity is still unconfirmed — the exact
        // promotion hazard (review 5295572f): confirmation must mean the identity that actually
        // stopped. A stale delivery must not promote the unconfirmed B identity.
        await MainActor.run { delivery.deliverOldest() }
        try await Task.sleep(nanoseconds: 200_000_000)
        var confirmed = await MainActor.run { player.confirmedStopEpoch() }
        for _ in 0..<50 {
            if confirmed != 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
            confirmed = await MainActor.run { player.confirmedStopEpoch() }
        }
        XCTAssertEqual(confirmed, drainEpoch,
                       "confirmation is EXACTLY the identity that physically stopped")
        // Deliver B's stop: B's identity confirms exactly; A's waiter resolves (the output it
        // awaited is genuinely quiescent).
        await MainActor.run { delivery.deliverOldest() }
        for _ in 0..<50 {
            let c = await MainActor.run { player.confirmedStopEpoch() }
            if c >= cancelEpoch { confirmed = c; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(confirmed, cancelEpoch, "B's identity confirms exactly when B's stop lands")
        let aResolved = await waiter.value
        XCTAssertTrue(aResolved, "A's waiter resolves: the output it awaited is quiescent")
        // Exhaust further deliveries: no regression, no promotion.
        await MainActor.run { delivery.deliverAll() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterStale = await MainActor.run { player.confirmedStopEpoch() }
        XCTAssertEqual(
            afterStale,
            cancelEpoch,
            "a delayed stale stop neither regresses nor promotes the confirmation"
        )
        await MainActor.run { player.setCapturedStopNotificationForTesting(nil) }
    }

    /// A waiter on an UNPERFORMED identity (never stopped) stays unconfirmed and returns false
    /// at its bound — a delayed foreign stop does not confirm it.
    func testUnperformedIdentityIsNeverConfirmedByAForeignStop() async throws {
        let player = CloudAudioPlayer()
        // Stop identity 1 (empty player; no capture → confirms 1).
        _ = player.cancel()
        var confirmedOnce = await MainActor.run { player.confirmedStopEpoch() }
        for _ in 0..<50 {
            if confirmedOnce != 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
            confirmedOnce = await MainActor.run { player.confirmedStopEpoch() }
        }
        // Identity 3 was never stopped (2 and 3 unperformed). A short bounded wait must NOT
        // be satisfied by the confirmed 1 — confirmation is identity-exact upward.
        let start = Date()
        let satisfied = await player.awaitActualStop(after: 3, timeout: 0.3)
        XCTAssertFalse(satisfied, "an unperformed identity is never confirmed")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25, "the bound was honored")
    }

    /// CANCEL BEFORE REGISTER (review fa03b7f9): a waiter whose await is cancelled before its
    /// registration runs must return false promptly, never park — and the registry holds ZERO
    /// tickets afterwards.
    func testCancelBeforeRegisterDoesNotStrandTheWaiter() async throws {
        let player = CloudAudioPlayer()
        let delivery = DeliveryBox()
        await MainActor.run { player.setCapturedStopNotificationForTesting { _, deliver in
            delivery.store(deliver)
        } }
        player.enqueue(CloudAudioFrame(data: Self.silentFrames()))
        let epoch = player.finish()
        let waiter = Task { await player.awaitActualStop(after: epoch, timeout: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        let start = Date()
        let result = await waiter.value
        XCTAssertFalse(result, "pre-register cancellation returns false")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "no strand, no timeout wait")
        let countAfterCancel = await MainActor.run { player.stopWaiterCountForTesting }
        XCTAssertEqual(countAfterCancel, 0,
                       "the registry is empty after cancellation")
        // The player still confirms normally afterwards.
        await MainActor.run { delivery.deliverAll() }
        for _ in 0..<50 {
            let c = await MainActor.run(body: { player.confirmedStopEpoch() })
            if c != 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let confirmed = await MainActor.run { player.confirmedStopEpoch() }
        XCTAssertEqual(confirmed, epoch, "confirmation lands after the cancelled waiter is gone")
        let countAfterConfirm = await MainActor.run { player.stopWaiterCountForTesting }
        XCTAssertEqual(countAfterConfirm, 0)
        await MainActor.run { player.setCapturedStopNotificationForTesting(nil) }
    }

    /// CANCEL BEFORE REGISTER, DETERMINISTIC (reviews 3b2d4386 + ec3b5150): the park is
    /// ASSERTED before cancelling; the awaiter's completion is probed with a BOUND (never an
    /// unbounded wait); a failed probe fails PROMPTLY and then RESCUES the (mutant-)stranded
    /// waiter so the process never hangs; the latch hook is always unset.
    func testCancelBeforeRegisterWithDeterministicOrdering() async throws {
        let player = CloudAudioPlayer()
        let latch = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        await MainActor.run {
            player.preRegistrationLatchForTesting = {
                // NON-cancellation-sensitive park: only the explicit release lets registration
                // proceed, so the cancellation handler deterministically runs first.
                latch.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        defer {
            release.signal()
            Task { @MainActor in
                player.preRegistrationLatchForTesting = nil
            }
        }
        // DETACHED: the latch blocks its thread, so the awaiter must not share the main actor.
        let waiter = Task.detached { await player.awaitActualStop(after: 1, timeout: 5) }
        let observer = Task.detached { [waiter] in
            let r = await waiter.value
            done.signal()
            return r
        }
        // ASSERT the park: registration must NOT have run when we cancel.
        let parked = latch.wait(timeout: .now() + 2)
        XCTAssertEqual(parked, .success, "the waiter is parked in the latch BEFORE the cancel")
        waiter.cancel()  // the cancellation handler runs BEFORE registration
        try await Task.sleep(nanoseconds: 100_000_000)
        release.signal()  // release INTO registration
        // BOUNDED completion probe: fail PROMPTLY instead of hanging, then rescue.
        var completed = false
        for _ in 0..<40 {
            if done.wait(timeout: .now()) == .success { completed = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if !completed {
            await MainActor.run { player.rescueStopWaitersForTesting() }
            XCTFail("the awaiter did not complete within the bound — stranded waiter (mutant?)")
            _ = await observer.value
            return
        }
        let result = await observer.value
        XCTAssertFalse(result, "pre-register cancellation returns false at registration")
        let count = await MainActor.run { player.stopWaiterCountForTesting }
        XCTAssertEqual(count, 0, "zero retained tickets after pre-register cancellation")
        await MainActor.run { player.preRegistrationLatchForTesting = nil }
    }

    /// TWO waiters on the SAME epoch are independent: cancelling one must neither resume the
    /// other nor consume its delivery; the survivor resolves exactly once at confirmation, and
    /// the registry ends at ZERO.
    func testSameEpochWaitersAreIndependent() async throws {
        let player = CloudAudioPlayer()
        let delivery = DeliveryBox()
        await MainActor.run { player.setCapturedStopNotificationForTesting { _, deliver in
            delivery.store(deliver)
        } }
        player.enqueue(CloudAudioFrame(data: Self.silentFrames()))
        let epoch = player.finish()
        let cancelled = Task { await player.awaitActualStop(after: epoch, timeout: 5) }
        let survivor = Task { await player.awaitActualStop(after: epoch, timeout: 5) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let countBoth = await MainActor.run { player.stopWaiterCountForTesting }
        XCTAssertEqual(countBoth, 2,
                       "both same-epoch waiters are registered independently")
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult, "the cancelled waiter returns false")
        let countAfterOneCancel = await MainActor.run { player.stopWaiterCountForTesting }
        XCTAssertEqual(countAfterOneCancel, 1,
                       "only the cancelled ticket was removed")
        // Deliver the stop: the SURVIVOR resolves true, exactly once.
        await MainActor.run { delivery.deliverAll() }
        let survivorResult = await survivor.value
        XCTAssertTrue(survivorResult, "the survivor is delivered its own confirmation")
        let countAfterConfirm = await MainActor.run { player.stopWaiterCountForTesting }
        XCTAssertEqual(countAfterConfirm, 0,
                       "the registry is empty after confirmation")
        await MainActor.run { player.setCapturedStopNotificationForTesting(nil) }
    }

    /// Cancellation: a cancelled awaiter is removed cleanly (no leaked continuation, no busy
    /// loop) and does not consume a later confirmation meant for someone else.
    func testCancelledStopWaiterIsRemovedCleanly() async throws {
        let player = CloudAudioPlayer()
        let delivery = DeliveryBox()
        await MainActor.run { player.setCapturedStopNotificationForTesting { _, deliver in
            delivery.store(deliver)
        } }
        player.enqueue(CloudAudioFrame(data: Self.silentFrames()))
        let epoch = player.finish()
        let waiter = Task { await player.awaitActualStop(after: epoch, timeout: 5) }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        let result = await waiter.value
        XCTAssertFalse(result, "a cancelled waiter returns false, not a fabricated confirmation")
        // The player still works: deliver the stop, confirmation lands.
        await MainActor.run { delivery.deliverAll() }
        var confirmedAfterCancel = await MainActor.run { player.confirmedStopEpoch() }
        for _ in 0..<50 {
            if confirmedAfterCancel != 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
            confirmedAfterCancel = await MainActor.run { player.confirmedStopEpoch() }
        }
        XCTAssertEqual(confirmedAfterCancel, epoch,
                       "the player confirms normally after a waiter cancelled")
        await MainActor.run { player.setCapturedStopNotificationForTesting(nil) }
    }
}

/// Thread-safe holder for intercepted stop-notification deliveries. The capture runs on the
/// MAIN queue, so it must never block: it stores the continuation; the test drives deliveries.
extension CloudAudioPlayerStopIdentityTests {
    static func silentFrames() -> Data {
        Data(count: 320) // 10 ms of PCM silence at 16 kHz mono 16-bit
    }
}

final class DeliveryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries: [() -> Void] = []
    func store(_ d: @escaping () -> Void) {
        lock.lock(); deliveries.append(d); lock.unlock()
    }
    /// Delivers ONLY the OLDEST withheld stop (the earliest identity still pending).
    func deliverOldest() {
        lock.lock(); let d = deliveries.isEmpty ? nil : deliveries.removeFirst(); lock.unlock()
        d?()
    }
    /// Delivers every withheld stop, oldest first.
    func deliverAll() {
        lock.lock(); let all = deliveries; deliveries = []; lock.unlock()
        all.forEach { $0() }
    }
}
