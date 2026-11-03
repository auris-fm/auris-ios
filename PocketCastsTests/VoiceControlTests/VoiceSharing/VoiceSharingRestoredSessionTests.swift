import XCTest
@testable import podcasts
@testable import PocketCastsServer

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

    /// REVIEWER (`cfcfab6f`) shape, found on this lane by measurement: the retry tick guarded with
    /// `restoredSessionAuthReadable()` (SyncManager.isUserLoggedIn()) before asking the ONE
    /// settlement decision, and those are different conditions. The cold-restore case is exactly
    /// where they part - a readable credential can name an account via `storedAccountIdentity()`
    /// while that defaults key is empty - so the tick declined while the entry point it guards
    /// would have settled.
    ///
    /// Polarity matters for what this bug IS: the Android form (gate admits, work declines) produces
    /// a repeated-acquisition loop. Here the gate declines and the work is never consulted, so
    /// nothing is attempted and nothing is acquired - a liveness bug, invisible to the server
    /// because nothing is ever sent.
    ///
    /// Driven THROUGH THE TICK, not through `settleFromOwnerReadiness()`: a control that calls the
    /// entry point directly cannot see a bug that lives in its guard, which is how the earlier probe
    /// and the fix differ.
    func test_retryTick_settlesFromReadableStoredCredential_whenTheNarrowAuthFlagIsFalse() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }

        // PRODUCTION defaults deliberately NOT stubbed, because reviewer (bd0766db) showed the
        // production cold path is narrower than an injected probe suggests: the default
        // `ownerCredentialIsPresent` is `committedAccountIdentity() != nil || isUserLoggedIn()`,
        // so with no commit and logged-in false the entry point ALSO refuses before reading the
        // stored identity. Stubbing it to `true` would manufacture a state production may not
        // reach, and the control would then prove only that the tick delegates in a fixture.
        //
        // So this control asserts the CONSEQUENCE OF DELEGATION in state we can actually produce:
        // no commit, credential present and readable, narrow flag false. Whether the production
        // cold process reaches that state is reported separately, as reviewer asked - fixture
        // disagreement and production reachability are distinct claims.
        coordinator.ownerAccountIdentityProvider = { nil }
        coordinator.ownerCredentialIsPresent = { true }
        coordinator.storedCredentialIdentityProvider = { "account-A" }
        coordinator.restoredSessionAuthReadable = { false }
        coordinator.restoredSessionRetryDelay = { 0.01 }

        VoiceSharingSessionGeneration.shared.clear()
        coordinator.startRestoredSessionRetry()
        let deadline = Date().addingTimeInterval(1.0)
        while settlements.value == 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(settlements.value, 1,
                       "the tick must delegate, not decide: a readable stored credential settles "
                       + "even while the narrow syncing-email flag is false")
        XCTAssertEqual(coordinator.settledAccountIdentityForTesting, "account-A",
                       "and settles on the account the credential actually names")
        VoiceSharingSessionGeneration.shared.clear()
    }

    /// REVIEWER (`bd0766db`): production reachability, measured separately from the fixture claim
    /// above. With the REAL default providers - no injected presence - and a signed-out process, the
    /// entry point refuses before it can read any stored identity, which is what keeps removal of
    /// the tick gate safe on a cold start. This pins that refusal so the previous control cannot be
    /// read as evidence about production.
    func test_productionDefaults_coldSignedOutProcess_settlesNothingThroughTheTick() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        // Real defaults for every identity provider; only the loop's timing is injected.
        coordinator.restoredSessionAuthReadable = { false }
        coordinator.restoredSessionRetryDelay = { 0.01 }

        VoiceSharingSessionGeneration.shared.clear()
        coordinator.startRestoredSessionRetry()
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertEqual(settlements.value, 0,
                       "production defaults on a signed-out cold process: the entry point refuses "
                       + "before reading a stored identity, so the tick settles nothing")
        XCTAssertNil(coordinator.settledAccountIdentityForTesting)
        VoiceSharingSessionGeneration.shared.clear()
    }

    /// The gate existed for a reason: a signed-out process must NOT settle from stale
    /// process-global state. Removing it is only safe because the decision guards itself -
    /// `storedAccountIdentity()` reports nothing without a refresh token in the Keychain. This
    /// control pins that the replacement preserves the old guard's purpose.
    func test_retryTick_stillSettlesNothingWhenNoCredentialIsReadable() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        coordinator.ownerAccountIdentityProvider = { nil }
        coordinator.ownerCredentialIsPresent = { false }
        coordinator.storedCredentialIdentityProvider = { nil }
        coordinator.restoredSessionAuthReadable = { true }
        coordinator.restoredSessionRetryDelay = { 0.01 }

        VoiceSharingSessionGeneration.shared.clear()
        coordinator.startRestoredSessionRetry()
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertEqual(settlements.value, 0,
                       "nothing readable to present => no settlement, however long the poll runs")
        VoiceSharingSessionGeneration.shared.clear()
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

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

    /// REVIEWER (gap 3 on `bf335f109`): the commit hook only observes commits that happen in THIS
    /// process, and both committed-state fields start nil. A COLD start into an already-readable
    /// stored session therefore deferred until some later credential exchange — the passive
    /// restoration stayed unclosed exactly where it matters. My earlier cold-start control hid this
    /// by injecting an owner identity.
    ///
    /// This one drives the real cold path: no call to `commitAuthentication`, no injected identity.
    /// The owner reports no committed credential (nothing has committed in this process); the process
    /// starts with READABLE auth state (a stored credential to present). That is enough to settle.
    func test_coldStartWithStoredCredential_settlesWithoutAnyCommitInThisProcess() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        // Nothing has committed in this process…
        coordinator.ownerAccountIdentityProvider = { nil }
        // …but a credential is present and readable, which is what cold readiness is about. The
        // STORED identity is named here exactly as the real owner would report it (a digest of the
        // stored account); what is absent is only the in-process COMMIT this process never observed.
        coordinator.ownerCredentialIsPresent = { true }
        coordinator.storedCredentialIdentityProvider = { "account-A" }
        coordinator.restoredSessionAuthReadable = { true }

        VoiceSharingSessionGeneration.shared.clear()
        let invalidate = coordinator.installIdentityInvalidation(startupAuthReadable: { true })
        defer { invalidate(); VoiceSharingSessionGeneration.shared.clear() }

        XCTAssertEqual(settlements.value, 1,
                       "a cold start with a stored credential must settle from readable state, not from an observed commit")
        XCTAssertNotNil(VoiceSharingSessionGeneration.shared.currentGeneration())
    }

    /// REVIEWER (`d23c3f613`): the cold fallback and the committed provider must name one account with
    /// ONE string. My earlier revision namespaced the stored form as "stored:<digest>" while the
    /// committed form returned the bare digest, so the first renewal commit after a cold start looked
    /// like a DIFFERENT account: lifecycle restarted, enrollment authority reset, in-flight work lost,
    /// and a fresh allowance request issued under an unchanged epoch.
    ///
    /// The assertion is the TRANSITION, not the string: settle cold, then commit the SAME account as a
    /// renewal and prove nothing settles again.
    func test_coldSettlement_thenRenewalCommitOfTheSameAccount_settlesOnce() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        // BOTH sides read ONE source of truth (the owner), exactly as production does: a cold start
        // asks the stored form, a commit asks the committed form, and whether these two agree is the
        // entire subject of this control. Giving them separate fixtures made it unable to notice a
        // divergence - the first version passed with the "stored:" prefix restored.
        let storedDigest = Cell(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let committedDigest = Cell<UUID?>(nil)
        coordinator.storedCredentialIdentityProvider = {
            VoiceSharingCoordinator.storedIdentity(from: storedDigest.value)
        }
        coordinator.ownerAccountIdentityProvider = {
            VoiceSharingCoordinator.committedIdentity(from: committedDigest.value)
        }
        coordinator.ownerCredentialIsPresent = { true }
        coordinator.restoredSessionAuthReadable = { true }

        VoiceSharingSessionGeneration.shared.clear()
        let invalidate = coordinator.installIdentityInvalidation(startupAuthReadable: { true })
        defer { invalidate(); VoiceSharingSessionGeneration.shared.clear() }

        XCTAssertEqual(settlements.value, 1,
                       "premise: the cold start settled from the stored credential")
        let generation = VoiceSharingSessionGeneration.shared.currentGeneration()
        XCTAssertNotNil(generation, "premise: and it holds a lifecycle")

        // The SAME account now commits — what `credentialCommitObserver` reports on every renewal.
        committedDigest.mutate { $0 = storedDigest.value }
        coordinator.credentialCommitDidOccur()

        XCTAssertEqual(settlements.value, 1,
                       "a renewal of the SAME account must not settle again - the two namings must agree")
        XCTAssertEqual(VoiceSharingSessionGeneration.shared.currentGeneration(), generation,
                       "and the lifecycle must not be restarted under it")
    }

    /// The other side of the same rule: readable-by-injection is not a credential. With nothing
    /// committed AND nothing present, a cold start must not mint a lifecycle on an assumption.
    func test_coldStartWithNothingToPresent_settlesNothing() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }
        coordinator.ownerAccountIdentityProvider = { nil }
        coordinator.ownerCredentialIsPresent = { false }
        coordinator.storedCredentialIdentityProvider = { nil }
        coordinator.restoredSessionAuthReadable = { true }

        VoiceSharingSessionGeneration.shared.clear()
        let invalidate = coordinator.installIdentityInvalidation(startupAuthReadable: { true })
        defer { invalidate(); VoiceSharingSessionGeneration.shared.clear() }

        XCTAssertEqual(settlements.value, 0,
                       "no credential to present means nothing to settle, however readable the session looks")
        XCTAssertNil(VoiceSharingSessionGeneration.shared.currentGeneration())
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

    /// REVIEWER (`86360d9e1`): the existing cold-path control injected the digests and called the
    /// callback directly, so it asserted the seam rather than the production transition. The item
    /// left open is the one that actually breaks a session: after an account is settled and a real
    /// projection has been applied under it, a RENEWAL commit — a different `commitAuthentication`,
    /// which is what the owner reports on every token exchange — must not reset that projection.
    ///
    /// This drives the real `ServerSettings.credentialCommitObserver` hook end to end. If a renewal
    /// re-settles, the enrollment store transitions and clears the settled authority, and the user's
    /// next capture is refused for want of an enrollment they did grant.
    func test_renewalThroughTheRealCommitHook_preservesSettledProjection() async throws {
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
        coordinator.restoredSessionAuthReadable = { true }
        let digests = Cell(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        coordinator.ownerCredentialIsPresent = { true }
        coordinator.storedCredentialIdentityProvider = {
            VoiceSharingCoordinator.storedIdentity(from: digests.value)
        }
        coordinator.ownerAccountIdentityProvider = {
            VoiceSharingCoordinator.committedIdentity(from: digests.value)
        }

        VoiceSharingSessionGeneration.shared.clear()
        let invalidate = coordinator.installIdentityInvalidation(startupAuthReadable: { true })
        defer { invalidate(); VoiceSharingSessionGeneration.shared.clear() }

        XCTAssertEqual(settlements.value, 1, "premise: the cold start settled")
        let generation = VoiceSharingSessionGeneration.shared.currentGeneration()

        let fetched = await client.fetchProjection()
        let membership = try XCTUnwrap(fetched?.membership, "premise: projection fetched")
        XCTAssertTrue(store.apply(authoritative: membership, readUnder: fetched!.issuedUnder),
                      "premise: projection applies under the settled lifecycle")
        XCTAssertTrue(store.currentEffectiveEnrolled, "premise: enrolled")

        // A RENEWAL: the owner commits again for the SAME account and reports completion through
        // the real observer the production wiring installs. That is exactly what a token exchange
        // at expiry produces.
        // The observer runs on the main queue, so this expectation is the control's SYNC POINT: it
        // is fulfilled after the observer fires and its hop has run. Without it the assertions below
        // execute before settlement is even attempted - measured: they all passed while the renewal
        // path had been deliberately broken, because the hop had not run yet.
        let renewalObserved = expectation(description: "renewal reported through the owner's hook")
        let previousObserver = ServerSettings.credentialCommitObserver
        ServerSettings.credentialCommitObserver = {
            previousObserver?()
            DispatchQueue.main.async { renewalObserved.fulfill() }
        }
        // Restored as soon as this renewal has been observed, NOT at function exit: leaving this
        // single-fulfil wrapper installed through the second renewal fulfils this expectation twice.
        defer { ServerSettings.credentialCommitObserver = previousObserver }
        let attempt = try XCTUnwrap(ServerSettings.beginAuthentication(explicit: false))
        XCTAssertTrue(ServerSettings.commitAuthentication(
            AuthenticationResponse(token: "renewed", uuid: "renewal-account", email: "b@example.com",
                                   refreshToken: "renewed-refresh"),
            for: attempt, password: "p"))
        // The observer hops to the main queue; let it run, since settlement must also happen there.
        wait(for: [renewalObserved], timeout: 5)
        ServerSettings.credentialCommitObserver = previousObserver

        // IN-FLIGHT WORK (reviewer on 87a020511): start a membership operation under the settled
        // session, then let a REAL renewal land while that operation is outstanding. The store's
        // fence decides - if a renewal bumps the operation generation or rotates the lifecycle,
        // the in-flight read is superseded and its answer can never be applied.
        store.setLocalOptIn(false)                     // a LOCAL change: bumps operation generation
        let staleOperation = try XCTUnwrap(store.projectionToken(),
                                            "premise: an operation can be issued under the settled session")
        store.setLocalOptIn(true)                      // the user opts back in: a second in-flight op
        let inFlight = try XCTUnwrap(store.projectionToken())
        XCTAssertNotEqual(staleOperation.operationGeneration, inFlight.operationGeneration,
                          "premise: the two operations are distinguishable, so supersession is observable")

        // A RENEWAL of the SAME account, through the real hook, lands while `inFlight` is outstanding.
        // Chains to the COORDINATOR's own observer (now back in place), so this renewal goes through
        // production settlement and reports through this expectation's hop.
        let secondRenewal = expectation(description: "second renewal reported")
        ServerSettings.credentialCommitObserver = {
            previousObserver?()
            DispatchQueue.main.async { secondRenewal.fulfill() }
        }
        let secondAttempt = try XCTUnwrap(ServerSettings.beginAuthentication(explicit: false))
        XCTAssertTrue(ServerSettings.commitAuthentication(
            AuthenticationResponse(token: "renewed-2", uuid: "renewal-account", email: "b@example.com",
                                   refreshToken: "renewed-refresh-2"),
            for: secondAttempt, password: "p"))
        wait(for: [secondRenewal], timeout: 5)

        XCTAssertEqual(settlements.value, 1,
                       "a renewal must not settle again - it is the same account")
        XCTAssertTrue(store.currentEffectiveEnrolled,
                      "and it must not reset the settled enrollment authority")
        XCTAssertEqual(VoiceSharingSessionGeneration.shared.currentGeneration(), generation,
                       "nor replace the lifecycle the projection was applied under")
        XCTAssertEqual(store.projectionToken()?.operationGeneration, inFlight.operationGeneration,
                       "nor supersede an operation already in flight")
        // The store's lifecycle is what governs the fence, and this fixture pins it to a literal;
        // comparing it against the process-wide `VoiceSharingSessionGeneration` would be comparing
        // two different things and failing for a reason that has nothing to do with the renewal.
        XCTAssertEqual(store.projectionToken()?.lifecycleGeneration, inFlight.lifecycleGeneration,
                       "the in-flight operation's lifecycle must still be the settled one")
        XCTAssertTrue(store.apply(authoritative: membership, readUnder: inFlight),
                      "so the in-flight operation's answer can still be applied")
    }

    /// (c) reviewer on the Android lane (f77aaa69), applied here as a control rather than an
    /// argument: a flag set by failure and cleared by consumption is a retry counter wearing the
    /// name of an event. The question is whether this coordinator's unresolved path re-fires work,
    /// or merely keeps asking the state.
    ///
    /// The distinguishing control is unresolved -> unresolved with ATTEMPTS COUNTED: if repeated
    /// unresolved ticks each produced a side effect, the side-effect count would climb with the
    /// tick count. It must not. Only an actual change of state may produce work.
    func test_repeatedUnresolvedTicks_produceNoWork_untilReadinessActuallyChanges() {
        let coordinator = makeCoordinator()
        let settlements = Cell(0)
        let lifecycles = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }

        // UNRESOLVED: a signed-in-looking process with no readable credential to present. The
        // owner holds nothing, so there is no identity to settle under.
        coordinator.ownerAccountIdentityProvider = { nil }
        coordinator.ownerCredentialIsPresent = { false }
        coordinator.storedCredentialIdentityProvider = { nil }

        for _ in 0..<25 { coordinator.settleFromOwnerReadiness() }
        XCTAssertEqual(settlements.value, 0,
                       "25 unresolved settles must produce ZERO settlements, not 25 retries")
        XCTAssertNil(coordinator.settledAccountIdentityForTesting,
                     "and no identity may be invented from an unresolved state")

        // STILL UNRESOLVED after a change attempt that also resolves nothing: still zero work.
        coordinator.ownerCredentialIsPresent = { true }
        coordinator.storedCredentialIdentityProvider = { nil }
        for _ in 0..<25 { coordinator.settleFromOwnerReadiness() }
        XCTAssertEqual(settlements.value, 0,
                       "present-but-unnameable is still unresolved; it must not be consumed as progress")

        // READINESS ACTUALLY CHANGES: now exactly one settlement, and only one, however many more
        // ticks follow.
        coordinator.storedCredentialIdentityProvider = { "account-A" }
        for _ in 0..<25 {
            coordinator.settleFromOwnerReadiness()
            lifecycles.mutate { $0 += 1 }
        }
        XCTAssertEqual(settlements.value, 1,
                       "a single change of readiness settles ONCE; repeated ticks do not re-fire it")
        XCTAssertEqual(coordinator.settledAccountIdentityForTesting, "account-A")
    }

    /// (d) reviewer on the Android lane (70d0801b) / @cloud: **a predicate used to decide whether
    /// there is anything to do must not perform the work it is supposed to gate.** Their form was a
    /// readiness check that called the full credential supplier, which can refresh over HTTP behind
    /// a shut gate - so a "closed" gate still acquired credentials, and the control saw only the
    /// returned Boolean.
    ///
    /// SCOPE, narrowed after reviewer on 979df22c6: an earlier version of this control counted
    /// "acquisitions" through a property no production path calls, so zero was guaranteed by the
    /// unused property and the red run proved only that an artificial call gets counted. That
    /// receipt is withdrawn. What this version asserts is what it can actually see: how many times
    /// the PRODUCTION collaborators are consulted, and that repeated unresolved consults produce no
    /// settlement. That acquisition cost is absent remains a source-inspection conclusion - these
    /// readers are synchronous Keychain/in-memory reads - not a measurement made here.
    func test_readinessPredicate_consultsProductionCollaboratorsWithoutSettling() {
        let coordinator = makeCoordinator()
        let ownerReads = Cell(0)
        let storedReads = Cell(0)
        let settlements = Cell(0)
        coordinator.initiateIdentityRecoveryRefresh = { settlements.mutate { $0 += 1 } }

        // Unresolved: every call consults the owner for committed identity, then for presence,
        // then the stored credential - all synchronous reads, counted here.
        coordinator.ownerAccountIdentityProvider = { ownerReads.mutate { $0 += 1 }; return nil }
        coordinator.ownerCredentialIsPresent = { true }
        coordinator.storedCredentialIdentityProvider = { storedReads.mutate { $0 += 1 }; return nil }

        for _ in 0..<20 { coordinator.settleFromOwnerReadiness() }

        XCTAssertEqual(ownerReads.value, 20,
                       "20 unresolved settles consult the owner exactly once each")
        XCTAssertEqual(storedReads.value, 20,
                       "and consult the stored credential exactly once each while unnameable")
        XCTAssertEqual(settlements.value, 0,
                       "still no settlement while unresolved")

        // Readiness changes: one settlement, and the cost profile is unchanged - resolving does not
        // become an excuse for extra consultations.
        coordinator.storedCredentialIdentityProvider = { storedReads.mutate { $0 += 1 }; return "account-A" }
        for _ in 0..<20 { coordinator.settleFromOwnerReadiness() }
        XCTAssertEqual(settlements.value, 1, "exactly one settlement across the transition")
        XCTAssertLessThanOrEqual(storedReads.value, 41,
                                 "call cost stays proportional to calls, not to attempts")
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
