import Foundation
import Combine

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

    // MARK: - Time-driven freshness (reviewer ffca9a27 / spec e3db4e30)

    /// Schedules the call that refreshes when TIME (not a mutation) makes the displayed state
    /// stale: an entry crossing the queue-age bound, or a lease lapsing. Without this the surface
    /// only changed when something else pushed, so an idle screen kept showing a count that had
    /// silently stopped being served.
    var scheduleTimeDrivenRefresh: ((_ after: TimeInterval, _ body: @escaping () -> Void) -> Void)?

    /// Seconds until the nearest time-caused transition that is still IN THE FUTURE: the next age
    /// boundary, or the lease deadline. Generous +1s margin so the refresh lands AFTER the
    /// transition, never before it.
    ///
    /// Transitions already in the past are EXCLUDED (reviewer 71088b91): an expired lease reports a
    /// negative delay, and turning that into a 50 ms delay re-armed the timer forever, once per
    /// fire. A past transition is not a reason to wake again — its refresh already happened.
    private func secondsUntilNextTimeTransition() -> TimeInterval? {
        var candidates: [TimeInterval] = []
        if let age = nextAgeBoundarySeconds?() { candidates.append(age) }
        if let lease = nextLeaseExpirySeconds?() { candidates.append(lease) }
        let future = candidates.filter { $0 > 0 }
        guard let soonest = future.min() else { return nil }
        return soonest + 1
    }

    /// Injected sources for the time-driven refresh: the queue's next age boundary and the
    /// policy's lease deadline. Defaults are nil so nothing is scheduled when unset.
    var nextAgeBoundarySeconds: (() -> TimeInterval?)?
    var nextLeaseExpirySeconds: (() -> TimeInterval?)?

    /// Arms ONE pending time-driven refresh, replacing any previous one (newest wins), so a clock
    /// change or a renewed lease cannot leave a stale timer behind.
    private var pendingTimeRefreshToken = 0
    /// The read sequence the current timer was armed for. Scheduling refuses anything older, so a
    /// slow read cannot replace a newer deadline.
    private var armedForSequence = 0

    /// Arms from the LATEST accepted read.
    ///
    /// NOT SAFE TO CALL WITH `changeLock` HELD — this method takes that lock itself and `NSLock` is
    /// not recursive, so a caller holding it would deadlock. Every caller unlocks first and passes
    /// the sequence it accepted (reviewer 8b902371).
    func armTimeDrivenRefresh() {
        armTimeDrivenRefresh(afterAcceptedSequence: currentSequence)
    }

    /// Test seam for the ordering control: an EXPLICIT sequence, as a read that was accepted earlier
    /// would present when it resumes and tries to arm.
    func armTimeDrivenRefreshForTesting(afterAcceptedSequence sequence: Int) {
        armTimeDrivenRefresh(afterAcceptedSequence: sequence)
    }

    /// Arms the timer, FENCED BY THE READ SEQUENCE IT BELONGS TO (reviewer 5a4738ca). An accepted
    /// read used to release `changeLock` and arm afterwards, so it could pause between the two: a
    /// NEWER read would arm the correct deadline, then the older one would invalidate it and how
    /// long it happened to wait before pausing decided the schedule. The delay is therefore measured
    /// and the token committed under ONE hold, and a sequence older than the armed one is refused.
    private func armTimeDrivenRefresh(afterAcceptedSequence sequence: Int) {
        changeLock.lock()
        guard sequence >= armedForSequence else {
            changeLock.unlock()
            return
        }
        // INVALIDATE FIRST, ALWAYS (reviewer 71088b91): even when nothing is due, any previously
        // armed timer must be superseded — otherwise a stale timer from an earlier, longer delay
        // keeps ownership and the newer deadline is never scheduled.
        pendingTimeRefreshToken &+= 1
        let token = pendingTimeRefreshToken
        armedForSequence = sequence
        let delay = secondsUntilNextTimeTransition()
        let schedule = scheduleTimeDrivenRefresh
        changeLock.unlock()
        guard let schedule, let delay else { return }
        schedule(delay) { [weak self] in
            guard let self else { return }
            self.changeLock.lock()
            let isCurrent = self.pendingTimeRefreshToken == token
            self.changeLock.unlock()
            guard isCurrent else { return }  // superseded: a newer timer owns the next refresh
            // `refreshLiveState` is the SINGLE owner of arming (reviewer e48ebcc6): it re-arms on
            // both the published and the unchanged path, so calling `armTimeDrivenRefresh` here as
            // well queued two closures per fire.
            self.refreshLiveState()
        }
    }

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
            // NO CHANGE IN DISPLAYED STATE, BUT THE DEADLINE MAY HAVE MOVED (reviewer e48ebcc6):
            // a renewed or shortened lease changes the snapshot's stamp and its deadline while
            // permission, count and guidance stay identical. The timer must be re-armed even when
            // nothing is published, or the OLD deadline keeps ownership. This read is still the
            // newest accepted one (`sequence > lastPublishedSequence` held above), so an obsolete
            // read cannot supersede newer scheduling.
            let armedSequence = sequence
            changeLock.unlock()
            armTimeDrivenRefresh(afterAcceptedSequence: armedSequence)
            return
        }
        lastPublishedState = state
        currentSequence = sequence
        let observers = Array(changeObservers.values)
        changeLock.unlock()

        let sent = SentLiveState(sequence: sequence, state: state)
        for observer in observers { observer(sent) }
        // RE-ARM ON EVERY AUTHORITATIVE UPDATE (reviewer 71088b91): an initially empty visible
        // queue schedules nothing, so the entry added right after it would never be given an expiry
        // timer, and a SHORTENED or newly installed lease could miss its deadline. Re-arming here
        // covers every source — queue, policy, enrollment — because they all refresh through here.
        armTimeDrivenRefresh(afterAcceptedSequence: sequence)
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
            // The serving authority's OWN count, so the displayed number can never disagree with
            // what is served (reviewer ffca9a27).
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

