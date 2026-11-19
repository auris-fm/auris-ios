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

    /// A minimal valid compact-v2 body so a 200 parses into a matcher.
    private func compactV2Body() -> Data {
        let json = """
        {"format":"fingerprint-compact-v2","total_duration":8.0,"checkpoint_interval":1,"checkpoint_duration":8,"timestamp_quantum":1,"checkpoints":[[0,"AQAAAA=="]]}
        """
        return Data(json.utf8)
    }

    func testRequestCarriesTheSelectedProvidersTokenAndThePodcastId() async throws {
        var seen: [URLRequest] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in seen.append(request) }
        let body = compactV2Body()
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
            .complete(status: 200, headers: [:], body: self.compactV2Body())
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

    /// The production default is the turn route's router — the SAME shared
    /// provider instance, so the fingerprint path shares the token cache and
    /// refresh lock with turns instead of minting a second chain.
    func testDefaultProviderIsTheTurnRoutesSharedRouterProvider() {
        let routed = CloudTokenProviderRouter.provider()
        let fetcher = CloudFingerprintReferenceFetcher(session: makeSession())
        XCTAssertTrue(fetcher.tokenProviderForTesting === (routed as AnyObject),
                      "the fetcher must present the router's selected provider, not a private identity string")
    }

    /// A 401 tells the provider its token was rejected, so the next fetch
    /// carries a fresh one — the same reactive contract the turn route has.
    func testUnauthorizedNotifiesTheProvider() async {
        let provider = StubTokenProvider("stale-token")
        CloudRouteTestURLProtocol.requestHandler = { _ in
            .complete(status: 401, headers: [:], body: Data())
        }

        let fetcher = CloudFingerprintReferenceFetcher(session: makeSession(), tokenProvider: provider)
        let matcher = await fetcher.fetchReference(baseUrl: "https://gateway.test", episodeUuid: "ep-1", podcastUuid: "pod-1")

        XCTAssertNil(matcher)
        XCTAssertEqual(provider.unauthorizedCalls, 1)
    }
}
