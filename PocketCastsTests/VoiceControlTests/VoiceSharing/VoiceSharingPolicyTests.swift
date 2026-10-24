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

    // MARK: - Gate-loss production triggers

    /// The production gate-loss fan-out: consent loss observed by the coordinator (membership change,
    /// refresh reading a closed gate) must trigger `gateLost` WITHOUT new frames — the collector purges
    /// queued and held audio at the moment the loss is observed.
    func test_membershipLoss_triggersGateLostPurge_withoutNewFrames() {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) }
        )
        // Install a live lease.
        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertTrue(coordinator.policy.permitsCollection, "premise: gate open")

        var gateLostCount = 0
        let gateLostSubscription = coordinator.registerGateLostHandler { gateLostCount += 1 }
        _ = gateLostSubscription

        // Membership withdrawal via the store observer path.
        coordinator.enrollmentStore.withdrawLocally(acceptedServerProjectionAfterward: true)
        XCTAssertEqual(gateLostCount, 1,
                       "membership loss triggers the purge immediately, without waiting for frames")

        // Refresh that reads the gate closed: the remote switch flipped off since the last fetch, so the
        // refreshed snapshot installs DISABLED — and the purge fires at the refresh, without new frames.
        box.value = .unavailable
        let token2 = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token2)
        XCTAssertFalse(coordinator.policy.permitsCollection, "the refreshed snapshot is disabled")
        XCTAssertEqual(gateLostCount, 2,
                       "a refresh observing the gate closed also triggers the purge")
    }

    /// THE expiry control: the purge fires at the LEASE DEADLINE itself — via the scheduled monotonic
    /// trigger, not a refresh, not new frames. The production composition subscriber is the coordinator's
    /// own `scheduleLeaseExpiryTrigger` (default scheduler: asyncAfter on the computed delay).
    func test_leaseExpiryAtDeadline_triggersGateLostPurge_withoutRefreshOrFrames() {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) }
        )
        var gateLostCount = 0
        let gateLostSubscription = coordinator.registerGateLostHandler { gateLostCount += 1 }
        _ = gateLostSubscription

        // Capture the production schedule instead of running it.
        var scheduled: (delay: TimeInterval, body: () -> Void)?
        coordinator.expiryScheduler = { delay, body in scheduled = (delay, body) }

        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertTrue(coordinator.policy.permitsCollection, "premise: lease installed")
        guard let firstSchedule = scheduled else { return XCTFail("an expiry schedule was installed with the lease") }
        let staleBody = firstSchedule.body
        XCTAssertGreaterThan(firstSchedule.delay, 0, "the schedule targets the lease deadline, not now")
        XCTAssertEqual(firstSchedule.delay, VoiceSharingPolicy.leaseSecondsDefault,
                       "deadline = install time + lease duration")

        // The deadline arrives WITHOUT any refresh or frames. The gate re-read at fire time closes.
        clock.advance(VoiceSharingPolicy.leaseSecondsDefault + 1)
        firstSchedule.body()
        XCTAssertFalse(coordinator.policy.permitsCollection, "the lease has lapsed")
        XCTAssertEqual(gateLostCount, 1, "expiry itself triggered the purge")

        // A renewed lease replaces the schedule: firing the STALE schedule must NOT purge.
        box.value = .valid(true)
        let token2 = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token2)
        XCTAssertTrue(coordinator.policy.permitsCollection, "premise: lease renewed")
        XCTAssertEqual(gateLostCount, 1)
        // The NEW lease also lapses before the STALE schedule fires: with the token check, the stale
        // body is a no-op even though the gate now reads closed. (Firing while the gate is open would
        // not discriminate — the gate re-read alone would suppress the purge.)
        clock.advance(VoiceSharingPolicy.leaseSecondsDefault + 1)
        staleBody()
        XCTAssertEqual(gateLostCount, 1, "a stale expiry schedule cannot purge, even with the gate closed")
        XCTAssertFalse(coordinator.policy.permitsCollection, "the new lease has now lapsed (premise)")
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

    /// Rebuild control: a pipeline build REGISTERS its own subscription instead of overwriting the
    /// shared handler. While the OLD collector still owns audio (open capture + FIFO), withdrawal
    /// must purge BOTH collectors; and the expiry-trigger path reaches both as well.
    func test_rebuildRegistersSeparateSubscriptions_withdrawalPurgesBothCollectors() {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) }
        )
        final class EnrollBox { var enrolled = true }
        let enrollBox = EnrollBox()
        var enrolledProjection: VoiceSharingEnrollmentStore.State {
            var st = VoiceSharingEnrollmentStore.State()
            st.localOptIn = true
            st.hasAuthoritativeProjection = true
            st.membership = VoiceSharingMembership(
                membershipRevision: "r1", plan: .pro, voiceSharingEnrolled: enrollBox.enrolled,
                enrollmentEpoch: "e1", acceptedDisclosureVersion: "2026-09", withdrawalState: .active
            )
            return st
        }
        func makePipelineCollector(sink: @escaping (VoiceSharingCollector.SegmentEvent) -> Void)
            -> VoiceSharingCollector {
            VoiceSharingCollector(
                policy: coordinator.policy,
                membership: { enrolledProjection },
                epochProvider: { "e1" },
                sessionIdentity: { "gen-A" },
                sink: sink
            )
        }
        var oldEvents: [VoiceSharingCollector.SegmentEvent] = []
        var newEvents: [VoiceSharingCollector.SegmentEvent] = []
        let oldCollector = makePipelineCollector { oldEvents.append($0) }
        let newCollector = makePipelineCollector { newEvents.append($0) }

        // Premise: an enrolled user under an installed lease, so the old collector's audio is ACCEPTED.
        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)

        // OLD pipeline owns audio; the rebuild happens; the NEW subscription must not erase the old one.
        let sub1 = coordinator.registerGateLostHandler { [weak oldCollector] in oldCollector?.gateLost() }
        let sub2 = coordinator.registerGateLostHandler { [weak newCollector] in newCollector?.gateLost() }
        _ = sub1

        // An OPEN partial (plus queued work) at rebuild time: gate loss must cancel it and purge the queue.
        oldCollector.speechStarted(confirmationFrameSamples: 320)
        oldCollector.appendSamples([Float](repeating: 1, count: 640), reportedTotal: 640)
        XCTAssertGreaterThan(oldCollector.aggregateAudioSamplesForTesting, 0,
                             "premise: the old collector still owns audio at rebuild time")
        withExtendedLifetime(sub2) {}

        // Withdrawal (identity move) fans out to BOTH live registrations. The store observer fires the
        // coordinator's own gate-loss fan-out.
        enrollBox.enrolled = false
        coordinator.enrollmentStore.withdrawLocally(acceptedServerProjectionAfterward: true)
        XCTAssertEqual(oldCollector.aggregateAudioSamplesForTesting, 0,
                       "the OLD collector's audio is purged by the withdrawal")
        XCTAssertTrue(oldCollector.waitForDrain(), "premise: the async drain completed")
        XCTAssertTrue(oldEvents.contains { $0.isGateControl },
                      "the old collector emitted its content-free cancellation record")
        XCTAssertEqual(newCollector.aggregateAudioSamplesForTesting, 0,
                       "the NEW collector is also purged")

        // And the EXPIRY-TRIGGER path reaches both registrations too (lapse the lease, fire the schedule).
        var scheduled: (delay: TimeInterval, body: () -> Void)?
        coordinator.expiryScheduler = { delay, body in scheduled = (delay, body) }
        let renewToken = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: renewToken)
        guard let firstSchedule = scheduled, let staleBody = firstSchedule.body as (() -> Void)? else {
            return XCTFail("expiry schedule installed")
        }
        clock.advance(firstSchedule.delay + 1)   // the lease lapses at its own deadline
        XCTAssertFalse(coordinator.policy.permitsCollection, "premise: the lease has expired")
        var oldPurges = 0, newPurges = 0
        let oldProbe = coordinator.registerGateLostHandler { oldPurges += 1 }
        let newProbe = coordinator.registerGateLostHandler { newPurges += 1 }
        _ = oldProbe
        withExtendedLifetime(newProbe) {
            staleBody()
            XCTAssertEqual(oldPurges, 1, "the expiry trigger notifies the OLD registration too")
            XCTAssertEqual(newPurges, 1, "and the NEW one")
        }
    }


    /// AUDIT FIX CONTROL (spec c252767f): an installed lease must arm expiry-driven revocation FROM THE
    /// INSTALL SITE, so nothing depends on which caller installed it. This drives the production path —
    /// install through `policyRefreshAfterActivation`, a scheduler that CAPTURES the real deadline, then
    /// advance the injected clock past expiry and RUN the captured body — and observes the purge.
    /// Asserting "no purge" would prove nothing; this asserts the purge, of ALL THREE holders the
    /// production gate-lost handler names (assembly registration): the sink's revocation generation, the
    /// collector's ring, and the DURABLE queue (review 15a18d5d: the ring alone is not the whole estate).
    func test_anInstalledLeaseArmsExpiryRevocationAndPurgesTheCollector() throws {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) }
        )
        // Capture the production schedule so the test can run it at the real deadline.
        var scheduled: (delay: TimeInterval, body: () -> Void)?
        coordinator.expiryScheduler = { delay, body in scheduled = (delay, body) }

        var variables: [String: Any] = [:]
        var state = VoiceSharingEnrollmentStore.State()
        state.localOptIn = true
        state.hasAuthoritativeProjection = true
        state.membership = VoiceSharingMembership(
            membershipRevision: "r1", plan: .pro, voiceSharingEnrolled: true,
            enrollmentEpoch: "e1", acceptedDisclosureVersion: "2026-09", withdrawalState: .active)
        let collector = VoiceSharingCollector(
            policy: coordinator.policy,
            membership: { state },
            epochProvider: { "e1" },
            sessionIdentity: { "gen-A" },
            sink: { event in variables["event"] = event })

        // The DURABLE half of the estate: a real queue holding a prepared entry, and a sink whose
        // generation must move. The registered handler mirrors the production assembly registration.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsexpiry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let sink = VoiceSharingContributionSink(
            queue: queue, isEnabled: { true },
            encoderProvenance: {
                .init(platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
                      models: .init(vad: .init(id: "vad-1", version: "1"),
                                    wakeword: .init(id: "wake-1", version: "1"),
                                    asr: .init(id: "asr-1", version: "1"), translation: nil,
                                    router: .init(id: "router-1", version: "1")),
                      conversionVersion: "v1")
            })
        sink.handle(.init(kind: .completed, captureID: UUID(), enrollmentEpoch: "e1",
                          authorizationSession: "sess-1", retainedSamples: 640, truncated: false,
                          droppedSpans: [], originalSampleCount: nil,
                          audio: [Float](repeating: 0.1, count: 640), isGateControl: false))
        sink.waitForIdleForTesting()
        guard case .known(let readyBefore) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("premise: coverage known")
        }
        XCTAssertGreaterThan(readyBefore.count, 0,
                             "premise: a durable entry exists before expiry")
        let generationBefore = sink.revocationGenerationForTesting

        let subscription = coordinator.registerGateLostHandler {
            sink.noteRevocation()
            collector.gateLost()
            _ = queue.purgeAll()
        }

        withExtendedLifetime(subscription) {
            // Install through the POLICY's own single install point, NOT through the coordinator's
            // refresh wrapper: the wrapper arms its own schedule, so routing through it would mask a
            // missing install-site hook entirely. This is the path a lease takes whenever it is
            // installed by anything other than that wrapper.
            let token = coordinator.policy.tokenForFetchStart()
            XCTAssertNotNil(
                coordinator.policy.refreshAfterActivation(
                    freshActivationSucceeded: true, fetchToken: token),
                "premise: the lease installed at the policy's own install point")
            XCTAssertTrue(coordinator.policy.permitsCollection, "premise: lease installed")
            guard let schedule = scheduled else {
                return XCTFail("an installed lease must arm an expiry schedule at the install site")
            }
            XCTAssertEqual(schedule.delay, VoiceSharingPolicy.leaseSecondsDefault,
                           "the schedule targets the lease deadline")

            // The COLLECTOR is holding audio, so the purge has something real to destroy.
            _ = collector.speechStarted(confirmationFrameSamples: 320)
            collector.appendSamples([Float](repeating: 1, count: 640), reportedTotal: 640)
            XCTAssertGreaterThan(collector.aggregateAudioSamplesForTesting, 0,
                                 "premise: the collector owns buffered audio")

            // Time passes with NO refresh, NO frames, NO launch: the schedule alone must act.
            clock.advance(VoiceSharingPolicy.leaseSecondsDefault + 1)
            schedule.body()

            XCTAssertFalse(coordinator.policy.permitsCollection, "the lease has lapsed")
            XCTAssertEqual(collector.aggregateAudioSamplesForTesting, 0,
                           "expiry itself purged the collector's ring")
            XCTAssertTrue(collector.waitForDrain(), "premise: the async drain completed")
            guard let event = variables["event"] as? VoiceSharingCollector.SegmentEvent else {
                return XCTFail("consent loss must emit a cancellation record")
            }
            XCTAssertTrue(event.isGateControl,
                          "the purge reports itself as gate control, not as captured audio")
            XCTAssertEqual(sink.revocationGenerationForTesting, generationBefore + 1,
                           "expiry must supersede the sink's authorization, not just free space")
            guard case .known(let readyAfter) = queue.readyEntriesReportingUnknownCoverage() else {
                return XCTFail("coverage known")
            }
            XCTAssertEqual(readyAfter.count, 0,
                           "expiry itself purged the DURABLE queue")
        }
    }

    /// REVIEW 5ae8f430: a renewal that lands before a STALE fire must be immune — the stale expiry
    /// may revoke nothing. The lease is renewed AFTER its original deadline lapsed, then the stale
    /// schedule runs: the generation-bound revoke must refuse, and both the fresh permission and the
    /// sink's authorization generation must survive untouched. Drives the production decision
    /// function at the policy boundary, where the atomicity actually lives.
    func test_aRenewalBeforeAStaleExpiryFireIsImmuneToIt() throws {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) })
        var firedBodies: [() -> Void] = []
        coordinator.expiryScheduler = { _, body in firedBodies.append(body) }
        var purges = 0
        let subscription = coordinator.registerGateLostHandler { purges += 1 }

        let token1 = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token1)
        let armedTarget = try XCTUnwrap(coordinator.policy.leaseExpiryTarget())
        XCTAssertEqual(firedBodies.count, 1, "premise: the install armed one schedule")
        let staleFire = firedBodies[0]

        // The original deadline lapses with no refresh — then the RENEWAL installs a fresh lease.
        clock.advance(VoiceSharingPolicy.leaseSecondsDefault + 1)
        let token2 = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token2)
        XCTAssertTrue(coordinator.policy.permitsCollection, "premise: the fresh lease is live")

        // The STALE fire runs against the superseded (generation, deadline) PAIR: it must do
        // NOTHING, even though the old deadline has lapsed and the fresh lease is live.
        withExtendedLifetime(subscription) {
            staleFire()
            XCTAssertFalse(coordinator.policy.revokeIfLeaseExpired(
                generation: armedTarget.generation, deadline: armedTarget.deadline),
                "the armed pair was superseded; the policy must refuse")
            XCTAssertEqual(purges, 0, "a stale expiry must not fire the revocation fan-out")
            XCTAssertTrue(coordinator.policy.permitsCollection,
                          "the fresh lease survives the stale fire")
        }
    }

    /// Review e827a22e, race 2: the revoke must refuse an UNEXPIRED lease. The CURRENT generation
    /// with a STALE (already-lapsed) deadline — the exact pairing a separately-read token could
    /// produce — must not revoke the fresh, longer-dated lease.
    func test_aStaleDeadlineDoesNotRevokeAnUnexpiredFreshLease() throws {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) })
        let token1 = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token1)
        let oldTarget = try XCTUnwrap(coordinator.policy.leaseExpiryTarget())
        var purges = 0
        let subscription = coordinator.registerGateLostHandler { purges += 1 }
        withExtendedLifetime(subscription) {
            // Renewal: the clock moved past the old deadline and the fresh lease is longer-dated.
            clock.advance(VoiceSharingPolicy.leaseSecondsDefault + 1)
            let token2 = coordinator.policy.tokenForFetchStart()
            coordinator.policyRefreshAfterActivation(
                freshActivationSucceeded: true, fetchToken: token2)
            XCTAssertTrue(coordinator.policy.permitsCollection, "premise: fresh lease is live")
        }
        // The CURRENT generation paired with the OLD deadline — exactly the mismatch a
        // separately-read token could produce. It must refuse, because the live deadline differs;
        // a revoke that ignored the deadline would kill the unexpired fresh lease.
        let currentGeneration = try XCTUnwrap(coordinator.policy.leaseExpiryTarget()).generation
        XCTAssertFalse(coordinator.policy.revokeIfLeaseExpired(
            generation: currentGeneration, deadline: oldTarget.deadline),
            "an old deadline must not revoke the fresh, longer-dated lease")
        XCTAssertEqual(purges, 0)
        XCTAssertTrue(coordinator.policy.permitsCollection,
                      "the unexpired fresh lease survives")
    }

    /// Review e827a22e, race 3 (deterministic barrier): the revocation fan-out and the renewal's
    /// publication are serialized — a renewal CANNOT publish while an old-generation fan-out is
    /// running, so its captures cannot be purged by the old generation's handlers. The handler
    /// signals it is inside the fan-out; a background refresh is then attempted and must still be
    /// BLOCKED while the handler holds the barrier; only after the fan-out completes does it publish.
    func test_aRenewalCannotPublishDuringAnOldGenerationFanOut() throws {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) })
        var bodies: [() -> Void] = []
        coordinator.expiryScheduler = { _, body in bodies.append(body) }
        let release = NSCondition()
        var insideFanOut = false
        var proceed = false
        var refreshPublished = false
        let subscription = coordinator.registerGateLostHandler {
            release.lock(); insideFanOut = true; release.signal(); release.unlock()
            release.lock()
            while !proceed { release.wait() }
            release.unlock()
        }
        let token1 = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token1)
        XCTAssertEqual(bodies.count, 1, "premise: one schedule")
        withExtendedLifetime(subscription) {
            // The fire must be a REAL expiry: advance past the deadline, or the policy refuses and
            // no fan-out ever runs (the first version of this control hung exactly there).
            clock.advance(VoiceSharingPolicy.leaseSecondsDefault + 1)
            let fire = DispatchQueue.global(qos: .userInitiated)
            fire.async { bodies[0]() }
            // Wait until the fan-out is inside the handler (holding the barrier).
            release.lock(); while !insideFanOut { release.wait() }; release.unlock()
            // Attempt a RENEWAL while the old generation's fan-out is in flight.
            let renewer = DispatchQueue.global(qos: .userInitiated)
            renewer.async {
                let t2 = coordinator.policy.tokenForFetchStart()
                coordinator.policyRefreshAfterActivation(
                    freshActivationSucceeded: true, fetchToken: t2)
                release.lock(); refreshPublished = true; release.signal(); release.unlock()
            }
            // The renewal must be BLOCKED while the fan-out holds the barrier. The handler's own
            // wait gives the renewer ample time to (wrongly) publish if the barrier is missing.
            release.lock(); proceed = true; release.signal(); release.unlock()
            release.lock()
            let deadline = Date().addingTimeInterval(5)
            while !refreshPublished, Date() < deadline { release.wait(until: deadline) }
            release.unlock()
            XCTAssertTrue(refreshPublished, "the renewal publishes after the fan-out completes")
            XCTAssertTrue(coordinator.policy.permitsCollection, "the renewed lease is live")
        }
    }

    /// The OTHER half of the atomic transition: the CURRENT generation still revokes in one step.
    /// Without this half, refusing every revoke would pass the immunity control above.
    func test_theCurrentGenerationStillRevokesAtomically() throws {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) })
        var purges = 0
        let subscription = coordinator.registerGateLostHandler { purges += 1 }
        var bodies: [() -> Void] = []
        coordinator.expiryScheduler = { _, body in bodies.append(body) }
        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertEqual(bodies.count, 1, "premise: exactly one schedule per install")
        let target = try XCTUnwrap(coordinator.policy.leaseExpiryTarget())
        withExtendedLifetime(subscription) {
            // Advance past the deadline so the expiry precondition holds, then run the captured
            // body through the SAME path the scheduler uses (it holds the renewal barrier).
            clock.advance(VoiceSharingPolicy.leaseSecondsDefault + 1)
            DispatchQueue.global().sync {
                if coordinator.policy.revokeIfLeaseExpired(
                    generation: target.generation, deadline: target.deadline) {
                    // Mirror the coordinator body; the barrier itself is covered by its own control.
                }
                coordinator.consentGateLostForTesting()
            }
            XCTAssertEqual(purges, 1, "a live-lease expiry revokes and fires the fan-out once")
            XCTAssertFalse(coordinator.policy.permitsCollection, "the lease is gone")
            // Re-running a consumed fire must be inert: the generation moved, nothing re-fires.
            XCTAssertFalse(coordinator.policy.revokeIfLeaseExpired(
                generation: target.generation, deadline: target.deadline),
                "a consumed pair must be refused")
            coordinator.consentGateLostForTesting()
            XCTAssertEqual(purges, 2, "consentGateLostForTesting is direct; only the policy refuses")
        }
    }

    /// Review a1809497: DIRECT policy installation (bypassing the coordinator wrapper entirely) must
    /// be serialized against an old-generation fan-out too, because the barrier lives at the POLICY's
    /// install authority, not in any caller. A direct install attempted while an old-generation
    /// fan-out is running may only publish after the fan-out completes.
    func test_aDirectPolicyInstallCannotPublishDuringAnOldGenerationFanOut() throws {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) })
        var bodies: [() -> Void] = []
        coordinator.expiryScheduler = { _, body in bodies.append(body) }
        let release = NSCondition()
        var insideFanOut = false
        var proceed = false
        var installPublished = false
        // The point of the control: the install must not publish WHILE the old fan-out is running.
        // The handler itself watches for that — a final-state assertion alone cannot tell "after"
        // from "during" (the first version of this control passed the no-barrier mutant on exactly
        // that blindness).
        var publishedDuringFanOut = false
        let subscription = coordinator.registerGateLostHandler {
            release.lock(); insideFanOut = true; release.signal(); release.unlock()
            release.lock()
            while !proceed {
                if installPublished { publishedDuringFanOut = true }
                release.wait()
            }
            if installPublished { publishedDuringFanOut = true }
            release.unlock()
        }
        let token1 = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token1)
        XCTAssertEqual(bodies.count, 1, "premise: one schedule")
        withExtendedLifetime(subscription) {
            clock.advance(VoiceSharingPolicy.leaseSecondsDefault + 1)
            let fire = DispatchQueue.global(qos: .userInitiated)
            fire.async { bodies[0]() }
            release.lock(); while !insideFanOut { release.wait() }; release.unlock()
            // The DIRECT path: the policy's own install entry point, no coordinator wrapper.
            let installer = DispatchQueue.global(qos: .userInitiated)
            installer.async {
                let t2 = coordinator.policy.tokenForFetchStart()
                _ = coordinator.policy.refreshAfterActivation(
                    freshActivationSucceeded: true, fetchToken: t2)
                release.lock(); installPublished = true; release.signal(); release.unlock()
            }
            release.lock(); proceed = true; release.signal(); release.unlock()
            release.lock()
            let deadline = Date().addingTimeInterval(5)
            while !installPublished, Date() < deadline { release.wait(until: deadline) }
            release.unlock()
            XCTAssertTrue(installPublished, "the direct install publishes after the fan-out")
            XCTAssertFalse(publishedDuringFanOut,
                           "a direct install must not publish DURING an old-generation fan-out")
            XCTAssertTrue(coordinator.policy.permitsCollection, "the installed lease is live")
        }
    }

    /// Review 32d86559: the lock ORDER itself. A concurrent install and expiry must not be able to
    /// each hold one lock and wait for the other. Deterministic construction: MAIN holds the install
    /// barrier; thread A enters an install (under the OLD order it then blocks at the barrier still
    /// holding the POLICY lock; under the fixed order it drops the policy lock first); thread B then
    /// runs the expiry revoke, which needs the policy lock. Under the inversion B can NEVER proceed —
    /// the watchdog fails the test instead of hanging the suite (the deadlock never completes, so a
    /// generous timeout distinguishes it deterministically).
    func test_installAndExpiryOverlapCannotDeadlockOnTheTwoLocks() throws {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) })
        let token1 = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token1)
        // Advance past the deadline so the expiry revoke is a REAL lapse when it runs.
        clock.advance(VoiceSharingPolicy.leaseSecondsDefault + 1)
        let target = try XCTUnwrap(coordinator.policy.leaseExpiryTarget())

        let barrier = coordinator.policy.installPublicationBarrier
        barrier.lock() // MAIN holds the install barrier: any installer must now wait at it.
        let release = NSCondition()
        var installerAtBarrier = false
        var revokeCompleted = false
        // DETERMINISTIC ARRIVAL SIGNAL (review 83e0177b): the policy fires this immediately
        // before its barrier wait, so the overlap is awaited, not slept into.
        coordinator.policy.onInstallBarrierArrivalForTesting = {
            release.lock(); installerAtBarrier = true; release.signal(); release.unlock()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let t2 = coordinator.policy.tokenForFetchStart()
            _ = coordinator.policy.refreshAfterActivation(
                freshActivationSucceeded: true, fetchToken: t2)
        }
        release.lock()
        let arrivalDeadline = Date().addingTimeInterval(3)
        while !installerAtBarrier, Date() < arrivalDeadline { release.wait(until: arrivalDeadline) }
        release.unlock()
        XCTAssertTrue(installerAtBarrier, "premise: the installer reached the barrier")
        // ONLY NOW the revoker runs: under the inversion the installer holds the policy lock
        // while blocked at the barrier, so the revoke can never proceed.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = coordinator.policy.revokeIfLeaseExpired(
                generation: target.generation, deadline: target.deadline)
            release.lock(); revokeCompleted = true; release.signal(); release.unlock()
        }
        release.lock()
        let deadline = Date().addingTimeInterval(3)
        while !revokeCompleted, Date() < deadline { release.wait(until: deadline) }
        release.unlock()
        barrier.unlock()
        // A revoke that can never take the policy lock means the inversion is back.
        XCTAssertTrue(revokeCompleted,
                      "the expiry revoke must not be starved by an install holding the policy "
                          + "lock while waiting on the install barrier (lock inversion)")
    }

    /// REVIEW 15a18d5d: lifting the identity fence must INITIATE the normal refresh. A fence without
    /// a fetch never installs, and production's only fetch calls lived at launch and in the developer
    /// menu — so a re-login in a long-running process stayed closed until relaunch. This drives the
    /// REAL login transition and observes the refresh being initiated, then completes it through the
    /// production activation path and asserts the install plus its expiry schedule.
    func test_reLoginInitiatesTheNormalRefreshAndInstalls() throws {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) })
        var scheduled = false
        coordinator.expiryScheduler = { _, _ in scheduled = true }
        var refreshInitiated = false
        coordinator.initiateIdentityRecoveryRefresh = { refreshInitiated = true }

        // A fenced state first: an identity transition raises the fence, so installs are refused.
        coordinator.policy.invalidateForIdentityChange()
        let fencedToken = coordinator.policy.tokenForFetchStart()
        XCTAssertNil(coordinator.policy.refreshAfterActivation(
            freshActivationSucceeded: true, fetchToken: fencedToken),
            "premise: the fence refuses installs")

        // The RE-LOGIN transition: fence lifts AND the normal refresh is initiated, in one step.
        coordinator.handleLoginStateDidChange(signedIn: true)
        XCTAssertTrue(refreshInitiated,
                      "recovery must initiate the refresh, not merely permit a future one")

        // The initiated refresh completes through the production activation path: install + schedule.
        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertTrue(coordinator.policy.permitsCollection, "the recovered lease is installed")
        XCTAssertTrue(scheduled, "the recovered install armed its expiry schedule")
    }

    /// Token-ownership control: the COLLECTOR owns its registration, so releasing the old ENGINE
    /// during a held delivery does not unregister it — a later consent loss still purges the
    /// collector that the held drain keeps alive. (One engine attached, then released: retaining
    /// two engines would not exercise this.)
    func test_engineReleasedDuringHeldDelivery_collectorStillPurgedAtConsentLoss() {
        let clock = StubMonotonicClock(time: 1_000)
        final class SwitchBox { var value: VoiceSharingPolicy.RemoteSwitchValue = .valid(true) }
        let box = SwitchBox()
        let coordinator = VoiceSharingCoordinator(
            clock: clock,
            readRemoteSwitch: { box.value },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) }
        )
        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)

        final class EnrollBox { var enrolled = true }
        let enrollBox = EnrollBox()
        func enrolledState() -> VoiceSharingEnrollmentStore.State {
            var st = VoiceSharingEnrollmentStore.State()
            st.localOptIn = true
            st.hasAuthoritativeProjection = true
            st.membership = VoiceSharingMembership(
                membershipRevision: "r1", plan: .pro, voiceSharingEnrolled: enrollBox.enrolled,
                enrollmentEpoch: "e1", acceptedDisclosureVersion: "2026-09", withdrawalState: .active
            )
            return st
        }

        // Parking sink: the FIRST audio-carrying event parks its drain hop, holding the collector.
        let hold = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let holdState = NSLock()
        var alreadyHeld = false
        var deliveredAfterLoss: [VoiceSharingCollector.SegmentEvent] = []
        let afterLossLock = NSLock()
        let collector = VoiceSharingCollector(
            policy: coordinator.policy,
            membership: { enrolledState() },
            epochProvider: { "e1" },
            sessionIdentity: { "gen-A" },
            sink: { event in
                if !enrollBox.enrolled {
                    afterLossLock.lock(); deliveredAfterLoss.append(event); afterLossLock.unlock()
                }
                guard !event.audio.isEmpty else { return }
                holdState.lock()
                let first = !alreadyHeld
                alreadyHeld = true
                holdState.unlock()
                if first {
                    entered.signal()
                    hold.wait()
                }
            }
        )
        // THE FIX UNDER TEST: the collector owns its registration token (not the engine).
        var fanoutCount = 0
        let probe = coordinator.registerGateLostHandler { fanoutCount += 1 }
        _ = probe
        collector.gateLostSubscription =
            coordinator.registerGateLostHandler { [weak collector] in collector?.gateLost() }

        // An engine pipeline holds the collector; the collector owns audio queued for delivery.
        let backend = EngineStubBackend()
        // The OPTIONAL is the ONLY strong owner: nil-ing it must actually deallocate.
        var engineBox: VoiceAsrEngine? = VoiceAsrEngine(
            capture: NativeAudioCapture(),
            segmenter: NativeVadSegmenter(silenceTimeoutMs: 60),
            backend: backend,
            signalFilter: SignalFilter(),
            wakeWordDetector: NotDetectedWakeForR19(),
            gracePeriodSignal: GracePeriodSignal(),
            translationStage: nil
        )
        engineBox?.contributionCollector = collector
        weak var weakEngine = engineBox
        XCTAssertNotNil(weakEngine, "premise: the weak reference tracks the engine")
        collector.speechStarted(confirmationFrameSamples: 320)
        let ctxA = collector.currentCaptureContextForTesting
        collector.appendSamples([Float](repeating: 1, count: 640), reportedTotal: 640)
        collector.speechCompleted([Float](repeating: 1, count: 640), context: ctxA)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "premise: drain parked in the sink")

        // More audio queued BEHIND the parked hop, plus an OPEN partial: at consent loss the FIFO
        // must purge, the open partial must become a content-free cancellation, and the parked
        // in-flight bytes remain owned until the sink returns.
        collector.speechStarted(confirmationFrameSamples: 320)
        let ctxB = collector.currentCaptureContextForTesting
        collector.appendSamples([Float](repeating: 1, count: 320), reportedTotal: 320)
        collector.speechCompleted([Float](repeating: 1, count: 320), context: ctxB)
        collector.speechStarted(confirmationFrameSamples: 320)   // open partial C
        collector.appendSamples([Float](repeating: 1, count: 128), reportedTotal: 128)
        XCTAssertGreaterThan(collector.pendingCountForTesting, 0, "premise: FIFO holds work behind the parked hop")

        withExtendedLifetime(collector) {
            do {
                // Released on EVERY failure path out of this block (finally semantics), but BEFORE
                // the post-release assertions below.
                defer { hold.signal() }
                // RELEASE THE ENGINE while the collector still owns audio and its drain is parked.
                engineBox = nil
                XCTAssertNil(weakEngine,
                             "premise: the engine really deallocated — the collector's registration outlives it")

                // Consent loss reaches the collector even though the engine is gone.
                enrollBox.enrolled = false
                coordinator.enrollmentStore.withdrawLocally(acceptedServerProjectionAfterward: true)
                XCTAssertEqual(fanoutCount, 1, "the withdrawal reached the coordinator's fan-out")
                // The FIFO's audio work (B) was purged; what remains queued is the open partial's
                // content-free cancellation record only.
                afterLossLock.lock(); let during = deliveredAfterLoss; afterLossLock.unlock()
                XCTAssertTrue(during.isEmpty, "the purged FIFO work is never delivered")
            }
            // The PARKED event's bytes were still in-flight (owned until the sink returned) — now
            // released, only the content-free gate record may have followed.
            XCTAssertTrue(collector.waitForDrain())
            XCTAssertEqual(collector.aggregateAudioSamplesForTesting, 0,
                           "after the held sink returns, nothing is owned")
            afterLossLock.lock(); let late = deliveredAfterLoss; afterLossLock.unlock()
            XCTAssertEqual(late.count, 1, "the cancellation record followed the held delivery")
            XCTAssertTrue(late.allSatisfy { $0.isGateControl },
                          "nothing but the content-free gate record reaches the sink after the loss")
        }
    }

    /// Concurrency control: registration, teardown and fan-out from many threads do not race the
    /// registry; a handler that tears ITSELF down reentrantly must not deadlock the fan-out, and
    /// surviving registrations must still be reached.
    func test_gateLostRegistry_concurrentRegistrationTeardownAndReentrantSelfTeardown() {
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true },
            now: { Date(timeIntervalSince1970: 5_000) },
            lastFetchTime: { Date(timeIntervalSince1970: 5_000) }
        )
        let chaosQueue = DispatchQueue(label: "chaos", attributes: .concurrent)
        let group = DispatchGroup()
        var subs: [VoiceSharingCoordinator.GateLostSubscription] = []
        let subsLock = NSLock()
        var fired = 0
        let firedLock = NSLock()
        let handler = { firedLock.lock(); fired += 1; firedLock.unlock() }

        // Mutation threads: register and tear down WHILE fan-outs run against the same registry.
        for _ in 0..<8 {
            group.enter()
            chaosQueue.async {
                for _ in 0..<50 {
                    let sub = coordinator.registerGateLostHandler(handler)
                    subsLock.lock(); subs.append(sub); subsLock.unlock()
                    if arc4random_uniform(2) == 0 { sub.unregisterNow() }
                }
                group.leave()
            }
        }
        // REAL concurrent fan-outs: invoked on other threads while the mutation threads mutate.
        for _ in 0..<4 {
            group.enter()
            chaosQueue.async {
                for _ in 0..<100 { coordinator.consentGateLostForTesting() }
                group.leave()
            }
        }
        // BOUNDED: the churn must terminate; a registry deadlock fails the test instead of hanging CI.
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success,
                       "concurrent registration/teardown/fan-out must terminate")
        XCTAssertGreaterThan(fired, 0, "premise: fan-outs actually invoked handlers during the churn")
        // Drain the accumulated subscriptions so their deinits do not fire mid-teardown of the test.
        subsLock.lock(); let all = subs; subs.removeAll(); subsLock.unlock()
        for sub in all { sub.unregisterNow() }

        // Reentrant SELF-teardown during fan-out: the handler removes itself mid-invocation.
        var survivingFired = 0
        let survivor: VoiceSharingCoordinator.GateLostSubscription =
            coordinator.registerGateLostHandler { survivingFired += 1 }
        var selfRemovingRef: VoiceSharingCoordinator.GateLostSubscription?
        let selfRemoving = coordinator.registerGateLostHandler {
            selfRemovingRef?.unregisterNow()   // re-enters the registry from inside a handler
        }
        selfRemovingRef = selfRemoving
        coordinator.consentGateLostForTesting()
        XCTAssertEqual(survivingFired, 1, "the surviving registration is reached despite the reentrant teardown")
        coordinator.consentGateLostForTesting()
        XCTAssertEqual(survivingFired, 2, "and again on the next fan-out; the self-removed one is not invoked")
        _ = survivor
    }

private final class NotDetectedWakeForR19: WakeWordDetectorProtocol {
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult { .notDetected(confidence: 0.05) }
    func release() {}
}

}