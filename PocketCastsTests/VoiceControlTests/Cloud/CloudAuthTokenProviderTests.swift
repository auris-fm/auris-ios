import XCTest
@testable import podcasts

/// Task #33 client half — `CloudTokenProviding` against the published contract:
/// `POST /api/v1/auth/token` exchange, reactive refresh-once-on-401 against
/// `POST /api/v1/auth/refresh` with rotation, 15-minute access lifetime, and the
/// fail-closed / no-same-turn-retry postures the seam already pins.
/// The transport every provider suite in this file uses: an ephemeral session with the stub URL
/// protocol registered. FILE-SCOPED because more than one class in this file needs exactly this
/// session — duplicating it per class is how two suites drift into testing different transports.
private func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CloudRouteTestURLProtocol.self]
    return URLSession(configuration: config)
}

final class CloudAuthTokenProviderTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - acquisition

    func testExchangesPresentedCredentialForAurisTokens() async throws {
        var requests: [(path: String, body: [String: Any])] = []
        CloudRouteTestURLProtocol.onRequest = { request, body in
            guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
            requests.append((request.url?.path ?? "", object))
        }
        stubTokenResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900)

        let provider = makeProvider(credential: "pc-session-credential")
        let token = await provider.token()

        XCTAssertEqual(token, "access-1")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.path, "/api/v1/auth/token")
        XCTAssertEqual(requests.first?.body["credential"] as? String, "pc-session-credential", "the app's existing session credential is presented")
        let device = try XCTUnwrap(requests.first?.body["device"] as? [String: Any])
        XCTAssertEqual(device["platform"] as? String, "ios")
        XCTAssertNotNil(device["app_version"])
    }

    func testCachedTokenIsReusedWithoutNetwork() async {
        stubTokenResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900)
        let provider = makeProvider(credential: "cred")
        _ = await provider.token()

        // Second call must be served from the cache: arm the failure only now.
        CloudRouteTestURLProtocol.onRequest = { _, _ in XCTFail("second call must reuse the cached access token") }
        let second = await provider.token()

        XCTAssertEqual(second, "access-1")
    }

    func testExpiredAccessTokenRefreshesRatherThanReExchangingCredential() async throws {
        var paths: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in paths.append(request.url?.path ?? "") }
        stubTokenResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900)

        let provider = makeProvider(credential: "cred")
        _ = await provider.token()

        // Advance past the 15-minute lifetime; the refresh token is still valid.
        now = now.addingTimeInterval(901)
        stubTokenResponse(accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 900)

        let refreshed = await provider.token()

        XCTAssertEqual(refreshed, "access-2")
        XCTAssertEqual(paths.last, "/api/v1/auth/refresh", "expiry uses the rotating refresh chain, not a new credential exchange")
    }

    // MARK: - reactive refresh on 401

    func testUnauthorizedTriggersExactlyOneRefresh() async throws {
        var paths: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in paths.append(request.url?.path ?? "") }
        stubTokenResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900)

        let provider = makeProvider(credential: "cred")
        _ = await provider.token()

        stubTokenResponse(accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 900)
        await provider.handleUnauthorized()

        XCTAssertEqual(paths.filter { $0 == "/api/v1/auth/refresh" }.count, 1, "a 401 refreshes once")
        let after = await provider.token()
        XCTAssertEqual(after, "access-2", "the rotated pair is adopted")
    }

    /// The load-bearing one: two concurrent 401s must not both rotate the refresh
    /// token — the second replay revokes the whole chain (401 refresh_reused),
    /// which would log the user out.
    func testConcurrentUnauthorizedEventsSingleFlightTheRefresh() async throws {
        var refreshCount = 0
        CloudRouteTestURLProtocol.onRequest = { request, _ in
            if request.url?.path == "/api/v1/auth/refresh" { refreshCount += 1 }
        }
        stubTokenResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900)
        let provider = makeProvider(credential: "cred")
        _ = await provider.token()

        CloudRouteTestURLProtocol.requestHandler = { _ in
            .slowChunks(
                body: Data(#"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":900}"#.utf8),
                chunkDelayNanoseconds: 60_000_000
            )
        }

        async let first: Void = provider.handleUnauthorized()
        async let second: Void = provider.handleUnauthorized()
        _ = await (first, second)

        XCTAssertEqual(refreshCount, 1, "concurrent 401s collapse into a single refresh")
    }

    /// A rotated-out refresh token returns 401: re-acquire from the session
    /// credential rather than retrying the refresh.
    func testReusedRefreshTokenFallsBackToCredentialExchange() async throws {
        var paths: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in paths.append(request.url?.path ?? "") }
        stubTokenResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900)
        let provider = makeProvider(credential: "cred")
        _ = await provider.token()

        // Refresh chain revoked/replayed: 401 from /refresh.
        CloudRouteTestURLProtocol.stubJSON(status: 401, body: #"{"code":"refresh_reused"}"#)
        await provider.handleUnauthorized()

        XCTAssertTrue(paths.contains("/api/v1/auth/refresh"), "the rotating chain is tried first")
        XCTAssertEqual(paths.filter { $0 == "/api/v1/auth/refresh" }.count, 1, "a 401 from refresh is not retried")

        // The rejected chain is dropped, so the next acquisition re-exchanges the
        // credential through the token endpoint instead of replaying the refresh.
        paths.removeAll()
        stubTokenResponse(accessToken: "access-3", refreshToken: "refresh-3", expiresIn: 900)
        let after = await provider.token()

        XCTAssertEqual(after, "access-3")
        XCTAssertEqual(paths, ["/api/v1/auth/token"], "re-authenticates via the token endpoint, never a refresh retry")
    }

    // MARK: - inconclusive vs rejected (nightshift's 503-vs-401 split)

    /// A 503 on the refresh path must not sign the user out: the chain is kept
    /// and a token still inside its real lifetime keeps serving calls.
    func testInconclusiveRefreshKeepsTheChainAndServesTheStillValidToken() async {
        stubTokenResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900)
        let provider = makeProvider(credential: "cred")
        _ = await provider.token()

        // Past the proactive-refresh boundary, but well inside the real lifetime.
        now = now.addingTimeInterval(880)
        CloudRouteTestURLProtocol.stubJSON(status: 503, body: #"{"code":"unavailable"}"#)

        let duringOutage = await provider.token()
        XCTAssertEqual(duringOutage, "access-1", "an upstream blip must not fail a call with a still-valid token")

        // Service recovers: the turn path stays non-blocking (it keeps serving the
        // still-valid token) and the refresh happens out of band.
        var paths: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in paths.append(request.url?.path ?? "") }
        stubTokenResponse(accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 900)
        let immediatelyAfterRecovery = await provider.token()
        XCTAssertEqual(immediatelyAfterRecovery, "access-1", "the turn path serves the still-valid token rather than waiting")

        // The background refresh then rotates the SAME chain (no re-exchange).
        var rotated: String?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if await provider.token() == "access-2" { rotated = "access-2"; break }
        }
        XCTAssertEqual(rotated, "access-2", "the background refresh adopts the rotated pair")
        XCTAssertEqual(paths, ["/api/v1/auth/refresh"], "the kept chain is rotated, not re-exchanged")
    }

    /// A 401 on the refresh path is definitive: the chain is dropped and the next
    /// acquisition re-exchanges the account credential.
    func testRejectedRefreshDropsTheChain() async {
        stubTokenResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900)
        let provider = makeProvider(credential: "cred")
        _ = await provider.token()

        now = now.addingTimeInterval(901)
        CloudRouteTestURLProtocol.stubJSON(status: 401, body: #"{"code":"refresh_revoked"}"#)
        var paths: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in paths.append(request.url?.path ?? "") }

        let rejected = await provider.token()
        XCTAssertNil(rejected)
        XCTAssertEqual(paths, ["/api/v1/auth/refresh", "/api/v1/auth/token"], "401 ⇒ re-acquire from the credential")

        // Next call goes straight to the credential exchange.
        paths.removeAll()
        stubTokenResponse(accessToken: "access-3", refreshToken: "", expiresIn: 900)
        let reacquired = await provider.token()
        XCTAssertEqual(reacquired, "access-3")
        XCTAssertEqual(paths, ["/api/v1/auth/token"])
    }

    // MARK: - fail closed

    func testNoCredentialAndNoRefreshTokenYieldsNilWithoutDialing() async {
        CloudRouteTestURLProtocol.onRequest = { _, _ in XCTFail("nothing should be dialed without a credential") }
        CloudRouteTestURLProtocol.stubJSON(status: 200, body: "{}")

        let provider = makeProvider(credential: nil)
        let token = await provider.token()

        XCTAssertNil(token, "no credential ⇒ no token, so callers fail closed")
    }

    func testExchangeFailureYieldsNilRatherThanThrowing() async {
        CloudRouteTestURLProtocol.stubJSON(status: 503, body: #"{"code":"unavailable"}"#)
        let provider = makeProvider(credential: "cred")
        let first = await provider.token()
        XCTAssertNil(first)
    }

    func testRetryableRefreshFailureKeepsTheCredentialForNextTime() async {
        CloudRouteTestURLProtocol.stubJSON(status: 503, body: #"{"code":"unavailable"}"#)
        let provider = makeProvider(credential: "cred")

        let failed = await provider.token()
        XCTAssertNil(failed)

        // A later attempt with a healthy service still succeeds from the same credential.
        stubTokenResponse(accessToken: "access-late", refreshToken: "refresh-late", expiresIn: 900)
        let late = await provider.token()
        XCTAssertEqual(late, "access-late")
    }

    // MARK: - helpers

    // MARK: - the authenticated SNAPSHOT (token + account together)

    /// The snapshot is the ONLY place an account and a credential are paired, so its four
    /// discriminating cases are controls rather than an incidental assertion.
    func testAuthenticatedSessionPairsTheValidatedTokenWithItsAccount() async throws {
        stubTokenResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900)
        let provider = makeProvider(credential: "pc-session-credential")

        // `XCTUnwrap` is an autoclosure too, so the await must complete before it is called.
        let resolvedSession = await provider.authenticatedSession()
        let session = try XCTUnwrap(resolvedSession)
        XCTAssertEqual(session.accountId, "acct-A")
        XCTAssertEqual(session.accessToken, "access-1",
                       "the snapshot's token is exactly the one handed to the frame")
        // `token()` is the same acquisition, not a second one. Resolved into a local first:
        // `XCTAssertEqual`'s arguments are autoclosures and cannot carry an `await`.
        let projectedToken = await provider.token()
        XCTAssertEqual(projectedToken, session.accessToken,
                       "token() and the snapshot must not describe different tokens")
    }

    /// MISSING CREDENTIAL: with nothing to authenticate, no session is reported — not a session
    /// with an empty token and a borrowed account.
    func testAuthenticatedSessionIsNilWithoutACredential() async {
        CloudRouteTestURLProtocol.onRequest = { _, _ in
            XCTFail("must not dial without a credential")
        }
        let provider = makeProvider(credential: nil)
        let session = await provider.authenticatedSession()
        XCTAssertNil(session, "no credential means no authenticated account to journal under")
    }

    /// ACCOUNT SWITCH: the cached session belongs to the account whose credential is stored, so a
    /// switch drops it and the snapshot reports the NEW account — never the old one's token.
    func testAuthenticatedSessionFollowsAnAccountSwitch() async throws {
        var credential = "cred-A"
        var identity = "acct-A"
        stubTokenResponse(accessToken: "token-for-A", refreshToken: "refresh-A", expiresIn: 900)
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: { credential },
            identityProvider: { identity },
            appVersionProvider: { "1.0" },
            session: makeStubSession(),
            now: { self.now }
        )
        let resolvedA = await provider.authenticatedSession()
        let forA = try XCTUnwrap(resolvedA)
        XCTAssertEqual(forA.accountId, "acct-A")

        identity = "acct-B"
        credential = "cred-B"
        stubTokenResponse(accessToken: "token-for-B", refreshToken: "refresh-B", expiresIn: 900)
        let resolvedB = await provider.authenticatedSession()
        let forB = try XCTUnwrap(resolvedB)
        XCTAssertEqual(forB.accountId, "acct-B", "A's account must not describe B's session")
        XCTAssertEqual(forB.accessToken, "token-for-B", "A's token must not be served to B")
    }

    /// ORIGIN CHANGE: a token minted by one auth origin is not presented to another, and the
    /// snapshot must not describe the old origin's session as the current one.
    func testAuthenticatedSessionIsNotCarriedAcrossAnOriginChange() async throws {
        var origin = "https://auth.test"
        var dialled: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in
            dialled.append(request.url?.host ?? "")
        }
        stubTokenResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900)
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { origin },
            credentialProvider: { "cred" },
            identityProvider: { "acct-A" },
            appVersionProvider: { "1.0" },
            session: makeStubSession(),
            // A LONG lifetime: the token must still be cache-valid when the origin changes, so
            // the ONLY thing that can invalidate it is the origin rule under test. With a short
            // lifetime the control can pass for expiry instead, and prove nothing about origin.
            now: { self.now }
        )
        let resolvedSnapshot = await provider.authenticatedSession()
        _ = try XCTUnwrap(resolvedSnapshot)
        let dialledBefore = dialled.count

        // Repointed at another environment: the cached token was minted by the old origin.
        //
        // RE-DIAL IS ALLOWED. The invariant under test is that the PREVIOUS ORIGIN'S SNAPSHOT is
        // never served here — discarding it and acquiring anew satisfies that. Forbidding the
        // re-dial categorically tested the implementation's discard strategy rather than the
        // property, and failing on any request made the assertion below unreachable.
        origin = "https://auth.other.test"
        let freshToken = "token-for-other-origin"
        CloudRouteTestURLProtocol.onRequest = { request, _ in
            dialled.append(request.url?.host ?? "")
        }
        stubTokenResponse(accessToken: freshToken, refreshToken: "refresh-2", expiresIn: 900)
        let afterOriginChange = await provider.authenticatedSession()
        XCTAssertNotEqual(afterOriginChange?.accessToken, "access-1",
                          "a token from the previous origin is never served here")
        XCTAssertEqual(afterOriginChange?.accessToken, freshToken,
                       "the session presented after the change is the one minted for the new origin")
        XCTAssertGreaterThanOrEqual(dialled.count, dialledBefore,
                                    "a fresh acquisition is permitted; suppressing it is not required")
    }

    /// EXPIRED CACHE with no way to refresh: no session, so nothing can be journaled under a
    /// credential that would not be presented.
    ///
    /// `onRequest` is an OBSERVER, not an answerer: it sees the request and changes nothing about
    /// the response, which still comes from `stubJSON`'s handler. An empty closure there therefore
    /// does NOT make the exchange unrefreshable — it was still answering 200 with `access-1`, which
    /// is precisely why an earlier version of this control observed a live session. The exchange is
    /// made unrefreshable here by installing a FAILING handler.
    func testAuthenticatedSessionIsNilOnceTheCacheIsExpiredAndUnrefreshable() async {
        // A transport that CANNOT answer: with no handler installed the URLProtocol fails the
        // request (`didFailWithError(.unknown)`), which is the provider's `inconclusive` outcome —
        // the genuine "we had a credential and the exchange failed" case, distinct from having no
        // credential at all. Asserted below rather than assumed.
        CloudRouteTestURLProtocol.clearStubHandler()
        var clock = now
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: { "cred" },
            identityProvider: { "acct-A" },
            appVersionProvider: { "1.0" },
            session: makeStubSession(),
            now: { clock }
        )
        _ = await provider.authenticatedSession()
        // BEYOND HARD EXPIRY, not merely past the proactive boundary. `expirySkew` is 30s and this
        // fixture mints with `expires_in: 1`, so `expiresAt` lands at mint time while
        // `hardExpiresAt` sits a full second later; advancing by anything less than that leaves
        // `cachedUsableSession()` legitimate and the control never reaches the refresh path it is
        // supposed to test. FORWARDS, not backwards: `now - 3600` is an hour BEFORE the token was
        // minted, which leaves it comfortably valid and asserts the opposite of the name.
        clock = now.addingTimeInterval(3600)
        let requestsBefore = CloudRouteTestURLProtocol.requestCount
        let expired = await provider.authenticatedSession()
        XCTAssertNil(expired, "an expired, unrefreshable session is not an authenticated one")
        // PROOF the exchange really was attempted and really could not be answered — without this,
        // a control can pass because nothing was dialled, which proves nothing about refresh.
        XCTAssertGreaterThan(CloudRouteTestURLProtocol.requestCount, requestsBefore,
                             "the refresh path must actually reach the network, not be skipped")
    }

    /// SWITCHING AT THE RETURN BOUNDARY. The account must come from the `Tokens` value whose
    /// access token is returned, never from an `identityProvider()` read taken after the token
    /// came back. This is the control that fails if anyone reintroduces the later read: the
    /// identity flips to a second account mid-flight, and the returned snapshot must still name
    /// the account the token was minted for.
    func testSnapshotAccountComesFromTheTokensNotALaterIdentityRead() async throws {
        var identity = "acct-A"
        // TWO PAIRS, each served to a DIFFERENT acquisition, so the expected owner is bound to the
        // token that was actually minted rather than to whichever account happens to be current.
        // The first acquisition presents acct-A and receives access-A; the second presents acct-B
        // and receives access-B. A provider that stamps the snapshot from a post-acquisition
        // `identityProvider()` read cannot satisfy both pairings at once.
        //
        // The old version of this control minted ONE pair and then asserted both that the second
        // snapshot kept access-A and that it did not name acct-B — two claims no implementation
        // can hold simultaneously, which is why it failed for a reason unrelated to the seam.
        var served: [(presented: String, token: String)] = []
        CloudRouteTestURLProtocol.onRequest = { _, _ in }
        CloudRouteTestURLProtocol.stubJSON(
            status: 200,
            body: #"{"access_token":"access-A","expires_in":900,"refresh_token":"refresh-A"}"#
        )
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: { "cred" },
            identityProvider: { identity },
            appVersionProvider: { "1.0" },
            session: makeStubSession(),
            now: { self.now }
        )
        let resolvedSnapshot = await provider.authenticatedSession()
        let session = try XCTUnwrap(resolvedSnapshot)
        // FIRST ACQUISITION: the fixture presented acct-A, so the snapshot must name acct-A and
        // carry exactly the token that acquisition received. Both halves are asserted against the
        // SAME pair, which is the property — not against a value chosen after the fact.
        served.append((presented: "acct-A", token: "access-A"))
        XCTAssertEqual(session.accessToken, "access-A")
        XCTAssertEqual(session.accountId, served[0].presented,
                       "the snapshot names the account whose credential produced access-A")

        // The identity that will be read from now on is a DIFFERENT account, and that account
        // brings its OWN token pair. The relay answers with access-B, so a second acquisition
        // legitimately names acct-B — this is a NEW session, not a relabelled old one.
        identity = "acct-B"
        CloudRouteTestURLProtocol.stubJSON(
            status: 200,
            body: #"{"access_token":"access-B","expires_in":900,"refresh_token":"refresh-B"}"#
        )
        let afterFlip = await provider.authenticatedSession()
        if afterFlip?.accessToken == "access-A" {
            // The OLD token is still being served, so its account must be the OLD one: an
            // unchanged token may never acquire a new label.
            XCTAssertEqual(afterFlip?.accountId, served[0].presented,
                           "a token that was not re-minted keeps the account it was minted for")
        } else {
            // A new token was acquired under acct-B, so the pair must move together.
            XCTAssertEqual(afterFlip?.accessToken, "access-B")
            XCTAssertEqual(afterFlip?.accountId, "acct-B",
                           "a freshly minted token is paired with the account that presented for it")
        }
        XCTAssertNotEqual(afterFlip?.accessToken, "access-A",
                          "acct-B's acquisition must not be answered with acct-A's token")
    }

    /// A token with no recorded account identity cannot name an owner, so it yields NO session
    /// rather than a token paired with a guess.
    func testSnapshotRequiresAnAccountStampedOnTheTokens() async {
        // Identity absent when the tokens are minted: the stored sourceIdentity is nil.
        CloudRouteTestURLProtocol.onRequest = { _, _ in }
        CloudRouteTestURLProtocol.stubJSON(
            status: 200,
            body: #"{"access_token":"access-A","expires_in":900,"refresh_token":"refresh-A"}"#
        )
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: { "cred" },
            identityProvider: { nil },
            appVersionProvider: { "1.0" },
            session: makeStubSession(),
            now: { self.now }
        )
        let session = await provider.authenticatedSession()
        XCTAssertNil(session, "no account identity means no snapshot, never token-plus-placeholder")
    }

    private func stubTokenResponse(accessToken: String, refreshToken: String, expiresIn: Int) {
        CloudRouteTestURLProtocol.stubJSON(
            status: 200,
            body: #"{"access_token":"\#(accessToken)","token_type":"Bearer","expires_in":\#(expiresIn),"refresh_token":"\#(refreshToken)","refresh_expires_in":2592000,"issuer":"https://auth.auris.fm","subject":"user-1"}"#
        )
    }

    private func makeProvider(credential: String?) -> CloudAuthTokenProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        return CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: { credential },
            identityProvider: { "acct-A" },
            appVersionProvider: { "1.2.3" },
            session: URLSession(configuration: config),
            now: { self.now }
        )
    }
}

