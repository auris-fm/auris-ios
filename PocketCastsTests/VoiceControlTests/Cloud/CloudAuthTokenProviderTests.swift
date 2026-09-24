import XCTest
@testable import podcasts

/// Task #33 client half — `CloudTokenProviding` against the published contract:
/// `POST /api/v1/auth/token` exchange, reactive refresh-once-on-401 against
/// `POST /api/v1/auth/refresh` with rotation, 15-minute access lifetime, and the
/// fail-closed / no-same-turn-retry postures the seam already pins.
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
            session: testSession(),
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
            session: testSession(),
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

    func testConfiguredOriginSelectsTheAurisProvider() async {
        let provider = CloudTokenProviderRouter.provider(aurisBaseURL: "https://api.test")
        XCTAssertTrue(provider is CloudAuthTokenProvider, "a configured Auris origin means Auris-issued tokens")
    }

    func testUnconfiguredOriginKeepsTheStaticProvider() async {
        let provider = CloudTokenProviderRouter.provider(aurisBaseURL: "")
        XCTAssertTrue(provider is CloudStaticIdentityTokenProvider, "no origin ⇒ today's trust-on-first-use provider")
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
            )
        )

        let events = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        XCTAssertEqual(events, [.error(code: "unauthorized", message: "")])
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