/// Account operations for the sharing screen. Local consent and server acknowledgement stay separate.
@MainActor
final class VoiceSharingAccountModel: ObservableObject {
    enum MembershipStatus: Equatable {
        case idle, loading, disclosureUnavailable, confirmationRequired, unavailable, conflict, unauthorized
        case refused(VoiceSharingMutationOutcome.RefusalReason)
        case enrolled, withdrawnServerConfirmed, withdrawalUnconfirmed
    }
    enum DeletionStatus: Equatable {
        case idle, sending, unavailable, unauthorized
        case refused(VoiceSharingMutationOutcome.RefusalReason)
        case pending(String)
    }
    @Published private(set) var membershipStatus: MembershipStatus = .idle
    @Published private(set) var deletionStatus: DeletionStatus = .idle
    @Published private(set) var localCleanup: VoiceSharingSettingsModel.DeleteResult?
    @Published private(set) var cleanupAttempted = false
    var localCleanupUnavailable: Bool { cleanupAttempted && localCleanup == nil }
    @Published private(set) var membership: VoiceSharingMembership?
    @Published private(set) var locallyOptedIn: Bool?
    @Published private(set) var refreshUnavailable = false
    @Published private(set) var busy = false
    var enrollmentAvailable: Bool { disclosureVersion != nil }

    private let store: VoiceSharingEnrollmentStore
    private let client: VoiceSharingAccountClient
    private let disclosureVersion: String?
    private let session: () -> String?
    private let purgeLocal: (() -> VoiceSharingSettingsModel.DeleteResult)?
    private var observer: UUID?
    private var account: String?
    private var serial = 0
    private var stamp: Stamp?
    private var mutation: VoiceSharingAccountClient.MutationOperation?
    private var deletion: VoiceSharingAccountClient.DeletionOperation?
    private var withdrawing = false
    private struct Stamp: Equatable {
        let serial: Int
        let token: VoiceSharingEnrollmentStore.ProjectionToken
    }