/// The credential presented for the exchange is the session the app already
/// holds, with the refresh token preferred (the verifier's refresh-exchange mode).
final class CloudAccountSessionCredentialProviderTests: XCTestCase {
    func testExistingPasswordSessionObtainsRefreshAtCredentialBoundary() {
        var refresh: String?
        var migrations = 0
        let provider = CloudAccountSessionCredentialProvider(refreshTokenReader: { refresh }, migrate: {
            migrations += 1
            refresh = "migrated-refresh"
        })
        XCTAssertEqual(provider.credential(), "migrated-refresh")
        XCTAssertEqual(provider.credential(), "migrated-refresh")
        XCTAssertEqual(migrations, 1)
    }

    func testFailedMigrationStillPresentsNoAccessToken() {
        var migrations = 0
        let provider = CloudAccountSessionCredentialProvider(refreshTokenReader: { nil }, migrate: { migrations += 1 })
        XCTAssertNil(provider.credential())
        XCTAssertEqual(migrations, 1)
    }

    func testPresentsTheAccountRefreshToken() {
        let provider = CloudAccountSessionCredentialProvider(refreshTokenReader: { "refresh-1" })
        XCTAssertEqual(provider.credential(), "refresh-1")
    }

    func testEmptyOrMissingRefreshTokenYieldsNil() {
        XCTAssertNil(CloudAccountSessionCredentialProvider(refreshTokenReader: { "" }).credential())
        XCTAssertNil(CloudAccountSessionCredentialProvider(refreshTokenReader: { nil }).credential(), "signed out ⇒ callers fail closed")
    }
}

