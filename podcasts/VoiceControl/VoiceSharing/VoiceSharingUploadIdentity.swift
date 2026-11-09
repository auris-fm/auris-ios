import Foundation

/// The durable identity an entry was captured under, and the live identity an admission is judged
/// against.
///
/// An enrollment epoch string alone is not an identity: two accounts can be issued the same opaque
/// epoch value, so comparing epochs would let an entry from one account satisfy another's
/// admission. This type makes the pair STRUCTURAL rather than a naming convention on a joined
/// string, so a caller cannot compare half of it by accident.
struct VoiceSharingUploadIdentity: Equatable {
    /// Account scope the entry belongs to, as the queue/entry owner recorded it.
    let accountScope: String
    /// Server-issued enrollment epoch the entry was captured under.
    /// PROVENANCE: stamped on the record and carried to the server. Never compared
    /// to decide whether an entry may be sent — that is the account's decision.
    let enrollmentEpoch: String

    /// Both components must be present. The ACCOUNT is what binds the entry; the
    /// epoch is provenance carried to the server, and the deployed record schema refuses an empty
    /// one (`invalid_enrollment_epoch`), so there is no useful "unknown epoch" identity.
    init?(accountScope: String?, enrollmentEpoch: String?) {
        guard let accountScope, !accountScope.isEmpty,
              let enrollmentEpoch, !enrollmentEpoch.isEmpty
        else { return nil }
        self.accountScope = accountScope
        self.enrollmentEpoch = enrollmentEpoch
    }
}
