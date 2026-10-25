import Foundation

/// Test-only observation points for the voice pipeline. Nil in production.
///
/// The interruption contract makes claims about OWNERSHIP — one interrupt, one submission, one
/// retained follow-up — and ownership is not observable from the wire alone. A frame count can say
/// a submission happened once; it cannot say which of two candidate dispatches won, whether the
/// loser was refused, or whether the bridge that was supposed to submit ever ran. Controls that
/// inferred those from frame counts and terminal recordings passed while proving nothing, so the
/// decisions are reported here instead, at the point each is actually made.
enum VoiceControlTestObservers {
    /// Reports `"<utteranceId>:owner"` or `"<utteranceId>:duplicate"` for each cloud dispatch.
    static var dispatchOwnership: (@Sendable (String) -> Void)?

    /// Reports `"<utteranceId>@origin<n>"` when the service bridge TAKES a released follow-up.
    /// The bridge is the acknowledgement's submitter; whether it ran at all is a separate fact
    /// from whether a submission appeared, and one terminal recording cannot distinguish them.
    static var followUpTaken: (@Sendable (String) -> Void)?
}
