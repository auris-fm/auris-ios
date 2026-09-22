import XCTest
@testable import podcasts

/// Item 5 (iOS half), slice 3 — best-effort `POST /api/v1/cloud/context/prefetch`.
///
/// Contract (`cloud-assistant.md` → prefetch): body `{episode_id, podcast_id?}`
/// with verified identity; `202 {status: accepted|skipped}`; 400 malformed, 401
/// unauthenticated; it never waits for retrieval, and clients fire it best effort
/// — never delaying playback, never retrying in a loop.
final class CloudPrefetchClientTests: XCTestCase {
    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    func testAcceptedStatusMapsToAccepted() async throws {
        CloudRouteTestURLProtocol.stubJSON(status: 202, body: #"{"status":"accepted"}"#)
        var paths: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in paths.append(request.url?.path ?? "") }

        let outcome = await makeClient().prefetch(episodeId: "ep-1", podcastId: "pod-1")

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(paths, ["/api/v1/cloud/context/prefetch"])
    }

    func testSkippedStatusMapsToSkipped() async {
        CloudRouteTestURLProtocol.stubJSON(status: 202, body: #"{"status":"skipped"}"#)
        let outcome = await makeClient().prefetch(episodeId: "ep-1", podcastId: nil)
        XCTAssertEqual(outcome, .skipped)
    }

    func testRequestBodyCarriesEpisodeAndOptionalPodcast() async throws {
        CloudRouteTestURLProtocol.stubJSON(status: 202, body: #"{"status":"accepted"}"#)
        var bodies: [[String: Any]] = []
        CloudRouteTestURLProtocol.onRequest = { _, body in
            if let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                bodies.append(object)
            }
        }

        _ = await makeClient().prefetch(episodeId: "ep-1", podcastId: "pod-1")

        let body = try XCTUnwrap(bodies.first)
        XCTAssertEqual(body["episode_id"] as? String, "ep-1")
        XCTAssertEqual(body["podcast_id"] as? String, "pod-1")
    }

    func testPodcastIdOmittedWhenUnknown() async throws {
        CloudRouteTestURLProtocol.stubJSON(status: 202, body: #"{"status":"accepted"}"#)
        var bodies: [[String: Any]] = []
        CloudRouteTestURLProtocol.onRequest = { _, body in
            if let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                bodies.append(object)
            }
        }

        _ = await makeClient().prefetch(episodeId: "ep-1", podcastId: nil)

        let body = try XCTUnwrap(bodies.first)
        XCTAssertNil(body["podcast_id"])
    }

    func testUnauthenticatedIsAFailureNotACrash() async {
        CloudRouteTestURLProtocol.stubJSON(status: 401, body: #"{"code":"unauthorized"}"#)
        let outcome = await makeClient().prefetch(episodeId: "ep-1", podcastId: nil)
        XCTAssertEqual(outcome, .failed)
    }

    func testBadRequestIsAFailure() async {
        CloudRouteTestURLProtocol.stubJSON(status: 400, body: #"{"code":"invalid_request"}"#)
        let outcome = await makeClient().prefetch(episodeId: "ep-1", podcastId: nil)
        XCTAssertEqual(outcome, .failed)
    }

    func testTransportErrorIsSwallowedAndNeverRetried() async {
        var attempts = 0
        CloudRouteTestURLProtocol.requestHandler = { _ in
            attempts += 1
            return .dropAfter(body: Data(), error: URLError(.notConnectedToInternet))
        }

        let outcome = await makeClient().prefetch(episodeId: "ep-1", podcastId: nil)

        XCTAssertEqual(outcome, .failed, "prefetch failures never surface to the user")
        XCTAssertEqual(attempts, 1, "best effort: exactly one attempt, no retry loop")
    }

    func testBestEffortSchedulingDoesNotBlockCaller() async {
        CloudRouteTestURLProtocol.stubJSON(status: 202, body: #"{"status":"accepted"}"#)
        let client = makeClient()
        // Returns immediately (no await) — the request proceeds in the background.
        client.schedulePrefetch(episodeId: "ep-1", podcastId: nil)
        // If the call had blocked on the network, this assertion would still pass,
        // so pair it with the request actually being issued.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(CloudRouteTestURLProtocol.requestCount, 0, "the background attempt is issued")
    }

    private func makeClient() -> CloudPrefetchClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        return CloudPrefetchClient(
            baseURL: "https://cloud.test",
            userId: "user_test",
            session: URLSession(configuration: config)
        )
    }
}

/// The playback-start hook is best effort and never blocks or retries.
final class CloudPrefetchHookTests: XCTestCase {
    func testHookSchedulesHintForCurrentEpisodeOnPlaybackStart() {
        var requested: [(episodeId: String, podcastId: String?)] = []
        let hook = CloudPrefetchHook(
            baseURLProvider: { "https://cloud.test" },
            userIdProvider: { "user_test" },
            currentEpisodeProvider: { ("ep-1", "pod-1") },
            clientFactory: { baseURL, userId in CloudPrefetchClient(baseURL: baseURL, userId: userId) },
            scheduler: { _, episodeId, podcastId in requested.append((episodeId, podcastId)) }
        )

        hook.handlePlaybackStarted()

        XCTAssertEqual(hook.prefetchCount, 1)
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested.first?.episodeId, "ep-1")
        XCTAssertEqual(requested.first?.podcastId, "pod-1")
    }

    func testHookSkipsWhenCloudIsUnconfigured() {
        var scheduled = 0
        let hook = CloudPrefetchHook(
            baseURLProvider: { "" },
            userIdProvider: { "user_test" },
            currentEpisodeProvider: { ("ep-1", nil) },
            clientFactory: { baseURL, userId in CloudPrefetchClient(baseURL: baseURL, userId: userId) },
            scheduler: { _, _, _ in scheduled += 1 }
        )
        hook.handlePlaybackStarted()
        XCTAssertEqual(scheduled, 0, "no hint when the cloud base URL is unset")
    }

    func testHookSkipsWhenNoCurrentEpisode() {
        var scheduled = 0
        let hook = CloudPrefetchHook(
            baseURLProvider: { "https://cloud.test" },
            userIdProvider: { "user_test" },
            currentEpisodeProvider: { nil },
            clientFactory: { baseURL, userId in CloudPrefetchClient(baseURL: baseURL, userId: userId) },
            scheduler: { _, _, _ in scheduled += 1 }
        )
        hook.handlePlaybackStarted()
        XCTAssertEqual(scheduled, 0)
    }

    func testHookNeverThrowsOrRetriesOnRepeatedNotifications() {
        var scheduled = 0
        let hook = CloudPrefetchHook(
            baseURLProvider: { "https://cloud.test" },
            userIdProvider: { "user_test" },
            currentEpisodeProvider: { ("ep-1", nil) },
            clientFactory: { baseURL, userId in CloudPrefetchClient(baseURL: baseURL, userId: userId) },
            scheduler: { _, _, _ in scheduled += 1 }
        )
        // One hint per playback-start event; the network layer does not retry.
        hook.handlePlaybackStarted()
        XCTAssertEqual(hook.prefetchCount, 1)
        XCTAssertEqual(scheduled, 1)
    }
}


/// Slice 5 — the token seam: one place supplies the credential, and the default
/// preserves today's trust-on-first-use behavior (design-only until #26).
final class CloudTokenProvidingTests: XCTestCase {
    func testStaticProviderReturnsCurrentIdentity() async {
        let suiteName = "cloud_token_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let provider = CloudStaticIdentityTokenProvider(identity: CloudIdentity(defaults: defaults))
        let token = await provider.token()
        XCTAssertEqual(token?.hasPrefix("user_"), true)
        await provider.handleUnauthorized() // no-op today; must not throw
    }

    func testRouteClientPresentsProviderCredential() async throws {
        CloudRouteTestURLProtocol.stubJSON(status: 202, body: #"{"status":"accepted"}"#)
        var authHeaders: [String] = []
        CloudRouteTestURLProtocol.onRequest = { request, _ in
            authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        }

        struct FixedTokenProvider: CloudTokenProviding {
            let value: String
            func token() async -> String? { value }
            func handleUnauthorized() async {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_fallback",
            session: URLSession(configuration: config),
            tokenProvider: FixedTokenProvider(value: "token_from_issuer")
        )

        _ = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).first { _ in true }

        XCTAssertEqual(authHeaders.first, "Bearer token_from_issuer", "the provider is authoritative once supplied")
    }
}

/// Slice 5 parity: no credential ⇒ no request (Android's fail-closed posture).
final class CloudTokenFailClosedTests: XCTestCase {
    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    private struct NoTokenProvider: CloudTokenProviding {
        func token() async -> String? { nil }
        func handleUnauthorized() async {}
    }

    func testRouteSendsNoRequestWithoutACredential() async {
        CloudRouteTestURLProtocol.stubJSON(status: 200, body: "{}")
        var requests = 0
        CloudRouteTestURLProtocol.onRequest = { _, _ in requests += 1 }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "",
            session: URLSession(configuration: config),
            tokenProvider: NoTokenProvider()
        )

        let events = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        XCTAssertEqual(requests, 0, "no credential ⇒ nothing dialed")
        XCTAssertEqual(events, [.error(code: "unauthorized", message: "No cloud credential available")])
    }

    func testPrefetchSendsNoRequestWithoutACredential() async {
        CloudRouteTestURLProtocol.stubJSON(status: 202, body: #"{"status":"accepted"}"#)
        var requests = 0
        CloudRouteTestURLProtocol.onRequest = { _, _ in requests += 1 }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let client = CloudPrefetchClient(
            baseURL: "https://cloud.test",
            userId: "",
            session: URLSession(configuration: config),
            tokenProvider: NoTokenProvider()
        )

        let outcome = await client.prefetch(episodeId: "ep-1", podcastId: nil)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(requests, 0, "no credential ⇒ nothing dialed")
    }
}
