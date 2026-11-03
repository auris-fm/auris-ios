import XCTest
@testable import podcasts

/// Restored-session settlement controls (reviewer 30630d31 finding 2):
/// a process that starts with a stored session has no login notification to react to, so the
/// coordinator polls auth state. The defects under control: (a) the poll was not cancelled when a
/// normal login notification settled first, so its next tick began a new lifecycle and superseded
/// the first login's in-flight work; (b) a hard 20-second bound left a LATE restoration
/// permanently unsettled, because nothing ever posts `.userLoginDidChange` for a session that
/// predates the process.
///
/// The test host is signed out (`SyncManager.isUserLoggedIn()` false — no Keychain email), so the
/// poll loop actually runs here; that is what makes these controls able to fail.
final class VoiceSharingRestoredSessionTests: XCTestCase {

    private func makeCoordinator() -> VoiceSharingCoordinator {
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            lastFetchTime: { nil },
            valueSource: nil)
        coordinator.expiryScheduler = { _, _ in }
        // The test host's process-global auth state is signed IN (a syncing email in the host's
        // defaults); the poll's whole subject is the signed-OUT restored-session case, so the
        // auth reader is injected explicitly.
        coordinator.restoredSessionAuthReadable = { false }
        return coordinator
    }

    /// (a) After a login settles, the poll must STOP ticking. Each attempt schedules by asking the
    /// delay provider, so tick continuation is observable as that counter advancing. With the
    /// cancel-on-settlement removed, the poll keeps ticking past the settlement and the counter
    /// keeps growing — that is the red state.
    func test_loginSettlement_cancelsThePendingPoll() {
        let coordinator = makeCoordinator()
        let ticks = Cell(0)
        coordinator.restoredSessionRetryDelay = {
            ticks.mutate { $0 += 1 } // counts every attempt scheduling
            return 0.02
        }
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate({ $0 += 1 }) }

        coordinator.startRestoredSessionRetry()
        // Let at least one poll tick run (the host is signed out, so it keeps polling).
        let waitUp = expectation(description: "poll ticking")
        let deadline = Date().addingTimeInterval(2)
        while ticks.value == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if ticks.value > 0 { waitUp.fulfill() }
        wait(for: [waitUp], timeout: 2)

        // A normal login notification settling the identity:
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1, "the login settles exactly once")
        let ticksAtSettlement = ticks.value

        // Any pending tick must now be cancelled. The old code let the loop continue here.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertLessThanOrEqual(ticks.value, ticksAtSettlement + 1,
                                 "no further poll ticks after the login settled (got \(ticks.value - ticksAtSettlement) extra)")
        XCTAssertEqual(settlements.value, 1, "and the settlement must not repeat")
    }

    /// (b) The poll must survive past the old 20-attempt bound: a session that restores late is
    /// otherwise permanently unsettled. Bound the run by cancelling through the invalidate
    /// closure, which is also what production teardown does.
    func test_pollContinuesPastTheOldAttemptBound() {
        let coordinator = makeCoordinator()
        let ticks = Cell(0)
        coordinator.restoredSessionRetryDelay = { ticks.mutate({ $0 += 1 }); return 0.005 }
        let invalidate = coordinator.installIdentityInvalidation()
        defer { invalidate() }

        coordinator.startRestoredSessionRetry()
        let deadline = Date().addingTimeInterval(5)
        while ticks.value <= 21 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(ticks.value, 21,
                             "attempt \(ticks.value): the poll must keep asking past the old 20-attempt bound")
    }
}

/// Tiny lock-protected mutable cell for cross-thread control observation.
private final class Cell<T> {
    private let lock = NSLock()
    private var stored: T
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
    init(_ initial: T) { stored = initial }
}
