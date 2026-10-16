import Foundation

/// The validated, immutable client snapshot of the Voice Sharing remote switch.
///
/// The contract this type exists to enforce (voice-recording-uploads spec,
/// "Remote policy"): Firebase supplies CONFIGURATION, never authorization, and a
/// missing/invalid/expired value must DISABLE the feature. Local defaults can only
/// ever be `false` — there is no code path where an absent remote value enables
/// collection. That asymmetry is the whole safety property, so it is expressed in
/// how snapshots are made: an enabled snapshot requires a valid remotely supplied
/// Boolean plus a fresh lease plus account enrollment, together or not at all.
struct VoiceSharingSnapshot: Equatable {
    let enabledRemotely: Bool
    /// Elapsed-monotonic instant until which this snapshot may be trusted.
    let leaseExpiresAt: MonotonicTime
    /// Enrollment is ACCOUNT state folded into the effective decision here, so no
    /// caller can read "enabled" from configuration alone.
    let accountEnrolled: Bool

    func permitsCollection(at now: MonotonicTime) -> Bool {
        enabledRemotely && accountEnrolled && now < leaseExpiresAt
    }
}

/// Reads the single scalar switch through the existing typed-accessor pattern and
/// installs snapshots only after a completed fetch/activate.
///
/// Deliberately does NOT persist any activation timestamp as lease evidence:
/// monotonic clocks restart with the process, so nothing carried across relaunch
/// can prove a lease's age, and a restored "valid until" would let a stale cached
/// value enable collection without a fresh remote read. After restart the ONLY way
/// to obtain a snapshot is `refreshAfterActivation()` backed by a real
/// fetch→activate completion. Persisted state may record that a refresh is owed;
/// it never records that a lease is valid.
final class VoiceSharingPolicy {
    /// Conservative compiled default while numeric activation limits remain owner
    /// decisions (spec "Decisions required before activation"). Stale config
    /// disables rather than continuing to collect.
    static let leaseSecondsDefault: TimeInterval = 6 * 60 * 60

    enum RemoteSwitchValue: Equatable {
        /// A genuine remotely supplied Boolean, read after activate completed.
        case valid(Bool)
        /// Absent, wrong-typed, read before activation completed, or produced by a failed
        /// fetch/activation. Never enables.
        case unavailable
    }

