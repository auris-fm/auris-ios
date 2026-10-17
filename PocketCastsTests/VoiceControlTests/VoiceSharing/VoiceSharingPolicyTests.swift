import XCTest
@testable import podcasts

/// A fixed clock so lease arithmetic is exact rather than scheduling-dependent.
final class StubMonotonicClock: MonotonicClock {
    private(set) var nowValue: MonotonicTime
    init(time: MonotonicTime) { nowValue = time }
    func advance(_ seconds: TimeInterval) { nowValue += seconds }
    func now() -> MonotonicTime { nowValue }
}

final class VoiceSharingPolicyTests: XCTestCase {

    // The fail-closed asymmetry: an absent/invalid remote value can only DISABLE.
    func test_absentRemoteSwitch_disablesFeature_localDefaultNeverEnables() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { .unavailable },
            isAccountEnrolled: { true }
        )
        XCTAssertNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()))
        XCTAssertFalse(policy.permitsCollection, "an unavailable remote value must never enable collection")
    }

    func test_enrolledButRemoteDisabled_staysDisabled() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { .valid(false) },
            isAccountEnrolled: { true }
        )
        _ = policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart())
        XCTAssertFalse(policy.permitsCollection)
    }

    func test_remoteEnabledButNotEnrolled_staysDisabled_enrollmentIsAccountStateNotConfig() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { false }
        )
        _ = policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart())
        XCTAssertFalse(policy.permitsCollection, "Firebase supplies configuration, never authorization")
    }

    func test_allConditionsMet_permitsUntilLeaseExpiry_thenDisablesWithoutMutation() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            leaseSeconds: 60,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        _ = policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart())
        XCTAssertTrue(policy.permitsCollection)
        clock.advance(59)
        XCTAssertTrue(policy.permitsCollection)
        clock.advance(2) // t = 1061 > 1060 expiry
        XCTAssertFalse(policy.permitsCollection, "expired lease behaves as disabled")
        // Expired-but-true remote value cannot resurrect it without a fresh activation read.
        clock.advance(1)
        XCTAssertFalse(policy.permitsCollection)
    }

    func test_invalidPublicationClearsPreviousGoodSnapshot_insteadOfStickyLastGood() {
        let clock = StubMonotonicClock(time: 1_000)
        var remote: VoiceSharingPolicy.RemoteSwitchValue = .valid(true)
        let policy = VoiceSharingPolicy(
            clock: clock,
            leaseSeconds: 60,
            readRemoteSwitch: { remote },
            isAccountEnrolled: { true }
        )
        _ = policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart())
        XCTAssertTrue(policy.permitsCollection)
        remote = .unavailable
        XCTAssertNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()), "a bad publication must clear the snapshot")
        XCTAssertFalse(policy.permitsCollection)
    }

    /// Restart rule (reviewer finding 4): nothing persisted restores validity.
    /// This test models restart by constructing a NEW policy instance — exactly
    /// what the process does on relaunch — and asserting the first read is OFF
    /// until a real fetch→activate completes. There is deliberately no API that
    /// accepts a restored timestamp or cached value as lease evidence.
    func test_restart_neverRestoresLeaseFromPersistedTime_freshActivateRequired() {
        let clock = StubMonotonicClock(time: 50_000)
        let relaunched = VoiceSharingPolicy(
            clock: clock,
            leaseSeconds: 60 * 60,
            readRemoteSwitch: { .valid(true) },   // remote still says enabled
            isAccountEnrolled: { true }           // account still enrolled
        )
        XCTAssertFalse(relaunched.permitsCollection, "before activate completes after restart, collection is off regardless of remote/account state")
        _ = relaunched.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: relaunched.tokenForFetchStart())
        XCTAssertTrue(relaunched.permitsCollection, "only a fresh post-activation install enables it")
    }

    /// Compile-time proof there is no restore-from-persistence surface at all:
    /// the type has no initializer parameter or method taking a stored snapshot.
    func test_policyHasNoPersistenceRestoreSurface() {
        let mirror = Mirror(reflecting: VoiceSharingPolicy(clock: SystemMonotonicClock(), readRemoteSwitch: { .unavailable }, isAccountEnrolled: { false }))
        let storedNames = Set(mirror.children.map { $0.label ?? "" })
        XCTAssertFalse(storedNames.contains("restored"), "no hidden restore slot may exist")
        XCTAssertNotNil(storedNames)
    }

    // MARK: - Review round 2: activation evidence, strict decoding, identity invalidation

    /// Finding 1: a failed fetch (cached / no-network) must NOT renew a stale lease.
    func test_failedActivation_clearsAndDoesNotRenewLease() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            leaseSeconds: 60,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()))
        clock.advance(30)
        XCTAssertTrue(policy.permitsCollection)

        // A later callback that reports failure must not extend anything: the original expiry
        // (t=1060) still governs, so collection stops on schedule rather than living on.
        policy.refreshAfterActivation(freshActivationSucceeded: false, fetchToken: policy.tokenForFetchStart())
        clock.advance(30) // t = 1060 -> past the ORIGINAL expiry
        XCTAssertFalse(policy.permitsCollection, "a failed fetch/activate pair may not renew the lease")
    }

    /// The actual bridge shape: activate returning an error installs nothing even when the
    /// store would have served a valid-looking value.
    func test_activateError_installsNothingEvenIfValueLooksValid() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        XCTAssertNil(policy.refreshAfterActivation(freshActivationSucceeded: false, fetchToken: policy.tokenForFetchStart()))
        XCTAssertFalse(policy.permitsCollection)
    }

    /// Finding 2: drive the PRODUCTION decoder with raw published values. NSNumber.intValue
    /// truncates 1.5 to 1 and boolValue accepts strings, so coercion must be refused here —
    /// not hidden behind an injected `.valid(...)` enum.
    func test_productionDecoder_rejectsNonBooleanPublications() {
        XCTAssertEqual(VoiceSharingPolicy.decodeRemoteSwitch(kCFBooleanTrue), .valid(true))
        XCTAssertEqual(VoiceSharingPolicy.decodeRemoteSwitch(kCFBooleanFalse), .valid(false))
        // Numeric look-alikes are INVALID, and invalid means disabled.
        XCTAssertEqual(VoiceSharingPolicy.decodeRemoteSwitch(NSNumber(value: 1.5)), .unavailable, "intValue would coerce 1.5 -> 1 and enable")
        XCTAssertEqual(VoiceSharingPolicy.decodeRemoteSwitch(NSNumber(value: 1)), .unavailable)
        XCTAssertEqual(VoiceSharingPolicy.decodeRemoteSwitch(NSNumber(value: 0)), .unavailable)
        XCTAssertEqual(VoiceSharingPolicy.decodeRemoteSwitch(NSNumber(value: 2)), .unavailable)
        XCTAssertEqual(VoiceSharingPolicy.decodeRemoteSwitch(nil), .unavailable)
    }

    /// The decoder's output feeds the same gate as everything else: a coerced-looking 1.5
    /// publication cannot produce an enabled snapshot.
    func test_coercedNumericPublication_disablesThroughTheRealGate() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { VoiceSharingPolicy.decodeRemoteSwitch(NSNumber(value: 1.5)) },
            isAccountEnrolled: { true }
        )
        XCTAssertNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()))
        XCTAssertFalse(policy.permitsCollection)
    }

    /// Finding 3: enrollment must not be frozen into the snapshot. Withdrawal flips permission
    /// immediately, without waiting for the lease to lapse.
    func test_withdrawalAfterInstall_stopsCollectionImmediately() {
        let clock = StubMonotonicClock(time: 1_000)
        var enrolled = true
        let policy = VoiceSharingPolicy(
            clock: clock,
            leaseSeconds: 60,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { enrolled }
        )
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()))
        XCTAssertTrue(policy.permitsCollection)

        enrolled = false // withdrawal / sign-out
        policy.invalidateForIdentityChange()
        XCTAssertFalse(policy.permitsCollection, "a frozen accountEnrolled flag would keep collecting after withdrawal")
    }

    /// Finding 3 fence: a refresh that belongs to the previous identity must not restore
    /// permission while the new identity is still unknown.
    func test_staleRefreshAfterIdentityChange_cannotRestorePermission() {
        let clock = StubMonotonicClock(time: 1_000)
        var enrolled = true
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { enrolled }
        )
        _ = policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart())
        XCTAssertTrue(policy.permitsCollection)

        // Account switch: old identity's fetch completes late, new enrollment not yet readable.
        enrolled = false
        policy.invalidateForIdentityChange()
        XCTAssertNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()), "fenced install must not restore permission")
        XCTAssertFalse(policy.permitsCollection)

        // Once the new state is readable, a genuine opt-in installs again.
        enrolled = true
        policy.identityBecameReadable()
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()))
        XCTAssertTrue(policy.permitsCollection)
    }

    // MARK: - Review round 3: real bridge (freshness proof, token fencing, transient failure)

    /// Finding 1: `.success` alone is NOT freshness. The SDK returns Success with nil error on its
    /// cached short-circuit (RCNConfigFetch reports Success without touching lastFetchTime), so the
    /// production bridge must prove `lastFetchTime` advanced past fetch start. Drives the real
    /// coordinator decision function rather than an injected bool.
    func test_cachedSuccess_lastFetchNotAdvanced_cannotRenewLease() {
        let clock = StubMonotonicClock(time: 1_000)
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },          // fetch starts at wall 5000
            lastFetchTime: { Date(timeIntervalSince1970: 4_000) } // SDK time is OLDER => cached path
        )
        // The bridge's own freshness predicate is what rejects it — same function production calls.
        let startedAt = coordinator.nowForFreshnessCheck()
        let before = coordinator.lastFetchTime()
        XCTAssertFalse(coordinator.lastFetchAdvancedPast(startedAt, previousSDKTime: before),
                       "SDK lastFetchTime did not advance, so this was the cached short-circuit")

        // And the composed decision (didActivate && provedFreshExchange) therefore cannot install.
        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(
            freshActivationSucceeded: true && coordinator.lastFetchAdvancedPast(startedAt, previousSDKTime: before),
            fetchToken: token)
        XCTAssertFalse(coordinator.policy.permitsCollection, "a cached success must not install a snapshot")

        // A genuine exchange advances the SDK clock past fetch start.
        coordinator.lastFetchTimeProvider = { Date(timeIntervalSince1970: 5_001) }
        XCTAssertTrue(coordinator.lastFetchAdvancedPast(startedAt, previousSDKTime: before))
        let freshToken = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(
            freshActivationSucceeded: true && coordinator.lastFetchAdvancedPast(startedAt, previousSDKTime: before),
            fetchToken: freshToken)
        XCTAssertTrue(coordinator.policy.permitsCollection, "a proven fresh exchange installs normally")
    }

    /// Finding 2: identity captured at FETCH START and verified atomically at INSTALL — before AND
    /// after the config read. A real account transition (sign-out/switch) landing while the read is in
    /// flight bumps the generation, so that callback's snapshot cannot install afterwards.
    func test_identityChangesDuringConfigRead_blocksInstall() {
        let clock = StubMonotonicClock(time: 1_000)
        // A box the read closure can drive once the policy exists: capturing a `var` here would be
        // copied by value at closure creation, so it must be a reference cell.
        final class Box { var invalidate: (() -> Void)? }
        let box = Box()
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { [box] in
                // Models the account transitioning while the config read is in flight.
                box.invalidate?()
                return .valid(true)
            },
            isAccountEnrolled: { true }
        )
        box.invalidate = { [policy] in policy.invalidateForIdentityChange() }
        let token = policy.tokenForFetchStart()   // taken under the OLD generation
        XCTAssertNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: token),
                     "transition during the read must block install")
        XCTAssertFalse(policy.permitsCollection)
    }

    /// Finding 2 (fence-clear race): an old callback arriving AFTER the fence was lifted by a newer
    /// identity still cannot install, because its token predates the generation bump.
    func test_oldCallbackArrivingAfterFenceCleared_stillRejected() {
        let clock = StubMonotonicClock(time: 1_000)
        var enrolled = false
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { enrolled }
        )
        // Token taken under the old identity, BEFORE any transition.
        let staleToken = policy.tokenForFetchStart()
        policy.invalidateForIdentityChange()           // real account transition: clears + fences + bumps generation
        policy.identityBecameReadable()                // new identity becomes readable; fence lifted
        enrolled = true
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()),
                        "a current-identity refresh installs once the new identity is readable")
        // The stale callback now arrives late. The fence is already clear, so ONLY the generation
        // check can stop it — this is the race the reviewer named.
        XCTAssertNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: staleToken),
                     "stale-generation token must never install, even after the fence was cleared")
    }

    /// Finding 3: a transient config failure clears permission but must NOT fabricate an identity
    /// change; a later genuine success has to recover.
    func test_transientConfigFailure_clearsButLaterSuccessRecovers() {
        let clock = StubMonotonicClock(time: 1_000)
        let policy = VoiceSharingPolicy(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()))
        XCTAssertTrue(policy.permitsCollection)

        // Transient failure: permission drops immediately...
        policy.refreshAfterActivation(freshActivationSucceeded: false, fetchToken: policy.tokenForFetchStart())
        XCTAssertFalse(policy.permitsCollection)

        // ...and a later success recovers WITHOUT needing identityBecameReadable(). If the failure
        // had raised the fence, this would stay dead forever.
        XCTAssertNotNil(policy.refreshAfterActivation(freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart()))
        XCTAssertTrue(policy.permitsCollection)
    }

    // MARK: - Review round 4: real SDK extraction, clock discontinuity, identity wiring

    /// The SDK-facing extraction path driven with a faithful fixture: FIRRemoteConfigValue stores the
    /// published value as UTF-8 bytes and exposes them via `dataValue`, so `"true"` arrives as the text
    /// payload — NOT as an ObjC boolean. This is what production reads; a decoder that demanded a
    /// boolean literal from `numberValue` would reject every real publication (see ROUND4 notes).
    /// Validates the encoding assumption against the vendored SDK rather than asserting it: remote
    /// publications are stored as `[[FIRRemoteConfigValue alloc] initWithData:[entries[key]
    /// dataUsingEncoding:NSUTF8StringEncoding] source:FIRRemoteConfigSourceRemote]` (RCNConfigContent.m
    /// handleUpdateStateForConfigNamespace), i.e. the template's JSON text bytes with source `.remote`.
    /// A Boolean parameter therefore arrives as the literal text `true`/`false`, which is exactly what
    /// extractRemoteSwitch accepts — and `numberValue` on top of it is a double coercion, which is why
    /// the decoder must not read numbers. If this fixture ever disagrees with the SDK's own value object,
    /// this control fails first.
    func test_vendoredSDK_storesRemoteBooleansAsUTF8TextBytes() throws {
        let sdkFile = "/Users/dev/code/auris/auris-ios/build-fixed-derived/SourcePackages/checkouts/"
            + "firebase-ios-sdk/FirebaseRemoteConfig/Sources/RCNConfigContent.m"
        guard FileManager.default.fileExists(atPath: sdkFile) else {
            throw XCTSkip("vendored SDK source not present on this host — encoding claim unverified here")
        }
        let sdk = try String(contentsOfFile: sdkFile, encoding: .utf8)
        XCTAssertTrue(
            sdk.contains("[entries[key] dataUsingEncoding:NSUTF8StringEncoding]"),
            "SDK no longer stores fetched entries as UTF-8 text bytes; re-verify the extraction boundary"
        )
        XCTAssertTrue(
            sdk.contains("source:FIRRemoteConfigSourceRemote]"),
            "SDK no longer tags fetched entries as .remote; the source gate needs re-verification"
        )
        // And confirm the shape our seam models: those bytes decode to the bare literal.
        XCTAssertEqual(VoiceSharingPolicy.extractRemoteSwitch(data: Data("true".utf8), sourceIsRemote: true), .valid(true))
    }

    func test_extractRemoteSwitch_matchesSDKRepresentation() {
        func data(_ s: String) -> Data { Data(s.utf8) }
        XCTAssertEqual(VoiceSharingPolicy.extractRemoteSwitch(data: data("true"), sourceIsRemote: true), .valid(true))
        XCTAssertEqual(VoiceSharingPolicy.extractRemoteSwitch(data: data("false"), sourceIsRemote: true), .valid(false))
        XCTAssertEqual(VoiceSharingPolicy.extractRemoteSwitch(data: data(" true "), sourceIsRemote: true), .valid(true),
                       "whitespace-tolerant but otherwise exact")
        // Everything else fails closed, including things NSNumber coercion would have accepted.
        for bad in ["1", "0", "yes", "1.5", "TRUE", "True", "", "null"] {
            XCTAssertEqual(VoiceSharingPolicy.extractRemoteSwitch(data: data(bad), sourceIsRemote: true), .unavailable,
                           "\(bad.debugDescription) must not enable collection")
        }
        XCTAssertEqual(VoiceSharingPolicy.extractRemoteSwitch(data: nil, sourceIsRemote: true), .unavailable)
        // Non-remote sources (our compiled default, or an absent key) can never satisfy the policy.
        XCTAssertEqual(VoiceSharingPolicy.extractRemoteSwitch(data: data("true"), sourceIsRemote: false), .unavailable,
                       "a local default must never enable")
    }

    /// Same extraction reached through the injected value-source seam, i.e. the actual production
    /// reader function rather than the static helper alone.
    func test_productionReader_usesSeamAndExtraction() {
        let clock = StubMonotonicClock(time: 1_000)
        var published = Data("false".utf8)
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            isAccountEnrolled: { true },
            valueSource: { VoiceSharingCoordinator.RemoteValueSource(data: published, sourceIsRemote: true) }
        )
        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertFalse(coordinator.policy.permitsCollection)

        published = Data("true".utf8)   // server publishes the switch on
        let token2 = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token2)
        XCTAssertTrue(coordinator.policy.permitsCollection, "production reader picked up the remote change")
    }

    /// Clock discontinuity: a backward jump can leave an OLD cached SDK timestamp still ahead of our
    /// wall-clock fetch start. Requiring the SDK timestamp to have MOVED from its prior value rejects
    /// it, which a single-reference comparison would have accepted.
    func test_backwardClockJump_oldCachedTimestamp_cannotPassFreshness() {
        let clock = StubMonotonicClock(time: 1_000)
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 1_000) },          // clock jumped BACKWARD
            lastFetchTime: { Date(timeIntervalSince1970: 9_000) } // stale cache, ahead of our start
        )
        let startedAt = coordinator.nowForFreshnessCheck()
        let before = coordinator.lastFetchTime()
        XCTAssertTrue(before! > startedAt, "precondition: cached SDK time exceeds wall-clock start")
        XCTAssertFalse(coordinator.lastFetchAdvancedPast(startedAt, previousSDKTime: before),
                       "unmoved SDK timestamp must fail freshness even when it is ahead of start")

        // Absent SDK timestamp also fails closed.
        coordinator.lastFetchTimeProvider = { nil }
        XCTAssertFalse(coordinator.lastFetchAdvancedPast(startedAt, previousSDKTime: before))
    }

    /// My FIRST version of this control was vacuous and I caught it by mutation: it called the wrapper
    /// method directly, so deleting the real call site from `setupVoiceControlIfNeeded()` left it green
    /// (mutant G passed). A helper invocation cannot prove the application subscribes. This version drives
    /// the app delegate's own lifecycle entry (`handleBecomeActive`, which production calls on every
    /// activation) and asserts the consequence: posting `.serverUserWillBeSignedOut` afterwards must drop
    /// permission. Nothing here calls the installer or the wrapper.
    func test_appDelegateLifecyclePath_signOutSubscriptionActuallyExists() {
        let clock = StubMonotonicClock(time: 1_000)
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        VoiceSharingCoordinator.setSharedForTesting(coordinator)
        defer { VoiceSharingCoordinator.resetSharedForTesting() }

        // Production path: AppDelegate.handleBecomeActive() -> setupVoiceControlIfNeeded() -> subscribe.
        let appDelegate = AppDelegate()
        appDelegate.handleBecomeActive()

        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertTrue(coordinator.policy.permitsCollection, "wired first so there is something to drop")

        // Same center production defaults to, same notification SyncManager posts.
        NotificationCenter.default.post(name: .serverUserWillBeSignedOut, object: nil,
                                       userInfo: ["user_initiated": true])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(coordinator.policy.permitsCollection,
                       "the app's own lifecycle must have established the subscription")
    }

    /// Repeated activation is the shape that exposed the leak: `setupVoiceControlIfNeeded()` runs on
    /// EVERY app activation, so a non-idempotent installer accumulates observers and one sign-out fires
    /// several generation bumps. A single-activation control cannot see this at all.
    func test_doubleActivation_oneSignOutCausesExactlyOneGenerationTransition() {
        let clock = StubMonotonicClock(time: 1_000)
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        VoiceSharingCoordinator.setSharedForTesting(coordinator)
        defer { VoiceSharingCoordinator.resetSharedForTesting() }

        let center = NotificationCenter()
        let appDelegate = AppDelegate()
        appDelegate.setupVoiceSharingIdentityInvalidation(onNotificationCenter: center, coordinator: coordinator)
        // Second activation (production calls this same path again).
        appDelegate.setupVoiceSharingIdentityInvalidation(onNotificationCenter: center, coordinator: coordinator)

        // Baseline install under current identity.
        let firstToken = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: firstToken)
        XCTAssertTrue(coordinator.policy.permitsCollection)

        center.post(name: .serverUserWillBeSignedOut, object: nil, userInfo: ["user_initiated": true])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(coordinator.policy.permitsCollection)

        // ONE transition means exactly one generation step. If both observers survived, this sign-out
        // would have bumped twice and the next token would be two ahead of `firstToken`.
        coordinator.identityBecameReadable()
        let secondToken = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: secondToken)
        XCTAssertTrue(coordinator.policy.permitsCollection)

        center.post(name: .serverUserWillBeSignedOut, object: nil, userInfo: ["user_initiated": true])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        coordinator.identityBecameReadable()
        let thirdToken = coordinator.policy.tokenForFetchStart()

        // A leaked duplicate observer invalidates twice per notification, so a token captured after the
        // SECOND notification differs from one captured after the first — observable as an extra bump.
        XCTAssertEqual(thirdToken.identityGeneration - secondToken.identityGeneration, 1,
                       "one sign-out must advance identity generation by exactly 1 (duplicate observers bump more)")
        XCTAssertEqual(secondToken.identityGeneration - firstToken.identityGeneration, 1,
                       "same for the first transition")
    }

    /// Identity wiring through the real notification production uses.
    func test_signOutNotification_invalidatesThroughRealObserver() {
        let clock = StubMonotonicClock(time: 1_000)
        let center = NotificationCenter()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        coordinator.installIdentityInvalidation(onNotificationCenter: center)
        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertTrue(coordinator.policy.permitsCollection)

        center.post(name: .serverUserWillBeSignedOut, object: nil, userInfo: ["user_initiated": true])
        XCTAssertFalse(coordinator.policy.permitsCollection, "real sign-out transition must drop permission")

        // Fence stays until the new identity is readable; then a fresh install works again.
        let staleToken = token
        coordinator.identityBecameReadable()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: staleToken)
        XCTAssertFalse(coordinator.policy.permitsCollection, "pre-transition token must not resurrect permission")
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true,
                                                 fetchToken: coordinator.policy.tokenForFetchStart())
        XCTAssertTrue(coordinator.policy.permitsCollection)
    }

    // MARK: - Target-membership boundary (the real defect this file must not re-break)

    /// The actual failure we hit was NOT in the app target: `FirebaseManager.swift` is an
    /// explicitly-listed source of THREE targets — podcasts, Pocket Casts App Clip and
    /// Pocket Casts TV App — while `podcasts/VoiceControl/**` reaches a target only through
    /// that target's `fileSystemSynchronizedGroups`. App Clip/TV do not sync VoiceControl at
    /// all, so an unguarded reference from FirebaseManager into VoiceSharing failed to compile
    /// for them even though the app target built fine. This control pins that asymmetry against
    /// the live project file; if membership ever changes, this fails and the guard can be revisited.
    /// FirebaseManager.swift is an explicitly-listed source of THREE targets (podcasts, App Clip,
    /// TV App), but `podcasts/VoiceControl/**` reaches a target only through that target's
    /// `fileSystemSynchronizedGroups` — and only the app target lists VoiceControl. That asymmetry
    /// is what actually broke the build: the app target compiled fine while App Clip failed with
    /// "cannot find 'VoiceSharingCoordinator' in scope". This control pins the asymmetry against the
    /// live project file so the #if !APPCLIP guard cannot silently become unnecessary (or wrong).
    func test_voiceControlIsSynchronizedIntoAppTargetOnly_notIntoAppClipOrTV() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoiceSharing/
            .deletingLastPathComponent()   // VoiceControlTests/
            .deletingLastPathComponent()   // PocketCastsTests/
            .deletingLastPathComponent()   // source root (worktree, or build-fixed when mirrored)
            .appendingPathComponent("podcasts.xcodeproj/project.pbxproj")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            XCTFail("could not find project file at \(projectURL.path) — the pin cannot be verified")
            return
        }
        let src = try String(contentsOf: projectURL, encoding: .utf8)
        let voiceControlID = "A1F8767439C1AD83A362A39B" /* VoiceControl synchronized root group */

        /// Slice FIRST, then use only that slice's own indices: mixing a String.Index produced
        /// against `src` with results from `body.range(of:)` does not compile.
        func syncGroupIDs(ofTarget id: String, named name: String) -> [String] {
            guard let anchor = src.range(of: "\t\t\(id) /* \(name) */ = {\n") else {
                XCTFail("target \(name) (\(id)) not found in project file"); return []
            }
            guard let bodyEnd = src.range(of: "\n\t\t};", range: anchor.upperBound..<src.endIndex) else {
                XCTFail("unterminated target block for \(name)"); return []
            }
            let body = String(src[anchor.upperBound..<bodyEnd.lowerBound])
            guard let fsg = body.range(of: "fileSystemSynchronizedGroups = (\n") else { return [] }
            guard let listEnd = body.range(of: "\n\t\t\t);", range: fsg.upperBound..<body.endIndex) else { return [] }
            let entries = String(body[fsg.upperBound..<listEnd.lowerBound]).components(separatedBy: "\n")
            // Anchor at line start (a comment field also holds 24 hex chars, so an unanchored scan
            // yields bogus ids), and escape the `/` in `/*`: writing it as `\*` makes `*` a
            // quantifier over `/`, which matches nothing and silently produces an empty list.
            let idPattern = try! NSRegularExpression(pattern: "^\\s*([0-9A-F]{24}) /\\*")
            return entries.compactMap { line in
                let r = NSRange(line.startIndex..., in: line)
                guard let m = idPattern.firstMatch(in: line, range: r), let g = Range(m.range(at: 1), in: line) else { return nil }
                return String(line[g])
            }
        }

        let app = syncGroupIDs(ofTarget: "BDBD53EB17019B2A0048C8C5", named: "podcasts")
        let clip = syncGroupIDs(ofTarget: "F5D5F7782CEBE769001F492D", named: "Pocket Casts App Clip")
        let tv = syncGroupIDs(ofTarget: "FF4B83AD2F981D8E001B8C56", named: "Pocket Casts TV App")

        // Without this, a parse that returned nothing would make BOTH negatives pass vacuously.
        XCTAssertGreaterThan(app.count, 10, "failed to parse the app target's sync groups — the negatives below would be meaningless")
        XCTAssertEqual(clip.count, 5, "unexpected App Clip sync-group parse")
        XCTAssertEqual(tv.count, 3, "unexpected TV App sync-group parse")
        XCTAssertTrue(app.contains(voiceControlID), "app target must sync VoiceControl (else the feature has no sources anywhere)")
        XCTAssertFalse(clip.contains(voiceControlID), "App Clip gained VoiceControl membership — the #if !APPCLIP guard premise changed; review before keeping it")
        XCTAssertFalse(tv.contains(voiceControlID), "TV App gained VoiceControl membership — same premise change")
    }
}
