import Foundation

/// The Voice Sharing settings surface, BUILT DISABLED (round 69).
///
/// What this exists to make impossible: a settings screen that can turn collection on by itself.
/// Every control here is either a local, non-authorizing preference or a read-only projection of
/// the live policy. Specifically:
///
/// - There is NO path from this view to `permitsCollection`. The remote switch, the lease and the
///   account enrollment remain the only inputs to that decision (see `VoiceSharingSnapshot`), so a
///   user toggling anything here cannot enable collection.
/// - The delete control goes through the queue's owner-wide purge (the same fail-explicit path
///   consent loss uses), so "delete my contributions" cannot silently succeed while storage is
///   unreconciled — the outcome is reported back, not swallowed.
/// - The section is gated on a compiled constant that is `false`: nothing here renders in
///   production until the owner approves activation, and flipping it is a deliberate source change
///   reviewed like any other.
///
/// Numeric limits shown here are the COMPILED bounds, labelled as such; they are not activation
/// values and are not editable.
final class VoiceSharingSettingsModel {
    /// Compiled switch. `false` in every shipped build until the owner approves activation.
    static let surfaceEnabled = false

    struct ContributionStatus: Equatable {
        /// Whether the queue's own state could be DETERMINED. `unknown` is a first-class state, not
        /// a zero count: an unreadable or unreconciled owner has stored items we cannot count.
        enum Storage: Equatable {
            /// Known ready-to-upload count (queue coverage is known and the owner is not held).
            case knownReady(Int)
            /// Could not DETERMINE the count (listing/stat/read/durability failure). Not evidence
            /// that a revocation failed (reviewer 8ae2b980).
            case unknown
            /// The owner is HELD by an unproven revocation: stored recordings may survive because
            /// the revocation's barriers did not reconcile.
            case revocationInDoubt
        }
        let storage: Storage
        /// True when the live policy currently permits collection. Read-only projection.
        let collectionPermitted: Bool
    }

    /// The outcome of a LOCAL deletion, carrying the queue's typed purge result through unchanged.
    /// Nothing here may be flattened into "success" — the spec's rule is that local removal never
    /// stands for server completion, and the purge's own three states must remain distinguishable.
    struct DeleteResult: Equatable {
        enum Disposition: Equatable {
            /// Every retained entry was removed or is durably disqualified; nothing is pending.
            case reconciled(removed: Int, durablyDisqualified: Int)
            /// Some survivors could not be CONFIRMED revoked; they stay on this device.
            case incomplete(removed: Int, survivorsUnknown: Int)
            /// The purge could not even enumerate storage; nothing was attempted or proven.
            case refused
        }
        let disposition: Disposition

        /// True only when storage was fully enumerated AND no survivor remains unconfirmed.
        var isFullyResolvedLocally: Bool {
            switch disposition {
            case .reconciled(let removed, let durablyDisqualified):
                return removed >= 0 && durablyDisqualified >= 0
            case .incomplete, .refused:
                return false
            }
        }
    }

    private let queue: VoiceSharingUploadQueue
    private let isCollectionPermitted: () -> Bool?

    private let isEnrolled: () -> Bool?
    private let isOptedIn: () -> Bool?
    private let coherenceAccount: () -> String?
    private let coherenceGeneration: () -> Int?
    private let coherenceVersion: () -> String?
    private let policyLeaseGeneration: () -> Int
    private let queueHoldGeneration: () -> Int

    /// `nil`-returning reads are REQUIRED: a wiring that cannot determine enrollment or opt-in must
    /// report `unknown`, not `false`. Passing a constant `false` closure would invent an opt-out.
    init(queue: VoiceSharingUploadQueue,
         isCollectionPermitted: @escaping () -> Bool?,
         isAccountEnrolled: @escaping () -> Bool?,
         isLocallyOptedIn: @escaping () -> Bool?,
         coherenceAccount: @escaping () -> String? = { nil },
         coherenceGeneration: @escaping () -> Int? = { 0 },
         coherenceVersion: @escaping () -> String? = { nil },
         policyLeaseGeneration: @escaping () -> Int = { 0 },
         queueHoldGeneration: @escaping () -> Int = { 0 }) {
        self.queue = queue
        self.isCollectionPermitted = isCollectionPermitted
        self.isEnrolled = isAccountEnrolled
        self.isOptedIn = isLocallyOptedIn
        self.coherenceAccount = coherenceAccount
        self.coherenceGeneration = coherenceGeneration
        self.coherenceVersion = coherenceVersion
        self.policyLeaseGeneration = policyLeaseGeneration
        self.queueHoldGeneration = queueHoldGeneration
    }

    var isSurfaceEnabled: Bool { Self.surfaceEnabled }

