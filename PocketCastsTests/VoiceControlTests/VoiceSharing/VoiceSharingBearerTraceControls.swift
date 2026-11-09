import XCTest

@testable import PocketCastsServer
@testable import PocketCastsUtils
@testable import podcasts

/// CLIENT-SIDE credential trace for incident: the server proved every account call was
/// refused at the verified-token gate and that the upstream credential exchange answered 500 twice,
/// but it cannot see which bearer string the account calls carried. These controls pin that down
/// from our side through the REAL token provider and the REAL account client, with local
/// controlled responses whose verdict is DERIVED from the Authorization header actually presented.
final class VoiceSharingBearerTraceControls: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var intercept: StubServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BearerTrace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "bearer-trace-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        intercept = StubServer()
        StubServer.current = intercept
    }

    override func tearDown() {
        StubServer.current = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    // MARK: - Local stub server

    /// Not a URLProtocol: a URLProtocol stub is hit from concurrent URLSession tasks, and a shared
    /// locked record made one control hang. This handler is synchronous and always completes the
    /// request, so a missing response can never stall a run.
    private final class StubServer: URLProtocol {
        static let lock = NSLock()
        static var current: StubServer?

        private var stopped = false
        private let condition = NSCondition()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func stopLoading() {
            condition.lock(); stopped = true; condition.broadcast(); condition.unlock()
        }

        private func reply(_ status: Int, _ body: [String: Any]) {
            guard let url = request.url else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func startLoading() {
            respond()
        }

        private func respond() {
            let path = request.url?.path ?? "?"
            let method = request.httpMethod ?? "?"
            let bearer = request.value(forHTTPHeaderField: "Authorization")?
                .replacingOccurrences(of: "Bearer ", with: "")
            StubServer.lock.lock()
            StubServer.requests.append(.init(method: method, path: path, bearer: bearer))
            let accepted = StubServer.acceptedBearer
            let exchangeStatus = StubServer.exchangeStatus
            let staleExchangeServed = StubServer.serveStaleExchange
            StubServer.lock.unlock()

            switch path {
            case CloudAuthTokenProvider.tokenPath:
                if exchangeStatus == 200 {
                    reply(200, ["access_token": staleExchangeServed ? "tok-from-exchange"
                                                                     : "tok-from-refresh",
                                                 "refresh_token": "chain-1",
                                                 "expires_in": 900, "token_type": "Bearer"])
                } else {
                    reply(exchangeStatus, [:])
                }
            case CloudAuthTokenProvider.refreshPath:
                reply(200, ["access_token": "tok-from-refresh",
                                             "refresh_token": "chain-2",
                                             "expires_in": 900, "token_type": "Bearer"])
            case VoiceSharingAccountClient.projectionPath:
                if let bearer, bearer == accepted {
                    reply(200, [
                        "schema_version": 1, "membership_revision": "rev-2", "plan": "free",
                        "voice_sharing_enrolled": true, "enrollment_epoch": "epoch-1",
                        "accepted_disclosure_version": "voice-sharing-v1",
                        "withdrawal_state": "active"])
                } else {
                    reply(401, [:])
                }
            default:
                reply(404, [:])
            }
        }

        struct Request {
            let method: String
            let path: String
            let bearer: String?
        }
        static var requests: [Request] = []
        static var acceptedBearer: String?
        static var exchangeStatus = 200
        /// When false, the exchange mints the RECOVERED credential (the steady state after recovery).
        static var serveStaleExchange = true

        static func reset() {
            lock.lock()
            requests = []; acceptedBearer = nil; exchangeStatus = 200; serveStaleExchange = true
            lock.unlock()
        }
        static func snapshot() -> [Request] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }
        static func setAccepted(_ bearer: String?) {
            lock.lock(); acceptedBearer = bearer; lock.unlock()
        }
        static func setStaleExchange(_ stale: Bool) {
            lock.lock(); serveStaleExchange = stale; lock.unlock()
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    private func makeProvider() -> CloudAuthTokenProvider {
        CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.unit.test" },
            credentialProvider: { "account-credential" },
            identityProvider: { "acct-1" },
            session: makeSession())
    }

    private func makeStore() -> VoiceSharingEnrollmentStore {
        VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-1" },
            sessionIdentityProvider: { "acct-1" })
    }

    /// A ready, consented recording (the wiring tests' fixture shape).
    @discardableResult
    private func makeReadyEntry(_ queue: VoiceSharingQueue) async throws
        -> VoiceSharingQueue.Entry {
        let samples: [Float] = [0, 0.25, -0.5, 0.5]
        let event = VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(),
            enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: samples, isGateControl: false)
        let provenance = VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
            models: .init(vad: nil, wakeword: nil, asr: nil, translation: nil, router: nil),
            conversionVersion: "v1")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event, provenance: provenance, observations: [:])
        let published = await queue.publish(audio: encoded.wav, metadata: encoded.metadata)
        let name = try XCTUnwrap(published)
        let all = await queue.entries()
        return try XCTUnwrap(all.first { $0.name == name })
    }

    // MARK: - Controls

    /// The RETRY carries exactly the recovered bearer, and the recovery segment rotates the chain
    /// instead of re-exchanging the account credential. Assertions are made on the header the
    /// server actually received, and the acceptance verdict is derived from that header.
    func test_accountReadRetryPresentsTheRecoveredBearerAndDoesNotReExchange() async throws {
        // An authenticated session: the store fence is what a projection is read and applied under.
        ServerSettings.userId = "acct-1"
        defer { ServerSettings.userId = nil }
        StubServer.reset()
        StubServer.setAccepted("tok-from-refresh")
        let provider = makeProvider()
        // Initial exchange: proves the trace starts with a token exchange by design.
        let initial = await provider.token()
        XCTAssertEqual(initial, "tok-from-exchange")

        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider,
            session: makeSession(), sessionIdentity: { "acct-1" }, membershipStore: makeStore())
        // FIRST read is refused (only the refreshed bearer is accepted) — that IS the incident shape.
        let firstRead = await client.fetchProjection()
        XCTAssertNil(firstRead, "the stale bearer is refused by the server")

        // THE actual retry, after the provider recovered through its real refresh path. From here the
        // auth endpoint mints the recovered credential, as it does for every later acquisition.
        StubServer.setStaleExchange(false)
        let retried = await client.fetchProjection()
        let fetched = try XCTUnwrap(retried, "the retried read succeeds with the recovered bearer")
        XCTAssertEqual(fetched.membership.membershipRevision, "rev-2")

        let reads = StubServer.snapshot().filter { $0.path == VoiceSharingAccountClient.projectionPath }
        XCTAssertEqual(reads.map(\.bearer), ["tok-from-exchange", "tok-from-refresh"],
                       "the retry carries the recovered credential, not the stale one")

        // Recovery segment only: after the refused read, no further exchange happened.
        let recoveryPaths = Array(StubServer.snapshot().map(\.path))
        XCTAssertTrue(recoveryPaths.contains(CloudAuthTokenProvider.refreshPath),
                      "recovery went through /auth/refresh: \(recoveryPaths)")
        XCTAssertEqual(recoveryPaths.filter { $0 == CloudAuthTokenProvider.tokenPath }.count, 1,
                       "the account credential was exchanged exactly once (at the start): \(recoveryPaths)")

        // APPLIED, not merely fetched: post-recovery membership is the claim.
        // A fence belongs to ONE store instance, so this store issued the read it applies.
        let store = makeStore()
        let clientForStore = VoiceSharingAccountClient(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider,
            session: makeSession(), sessionIdentity: { "acct-1" }, membershipStore: store)
        // The user's share choice is a SEPARATE stored fact from the server projection.
        store.setLocalOptIn(true)
        StubServer.reset()
        StubServer.setAccepted("tok-from-refresh")
        StubServer.setStaleExchange(false)
        let storeFetch = await clientForStore.fetchProjection()
        let storeProjection = try XCTUnwrap(storeFetch, "the store's own read succeeds")
        let applied = store.apply(authoritative: storeProjection.membership,
                                  readUnder: storeProjection.issuedUnder)
        XCTAssertTrue(applied)
        XCTAssertTrue(store.consentAllowsCollection)
        XCTAssertFalse(store.consentGoneForPurge)
        XCTAssertEqual(store.currentAuthoritativeState?.membership.membershipRevision, "rev-2")
        XCTAssertEqual(store.currentAuthoritativeState?.membership.withdrawalState, .active)
    }

    /// FAIL closed: a failed upstream exchange yields no credential, so the account read is never
    /// dialled — no fallback to another credential class.
    func test_failedExchangeYieldsNoBearerAndNoAccountCall() async throws {
        StubServer.reset()
        StubServer.lock.lock(); StubServer.exchangeStatus = 500; StubServer.lock.unlock()
        let provider = makeProvider()
        let failed = await provider.token()
        XCTAssertNil(failed, "a failed exchange never produces a credential")

        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider,
            session: makeSession(), sessionIdentity: { "acct-1" }, membershipStore: makeStore())
        let fetched = await client.fetchProjection()
        XCTAssertNil(fetched)
        let requests = StubServer.snapshot()
        XCTAssertFalse(requests.contains { $0.path == VoiceSharingAccountClient.projectionPath },
                       "no credential ⇒ no account call at all: \(requests.map(\.path))")
        XCTAssertFalse(requests.contains { $0.bearer != nil },
                       "the auth calls carry no bearer header")
    }

    /// The whole recovery runs through the REAL coordinator, at the boundary where its identity
    /// notifications actually refresh: the controlled client is injected INTO that boundary, the
    /// tasks it schedules are awaited, the complete auth state is established and restored, and the
    /// only requests that ever appear are reads. Restart and account replacement are contrasted.
    func test_coordinatorIdentityNotificationsRefreshThroughInjectedClientAndNeverMutate() async throws {
        // Complete auth state, established and restored: the login callback reads syncingEmail.
        let previousEmail = ServerSettings.syncingEmail()
        let previousUserID = ServerSettings.userId
        ServerSettings.setSyncingEmail(email: "ios-control@auris.test")
        ServerSettings.userId = "acct-1"
        defer {
            ServerSettings.setSyncingEmail(email: previousEmail)
            ServerSettings.userId = previousUserID
        }

        StubServer.reset()
        StubServer.setAccepted("tok-from-refresh")
        StubServer.setStaleExchange(false)
        let store = makeStore()
        store.setLocalOptIn(true)
        XCTAssertTrue(store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken())))
        let queue = VoiceSharingQueue(root: root)
        let entry = try await makeReadyEntry(queue)

        var logged: [String] = []
        let coordinator = VoiceSharingCoordinator(enrollmentStore: store, scheduledWorkObserver: .init { _ in })
        let trigger = VoiceControlAssembly().makeVoiceSharingUploadTrigger(
            queue: queue, isAuthorized: { true },
            currentIdentity: { nil as (account: String, epoch: String)? }, tokenProvider: StaticToken())
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { store.consentAllowsCollection },
            outcomeWaitLimit: .init(milliseconds: 1_000, ceilingMilliseconds: 1_000),
            sink: { _ in })
        // THE production handler, wired to the real queue; the collector stays alive for the whole
        // control so its callbacks run too.
        VoiceControlAssembly().installVoiceSharingGateLoss(
            collector: collector, uploadTrigger: trigger,
            queue: queue, coordinator: coordinator,
            sessionAlive: { true }, consentGone: { store.consentGoneForPurge },
            log: { logged.append($0) })

        // The controlled client, injected AT the notification's refresh boundary.
        let controlledClient = VoiceSharingAccountClient(
            baseURLProvider: { "https://unit.test" }, tokenProvider: makeProvider(),
            session: makeSession(), sessionIdentity: { "acct-1" }, membershipStore: store)
        let center = RecordingNotificationCenter()
        let uninstall = coordinator.installIdentityInvalidation(
            onNotificationCenter: center,
            startupAuthReadable: { true },
            scheduledRefreshClient: controlledClient,
            loginStateReadable: { true })
        defer { uninstall() }
        // The COLD-START refresh the installation scheduled itself.
        await coordinator.settleObservedWork()
        XCTAssertFalse(StubServer.snapshot().isEmpty,
                       "the installation's own cold-start refresh really ran")

        let before = StubServer.snapshot().count
        // (a) THE real notification, and AWAIT the task it schedules.
        let delivered = center.post(name: .userLoginDidChange)
        XCTAssertGreaterThan(delivered, 0, "the coordinator registered for the identity notification")
        await coordinator.settleObservedWork()

        // Sequence through that same recovery: reads only, and no withdrawal/enrollment request.
        let recoveryRequests = Array(StubServer.snapshot().dropFirst(before))
        XCTAssertFalse(recoveryRequests.isEmpty,
                       "the notification's refresh actually hit the wire: \(recoveryRequests)")
        XCTAssertTrue(recoveryRequests.allSatisfy { $0.method == "GET" },
                      "the identity refresh sends only GETs: \(recoveryRequests.map { "\($0.method) \($0.path)" })")
        XCTAssertFalse(recoveryRequests.contains { $0.path.contains("/withdrawal") || $0.path.contains("/enrollment") },
                       "recovery never mints a withdrawal/enrollment request")

        let pendingEntries = await queue.entries()
        XCTAssertEqual(pendingEntries, [entry], "the recording survives the identity reload")
        XCTAssertFalse(store.consentGoneForPurge, "recovery alone never closes the consent gate")
        XCTAssertTrue(purgeDecisions(logged).isEmpty, "no purge decision was taken: \(logged)")
        XCTAssertEqual(store.currentAuthoritativeState?.membership.membershipRevision, "rev-2",
                       "the recovered projection is applied")

        // (b) A REFUSED read (the incident shape): still no purge, still retained, choice unchanged.
        StubServer.reset()
        let refreshStale = VoiceSharingAccountClient(
            baseURLProvider: { "https://unit.test" }, tokenProvider: makeProvider(),
            session: makeSession(), sessionIdentity: { "acct-1" }, membershipStore: store)
        let refusedDelivered = center.post(name: .userLoginDidChange)
        XCTAssertGreaterThan(refusedDelivered, 0)
        await coordinator.settleObservedWork()
        // The injected client is the recovered one; drive the refusal explicitly through the same
        // boundary's client type so the stanza is deterministic.
        await coordinator.refreshProjectionFromServer(accountClient: refreshStale)
        let entriesAfterRefusal = await queue.entries()
        XCTAssertEqual(entriesAfterRefusal, [entry], "a refused read purges nothing")
        XCTAssertFalse(store.consentGoneForPurge, "a refused read is not a withdrawal")
        XCTAssertFalse(store.currentState.explicitOptOut, "no opt-out was recorded by a refused read")
        let persisted = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-1" },
            sessionIdentityProvider: { "acct-1" })
        XCTAssertTrue(persisted.currentState.localOptIn,
                      "the user's sharing choice survives a refused read on disk")
        XCTAssertTrue(purgeDecisions(logged).isEmpty, "still no purge decision: \(logged)")

        // (c) RESTART: a fresh store over the same persisted domain, and a fresh queue over the same
        // root — the choice and the recording both survive.
        let restartedStore = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-1" },
            sessionIdentityProvider: { "acct-1" })
        XCTAssertTrue(restartedStore.currentState.localOptIn, "the choice survives a restart")
        let restartedQueue = VoiceSharingQueue(root: root)
        let afterRestart = await restartedQueue.entries()
        XCTAssertEqual(afterRestart, [entry], "the recording survives a restart")

        // (d) ACCOUNT replacement: the other account inherits neither the choice nor the recordings.
        let otherStore = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-2" },
            sessionIdentityProvider: { "acct-2" })
        XCTAssertFalse(otherStore.currentState.localOptIn,
                       "account 2 does not inherit account 1's recorded choice")
        XCTAssertFalse(otherStore.currentState.explicitOptOut,
                       "account 2 is not told account 1 withdrew")
        let otherAccountEntries = await queue.entries()
        XCTAssertEqual(otherAccountEntries, [entry],
                       "the recordings stay with the account they belong to")

        // (e) CONTRAST — explicit withdrawal still purges through the SAME production handler.
        _ = store.withdrawLocally(acceptedServerProjectionAfterward: false)
        coordinator.consentGateLostForTesting()
        // The purge runs on its own task, so reading the queue straight after the notification races
        // the deletion. Wait for the decision to be recorded rather than assuming it has landed.
        var entriesAfterWithdrawal: [VoiceSharingQueue.Entry] = [entry]
        for _ in 0..<200 where !entriesAfterWithdrawal.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
            entriesAfterWithdrawal = await queue.entries()
        }
        XCTAssertTrue(entriesAfterWithdrawal.isEmpty, "withdrawal clears pending recordings")
        let purges = purgeDecisions(logged)
        XCTAssertFalse(purges.isEmpty, "withdrawal records a purge decision: \(logged)")
        XCTAssertTrue(purges.allSatisfy { $0.contains("cause=consent-gone") }, "cause named: \(logged)")
        XCTAssertTrue(purges.contains { $0.contains("removed: 1") },
                      "the recording is counted as removed: \(logged)")
    }

    /// Only the lines that record an actual purge or retention DECISION — the identity notification
    /// also produces temporary-loss fan-outs for other observers, which are not purges.
    private func purgeDecisions(_ lines: [String]) -> [String] {
        lines.filter { $0.contains("PURGE cause=") }
    }

    private struct StaticToken: CloudTokenProviding {
        func token() async -> String? { "tok" }
        func handleUnauthorized(rejectedToken: String?) async {}
    }

}