    init(store: VoiceSharingEnrollmentStore = .shared,
         client: VoiceSharingAccountClient,
         disclosureVersion: String? = nil,
         session: @escaping () -> String? = { VoiceSharingSessionGeneration.shared.currentGeneration() },
         purgeLocal: (() -> VoiceSharingSettingsModel.DeleteResult)? = nil) {
        self.store = store
        self.client = client
        self.disclosureVersion = disclosureVersion.flatMap { $0.isEmpty ? nil : $0 }
        self.session = session
        self.purgeLocal = purgeLocal
        account = session()
        observer = store.addObserver { [weak self] _ in
            Task { @MainActor [weak self] in self?.storeChanged() }
        }
        updateMembership()
    }

    private func updateMembership() {
        let state = store.currentAuthoritativeState
        membership = state?.membership
        locallyOptedIn = state?.localOptIn
    }

    private func storeChanged() {
        if account != session() {
            account = session()
            serial += 1
            stamp = nil
            mutation = nil
            deletion = nil
            withdrawing = false
            busy = false
            localCleanup = nil
            cleanupAttempted = false
            membershipStatus = .idle
            deletionStatus = .idle
            refreshUnavailable = false
        } else if let stamp, store.projectionToken() != stamp.token {
            serial += 1
            self.stamp = nil
            mutation = nil
            busy = false
            membershipStatus = .idle
        }
        updateMembership()
    }

    private func begin() -> Stamp? {
        storeChanged()
        serial += 1
        stamp = nil
        busy = false
        guard let token = store.projectionToken(), token.lifecycleGeneration == session() else { return nil }
        let next = Stamp(serial: serial, token: token)
        stamp = next
        busy = true
        return next
    }

    private func current(_ sent: Stamp) -> Bool {
        sent == stamp && sent.token == store.projectionToken() && sent.token.lifecycleGeneration == session()
    }

    func refresh() async {
        guard let sent = begin() else { membershipStatus = .unavailable; return }
        membershipStatus = .loading
        let result = await refreshProjection(under: sent)
        guard current(sent) else { storeChanged(); return }
        busy = false
        membershipStatus = result == .success ? .idle : .unavailable
    }

    private enum RefreshResult { case success, failure, stale }
    private func refreshProjection(under sent: Stamp) async -> RefreshResult {
        guard current(sent) else { return .stale }
        guard let result = await client.fetchProjection() else {
            guard current(sent) else { return .stale }
            refreshUnavailable = true
            return .failure
        }
        guard current(sent), result.issuedUnder == sent.token,
              store.apply(authoritative: result.membership, readUnder: result.issuedUnder) else { return .stale }
        refreshUnavailable = false
        updateMembership()
        return .success
    }

    func enroll(disclosureConfirmed: Bool) async {
        storeChanged()
        guard disclosureConfirmed else { membershipStatus = .confirmationRequired; return }
        guard let disclosureVersion else { membershipStatus = .disclosureUnavailable; return }
        guard !busy, let revision = store.currentAuthoritativeState?.membership.membershipRevision else { membershipStatus = .unavailable; return }
        store.setLocalOptIn(true)
        guard let sent = begin(), let operation = client.beginEnrollment(
            acceptedDisclosureVersion: disclosureVersion, expectedMembershipRevision: revision) else {
            membershipStatus = .unavailable
            busy = false
            return
        }
        withdrawing = false
        mutation = operation
        await performMutation(operation, under: sent)
    }

    /// Never blocked by an enrollment/fetch in flight. Capture server preconditions BEFORE local stop.
    func withdraw() async {
        storeChanged()
        let original = store.currentAuthoritativeState?.membership
        let revision = original?.membershipRevision
        let epoch = original?.enrollmentEpoch
        serial += 1
        stamp = nil
        mutation = nil
        withdrawing = true
        _ = store.withdrawLocally(acceptedServerProjectionAfterward: false)
        cleanupAttempted = true
        localCleanup = purgeLocal?()
        updateMembership()
        membershipStatus = .withdrawalUnconfirmed
        guard let sent = begin() else { busy = false; return }
        guard let revision, let operation = client.beginWithdrawal(
            enrollmentEpoch: epoch, expectedMembershipRevision: revision) else { busy = false; return }
        mutation = operation
        await performMutation(operation, under: sent)
    }

