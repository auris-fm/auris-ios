import XCTest
@testable import podcasts

/// Restored-session settlement controls (reviewer 30630d31 finding 2; reworked for the owner's
/// commit hook after spec 2026-11-03 / reviewer on `466576407`):
/// a process that starts with a stored session has no login notification to react to, so the
/// coordinator polls auth state. The defects under control: (a) the poll was not cancelled when a
/// normal login notification settled first, so its next tick began a new lifecycle and superseded
/// the first login's in-flight work; (b) a hard 20-second bound left a LATE restoration
/// permanently unsettled, because nothing ever posts `.userLoginDidChange` for a session that
/// predates the process.
///
/// The test host is signed out (`SyncManager.isUserLoggedIn()` false — no Keychain email), so the
/// poll loop actually runs here; that is what makes these controls able to fail.
///
/// The settlement subject is now READINESS REPORTED BY THE CREDENTIAL OWNER: an account identity
/// for a credential committed in this process. Renewal commits do not change that identity, so they
/// do not reset a live lifecycle; a genuine session replacement does.
final class VoiceSharingRestoredSessionTests: XCTestCase {

    private func makeCoordinator(enrollmentStore: VoiceSharingEnrollmentStore? = nil) -> VoiceSharingCoordinator {
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            lastFetchTime: { nil },
            valueSource: nil,
            enrollmentStore: enrollmentStore)
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
        coordinator.ownerAccountIdentityProvider = { "account-A" }

        coordinator.startRestoredSessionRetry()
        // Let at least one poll tick run (the host is signed out, so it keeps polling).
        let waitUp = expectation(description: "poll ticking")
        let deadline = Date().addingTimeInterval(2)
        while ticks.value == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if ticks.value > 0 { waitUp.fulfill() }
        wait(for: [waitUp], timeout: 2)

        // A normal login notification settling the identity (observed, not derived):
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
        coordinator.ownerAccountIdentityProvider = { "account-A" }

