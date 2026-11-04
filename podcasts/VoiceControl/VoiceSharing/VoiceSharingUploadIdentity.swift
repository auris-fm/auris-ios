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
    /// PROVENANCE (spec 4afc6e43): stamped on the record and carried to the server. Never compared
    /// to decide whether an entry may be sent — that is the account's decision.
    let enrollmentEpoch: String

    /// The ACCOUNT must be present: an entry with no owner cannot be attributed. The epoch is
    /// provenance and may be absent — an empty string records that it was unknown at capture time
    /// (spec 4afc6e43), and the entry still travels.
    init?(accountScope: String?, enrollmentEpoch: String?) {
        guard let accountScope, !accountScope.isEmpty else { return nil }
        self.accountScope = accountScope
        self.enrollmentEpoch = enrollmentEpoch ?? ""
    }
}