/// PR #20 review fixes: burst-idempotent 401 handling, a non-blocking turn path,
/// and a cache keyed to the account it was minted for.
final class CloudAuthTokenReviewFixTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    private func stub(access: String, refresh: String) {
        CloudRouteTestURLProtocol.stubJSON(
            status: 200,
            body: #"{"access_token":"\#(access)","expires_in":900,"refresh_token":"\#(refresh)"}"#
        )
    }

    /// A 401 for a token a concurrent refresh already replaced must be a no-op.
    func testLateUnauthorizedForAReplacedTokenDoesNotRefreshAgain() async {
        var refreshCount = 0
        CloudRouteTestURLProtocol.onRequest = { request, _ in
            if request.url?.path == "/api/v1/auth/refresh" { refreshCount += 1 }
        }
        stub(access: "access-1", refresh: "refresh-1")
        let provider = makeProvider { "cred" }
        let first = await provider.token()
        XCTAssertEqual(first, "access-1")

        // One refresh for the burst.
        now = now.addingTimeInterval(901)
        stub(access: "access-2", refresh: "refresh-2")
        await provider.handleUnauthorized(rejectedToken: "access-1")
        XCTAssertEqual(refreshCount, 1)

        // Late 401s carrying the *old* token arrive after the refresh completed.
        await provider.handleUnauthorized(rejectedToken: "access-1")
        await provider.handleUnauthorized(rejectedToken: "access-1")

        XCTAssertEqual(refreshCount, 1, "a rejection of an already-replaced token must not rotate again")
        let current = await provider.token()
        XCTAssertEqual(current, "access-2", "the refreshed token keeps serving")
    }

    /// The turn path must not wait on a network round trip while a token is still
    /// inside its real lifetime: it serves that token and refreshes out of band.
    func testTurnPathServesTheUsableTokenWithoutWaitingWhenPastTheSkew() async {
        stub(access: "access-1", refresh: "refresh-1")
        let provider = makeProvider { "cred" }
        _ = await provider.token()

        // Past the proactive boundary, inside the real lifetime; the refresh
        // response is deliberately slow so a blocking implementation would show.
        now = now.addingTimeInterval(880)
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .slowChunks(
                body: Data(#"{"access_token":"access-2","expires_in":900,"refresh_token":"refresh-2"}"#.utf8),
                chunkDelayNanoseconds: 300_000_000
            )
        }

        let start = Date()
        let served = await provider.token()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(served, "access-1", "the still-valid token is served")
        XCTAssertLessThan(elapsed, 0.25, "the turn path must not wait out the refresh")
    }

    /// The cache is dropped when the credential behind it changes (sign-out or a
    /// different account), so a second user is never served the first user's token.
    func testCacheIsDroppedWhenTheAccountCredentialChanges() async {
        var credential = "cred-A"
        var identity = "acct-A"
        var requestedTokens: [String?] = []
        CloudRouteTestURLProtocol.onRequest = { request, body in
            if request.url?.path == "/api/v1/auth/token",
               let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                requestedTokens.append(object["credential"] as? String)
            }
        }
        stub(access: "token-for-A", refresh: "refresh-A")
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: { credential },
            identityProvider: { identity },
            appVersionProvider: { "1.0" },
            session: makeStubSession(),
            now: { self.now }
        )
        let forA = await provider.token()
        XCTAssertEqual(forA, "token-for-A")

        // Same account, renewed credential (a sync-session refresh): the cache is
        // kept — keying on the rotating credential made this look like a switch.
        credential = "cred-B"
        let afterRenewal = await provider.token()
        XCTAssertEqual(afterRenewal, "token-for-A", "a credential renewal is not an account change")
        XCTAssertEqual(requestedTokens, ["cred-A"], "no extra exchange for a renewal")

        // A different ACCOUNT signs in without an app restart: dropped and re-acquired.
        identity = "acct-B"
        stub(access: "token-for-B", refresh: "refresh-B")
        let forB = await provider.token()

        XCTAssertEqual(forB, "token-for-B", "A's cached token must not be served to B")
        XCTAssertEqual(requestedTokens, ["cred-A", "cred-B"], "B's exchange presents B's credential")
    }

    private func makeProvider(credential: @escaping () -> String?) -> CloudAuthTokenProvider {
        CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: credential,
            identityProvider: { "acct-A" },
            appVersionProvider: { "1.0" },
            session: makeStubSession(),
            now: { self.now }
        )
    }

    private func testSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// PR #20 review: tokens are keyed to the **account** the request was made for,
