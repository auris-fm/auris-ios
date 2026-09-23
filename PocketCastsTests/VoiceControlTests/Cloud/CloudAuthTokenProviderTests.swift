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

        // Service recovers: the SAME refresh chain is used (not a new credential
        // exchange), proving the chain was never discarded.
        var paths: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in paths.append(request.url?.path ?? "") }
        stubTokenResponse(accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 900)
        let afterOutage = await provider.token()

        XCTAssertEqual(afterOutage, "access-2")
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
