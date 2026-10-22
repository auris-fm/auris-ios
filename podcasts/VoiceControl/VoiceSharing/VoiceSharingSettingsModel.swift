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
        /// Entries that are ready and would be served by an uploader (0 when the owner is held).
        let readyEntries: Int
        /// True when the queue reports unknown coverage or an unreconciled revocation.
        let held: Bool
        /// True when the live policy currently permits collection.
        let collectionPermitted: Bool
    }

    struct DeleteResult: Equatable {
        let removed: Int
        let retained: Int
        /// False when revocation could NOT be proven complete; the UI must say so plainly.
        let fullyRevoked: Bool
    }

    private let queue: VoiceSharingUploadQueue
    private let isCollectionPermitted: () -> Bool

    init(queue: VoiceSharingUploadQueue, isCollectionPermitted: @escaping () -> Bool) {
        self.queue = queue
        self.isCollectionPermitted = isCollectionPermitted
    }

    var isSurfaceEnabled: Bool { Self.surfaceEnabled }

    /// Read-only projection. Errors are reported as `held` rather than as an empty, healthy list:
    /// "we could not determine" must never render as "nothing to delete".
    func status() -> ContributionStatus {
        switch queue.readyEntriesReportingUnknownCoverage() {
        case .unknownCoverage:
            return ContributionStatus(readyEntries: 0, held: true,
                                      collectionPermitted: isCollectionPermitted())
        case .known(let entries):
            return ContributionStatus(readyEntries: entries.count, held: false,
                                      collectionPermitted: isCollectionPermitted())
        }
    }

    /// Deletes ALL retained contributions through the owner-wide purge. Never claims success it
    /// cannot prove: a refused or held purge reports `fullyRevoked == false`.
    func deleteAllContributions() -> DeleteResult {
        switch queue.purgeAll() {
        case .reconciled(let removed, let retained):
            return DeleteResult(removed: removed, retained: retained, fullyRevoked: true)
        case .held(let removed, let retained):
            return DeleteResult(removed: removed, retained: retained, fullyRevoked: false)
        case .refused:
            return DeleteResult(removed: 0, retained: 0, fullyRevoked: false)
        }
    }

    /// The compiled bounds, for a read-only "what the app will do" line. Not editable, not
    /// activation values.
    var compiledBoundsDescription: String {
        "Audio up to \(VoiceSharingUploadQueue.maxEntryAudioBytes / 1024) KB per contribution, "
            + "retained for at most \(Int(VoiceSharingUploadQueue.maxEntryAge / 3600)) hours."
    }
}