/// not to the rotating session credential — otherwise a credential renewal during
/// a request would look like an account switch.
final class CloudAuthTokenAccountKeyingTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    func testTokensAreKeyedToTheAccountTheRequestWasMadeFor() async {
        var credential = "cred-A"
        var identity = "acct-A"
        // The exchange response is delivered slowly enough that the account can
        // switch before it is decoded.
        CloudRouteTestURLProtocol.stubJSON(
            status: 200,
            body: #"{"access_token":"token-for-A","expires_in":900,"refresh_token":"refresh-A"}"#
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: { credential },
            identityProvider: { identity },
            appVersionProvider: { "1.0" },
            session: URLSession(configuration: config),
            now: { self.now }
        )

        // A renewed credential mid-flight is not an account change: the mint
        // still belongs to this account and is served.
        let inFlight = Task { await provider.token() }
        try? await Task.sleep(nanoseconds: 5_000_000)
        credential = "cred-B"
        let minted = await inFlight.value
        XCTAssertEqual(minted, "token-for-A", "a credential renewal must not invalidate the turn")

        // An ACCOUNT change mid-flight must never hand over the previous
        // account's token: the caller acquires for the new account instead.
        now = now.addingTimeInterval(901)
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .slowChunks(
                body: Data(#"{"access_token":"token-for-A2","expires_in":900,"refresh_token":"refresh-A2"}"#.utf8),
                chunkDelayNanoseconds: 200_000_000
            )
        }
        let secondFlight = Task { await provider.token() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        identity = "acct-B"
        CloudRouteTestURLProtocol.stubJSON(
            status: 200,
            body: #"{"access_token":"token-for-B","expires_in":900,"refresh_token":"refresh-B"}"#
        )
        let afterSwitch = await secondFlight.value
        XCTAssertEqual(afterSwitch, "token-for-B", "the new account acquires its own token, never the previous account's")
    }
}

