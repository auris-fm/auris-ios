import Foundation

/// Authoritative membership state for Voice Sharing, exactly as the Go-owned account routes publish it.
///
/// Contract source: `docs/specs/voice-recording-uploads.md` at `270dfa5b`, "Authenticated account
/// operations". Field names below mirror the wire (`schema_version: 1`) rather than inventing a client
/// vocabulary, and every field is optional-with-a-fail-closed-default so a partial or unknown response can
/// never read as enrolled.
struct VoiceSharingMembership: Equatable {
    /// Server-issued opaque revision. Clients must send the value they last observed as
    /// `expected_membership_revision`; every successfully applied mutation advances it.
    let membershipRevision: String
    let plan: Plan
    let voiceSharingEnrolled: Bool
    /// Opaque server-issued epoch. Unknown/stale epochs cannot authorize new collection.
    let enrollmentEpoch: String?
    let acceptedDisclosureVersion: String?
    let withdrawalState: WithdrawalState

    enum Plan: String { case free, pro }
    enum WithdrawalState: String {
        // Explicit server wire values (fix): implicit Swift rawValues are camelCase
        // ("notEnrolled"), but the server publishes snake_case ("not_enrolled") — the mismatch
        // made every real projection fail strict decode, reading as "unknown state".
        case active = "active"
        case withdrawn = "withdrawn"
        case notEnrolled = "not_enrolled"
    }

    /// A missing/unknown projection is not enrolled: parsing failure yields this rather than throwing, so
    /// callers cannot accidentally treat garbage as permission.
    static let unavailable = VoiceSharingMembership(
        membershipRevision: "",
        plan: .free,
        voiceSharingEnrolled: false,
        enrollmentEpoch: nil,
        acceptedDisclosureVersion: nil,
        withdrawalState: .notEnrolled
    )
}

/// Outcome of one account mutation, distinguishing what the caller must do next.
enum VoiceSharingMutationOutcome: Equatable {
    /// `200` with a projection, plus the store fence value the mutation was ISSUED under. Application goes
    /// through the store with that token, which refuses if a withdrawal or account transition landed in the
    /// meantime. A bare projection would let any caller apply a late success under a token it grabbed after
    /// the reply, which is exactly how an opted-out user gets re-enabled.
    case applied(membership: VoiceSharingMembership, issuedUnder: VoiceSharingEnrollmentStore.ProjectionToken)
    /// `409`: either `membership_conflict` (stale expected revision) or an idempotent-retry replay that
    /// returned the original result. The client must not auto-replay a conflicted opt-in against the newer
    /// revision; renewed opt-in requires fresh user intent.
    /// `409` with the server's current projection, again carrying the ISSUING fence for the same reason.
    case conflict(current: VoiceSharingMembership?, issuedUnder: VoiceSharingEnrollmentStore.ProjectionToken)
    /// `403` ineligible / `422` unsupported disclosure or invalid fields. Never silently enrolled.
    case refused(reason: RefusalReason)
    /// `401` — credential rejected; caller refreshes and does not retry blindly.
    case unauthorized
    /// `503` or transport failure — retryable, and explicitly not a state change.
    case unavailableBackend
    /// The operation's originating session no longer exists: the request is refused before transport (for
    /// mutations) or the reply is dropped without applying (for reads), so one account's intent can never be
    /// sent or consumed under another account's credential.
    case refusedStaleSession

    enum RefusalReason: String { case ineligible, unsupportedDisclosure, invalidRequest }
}

/// Deletion is its own operation with its own request identity, independent of enrollment and plan.
enum VoiceSharingDeletionOutcome: Equatable {
    /// `204` with an empty body: the server deleted synchronously. There is no receipt and nothing to
    /// follow up on, so this is the one outcome that may be shown as completed.
    case deleted
    case refused(reason: VoiceSharingMutationOutcome.RefusalReason)
    case unauthorized
    case unavailableBackend
}
