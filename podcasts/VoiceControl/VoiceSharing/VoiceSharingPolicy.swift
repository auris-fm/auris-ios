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
        /// Absent, wrong-typed, or read before activation completed. Never enables.
        case unavailable
    }

    private let clock: MonotonicClock
    private let leaseSeconds: TimeInterval
    private let readRemoteSwitch: () -> RemoteSwitchValue
    private let isAccountEnrolled: () -> Bool

    private let lock = NSLock()
    private var installed: VoiceSharingSnapshot?

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
    @discardableResult
    func refreshAfterActivation() -> VoiceSharingSnapshot? {
        let value = readRemoteSwitch()
        let now = clock.now()
        lock.lock()
        defer { lock.unlock() }
        switch value {
        case .unavailable:
            installed = nil
            return nil
        case .valid(let enabled):
            let snapshot = VoiceSharingSnapshot(
                enabledRemotely: enabled,
                leaseExpiresAt: now + leaseSeconds,
                accountEnrolled: isAccountEnrolled()
            )
            installed = snapshot
            return snapshot
        }
    }

    /// Current effective permission. Expired leases report false without mutating
    /// state; a fresh `refreshAfterActivation()` is the only path back to enabled.
    var permitsCollection: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let installed else { return false }
        return installed.permitsCollection(at: clock.now())
    }
}