/// PR #20 review: the single-flight result must not be handed to a different
/// account — a 15s refresh can outlive a sign-out.
final class CloudAuthTokenInflightSwitchTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    func testTokenDoesNotReturnAnotherAccountsInflightRefreshResult() async {
        var credential = "cred-A"
        var identity = "acct-A"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: { credential },
            identityProvider: { identity },
            appVersionProvider: { "1.0" },
            session: URLSession(configuration: config),
            now: { self.now }
        )

        // A mints and then its refresh is in flight (slow response).
        CloudRouteTestURLProtocol.stubJSON(
            status: 200,
            body: #"{"access_token":"token-for-A","expires_in":900,"refresh_token":"refresh-A"}"#
        )
        _ = await provider.token()
        now = now.addingTimeInterval(901)  // past the skew: the next call refreshes

        CloudRouteTestURLProtocol.requestHandler = { _ in
            .slowChunks(
                body: Data(#"{"access_token":"refreshed-for-A","expires_in":900,"refresh_token":"refresh-A2"}"#.utf8),
                chunkDelayNanoseconds: 300_000_000
            )
        }
        let inFlight = Task { await provider.token() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // A *different account* signs in while A's refresh is still running: that
        // result belongs to A, so the caller must acquire for B instead of taking it.
        credential = "cred-B"
        identity = "acct-B"
        CloudRouteTestURLProtocol.stubJSON(
            status: 200,
            body: #"{"access_token":"token-for-B","expires_in":900,"refresh_token":"refresh-B"}"#
        )
        let forB = await inFlight.value

        XCTAssertEqual(forB, "token-for-B", "B gets its own token, never A's in-flight refresh result")
    }
}

