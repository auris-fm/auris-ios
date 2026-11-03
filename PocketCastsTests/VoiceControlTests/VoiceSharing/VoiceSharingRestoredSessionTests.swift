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

    /// (c) IDEMPOTENT SETTLEMENT (reviewer on ac82eab04): a login notification arriving AFTER
    /// the poll already settled the same account must be a no-op — `beginNewLifecycle()`
    /// unconditionally replaced the settled lifecycle and superseded its in-flight work. The
    /// refresh counter is the observable: the settled lifecycle initiated exactly one recovery
    /// refresh, and the repeat adds none.
    func test_notificationAfterPollSettlement_isANoop() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        var readable = false
        coordinator.restoredSessionAuthReadable = { readable }
        coordinator.settledAccountIdentityProvider = { "account-A" }

        // The poll settles the restored session late.
        coordinator.startRestoredSessionRetry()
        let deadline = Date().addingTimeInterval(2)
        while settlements.value == 0 && Date() < deadline {
            if !readable { readable = true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(settlements.value, 1, "the late-restored session settles exactly once")

        // A login notification for the SAME account lands afterwards (production shape:
        // some other observer posts .userLoginDidChange while signed in).
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1,
                       "a repeat settlement for the same account must not begin a new lifecycle")
    }

    /// (d) Two login notifications for the same session, no poll involved: the second is a
    /// no-op. And a real account change (A→B) still settles.
    func test_repeatNotification_noop_newAccount_settles() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        var account: String? = "account-A"
        coordinator.settledAccountIdentityProvider = { account }
        coordinator.restoredSessionAuthReadable = { true }

        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1)
        coordinator.handleLoginStateDidChange(signedIn: true) // duplicate notification
        XCTAssertEqual(settlements.value, 1, "duplicate settlement for the same session is a no-op")

        account = "account-B" // real account switch
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 2, "a genuinely different account settles again")
    }

    /// (e) Sign-out while restoration is pending: the lifecycle clears, the pending poll
    /// remains the late-coverage, and a later settle for the new account still lands exactly
    /// once.
    func test_signOutWhileRestorationPending_thenNewAccountSettles() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        var readable = false
        var account: String? = nil
        coordinator.restoredSessionAuthReadable = { readable }
        coordinator.settledAccountIdentityProvider = { account }

        coordinator.startRestoredSessionRetry() // polling while unreadable
        // Sign-out arrives while restoration is still pending.
        coordinator.handleLoginStateDidChange(signedIn: false)

        // Later the session becomes readable, for a new account.
        readable = true
        account = "account-B"
        let deadline = Date().addingTimeInterval(2)
        while settlements.value == 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(settlements.value, 1,
                       "the pending poll must still settle after a pending sign-out, exactly once")
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