    /// Read-only projection. "Could not determine" is reported as `.unknown`, never as a zero
    /// count — the reviewer's point that a held owner must not render "Stored contributions: 0".
    func status() -> ContributionStatus {
        switch queue.readyEntriesReportingUnknownCoverage() {
        case .unknownCoverage:
            return ContributionStatus(storage: .unknown,
                                      collectionPermitted: isCollectionPermitted() ?? false)
        case .revocationHeld:
            return ContributionStatus(storage: .revocationInDoubt,
                                      collectionPermitted: isCollectionPermitted() ?? false)
        case .known(let entries):
            return ContributionStatus(storage: .knownReady(entries.count),
                                      collectionPermitted: isCollectionPermitted() ?? false)
        }
    }

    /// Deletes ALL retained contributions through the owner-wide purge. Never claims success it
    /// cannot prove: a refused or held purge reports `fullyRevoked == false`.
    /// LOCAL scope, stated in the name: this deletes recordings held ON THIS DEVICE. It is not
    /// account-wide deletion — accepted data on the server is a separate operation the client does
    /// not perform here (spec: local removal never stands for server completion).
    func deletePendingRecordingsOnThisDevice() -> DeleteResult {
        switch queue.purgeAll() {
        case .reconciled(let removed, let retained):
            // `retained` here are entries whose removal failed but whose disqualification IS
            // durable: they stay on disk, provably dead, and the UI must say both things.
            return DeleteResult(disposition: .reconciled(removed: removed,
                                                         durablyDisqualified: retained))
        case .held(let removed, let retained):
            return DeleteResult(disposition: .incomplete(removed: removed,
                                                         survivorsUnknown: retained))
        case .refused:
            // Nothing could be enumerated: do NOT report 0 removed / 0 retained as if that were a
            // measurement of an empty device.
            return DeleteResult(disposition: .refused)
        }
    }

    /// The compiled bounds, for a read-only "what the app will do" line. Not editable, not
    /// activation values.
    /// Explicitly LOCAL wording, so the surface can never imply account/server deletion.
    var deletionScopeDescription: String {
        "Deletes voice recordings still waiting to upload on this device. "
            + "It does not delete contributions already accepted by the service."
    }

    var compiledBoundsDescription: String {
        "Audio up to \(VoiceSharingUploadQueue.maxEntryAudioBytes / 1024) KB per contribution, "
            + "retained for at most \(Int(VoiceSharingUploadQueue.maxEntryAge / 3600)) hours."
    }
    // MARK: - Recovery / stopped state (spec 62d39f8f, reviewer 8ae2b980)

    /// Live-state dependencies the surface cannot guess.
    ///
    /// The previous version took plain Bools with `false` defaults, which silently INVENTED "the
    /// user turned it off" whenever a caller didn't wire them. These are now explicit: `nil` means
    /// the caller cannot determine it, and an undeterminable reason renders as `.unknown` rather
    /// than as an accusation or an invented pause (reviewer 8ae2b980).
    struct LiveState: Equatable {
        /// Whether the live policy currently permits collection. `nil` = unknown.
        var policyPermits: Bool?
        /// Server-authoritative enrollment. `nil` = not read yet/unknown.
        var enrolled: Bool?
        /// The user's own opt-in gesture on this device. `nil` = unknown.
        var localOptIn: Bool?
        /// Storage fault, already classified by the queue (never inferred from a single flag).
        var storageFault: StoppedReason.StorageFault = .none
        /// Ready-to-upload count from the SAME queue read that produced `storageFault`. `nil` when
        /// coverage was unknown/held, so a count can never be invented from a second read.
        var knownReadyCount: Int?
        /// The account+generation+lease generation all three reads were taken under. When the
        /// stamps disagree the reads were NOT coherent, and every derived conclusion is unknown
        /// rather than a mix of two moments (reviewer e40508a1).
        var coherence: Coherence = .incoherent

        enum Coherence: Equatable {
            /// Every read was taken under the same account, enrollment generation and lease epoch.
            case coherent(account: String?, generation: Int, version: String?)
            /// At least one read had no stamp, or the stamps disagree.
            case incoherent
        }

        /// A snapshot may only support a conclusion about WHY sharing is stopped when its reads
        /// were mutually coherent. Otherwise the honest answer is `.unknown`.
        var isCoherent: Bool {
            if case .coherent = coherence { return true }
            return false
        }
    }

    /// Why collection is not running. Every case is derived from `LiveState` — the surface reports
    /// what the app can actually verify, and `unknown` is reachable by construction.
    enum StoppedReason: Equatable {
        /// Storage state that is relevant to recovery, classified at the source.
        enum StorageFault: Equatable {
            case none
            /// An unproven revocation: barriers did not reconcile, intent is still on disk. The
            /// local deletion path is the verified remedy (a successful purge retires the intent).
            case revocationInDoubt
            /// The store could not be read/enumerated. NOT a revocation failure, and not something
            /// the user can fix by turning anything on or by deleting.
            case unreadable
        }