/// PR #20 review (blocking): dropping the *credential* while the account id stays
/// set — what the app does after a failed re-auth — must fail closed rather than
/// keep serving the invalidated session.
final class CloudAuthTokenCredentialLossTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    func testLosingTheCredentialDropsTheCacheAndFailsClosed() async {
        var credential: String? = "cred-A"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: { credential },
            identityProvider: { "acct-A" },  // the app leaves the account id set
            appVersionProvider: { "1.0" },
            session: URLSession(configuration: config),
            now: { self.now }
        )
        CloudRouteTestURLProtocol.stubJSON(
            status: 200,
            body: #"{"access_token":"token-A","expires_in":900,"refresh_token":"refresh-A"}"#
        )
        let before = await provider.token()
        XCTAssertEqual(before, "token-A")

        // The app invalidated the session: credential gone, account id still set.
        credential = nil
        let after = await provider.token()

        XCTAssertNil(after, "no credential ⇒ no token; the caller must dial nothing")
    }
}

/// PR #20 review: an acquisition that completes after the credential was
/// withdrawn must not be handed out — both conditions apply to the *result*.
final class CloudAuthTokenResultGuardTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    func testAcquisitionResultIsRefusedWhenTheCredentialWasWithdrawnMidFlight() async {
        var credential: String? = "cred-A"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.test" },
            credentialProvider: { credential },
            identityProvider: { "acct-A" },
            appVersionProvider: { "1.0" },
            session: URLSession(configuration: config),
            now: { self.now }
        )
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .slowChunks(
                body: Data(#"{"access_token":"token-A","expires_in":900,"refresh_token":"refresh-A"}"#.utf8),
                chunkDelayNanoseconds: 200_000_000
            )
        }

        let inFlight = Task { await provider.token() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        credential = nil  // the app abandons the session mid-acquisition

        let minted = await inFlight.value
        XCTAssertNil(minted, "a token acquired for a withdrawn credential must not be handed out")
    }
}