    func retryMembership() async {
        storeChanged() // Retire stale operations before capturing an immutable retry.
        guard !busy else { return }
        if let operation = mutation {
            guard operation.issuedUnder == store.projectionToken() else {
                mutation = nil
                membershipStatus = .unavailable
                return
            }
            guard let sent = begin() else { return }
            guard operation.issuedUnder == sent.token else {
                if stamp == sent { mutation = nil; busy = false; membershipStatus = .unavailable }
                return
            }
            await performMutation(operation, under: sent)
        } else if withdrawing {
            guard let sent = begin() else { return }
            let refreshed = await refreshProjection(under: sent)
            guard current(sent) else { storeChanged(); return }
            busy = false
            guard refreshed == .success else { membershipStatus = .withdrawalUnconfirmed; return }
            await withdraw()
        }
    }

    func retryLocalCleanup() { cleanupAttempted = true; localCleanup = purgeLocal?() }

    private func performMutation(_ operation: VoiceSharingAccountClient.MutationOperation, under sent: Stamp) async {
        let result = await client.perform(operation)
        guard current(sent) else { storeChanged(); return }
        switch result {
        case .applied(let projection, let issuedUnder):
            guard issuedUnder == sent.token, store.apply(authoritative: projection, readUnder: issuedUnder) else {
                busy = false; membershipStatus = .unavailable; return
            }
            mutation = nil
            if withdrawing {
                membershipStatus = projection.voiceSharingEnrolled ? .withdrawalUnconfirmed : .withdrawnServerConfirmed
            } else {
                membershipStatus = store.currentEffectiveEnrolled ? .enrolled : .unavailable
            }
        case .conflict(let projection, let issuedUnder):
            guard issuedUnder == sent.token else { busy = false; membershipStatus = .unavailable; return }
            store.applyConflict(current: projection, readUnder: issuedUnder)
            mutation = nil // Never replay conflicted opt-in against a newer revision.
            membershipStatus = .conflict
        case .unauthorized: membershipStatus = .unauthorized
        case .refused(let reason): mutation = nil; membershipStatus = .refused(reason)
        case .unavailableBackend: membershipStatus = withdrawing ? .withdrawalUnconfirmed : .unavailable
        case .refusedStaleSession:
            storeChanged()
            if stamp == sent { busy = false; membershipStatus = .unavailable }
            return
        }
        updateMembership()
        _ = await refreshProjection(under: sent)
        guard current(sent) else { storeChanged(); return }
        busy = false
    }

    func deleteAcceptedData(confirmed: Bool) async {
        storeChanged()
        guard confirmed, deletionStatus != .sending, let operation = client.beginDeletion() else { return }
        deletion = operation
        await performDeletion(operation)
    }

    func retryDeletion() async {
        storeChanged()
        guard deletionStatus != .sending, let operation = deletion else { return }
        await performDeletion(operation)
    }

    private func performDeletion(_ operation: VoiceSharingAccountClient.DeletionOperation) async {
        guard session() == operation.originatingGeneration else { return }
        deletionStatus = .sending
        let result = await client.performDeletion(operation)
        guard session() == operation.originatingGeneration, deletion?.requestID == operation.requestID else { storeChanged(); return }
        switch result {
        case .pending(let id): deletion = nil; deletionStatus = .pending(id)
        case .unauthorized: deletionStatus = .unauthorized
        case .refused(let reason): deletion = nil; deletionStatus = .refused(reason)
        case .unavailableBackend: deletionStatus = .unavailable
        }
    }

    deinit { if let observer { store.removeObserver(observer) } }
}