        // The restored session settles through the ONE path that can prove a sign-in: an observed
        // login change. The poll keeps carrying debt but never settles on derived state.
        coordinator.startRestoredSessionRetry()
        readable = true
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1, "the restored session settles exactly once")

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
        coordinator.ownerAccountIdentityProvider = { account }
        coordinator.restoredSessionAuthReadable = { true }

        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1)
        coordinator.handleLoginStateDidChange(signedIn: true) // duplicate notification
        XCTAssertEqual(settlements.value, 1, "duplicate settlement for the same session is a no-op")

        account = "account-B" // real account switch, announced by a login change
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 2, "a genuinely different account settles again")
    }

    /// (e) Sign-out while restoration is pending, then the new account's login notification
    /// settles exactly once: a pending restoration must not be able to publish a lifecycle for
    /// the new session on its own.
    func test_signOutWhileRestorationPending_thenNewAccountSettles() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        var account: String? = nil
        coordinator.ownerAccountIdentityProvider = { account }

        let invalidate = coordinator.installIdentityInvalidation(startupAuthReadable: { false })
        defer { invalidate() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05)) // restoration debt pending

        coordinator.handleLoginStateDidChange(signedIn: false) // sign-out while pending
        account = "account-B"                                  // a different account signs in
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1,
                       "the new account settles exactly once after a pending restoration")
    }

    /// (f) SAME ACCOUNT, NEW SESSION settles again (reviewer on 59371aaf7 + spec: account id alone
    /// must not suppress refresh after a real session change). On iOS a session ends through the
    /// signed-out transition, which clears the settled key AND the lifecycle; the next observed
    /// login for the SAME account then settles again. Red shape: a dedupe without a session boundary
    /// answers "same account, no-op" for a fresh session.
    ///
    /// Not keyed on `committedAuthenticationID` (reviewer direction), MEASURED in this tree:
    /// `TokenHelper.acquireToken` runs `beginAuthentication(explicit: false)` then
    /// `commitAuthentication` on EVERY renewal (TokenHelper.swift:95,122; ServerSettings.swift:533),
    /// so the committed id changes at every expiry — that key would re-settle a LIVE session on
    /// renewal, which control (f2) forbids.
    func test_sameAccountNewSession_settlesAgain() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        coordinator.ownerAccountIdentityProvider = { "account-A" }

        coordinator.handleLoginStateDidChange(signedIn: true) // session 1
        XCTAssertEqual(settlements.value, 1)

        // Session 1 ends through the app's own sign-out producer, then the SAME account signs in.
        let invalidate = coordinator.installIdentityInvalidation(startupAuthReadable: { false })
        defer { invalidate() }
        NotificationCenter.default.post(name: .serverUserWillBeSignedOut, object: nil)
        coordinator.handleLoginStateDidChange(signedIn: false) // session 1 ends
        coordinator.handleLoginStateDidChange(signedIn: true)  // session 2, SAME account
        XCTAssertEqual(settlements.value, 2,
                       "a new session for the SAME account must settle again, not dedupe away")
    }

    /// (f2) A renewal inside a live session must NOT re-settle: renewals re-commit credentials and
    /// can re-post a login notification, but no session boundary occurs. This is the control that
    /// rejects keying settlement on the committed authentication id.
    func test_tokenRenewalWithinLiveSession_doesNotResettle() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        coordinator.ownerAccountIdentityProvider = { "account-A" }

        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1)
        coordinator.handleLoginStateDidChange(signedIn: true) // renewal, same live session
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1,
                       "a renewal inside a live session must not replace the settled lifecycle")
    }

    /// (h) UNREADABLE identity defers settlement — no placeholder key, no side effects
    /// (reviewer on 59371aaf7). Once the owner identity publishes, the settlement lands.
    func test_unreadableIdentity_defersSettlement() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        var account: String? = nil
        coordinator.ownerAccountIdentityProvider = { account }

        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 0, "an unreadable identity must not settle")

        account = "account-A"
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1, "and settles once it becomes readable")
    }

    /// (h2) The poll asks the OWNER and never decides on its own reading. Two red shapes are
    /// controlled here:
    ///  * `4035a1ebf`: a tick that "settled" and returned while its settlement had deferred — it
    ///    stopped the poll and promised a later tick that could never come.
    ///  * settling on the tick's own view of auth: every state a tick reads (auth readable, a cached
    ///    account string) survives sign-out, so a tick-driven settlement minted a lifecycle for a
    ///    session nobody established in this process.
    func test_pollAsksTheOwner_andKeepsItsDebtWhenTheOwnerIsSilent() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        let ticks = Cell(0)
        coordinator.restoredSessionRetryDelay = { ticks.mutate { $0 += 1 }; return 0.01 }
        coordinator.restoredSessionAuthReadable = { true } // auth readable from the start
        let invalidate = coordinator.installIdentityInvalidation(startupAuthReadable: { false })
        defer { invalidate() }

        // The owner reports NO committed credential: the tick must not settle and must not stop.
        coordinator.ownerAccountIdentityProvider = { nil }
        coordinator.startRestoredSessionRetry()
        let deadline = Date().addingTimeInterval(1.5)
        while ticks.value < 8 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(settlements.value, 0, "nothing was settled while the owner reported no credential")
        let ticksBefore = ticks.value
        let window = Date().addingTimeInterval(0.3)
        while Date() < window { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertGreaterThan(ticks.value, ticksBefore,
                             "the poll must keep asking: it never clears its own debt")

        // And when the owner DOES report a committed credential, the very next tick settles it —
        // this is the "session becoming readable after startup" case, and it settles exactly once.
        coordinator.ownerAccountIdentityProvider = { "owner-account-A" }
        let settleDeadline = Date().addingTimeInterval(1.5)
        while settlements.value == 0 && Date() < settleDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(settlements.value, 1,
                       "a session that becomes readable after startup must settle, exactly once")
        // The poll's cancellation is not observable as "ticks froze": a tick already in flight
        // re-schedules itself before the cancellation lands. What must hold is that the poll cannot
        // settle a SECOND time, and that the same owner answer keeps being a no-op.
        let afterSettle = Date().addingTimeInterval(0.3)
        while Date() < afterSettle { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(settlements.value, 1,
                       "a tick must never settle twice for one lifecycle")
    }

    /// (j) COLD RESTORATION (spec 2026-11-03, reviewer on `466576407`): a stored session the app can
    /// already read at startup, with the owner reporting its committed credential, MUST reach the
    /// projection/capture decision without any login notification — no `.userLoginDidChange` exists
    /// for a session that predates the process. Red shape: the observed-login-only gate, which
    /// refused this and left a restored session unable to initiate identity recovery.
    func test_coldRestoredSession_settlesFromOwnerReadiness() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        coordinator.ownerAccountIdentityProvider = { "owner-account-A" }
        coordinator.restoredSessionAuthReadable = { true }

        VoiceSharingSessionGeneration.shared.clear()
        let invalidate = coordinator.installIdentityInvalidation(startupAuthReadable: { true })
        defer { invalidate(); VoiceSharingSessionGeneration.shared.clear() }

        XCTAssertEqual(settlements.value, 1,
                       "a cold restored session must settle from the owner's committed credential")
        XCTAssertNotNil(VoiceSharingSessionGeneration.shared.currentGeneration(),
                        "and it acts under a lifecycle")
    }

    /// (k) The sign-out race, re-stated for owner readiness: an account that is no longer the
    /// committed one is never resurrected. The owner reports NOTHING once signed out, so a later
    /// derivation over a still-readable stored session settles nothing.
    func test_signedOutAccount_isNotResurrectedByALaterDerivation() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        var committed: String? = "owner-account-A"
        coordinator.ownerAccountIdentityProvider = { committed }
        coordinator.restoredSessionAuthReadable = { true }

        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1, "the committed account settles")
        coordinator.handleLoginStateDidChange(signedIn: false) // signs out: owner reports nothing
        committed = nil
        XCTAssertNil(VoiceSharingSessionGeneration.shared.currentGeneration(), "sign-out ends the lifecycle")

        // A LATER derivation over the still-readable stored session must not resurrect it.
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1,
                       "a derivation with no committed credential must not re-settle the departed account")
        XCTAssertNil(VoiceSharingSessionGeneration.shared.currentGeneration(),
                     "and must not mint a lifecycle for it")
    }

    /// (i) DUPLICATE settlement must not disturb enrollment authority
    /// (reviewer on 59371aaf7): transitionToAccount bumps the operation generation and resets
    /// state, so deduping AFTER it cleared the projection before returning "same account".
    /// The duplicate must be a full no-op — the settled store survives intact.
    func test_duplicateSettlement_enrollmentAuthoritySurvives() async throws {
        let store = VoiceSharingEnrollmentStore(sessionIdentityProvider: { "gen-A" })
        store.setLocalOptIn(true)
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] = .init(
            status: 200,
            body: [
                "schema_version": 1,
                "membership_revision": "r1",
                "plan": "pro",
                "voice_sharing_enrolled": true,
                "withdrawal_state": "active",
                "enrollment_epoch": "e1" as Any,
                "accepted_disclosure_version": "voice-sharing-v1" as Any,
            ])
        defer { VoiceSharingStubProtocol.replies.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSharingStubProtocol.self]
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" },
            membershipStore: store)
        let coordinator = makeCoordinator(enrollmentStore: store)
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        coordinator.ownerAccountIdentityProvider = { "account-A" }

        // Settle FIRST: the settlement transition resets the store and rotates its fences, so
        // the authoritative projection must be read under the SETTLED lifecycle (a projection
        // fetched before the transition is stale by the store's own fence rule).
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertEqual(settlements.value, 1)
        let fetched = await client.fetchProjection()
        let membership = try XCTUnwrap(fetched?.membership, "control precondition: projection fetched")
        let applied = store.apply(authoritative: membership, readUnder: fetched!.issuedUnder)
        XCTAssertTrue(applied, "control precondition: projection applies under the settled lifecycle")
        XCTAssertTrue(store.currentEffectiveEnrolled, "control precondition: enrolled")

        coordinator.handleLoginStateDidChange(signedIn: true) // duplicate, same identity
        XCTAssertEqual(settlements.value, 1, "duplicate is a no-op")
        XCTAssertTrue(store.currentEffectiveEnrolled,
                      "the duplicate must not have reset the settled enrollment authority")
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

/// Trust-on-first-use stub credential, mirroring the account-client controls.
private final class StubTokens: CloudTokenProviding {
    func token() async -> String? { "test-bearer" }
    func prepare() async {}
    func handleUnauthorized(rejectedToken: String?) async {}
}

/// Tiny lock-protected mutable cell for cross-thread control observation.
private final class Cell<T> {
    private let lock = NSLock()
    private var stored: T
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
    init(_ initial: T) { stored = initial }
}
