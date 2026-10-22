import Foundation

/// Binds upload authorization to the identity it was granted under — account scope plus the
/// server-issued enrollment epoch (spec 724577f3).
///
/// `permitsCollection` answers "may this account collect NOW". That is not the same question a
/// queued entry needs: an entry queued under epoch A must not be uploaded when the account has
/// since moved to epoch B, even though B also permits collection. Without the pin a re-enrollment,
/// an account switch that lands back on an enrolled state, or a withdrawal-and-re-enroll would let
/// the old entry go out under the new identity's authority.
///
/// The pin is sampled at construction and re-compared on every read; the coordinator raises its
/// identity fence on real transitions, so a moved identity is observed rather than assumed.
struct VoiceSharingUploadIdentityPin {
    private let accountScope: () -> String
    private let enrollmentEpoch: () -> String?
    private let pinned: String?

    init(accountScope: @escaping () -> String, enrollmentEpoch: @escaping () -> String?) {
        self.accountScope = accountScope
        self.enrollmentEpoch = enrollmentEpoch
        self.pinned = Self.compose(accountScope(), enrollmentEpoch())
    }

    /// Account scope alone is not an identity: the epoch is what the server issued, and a
    /// re-enrollment under the same account changes it.
    static func compose(_ account: String, _ epoch: String?) -> String? {
        guard let epoch, !epoch.isEmpty else { return nil }
        return "\(account)|\(epoch)"
    }

    /// True only while the identity this pin was created under is still the live one.
    var isCurrent: Bool {
        guard let pinned else { return false }
        return Self.compose(accountScope(), enrollmentEpoch()) == pinned
    }
}