    /// Strict decode of a raw published value into a switch decision. This is the PRODUCTION
    /// decoder — callers pass whatever the config store handed them rather than a pre-decided
    /// `.valid(...)`, so coercion bugs cannot hide behind injected enums.
    ///
    /// Only a real boolean counts. `NSNumber.intValue` truncates (`1.5 -> 1`) and its
    /// `boolValue` accepts non-boolean strings, so neither may decide this: anything that is
    /// not a genuine ObjC boolean literal is INVALID, and invalid means disabled.
    static func decodeRemoteSwitch(_ raw: Any?) -> RemoteSwitchValue {
        guard let number = raw as? NSNumber else { return .unavailable }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .valid(number.boolValue)
        }
        return .unavailable
    }

    private let clock: MonotonicClock
    private let leaseSeconds: TimeInterval
    private let readRemoteSwitch: () -> RemoteSwitchValue
    private let isAccountEnrolled: () -> Bool
    /// Monotonically increasing identity generation. Bumped by every real account transition so a
    /// callback that began under an older generation can be recognised as stale at install time.
    private var identityGenerationCounter: Int = 0

    private let lock = NSLock()
    private var installed: VoiceSharingSnapshot?
    private var pendingIdentityFence: Int = 0

    init(
        clock: MonotonicClock = SystemMonotonicClock(),
        leaseSeconds: TimeInterval = VoiceSharingPolicy.leaseSecondsDefault,
        readRemoteSwitch: @escaping () -> RemoteSwitchValue,
        isAccountEnrolled: @escaping () -> Bool
    ) {
        self.clock = clock
        self.leaseSeconds = leaseSeconds
        self.readRemoteSwitch = readRemoteSwitch
        self.isAccountEnrolled = isAccountEnrolled
    }

    /// Called by the existing fetch/activate completion path. Installs exactly one
    /// snapshot per successful activation. An invalid read CLEARS any previous
    /// snapshot, so a bad publication takes effect as OFF instead of keeping the
    /// last good value alive past its lease.
    /// A fetch-start identity token, captured by the caller BEFORE the network round trip and
    /// handed back at install time. The policy compares it against current identity atomically,
    /// so a callback that completes after an account switch — or after the fence has been lifted
    /// by a newer identity — cannot install under the new identity's authority.
    struct FetchToken: Equatable {
        let identityGeneration: Int
        let enrolledAtFetchStart: Bool
    }

    /// Snapshot of identity for starting a fetch. Call this at FETCH START, not at completion.
    func tokenForFetchStart() -> FetchToken {
        lock.lock()
        defer { lock.unlock() }
        return FetchToken(identityGeneration: identityGenerationCounter, enrolledAtFetchStart: isAccountEnrolled())
    }

    /// `freshActivationSucceeded` is the caller's evidence that THIS call follows a fetch
    /// that actually succeeded AND proved a fresh network exchange (see FirebaseManager: it
    /// compares `lastFetchTime` before/after). It is required: without it a cached/no-network
    /// outcome would renew the lease on stale values and keep collection alive past the point
    /// where the server was last consulted.
    @discardableResult
    func refreshAfterActivation(
        freshActivationSucceeded: Bool,
        fetchToken: FetchToken
    ) -> VoiceSharingSnapshot? {
        // A failed activation clears rather than renews, and does not extend any lease.
        guard freshActivationSucceeded else {
            // Transient config failure: clear permission, but do NOT touch the identity fence.
            // Fabricating an identity change here would latch the fence and prevent any later
            // genuine success from ever installing again.
            lock.lock()
            installed = nil
            lock.unlock()
            return nil
        }
        // The fence from an identity change blocks installs until the new identity is readable;
        // without it, a refresh that belongs to the departed account would restore permission.
        lock.lock()
        if pendingIdentityFence > 0 {
            lock.unlock()
            return nil
        }
        // Verify the token against CURRENT identity before reading config: a transition during
        // the config read must still invalidate this install, so re-check after the read too.
        let generationNowAtStart = identityGenerationCounter
        lock.unlock()
        let value = readRemoteSwitch()
        let now = clock.now()
        lock.lock()
        defer { lock.unlock() }
        // The generation is the authority: any real account transition bumps it, so a token from
        // before the transition can never install afterwards — including the case where the fence
        // has already been lifted by the newer identity. Enrollment is re-read for the snapshot
        // itself rather than trusted from the token.
        // Enrollment is compared too: a transition that does NOT bump the generation (e.g. an
        // in-account withdrawal) still changes this, so the read-time value cannot be trusted as
        // "still the identity we started for".
        guard pendingIdentityFence == 0,
              fetchToken.identityGeneration == identityGenerationCounter,
              generationNowAtStart == identityGenerationCounter,
              fetchToken.enrolledAtFetchStart == isAccountEnrolled(),
              fetchToken.enrolledAtFetchStart == isAccountEnrolled()
        else { return nil }
        switch value {
        case .unavailable:
            installed = nil
            return nil
        case .valid(let enabled):
            let snapshot = VoiceSharingSnapshot(
                enabledRemotely: enabled,
                leaseExpiresAt: now + leaseSeconds,
                // Enrollment is sampled here but NOT treated as immutable: `permitsCollection`
                // re-reads current identity so withdrawal/sign-out takes effect immediately.
                accountEnrolled: isAccountEnrolled()
            )
            installed = snapshot
            return snapshot
        }
    }

    /// Synchronous invalidation on withdrawal / account switch. Required because a frozen
    /// snapshot would otherwise keep a departed account's permission true until its lease
    /// lapsed (hours). Also fences a late refresh belonging to the previous identity: while a
    /// generation is pending, installs are refused rather than restoring stale permission.
    func invalidateForIdentityChange() {
        lock.lock()
        defer { lock.unlock() }
        installed = nil
        pendingIdentityFence += 1
        identityGenerationCounter += 1
    }

    /// Called by the identity provider once the new account state is readable. Later refreshes
    /// then install against the CURRENT identity, never the one that was active when the
    /// outstanding fetch began.
    func identityBecameReadable() {
        lock.lock()
        defer { lock.unlock() }
        pendingIdentityFence = 0
    }

    /// Current effective permission. Expired leases report false without mutating
    /// state; a fresh `refreshAfterActivation()` is the only path back to enabled.
    var permitsCollection: Bool {
        lock.lock()
        let snapshot = installed
        let fenced = pendingIdentityFence > 0
        lock.unlock()
        guard let snapshot, !fenced else { return false }
        // Re-check identity NOW instead of trusting the value folded into the snapshot: a
        // withdrawal or account switch between install and this read must not keep collecting.
        return snapshot.enabledRemotely && clock.now() < snapshot.leaseExpiresAt && isAccountEnrolled()
    }
}
