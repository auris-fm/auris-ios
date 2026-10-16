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
    enum WithdrawalState: String { case active, withdrawn, notEnrolled }

    /// A missing/unknown projection is NOT enrolled: parsing failure yields this rather than throwing, so
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
    /// `200` with a projection — apply it.
    case applied(VoiceSharingMembership)
    /// `409`: either `membership_conflict` (stale expected revision) or an idempotent-retry replay that
    /// returned the original result. The client MUST NOT auto-replay a conflicted opt-in against the newer
    /// revision; renewed opt-in requires fresh user intent.
    case conflict(current: VoiceSharingMembership?)
    /// `403` ineligible / `422` unsupported disclosure or invalid fields. Never silently enrolled.
    case refused(reason: RefusalReason)
    /// `401` — credential rejected; caller refreshes and does not retry blindly.
    case unauthorized
    /// `503` or transport failure — retryable, and explicitly not a state change.
    case unavailableBackend
    /// Response belonged to an obsolete account/session and was dropped without applying.
    case droppedStaleSession

    enum RefusalReason: String { case ineligible, unsupportedDisclosure, invalidRequest }
}

/// Deletion is its own operation with its own request identity, independent of enrollment and plan.
enum VoiceSharingDeletionOutcome: Equatable {
    /// `202` with opaque `deletion_request_id` + `status: deletion_pending`. Local UI must show this as
    /// PENDING, never as completed, because local queue removal alone proves nothing about server state.
    case pending(deletionRequestId: String)
    case refused(reason: VoiceSharingMutationOutcome.RefusalReason)
    case unauthorized
    case unavailableBackend
}
