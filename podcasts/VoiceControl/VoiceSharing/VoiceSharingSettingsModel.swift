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
            /// Could not determine: unknown coverage or an unreconciled revocation.
            case unknown
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
    private let isCollectionPermitted: () -> Bool

    private let isEnrolled: () -> Bool
    private let isOptedIn: () -> Bool

    init(queue: VoiceSharingUploadQueue,
         isCollectionPermitted: @escaping () -> Bool,
         isAccountEnrolled: @escaping () -> Bool = { false },
         isLocallyOptedIn: @escaping () -> Bool = { false }) {
        self.queue = queue
        self.isCollectionPermitted = isCollectionPermitted
        self.isEnrolled = isAccountEnrolled
        self.isOptedIn = isLocallyOptedIn
    }

    /// Live reads used by the stopped/recovery projection. Read-only, never a write path.
    func isAccountEnrolled() -> Bool { isEnrolled() }
    func isLocallyOptedIn() -> Bool { isOptedIn() }

    var isSurfaceEnabled: Bool { Self.surfaceEnabled }

    /// Read-only projection. "Could not determine" is reported as `.unknown`, never as a zero
    /// count — the reviewer's point that a held owner must not render "Stored contributions: 0".
    func status() -> ContributionStatus {
        switch queue.readyEntriesReportingUnknownCoverage() {
        case .unknownCoverage:
            return ContributionStatus(storage: .unknown,
                                      collectionPermitted: isCollectionPermitted())
        case .known(let entries):
            return ContributionStatus(storage: .knownReady(entries.count),
                                      collectionPermitted: isCollectionPermitted())
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
    // MARK: - Recovery / stopped state (spec 62d39f8f)

    /// Why collection is not running, from ACTUAL live state — never a guess.
    ///
    /// Every case derives from a query the caller supplies, so the surface reports what the app
    /// can verify right now. `unknown` exists for the same reason `.unknown` storage does: a
    /// reason the app cannot determine must not be rendered as "you turned it off".
    enum StoppedReason: Equatable {
        /// The live policy's snapshot permits collection and no other blocker applies.
        case notStopped
        /// No usable snapshot (never fetched, fenced, or expired): the app must fetch again.
        case noActiveLease
        /// Server membership is withdrawn or the account is not enrolled.
        case notEnrolled
        /// The user turned sharing off on this device.
        case turnedOffLocally
        /// A revocation is in doubt: the owner is held and stored recordings may survive.
        case storageHeld
        /// Could not determine (read failure); never presented as a user action.
        case unknown
    }

    struct RecoveryGuidance: Equatable {
        let reason: StoppedReason
        /// A short line naming what will make sharing work again. `nil` when nothing is required.
        let action: String?
    }

    /// The model's OWN live projection: policy, enrollment and local intent read at call time.
    func stoppedGuidance(policyPermits: Bool, enrolled: Bool, localOptIn: Bool) -> RecoveryGuidance {
        // `unknownCoverage` covers exactly the "we could not even enumerate, or a revocation is in
        // doubt" cases — the same condition the status projection reports as `.unknown`.
        let ownerHeld: Bool
        switch queue.readyEntriesReportingUnknownCoverage() {
        case .unknownCoverage: ownerHeld = true
        case .known: ownerHeld = false
        }
        return recoveryGuidance(policyPermits: policyPermits,
                                enrolled: enrolled,
                                localOptIn: localOptIn,
                                ownerHeld: ownerHeld)
    }

    /// Read-only projection of why collection is stopped and what the user can do. The queries are
    /// injected so tests drive every branch without inventing policy state.
    func recoveryGuidance(
        policyPermits: Bool,
        enrolled: Bool,
        localOptIn: Bool,
        ownerHeld: Bool
    ) -> RecoveryGuidance {
        if ownerHeld {
            return RecoveryGuidance(
                reason: .storageHeld,
                action: "Some stored recordings could not be revoked. Open Voice Sharing and delete "
                      + "recordings on this device to finish.")
        }
        if policyPermits && enrolled && localOptIn {
            return RecoveryGuidance(reason: .notStopped, action: nil)
        }
        if !localOptIn {
            return RecoveryGuidance(reason: .turnedOffLocally,
                                    action: "Turn on Voice Sharing in Settings to resume.")
        }
        if !enrolled {
            return RecoveryGuidance(reason: .notEnrolled,
                                    action: "Voice Sharing is not enabled for this account. "
                                          + "Check your account on pocketcasts.com.")
        }
        return RecoveryGuidance(reason: .noActiveLease,
                                action: "Voice Sharing is paused until the app can confirm its "
                                      + "settings. Open the app with a connection to resume.")
    }
}
