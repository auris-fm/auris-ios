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

    /// Optional warm-up, called off the turn path (assistant UI open, session
    /// start) so the turn path only ever reads a cache. The default is a no-op
    /// for providers whose `token()` is already instant.
    func prepare() async

    /// Called after a 401, reporting **which** credential was rejected.
    ///
    /// The parameter is what lets a provider tell a fresh 401 from one for a
    /// token a concurrent refresh has already replaced — without it a burst of N
    /// 401s costs N sequential refreshes (PR #20 review). Implementations should
    /// treat a rejection of an already-replaced token as a no-op; pass `nil` when
    /// the caller cannot say which credential was used.
    func handleUnauthorized(rejectedToken: String?) async

    /// The validated token-and-account snapshot, or nil when there is no usable session.
    ///
    /// **There is deliberately NO default implementation.** A default of `nil` reads as "this
    /// provider has no session", which is indistinguishable from a provider that simply never
    /// implemented the requirement — and that is exactly how every pre-existing test provider
    /// silently became unauthenticated when this requirement was introduced, taking the whole
    /// client suite with it. A default that invented a session instead would be worse: it would
    /// let a missing credential authenticate.
    ///
    /// So every conformer states its own answer. A provider that genuinely cannot name the account
    /// behind its token must say so explicitly (`return nil`) rather than inherit silence.
    ///
    /// The token the authenticate frame presents and the account the journal records must come
    /// from ONE instance of this value, produced by one validated acquisition — never a `token()`
    /// call followed by an account read from somewhere else.
    func authenticatedSession() async -> CloudAuthenticatedSession?
}

/// An ACCESS TOKEN and the ACCOUNT it authenticates, resolved as ONE validated snapshot.
///
/// The two must not be read separately. `token()` validates the cached/acquired token against the
/// current identity, the stored credential and the auth origin, and invalidates the cache when the
/// account changes; a caller that asks `token()` for a credential and then reads the account from
/// somewhere else has stepped outside all of that, and can bind one account's operation to
/// another account's token. So the validated acquisition itself produces this pair, the WebSocket
/// authenticate frame takes its `access_token` from it, and the journal takes its owner from the
/// SAME instance.
///
/// The account ID is the only part that may be persisted. The token is compared and presented,
/// never persisted and never logged.
struct CloudAuthenticatedSession: Equatable {
    /// The stable account identity (account UUID), NOT the rotating session credential.
    let accountId: String
    /// The credential presented to the server. Never persisted, never logged.
    let accessToken: String
}

extension CloudTokenProviding {
    func prepare() async {}

    /// The TRANSPORT credential for an ordinary turn, when the provider has no established
    /// principal to pair it with.
    ///
    /// This exists because those two things are different questions and conflating them breaks
    /// one of them:
    ///
    /// - **"what credential carries this turn?"** — answered by the bearer the server accepts for
    ///   transport (`UserIDMiddleware`). Trust-on-first-use satisfies this today.
    /// - **"who is the verified principal that may claim app operations?"** — NOT answered by that
    ///   bearer, and nil until the issuer lands (task #26).
    ///
    /// A provider with no established principal returns nil from `authenticatedSession()` and must
    /// still be able to open a turn, or every legacy turn breaks. The returned credential is for
    /// AUTHENTICATION FRAMING ONLY: it carries no owner, and a caller that pairs it with an account
    /// would be inventing one. App-operation admission reads `authenticatedSession()`, which stays
    /// nil, so v1 capability advertisement and operation claiming remain off.
    ///
    /// The DEFAULT forwards to `token()`: a provider that has a credential for an ordinary turn
    /// keeps working without changing anything. Providers that DO establish a principal override
    /// this to return the SAME credential as their snapshot — they must not acquire a second,
    /// independent token here, or framing and journaling could disagree.
    func transportCredential() async -> String? { await token() }

    /// Convenience for callers that cannot name the rejected credential.
    func handleUnauthorized() async {
        await handleUnauthorized(rejectedToken: nil)
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

    /// NO AUTHENTICATED SESSION — stated explicitly, because there is no principal to name.
    ///
    /// This provider is the TRUST-ON-FIRST-USE transport bearer: the client generates
    /// `user_<uuid>`, persists it locally, and sends it verbatim. The server's `UserIDMiddleware`
    /// stores that raw bearer value as the user ID without validating it (see
    /// `cloud-identity.md` — the issuer that would verify it is task #26). So the server knows
    /// only "some bearer was presented and we will treat it as this id", which is enough to carry
    /// a turn and meter it, and is NOT a verified statement that this client is that principal.
    ///
    /// Pairing `accountId` with this credential would manufacture authenticated ownership out of
    /// a value the client wrote itself, and the journal would then record an owner that no issuer
    /// vouched for. The distinction that matters:
    ///
    /// - **Legacy transport compatibility** — the bearer keeps the turn working. Unchanged.
    /// - **Permission to claim or advertise app operations** — requires an established principal.
    ///   Not available here, so it is not claimed.
    ///
    /// A nil session is therefore the honest answer, and it is fail-closed at the operation gate:
    /// `AdmittedTurnIdentity.owner` empty means no trusted owner, and an app operation is refused
    /// rather than journaled under a self-asserted identity. When the trusted issuer lands, this
    /// becomes a real minted pair and app operations become claimable.
    func authenticatedSession() async -> CloudAuthenticatedSession? { nil }

    func handleUnauthorized(rejectedToken: String?) async {
        // Trust-on-first-use: there is nothing to refresh yet. The issuer
        // decision (task #26) defines whether this becomes a refresh call.
    }
}