        /// The live policy's snapshot permits collection and no other blocker applies.
        case notStopped
        /// No usable snapshot (never fetched, fenced, or expired): the app must fetch again.
        case noActiveLease
        /// Server membership is withdrawn or the account is not enrolled.
        case notEnrolled
        /// The user turned sharing off on this device.
        case turnedOffLocally
        /// A revocation is in doubt; local deletion is the verified remedy.
        case storageHeld
        /// Stored recordings could not be read — nothing is claimed about revocation.
        case storageUnreadable
        /// Could not determine; never presented as a user action.
        case unknown
    }

    struct RecoveryGuidance: Equatable {
        let reason: StoppedReason
        /// What will make sharing work again. `nil` when nothing is required or nothing is claimed.
        let action: String?
    }

    // MARK: - The single published view state (reviewer 05aaaedc)

    /// Everything the surface displays, derived from ONE coherent snapshot. The two UI parts cannot
    /// disagree because they read the same value, and a listener cannot be called with values from
    /// two different moments.
    struct PublishedViewState: Equatable {
        let live: LiveState
        let storage: ContributionStatus.Storage
        let guidance: RecoveryGuidance
    }

    func publishedViewState(for live: LiveState) -> PublishedViewState {
        PublishedViewState(live: live,
                           storage: storage(for: live),
                           guidance: recoveryGuidance(for: live))
    }

    /// Storage projection FROM the snapshot (not a second read of the queue).
    private func storage(for live: LiveState) -> ContributionStatus.Storage {
        switch live.storageFault {
        case .revocationInDoubt: return .revocationInDoubt
        case .unreadable: return .unknown
        case .none: break
        }
        switch live.knownReadyCount {
        case .some(let count): return .knownReady(count)
        case .none: return .unknown
        }
    }

    // MARK: - Change subscription (reviewer 8ae2b980)

    private var changeObservers: [UUID: (SentLiveState) -> Void] = [:]
    private let changeLock = NSLock()
    private var readSequence = 0
    private var lastPublishedSequence = -1
    private var currentSequence = 0

    /// Registers a listener for state changes. The returned token must be removed on teardown.
    /// The delivery carries the sequence it was read at, so a consumer can reject an older one.
    func addStateObserver(_ body: @escaping (SentLiveState) -> Void) -> UUID {
        changeLock.lock(); defer { changeLock.unlock() }
        let id = UUID()
        changeObservers[id] = body
        return id
    }

    func removeStateObserver(_ id: UUID) {
        changeLock.lock(); changeObservers.removeValue(forKey: id); changeLock.unlock()
    }

    /// Re-reads live state and notifies listeners ONLY when it actually changed. Called from the
    /// production update paths (enrollment store mutations, queue purges) — a snapshot per render
    /// is not a subscription, and pretending otherwise was the reviewer's point.
    /// A published snapshot tagged with the sequence it was taken at. Consumers keep the highest
    /// sequence they have applied, so a delivery that arrives late cannot overwrite a newer one.
    struct SentLiveState: Equatable {
        let sequence: Int
        let state: LiveState
    }

    /// Test seam: invoked INSIDE a refresh, right after its read and BEFORE the commit, so a
    /// control can hold an older read open while a newer one completes (reviewer 31c7758f).
    var afterReadBeforeCommitForTesting: (() -> Void)?

    func refreshLiveState() {
        // SERIALIZED: the comparison AND the commit of `lastPublishedState` happen under the same
        // lock as the observer list, so two concurrent refreshes cannot both decide to publish, and
        // an out-of-order snapshot cannot overwrite a newer one (reviewer 05aaaedc). Observers are
        // called OUTSIDE the lock, so a listener that re-enters cannot deadlock.
        changeLock.lock()
        readSequence &+= 1
        let sequence = readSequence
        changeLock.unlock()

        let state = liveState()
        afterReadBeforeCommitForTesting?()

        // LAST WRITER WINS: a refresh whose read is OLDER than one already published is obsolete —
        // it must not deliver, even if its read finished later (reviewer f62b19a4). Ordering is by
        // the read that produced the state, not by the order callbacks happen to run.
        changeLock.lock()
        // THE WATERMARK ADVANCES ON EVERY COMPLETED READ, CHANGE OR NOT (reviewer 31c7758f): a
        // refresh that found nothing new still proves every EARLIER read is obsolete, so a slow
        // older read must not publish afterwards. Advancing only when the state differed let a
        // stale read slip through behind an unchanged newer one.
        guard sequence > lastPublishedSequence else {
            changeLock.unlock()
            return
        }
        lastPublishedSequence = sequence
        guard state != lastPublishedState else {
            changeLock.unlock()
            return
        }
        lastPublishedState = state
        currentSequence = sequence
        let observers = Array(changeObservers.values)
        changeLock.unlock()

        let sent = SentLiveState(sequence: sequence, state: state)
        for observer in observers { observer(sent) }
    }

