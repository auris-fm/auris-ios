import Foundation

/// The durable identity an entry was captured under, and the live identity an admission is judged
/// against (reviewer 2b121320).
///
/// An enrollment epoch string alone is not an identity: two accounts can be issued the same opaque
/// epoch value, so comparing epochs would let an entry from one account satisfy another's
/// admission. This type makes the pair STRUCTURAL rather than a naming convention on a joined
/// string, so a caller cannot compare half of it by accident.
struct VoiceSharingUploadIdentity: Equatable {
    /// Account scope the entry belongs to, as the queue/entry owner recorded it.
    let accountScope: String
    /// Server-issued enrollment epoch the entry was captured under.
    let enrollmentEpoch: String

    /// Both components must be present: an unknown account or epoch is not an identity.
    init?(accountScope: String?, enrollmentEpoch: String?) {
        guard let accountScope, !accountScope.isEmpty,
              let enrollmentEpoch, !enrollmentEpoch.isEmpty
        else { return nil }
        self.accountScope = accountScope
        self.enrollmentEpoch = enrollmentEpoch
    }
}
