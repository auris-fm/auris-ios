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

    /// A rejected credential must be **named**, not merely detected.
    ///
    /// This is the only production call site of `handleUnauthorized(rejectedToken:)`
    /// left in the app, and naming the credential is the whole property: the
    /// provider refreshes once for the burst that was rejected, rather than
    /// refreshing per response. Without the argument the provider cannot tell which
    /// credential to invalidate, and a burst of hints re-exchanges on each one.
    func testRejectedCredentialIsNamedSoTheProviderRefreshesOnce() async {
        CloudRouteTestURLProtocol.stubJSON(status: 401, body: #"{"code":"unauthorized"}"#)
        let provider = RecordingTokenProvider(token: "token-1")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let client = CloudPrefetchClient(
            baseURL: "https://cloud.test",
            userId: "user_test",
            session: URLSession(configuration: config),
            tokenProvider: provider
        )

        _ = await client.prefetch(episodeId: "ep-1", podcastId: nil)

        let reported = await provider.awaitRejections(atLeast: 1)
        XCTAssertTrue(reported, "a 401 must be reported to the provider")
        let rejections = await provider.rejections
        XCTAssertEqual(rejections, ["token-1"], "the credential that was rejected is the one named")
    }

    /// Records what the client reported, and can be awaited rather than raced —
    /// the report happens off the caller's path.
    private final class RecordingTokenProvider: CloudTokenProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _rejections: [String?] = []
        private let tokenValue: String?

        init(token: String?) { tokenValue = token }

        var rejections: [String?] {
            lock.lock(); defer { lock.unlock() }
            return _rejections
        }

        func token() async -> String? { tokenValue }

        func handleUnauthorized(rejectedToken: String?) async {
            lock.lock(); _rejections.append(rejectedToken); lock.unlock()
        }

        func awaitRejections(atLeast count: Int, timeout: TimeInterval = 2) async -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if rejections.count >= count { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return rejections.count >= count
        }
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
        // so pair it with the request actually being issued. Wait for the
        // condition rather than sleeping a fixed 200 ms: on a loaded runner the
        // background attempt lands later, which failed the count at zero and read
        // as "the request was never issued".
        let issued = await waitUntil(timeout: 10) { CloudRouteTestURLProtocol.requestCount > 0 }
        XCTAssertTrue(issued, "the background attempt is issued")
    }

    /// Polls for a condition, so the test measures the behaviour instead of the
    /// scheduler's speed.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
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
        // The credential rides the socket's **first frame**, not an HTTP header
        // (`Authorization` was the SSE-era carrier), so this asserts on the auth
        // frame the client actually sends — reading a header that is never sent
        // makes the case pass without exercising anything.
        struct FixedTokenProvider: CloudTokenProviding {
            let value: String
            func token() async -> String? { value }
            func handleUnauthorized(rejectedToken: String?) async {}
        }

        let task = StubWebSocketTask(textFrames: [#"{"type":"done","usage":{"input_tokens":1,"output_tokens":0}}"#])
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_fallback",
            requestTimeoutSeconds: 15,
            tokenProvider: FixedTokenProvider(value: "token_from_issuer"),
            webSocketTaskFactory: { _ in task }
        )

        _ = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).first { _ in true }

        XCTAssertEqual(
            task.sentAuthFrame?["access_token"] as? String,
            "token_from_issuer",
            "the provider is authoritative once supplied"
        )
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
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    func testRouteSendsNoRequestWithoutACredential() async {
        CloudRouteTestURLProtocol.stubJSON(status: 200, body: "{}")
        var requests = 0
        CloudRouteTestURLProtocol.onRequest = { _, _ in requests += 1 }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let client = CloudRouteClient(
            baseURL: "https://cloud.test",
            userId: "user_legacy",   // non-empty: the old fallback would have dialled with this
            session: URLSession(configuration: config),
            tokenProvider: NoTokenProvider(),
        )

        let events = await client.route(request: "x", context: CloudRouteContext(episodeId: "ep", clientPositionMs: 0)).reduce(into: [CloudRouteEvent]()) { $0.append($1) }

        XCTAssertEqual(requests, 0, "no credential ⇒ nothing dialed")
        // Code only: the message is empty so the sink emits its localized earcon
        // rather than TTS reading English prose to a non-English user.
        XCTAssertEqual(events, [.error(code: "unauthorized", message: "")])
    }

    func testPrefetchSendsNoRequestWithoutACredential() async {
        CloudRouteTestURLProtocol.stubJSON(status: 202, body: #"{"status":"accepted"}"#)
        var requests = 0
        CloudRouteTestURLProtocol.onRequest = { _, _ in requests += 1 }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let client = CloudPrefetchClient(
            baseURL: "https://cloud.test",
            userId: "user_legacy",   // non-empty: the old fallback would have dialled with this
            session: URLSession(configuration: config),
            tokenProvider: NoTokenProvider()
        )

        let outcome = await client.prefetch(episodeId: "ep-1", podcastId: nil)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(requests, 0, "no credential ⇒ nothing dialed")
    }
}


/// PR #19 review: the hint must survive the caller dropping its client — the
/// playback-start hook creates one just to fire the request.
final class CloudPrefetchRetentionTests: XCTestCase {
    override func tearDown() {
        CloudRouteTestURLProtocol.reset()
        super.tearDown()
    }

    func testHintIsSentEvenWhenTheCallerDropsTheClientImmediately() async {
        CloudRouteTestURLProtocol.stubJSON(status: 202, body: #"{"status":"accepted"}"#)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudRouteTestURLProtocol.self]
        let session = URLSession(configuration: config)

        // Exactly the hook's shape: a temporary client, no other reference kept.
        CloudPrefetchClient(baseURL: "https://cloud.test", userId: "user_test", session: session)
            .schedulePrefetch(episodeId: "ep-1", podcastId: nil)

        // Poll rather than sleep once: the hint runs on a detached task, and the
        // protected counter avoids reading a captured var across threads.
        var observed = 0
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            observed = CloudRouteTestURLProtocol.requestCount
            if observed > 0 { break }
        }
        XCTAssertEqual(observed, 1, "a weakly-held client deallocates before the detached task runs, silencing the hint")
    }
}