/// PR #20 review (scope): the provider must actually be reachable in production —
/// the credential source is chosen per call from the configured origin.
final class CloudTokenProviderRouterTests: XCTestCase {
    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    func testEdgeTokensEnabledSelectsTheAurisProvider() async {
        let provider = CloudTokenProviderRouter.provider(aurisBaseURL: "https://api.test", edgeTokensEnabled: true)
        XCTAssertTrue(provider is CloudAuthTokenProvider, "the switch is on and an origin is configured ⇒ Auris tokens")
    }

    /// The switch is deliberately independent of the origin: a configured origin
    /// is also what makes the assistant work, so coupling the two would flip every
    /// configured client to Auris tokens the moment this shipped.
    func testConfiguredOriginAloneKeepsTheStaticProvider() async {
        let provider = CloudTokenProviderRouter.provider(aurisBaseURL: "https://api.test", edgeTokensEnabled: false)
        XCTAssertTrue(provider is CloudStaticIdentityTokenProvider,
                      "a configured origin without the switch ⇒ today's bearer, so the change is deferrable")
    }

    func testUnconfiguredOriginKeepsTheStaticProvider() async {
        let provider = CloudTokenProviderRouter.provider(aurisBaseURL: "", edgeTokensEnabled: true)
        XCTAssertTrue(provider is CloudStaticIdentityTokenProvider, "no origin ⇒ nothing to mint against")
    }

