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
        // it, so B's confirmation is withheld too. Release ONLY B's delivery.
        let cancelEpoch = player.cancel()
        XCTAssertGreaterThan(cancelEpoch, drainEpoch, "the cancel allocated a fresh identity")
        try await Task.sleep(nanoseconds: 200_000_000)
        // Deliver ONLY the newest stop (B's): the box holds A's first, B's second.
        await MainActor.run { delivery.deliverLast() }
        var confirmed = await MainActor.run { player.confirmedStopEpoch() }
        for _ in 0..<50 {
            if confirmed != 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
            confirmed = await MainActor.run { player.confirmedStopEpoch() }
        }
        XCTAssertEqual(confirmed, cancelEpoch, "confirmation is EXACTLY the stopped identity")
        let aResolved = await waiter.value
        XCTAssertTrue(aResolved, "A's waiter resolves: the output it awaited is quiescent")
        // Stale delivery of A's notification: no regression, no promotion.
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
    /// Delivers ONLY the most recent withheld stop (newest identity).
    func deliverLast() {
        lock.lock(); let d = deliveries.popLast(); lock.unlock()
        d?()
    }
    /// Delivers every withheld stop, oldest first.
    func deliverAll() {
        lock.lock(); let all = deliveries; deliveries = []; lock.unlock()
        all.forEach { $0() }
    }
}
