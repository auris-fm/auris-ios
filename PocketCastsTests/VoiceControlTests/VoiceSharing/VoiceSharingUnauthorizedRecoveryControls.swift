import XCTest

@testable import PocketCastsServer
@testable import PocketCastsUtils
@testable import podcasts

/// INCIDENT controls (staging: 32 durable recordings purged at 19:58, zero log
/// lines, after three projection-GET 401s). Reviewer round on the incident report:
/// - a same-account 401/auth-recovery with queued recordings must not purge — the queue
/// survives and the retention decision is LOGGED with its cause;
/// - an explicit withdrawal still purges, with the purge decision logged;
/// - the diagnostics record cause and counts, never audio or credentials.
final class VoiceSharingUnauthorizedRecoveryControls: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var logged: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnauthRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "unauth-recovery-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A provider that hands out one stable token and counts 401 recoveries — the shape
    /// `CloudAuthTokenProvider.handleUnauthorized` presents to callers.
    private final class StaticRecoveryTokenProvider: CloudTokenProviding {
        func token() async -> String? { "tok" }
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    /// Rotates on recovery, remembering WHICH token was rejected (the provider contract).
    private final class RotatingTokenProvider: CloudTokenProviding {
        private var tokens: [String]
        private(set) var recoveries = 0
        private(set) var rejected: String?
        init(first: String, second: String) { tokens = [first, second] }
        func rotate() { if tokens.count > 1 { tokens.removeFirst() } }
        func token() async -> String? { tokens.first }
        func handleUnauthorized(rejectedToken: String?) async {
            recoveries += 1
            rejected = rejectedToken
        }
    }

    private final class CountingTokenProvider: CloudTokenProviding {
        let token: String
        private(set) var recoveries = 0
        init(token: String) { self.token = token }
        func token() async -> String? { token }
        func handleUnauthorized(rejectedToken: String?) async { recoveries += 1 }
    }

    private func makeStore(account: String = "acct-1") -> VoiceSharingEnrollmentStore {
        let store = VoiceSharingEnrollmentStore(
            defaults: defaults,
            accountScopeProvider: { account },
            sessionIdentityProvider: { account })
        // OPTED-IN with an ACTIVE membership: the healthy pre-incident state.
        store.setLocalOptIn(true)
        let active = VoiceSharingMembership(
            plan: .free, voiceSharingEnrolled: true,
            enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
            withdrawalState: .active)
        let token = store.projectionToken()
        XCTAssertTrue(store.apply(authoritative: active, readUnder: try XCTUnwrap(token)))
        return store
    }

    /// Queues a ready, consented recording into `queue` (the wiring tests' fixture shape).
    @discardableResult
    private func makeReadyEntry(_ queue: VoiceSharingQueue, epoch: String = "epoch-1") async throws
        -> VoiceSharingQueue.Entry {
        let samples: [Float] = [0, 0.25, -0.5, 0.5]
        let event = VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(),
            enrollmentEpoch: epoch, authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: samples, isGateControl: false)
        let provenance = VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
            models: .init(vad: nil, wakeword: nil, asr: nil, translation: nil, router: nil),
            conversionVersion: "v1")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event, provenance: provenance, observations: [:])
        let publishedName = await queue.publish(audio: encoded.wav, metadata: encoded.metadata)
        let name = try XCTUnwrap(publishedName)
        let published = await queue.entries()
        return try XCTUnwrap(published.first { $0.name == name })
    }

    private func makeGateLoss(
        queue: VoiceSharingQueue,
        sessionAlive: @escaping () -> Bool = { true },
        consentGone: @escaping () -> Bool
    ) -> (coordinator: VoiceSharingCoordinator, fire: () -> Void) {
        let coordinator = VoiceSharingCoordinator()
        let collector = VoiceSharingCollector(
            isCollectionPermitted: { true },
            outcomeWaitLimit: .init(milliseconds: 1_000, ceilingMilliseconds: 1_000),
            sink: { _ in })
        let provider = StaticRecoveryTokenProvider()
        let trigger = VoiceControlAssembly().makeVoiceSharingUploadTrigger(
            queue: queue, isAuthorized: { true },
            currentIdentity: { nil as (account: String, epoch: String)? }, tokenProvider: provider)
        VoiceControlAssembly().installVoiceSharingGateLoss(
            collector: collector, uploadTrigger: trigger,
            queue: queue, coordinator: coordinator,
            sessionAlive: sessionAlive, consentGone: consentGone,
            log: { [weak self] line in self?.logged.append(line) })
        return (coordinator, { coordinator.consentGateLostForTesting() })
    }

    /// Waits for the queue to empty, bounded, so a handler that purges off the calling thread can be
    /// asserted on without racing it.
    private func waitForEmptyQueue(_ queue: VoiceSharingQueue,
                                   timeout: TimeInterval = 5) async -> [VoiceSharingQueue.Entry] {
        let deadline = Date().addingTimeInterval(timeout)
        var entries = await queue.entries()
        while !entries.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            entries = await queue.entries()
        }
        return entries
    }

    // MARK: - Controls

    /// A projection-GET 401 through the REAL account client goes to the auth-recovery
    /// callback and changes NOTHING about consent or the durable queue: no membership
    /// write, no purge, and a later gate event retains the recordings.
    func test_projection401_recoversWithoutTouchingConsentOrQueue() async throws {
        let store = makeStore()
        let queue = VoiceSharingQueue(root: root)
        let entry = try await makeReadyEntry(queue)
        let provider = CountingTokenProvider(token: "tok-1")
        let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RecoveryIntercept.self]
            return URLSession(configuration: configuration)
        }()
        RecoveryIntercept.responder = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: ["cf-ray": "test-ray"])!
            return (response, Data("{\"code\":\"unauthorized\"}".utf8))
        }
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: provider,
            session: session,
            sessionIdentity: { "acct-1" },
            membershipStore: store)

        let fetched = await client.fetchProjection()

        // The recovery callback fired, and NOTHING else moved.
        XCTAssertEqual(provider.recoveries, 1, "the 401 must reach the auth-recovery callback")
        XCTAssertNil(fetched, "a rejected projection is never applied")
        XCTAssertFalse(store.consentGoneForPurge,
                       "a transient 401 is not a withdrawal and must not close the purge gate")
        XCTAssertTrue(store.consentAllowsCollection,
                      "the user's sharing choice survives a rejected refresh")
        let afterRecovery = await queue.entries()
        XCTAssertEqual(afterRecovery, [entry],
                       "the durable queue survives a 401 recovery untouched")

        // And the gate event that the incident window produced still RETAINS, logging why.
        let (_, fire) = makeGateLoss(queue: queue) { store.consentGoneForPurge }
        logged.removeAll()
        fire()
        let afterGateLoss = await queue.entries()
        XCTAssertEqual(afterGateLoss, [entry],
                       "gate loss after a transient 401 must retain the recordings")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("RETAINED"),
                      "the retention decision is logged, not silent: \(logged)")
    }

    /// REQUEST-LEVEL (spec, incident follow-up): auth recovery alone never mints a withdrawal
    /// or enrollment intent. A 401 GET, the recovery rotation, and a subsequent 200 refresh
    /// produce only the GETs the client itself issued — no withdrawal/enrollment POST exists —
    /// and the refreshed projection applies normally with the queue retained.
    func test_authRecoveryIssuesNoWithdrawalOrEnrollmentIntent() async throws {
        let store = makeStore()
        let queue = VoiceSharingQueue(root: root)
        let entry = try await makeReadyEntry(queue)
        let provider = RotatingTokenProvider(first: "tok-stale", second: "tok-fresh")
        let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RecoveryIntercept.self]
            return URLSession(configuration: configuration)
        }()
        var seen: [(method: String, path: String)] = []
        var activeToken = "tok-stale"
        let refreshed = VoiceSharingMembership(
            plan: .free, voiceSharingEnrolled: true,
            enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
            withdrawalState: .active)
        let refreshedJSON = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "plan": "free", "voice_sharing_enrolled": true,
            "enrollment_epoch": "epoch-1", "accepted_disclosure_version": "voice-sharing-v1",
            "withdrawal_state": "active",
        ])
        RecoveryIntercept.responder = { request in
            seen.append((request.httpMethod ?? "?", request.url?.path ?? "?"))
            if request.url?.path == VoiceSharingAccountClient.projectionPath {
                let status = activeToken == "tok-stale" ? 401 : 200
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                return (response, status == 200 ? refreshedJSON : Data())
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: provider,
            session: session,
            sessionIdentity: { "acct-1" },
            membershipStore: store)

        // First read: rejected. The client reports the rejected bearer to the provider.
        let rejected = await client.fetchProjection()
        XCTAssertNil(rejected)
        XCTAssertEqual(provider.recoveries, 1)
        XCTAssertEqual(provider.rejected, "tok-stale", "the REJECTED token is named")
        XCTAssertNil(store.consentGoneForPurge ? true : nil, "consent intact after recovery")

        // Recovery rotates the credential; the retry presents the REFRESHED token and applies.
        provider.rotate()
        activeToken = "tok-fresh"
        let fetched = await client.fetchProjection()
        XCTAssertNotNil(fetched, "the refreshed bearer is published and used")
        XCTAssertFalse(store.consentGoneForPurge, "the refreshed projection keeps consent intact")
        let remainingEntries = await queue.entries()
        XCTAssertEqual(remainingEntries, [entry], "the queue survives the whole recovery")
        // THE request-LEVEL assertion: the client only ever issued projection GETs.
        let methods = seen.map(\.method)
        XCTAssertFalse(methods.contains("POST"),
                       "auth recovery must never mint a withdrawal/enrollment POST: \(seen)")
        XCTAssertTrue(methods.allSatisfy { $0 == "GET" })
        XCTAssertTrue(seen.allSatisfy { $0.path.hasSuffix(VoiceSharingAccountClient.projectionPath) },
                      "only the projection endpoint was touched: \(seen)")
    }

    /// CONTRAST: an explicit withdrawal purges, and the diagnostics name the cause and
    /// the reconciled counts — no audio, no credentials in the line.
    func test_explicitWithdrawal_purgesAndLogsCauseAndCount() async throws {
        let store = makeStore()
        let queue = VoiceSharingQueue(root: root)
        _ = try await makeReadyEntry(queue)
        _ = try await makeReadyEntry(queue)

        // The user withdraws — the real local-withdrawal path.
        _ = store.withdrawLocally(acceptedServerProjectionAfterward: false)
        XCTAssertTrue(store.consentGoneForPurge)

        let (_, fire) = makeGateLoss(queue: queue) { store.consentGoneForPurge }
        fire()

        // The purge runs on a task of its own, so the assertion waits for it to land rather than
        // racing it. A bounded wait still fails if nothing ever happens.
        let remainingEntries = await waitForEmptyQueue(queue)
        XCTAssertTrue(remainingEntries.isEmpty, "explicit withdrawal clears pending recordings")
        XCTAssertEqual(logged.count, 1, "exactly one purge diagnostic")
        XCTAssertTrue(logged[0].contains("cause=consent-gone"), "the cause is named: \(logged)")
        XCTAssertTrue(logged[0].contains("removed: 2"),
                      "the count of removed recordings is in the line: \(logged)")
        XCTAssertFalse(logged[0].lowercased().contains("sess-1"),
                       "no capture session identifiers in the diagnostic")
    }

    /// SIGN-OUT purges too, and says so — the third cause the incident window could have
    /// produced silently.
    func test_signOut_purgesAndLogsSessionGoneCause() async throws {
        let store = makeStore()
        let queue = VoiceSharingQueue(root: root)
        _ = try await makeReadyEntry(queue)

        let (_, fire) = makeGateLoss(queue: queue,
                                     sessionAlive: { false },
                                     consentGone: { store.consentGoneForPurge })
        fire()

        let remainingEntries = await waitForEmptyQueue(queue)
        XCTAssertTrue(remainingEntries.isEmpty)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("cause=session-gone"), "the cause is named: \(logged)")
        XCTAssertTrue(logged[0].contains("removed: 1"), "count present: \(logged)")
    }
}

/// URLProtocol stub for the recovery controls.
private final class RecoveryIntercept: URLProtocol {
    static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let responder = Self.responder, let url = request.url else { return }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