    func testConfiguredOriginDoesNotFallBackToTheLegacyBearer() async {
        // With the Auris provider selected and no credential, the route path must
        // fail closed rather than dial with `user_<uuid>`.
        var credential: String? = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        var requests: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in requests.append(request.value(forHTTPHeaderField: "Authorization") ?? "") }
        let client = CloudRouteClient(
            baseURL: "https://api.test",
            userId: "user_legacy",
            session: URLSession(configuration: config),
            tokenProvider: CloudAuthTokenProvider(
                authBaseURLProvider: { "https://auth.test" },
                credentialProvider: { credential },
                identityProvider: { "acct-A" },
                appVersionProvider: { "1.0" },
                session: URLSession(configuration: config)
            ),
        )

        let events = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0), turn: testTurnEnvelope()).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        // No credential ⇒ no frame built ⇒ .requestConstruction, matching the emission site.
        XCTAssertEqual(events, [.error(source: .requestConstruction, code: "unauthorized", message: "")])
        XCTAssertTrue(requests.isEmpty, "no credential ⇒ nothing dialled, and never the legacy bearer")
    }
}

/// PR #20 review: the provider must be shared across the production paths, and a
/// shared instance must not replay another environment's token.
final class CloudTokenProviderSharingTests: XCTestCase {
    func testRouterReturnsTheSameProviderAcrossCalls() {
        let first = CloudTokenProviderRouter.provider(aurisBaseURL: "https://api.test")
        let second = CloudTokenProviderRouter.provider(aurisBaseURL: "https://api.test")
        XCTAssertTrue((first as AnyObject) === (second as AnyObject),
                      "a fresh provider per client would start cold every turn and break the shared refresh lock")
        let staticFirst = CloudTokenProviderRouter.provider(aurisBaseURL: "")
        let staticSecond = CloudTokenProviderRouter.provider(aurisBaseURL: "")
        XCTAssertTrue((staticFirst as AnyObject) === (staticSecond as AnyObject))
    }

    func testInFlightAcquisitionIsRejectedAfterAnOriginChange() async {
        var origin = "https://auth-one.test"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { origin },
            credentialProvider: { "cred" },
            identityProvider: { "acct-A" },
            appVersionProvider: { "1.0" },
            session: URLSession(configuration: config)
        )
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .slowChunks(
                body: Data(#"{"access_token":"one","expires_in":900,"refresh_token":"r1"}"#.utf8),
                chunkDelayNanoseconds: 200_000_000
            )
        }
        let inFlight = Task { await provider.token() }
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Repointed at another environment mid-flight.
        origin = "https://auth-two.test"
        CloudRouteTestURLProtocol.stubJSON(status: 200, body: #"{"access_token":"two","expires_in":900,"refresh_token":"r2"}"#)

        let minted = await inFlight.value
        XCTAssertEqual(minted, "two", "the in-flight result belongs to the old origin and must not be published")
    }

    func testSharedProviderDoesNotReplayAnotherOriginsToken() async {
        var origin = "https://auth-one.test"
        var requests: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in requests.append(request.url?.absoluteString ?? "") }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        CloudRouteTestURLProtocol.stubJSON(status: 200, body: #"{"access_token":"one","expires_in":900,"refresh_token":"r1"}"#)
        let provider = CloudAuthTokenProvider(
            authBaseURLProvider: { origin },
            credentialProvider: { "cred" },
            identityProvider: { "acct-A" },
            appVersionProvider: { "1.0" },
            session: URLSession(configuration: config)
        )
        let first = await provider.token()
        XCTAssertEqual(first, "one")

        // The app is repointed at another environment; the cached token belongs to
        // the previous origin and must not be served.
        origin = "https://auth-two.test"
        CloudRouteTestURLProtocol.stubJSON(status: 200, body: #"{"access_token":"two","expires_in":900,"refresh_token":"r2"}"#)
        let second = await provider.token()

        XCTAssertEqual(second, "two", "a token minted for one origin must not be replayed to another")
    }
}
