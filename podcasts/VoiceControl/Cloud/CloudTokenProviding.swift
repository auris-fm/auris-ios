import Foundation

/// Item 5 (iOS half), slice 5 — the token-acquisition seam.
///
/// **Design only, intentionally not finalized.** `cloud-identity.md` makes
/// admission authoritative: the eventual shape depends on the trusted-issuer
/// decision tracked by task #26 (who mints the credential the client presents,
/// and how it is refreshed mid-session). Today the client sends a local
/// trust-on-first-use `user_<uuid>` bearer; `CloudStaticIdentityTokenProvider`
/// preserves exactly that behavior so this seam changes nothing until the
/// issuer lands.
///
/// What the seam buys now:
/// - every cloud call takes its credential from one place, so swapping the
///   issuer is a provider change rather than a call-site sweep;
/// - async acquisition/refresh has a defined home (`token()` is async and may
///   return nil to mean "no credential available" — callers must not retry in a
///   loop, matching the turn contract's no-retry posture);
/// - an expiry mid-session has one place to be handled.
protocol CloudTokenProviding {
    /// The credential to present, or nil when none is available. Implementations
    /// must not block on network refresh for the turn path: a cached value is
    /// returned and refresh happens out of band.
    func token() async -> String?

    /// Called after a 401 to allow an out-of-band refresh. Best effort: callers
    /// do not retry the turn with the new credential in the same turn.
    func handleUnauthorized() async

    /// Preferred form: report **which** credential was rejected.
    ///
    /// Without it a provider cannot tell a fresh 401 from one for a token a
    /// concurrent refresh has already replaced, so a burst of N 401s costs N
    /// sequential refreshes (PR #20 review). Implementations should treat a
    /// rejection of an already-replaced token as a no-op; the default
    /// implementation preserves the previous behaviour for conformances that
    /// don't care.
    func handleUnauthorized(rejectedToken: String?) async
}

extension CloudTokenProviding {
    func handleUnauthorized(rejectedToken: String?) async {
        await handleUnauthorized()
    }
}

/// Today's behavior, unchanged: a stable client-generated `user_<uuid>`.
/// When the trusted issuer ships (task #26), this is the type that gets
/// replaced — no call site changes.
final class CloudStaticIdentityTokenProvider: CloudTokenProviding {
    private let identity: CloudIdentity

    init(identity: CloudIdentity = .shared) {
        self.identity = identity
    }

    func token() async -> String? {
        identity.userId
    }

    func handleUnauthorized() async {
        // Trust-on-first-use: there is nothing to refresh yet. The issuer
        // decision (task #26) defines whether this becomes a refresh call.
    }
}
