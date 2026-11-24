import XCTest

@testable import podcasts

/// The fingerprint reference fetch presents the same credential the turn route
/// uses: the config-gated `CloudTokenProviding` (Auris access token when an
/// Auris origin is configured, today's TOFU bearer otherwise), and it carries
/// the episode's podcast id so the server can resolve uncached episodes.
final class CloudFingerprintFetchAuthTests: XCTestCase {

    private final class StubTokenProvider: CloudTokenProviding {
        let value: String?
        private(set) var unauthorizedCalls = 0
        init(_ value: String?) { self.value = value }
        func token() async -> String? { value }
        func handleUnauthorized(rejectedToken: String?) async { unauthorizedCalls += 1 }
    }

    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A minimal valid Auris body so a 200 parses into a matcher. These cases are about the
    /// bearer token and the retry, so the payload has to be one the Auris site accepts — a v2
    /// body would be refused for its format and every assertion here would fail for the wrong
    /// reason. The format is a literal, not the constant under test.
    private func aurisBody() -> Data {
        let json = """
        {"format":"fingerprint-compact-v3","total_duration":8.0,"checkpoint_interval":1,"checkpoint_duration":8,"timestamp_quantum":1,"checkpoints":[[0,"AQAAAA=="]]}
        """
        return Data(json.utf8)
    }

    func testRequestCarriesTheSelectedProvidersTokenAndThePodcastId() async throws {
        var seen: [URLRequest] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in seen.append(request) }
        let body = aurisBody()
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .complete(status: 200, headers: ["Content-Type": "application/json"], body: body)
        }

        let fetcher = CloudFingerprintReferenceFetcher(
            session: makeSession(),
            tokenProvider: StubTokenProvider("auris-access-token")
        )
        let matcher = await fetcher.fetchReference(
            baseUrl: "https://gateway.test",
            episodeUuid: "ep-1",
            podcastUuid: "pod-1"
        )

        XCTAssertNotNil(matcher)
        XCTAssertEqual(seen.count, 1)
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer auris-access-token")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/v1/episodes/ep-1/fingerprints")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "podcast_id", value: "pod-1")])
    }

    /// No token from the selected provider ⇒ nothing is dialled. The legacy
    /// `user_<uuid>` bearer must not leak onto a route that verifies tokens.
    func testNoTokenMeansNoRequest() async {
        var seen: [URLRequest] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in seen.append(request) }
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .complete(status: 200, headers: [:], body: self.aurisBody())
        }

        let fetcher = CloudFingerprintReferenceFetcher(
            session: makeSession(),
            tokenProvider: StubTokenProvider(nil)
        )
        let matcher = await fetcher.fetchReference(
            baseUrl: "https://gateway.test",
            episodeUuid: "ep-1",
            podcastUuid: "pod-1"
        )

        XCTAssertNil(matcher)
        XCTAssertTrue(seen.isEmpty, "no credential ⇒ no request, and never the legacy bearer")
    }

    /// The production default is the shared AURIS provider directly — never
    /// the router's per-call choice, whose legacy branch would send a TOFU id
    /// that the verified route rejects.
    func testDefaultProviderIsTheSharedAurisProvider() {
        let auris = CloudTokenProviderRouter.fingerprintReferenceProvider()
        XCTAssertTrue(auris is CloudAuthTokenProvider)
        let sharing = CloudTokenProviderRouter.voiceSharingProvider(aurisBaseURL: "https://gateway.test")
        XCTAssertTrue((auris as AnyObject) === (sharing as AnyObject),
                      "one shared Auris provider: a second instance would rotate the same refresh chain")
        let fetcher = CloudFingerprintReferenceFetcher(session: makeSession())
        XCTAssertTrue((fetcher.tokenProviderForTesting as AnyObject) === (auris as AnyObject),
                      "the fetcher must present the shared Auris provider, not the routing choice")
    }

    /// A 401 refreshes once and retries once with the fresh token — the plan's
    /// refresh-and-retry-once contract for this route.
    func testUnauthorizedRefreshesAndRetriesOnceWithTheFreshToken() async throws {
        final class RotatingProvider: CloudTokenProviding {
            var tokens: [String]
            private(set) var unauthorizedCalls = 0
            init(_ tokens: [String]) { self.tokens = tokens }
            func token() async -> String? { tokens.isEmpty ? nil : tokens[0] }
            func handleUnauthorized(rejectedToken: String?) async {
                unauthorizedCalls += 1
                if !tokens.isEmpty { tokens.removeFirst() }
            }
        }
        let provider = RotatingProvider(["stale-token", "fresh-token"])
        var seen: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in
            seen.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        }
        let body = aurisBody()
        CloudRouteTestURLProtocol.requestHandler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token" {
                return .complete(status: 200, headers: ["Content-Type": "application/json"], body: body)
            }
            return .complete(status: 401, headers: [:], body: Data())
        }

        let fetcher = CloudFingerprintReferenceFetcher(session: makeSession(), tokenProvider: provider)
        let matcher = await fetcher.fetchReference(baseUrl: "https://gateway.test", episodeUuid: "ep-1", podcastUuid: "pod-1")

        XCTAssertNotNil(matcher, "the retry with the refreshed token must succeed")
        XCTAssertEqual(seen, ["Bearer stale-token", "Bearer fresh-token"])
        XCTAssertEqual(provider.unauthorizedCalls, 1)
    }

    /// A second rejection gives up: two requests, ONE refresh report (the
    /// retry's), nil. Reporting the second rejection too would rotate the
    /// shared Auris refresh chain twice for a request that is never retried.
    func testSecondRejectionGivesUp() async {
        final class RotatingProvider: CloudTokenProviding {
            var tokens: [String]
            private(set) var unauthorizedCalls = 0
            init(_ tokens: [String]) { self.tokens = tokens }
            func token() async -> String? { tokens.isEmpty ? nil : tokens[0] }
            func handleUnauthorized(rejectedToken: String?) async {
                unauthorizedCalls += 1
                if !tokens.isEmpty { tokens.removeFirst() }
            }
        }
        let provider = RotatingProvider(["bad-1", "bad-2"])
        var requests = 0
        CloudRouteTestURLProtocol.onRequest = { _, _ in requests += 1 }
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .complete(status: 401, headers: [:], body: Data())
        }

        let fetcher = CloudFingerprintReferenceFetcher(session: makeSession(), tokenProvider: provider)
        let matcher = await fetcher.fetchReference(baseUrl: "https://gateway.test", episodeUuid: "ep-1", podcastUuid: "pod-1")

        XCTAssertNil(matcher)
        XCTAssertEqual(requests, 2, "refresh-and-retry-ONCE, never a loop")
        XCTAssertEqual(provider.unauthorizedCalls, 1, "only the rejection a retry follows is reported; the shared chain rotates once")
    }
}