    /// The sequence of the most recently committed publication; seeded on subscribe so a new
    /// listener cannot apply a delivery older than the state it already seeded from.
    var publicationSequence: Int { changeLock.lock(); defer { changeLock.unlock() }; return currentSequence }

    private var lastPublishedState: LiveState?

    /// The model's ONE live snapshot: queue coverage plus whatever the two injected reads return.
    /// `nil` from a read is preserved as `unknown` — never coerced to `false`, which would accuse
    /// the user of opting out (reviewer 8ae2b980).
    func liveState() -> LiveState {
        // Stamp BEFORE and AFTER every read, INCLUDING the queue read: a hold transition or an
        // account/enrollment move between the queue coverage read and the first stamp used to be
        // invisible (reviewer f62b19a4). No read happens outside the interval.
        let before = coherenceStamp()
        let fault: StoppedReason.StorageFault
        let readyCount: Int?
        switch queue.readyEntriesReportingUnknownCoverage() {
        case .revocationHeld:
            fault = .revocationInDoubt
            readyCount = nil
        case .unknownCoverage:
            fault = .unreadable
            readyCount = nil
        case .known(let entries):
            fault = .none
            readyCount = entries.count
        }
        let permits = isCollectionPermitted()
        let enrolled = isEnrolled()
        let optedIn = isOptedIn()
        let after = coherenceStamp()
        let coherence: LiveState.Coherence
        if let before, let after, before == after {
            coherence = .coherent(account: before.account,
                                  generation: before.generation,
                                  version: before.version)
        } else {
            coherence = .incoherent
        }
        return LiveState(policyPermits: permits,
                         enrolled: enrolled,
                         localOptIn: optedIn,
                         storageFault: fault,
                         knownReadyCount: readyCount,
                         coherence: coherence)
    }

    /// Account + enrollment generation + lease version, read atomically enough to detect a move
    /// between two calls. `nil` when the caller cannot answer — which makes the snapshot
    /// incoherent rather than silently trusting a half-known world.
    private func coherenceStamp() -> CoherenceStamp? {
        // Account and generation are required: without them there is nothing to prove the reads
        // belong together. The version is informative only and may legitimately be nil.
        guard let account = coherenceAccount(),
              let generation = coherenceGeneration() else { return nil }
        return CoherenceStamp(account: account,
                              generation: generation,
                              version: coherenceVersion(),
                              policyLease: policyLeaseGeneration(),
                              queueHold: queueHoldGeneration())
    }

    struct CoherenceStamp: Equatable {
        let account: String?
        let generation: Int
        let version: String?
        /// The policy's own lease generation and the queue's hold generation: these version the
        /// OTHER two authorities the snapshot reads, so a lease expiry/fence or a queue hold change
        /// during the read is detected (reviewer 05aaaedc).
        let policyLease: Int
        let queueHold: Int
    }

    /// Projection over explicit live state. Pure: no reads, no writes, no cached mixing.
    func recoveryGuidance(for live: LiveState) -> RecoveryGuidance {
        switch live.storageFault {
        case .revocationInDoubt:
            // VERIFIED remedy: a successful purge retires the intent and releases the hold
            // (VoiceSharingUploadQueue.purgeLocked). Nothing else clears it.
            return RecoveryGuidance(reason: .storageHeld, action: L10n.voiceSharingRecoveryHeld)
        case .unreadable:
            // No action promised: an unreadable store is not cleared by the user doing anything.
            return RecoveryGuidance(reason: .storageUnreadable, action: nil)
        case .none:
            break
        }
        guard live.isCoherent else {
            // Reads from two different moments (or an unstamped read) cannot name a reason.
            return RecoveryGuidance(reason: .unknown, action: nil)
        }
        guard let permits = live.policyPermits,
              let enrolled = live.enrolled,
              let optedIn = live.localOptIn else {
            return RecoveryGuidance(reason: .unknown, action: nil)
        }
        if permits && enrolled && optedIn {
            return RecoveryGuidance(reason: .notStopped, action: nil)
        }
        if !optedIn {
            return RecoveryGuidance(reason: .turnedOffLocally,
                                    action: L10n.voiceSharingRecoveryTurnedOff)
        }
        if !enrolled {
            return RecoveryGuidance(reason: .notEnrolled,
                                    action: L10n.voiceSharingRecoveryNotEnrolled)
        }
        return RecoveryGuidance(reason: .noActiveLease,
                                action: L10n.voiceSharingRecoveryPaused)
    }
}
