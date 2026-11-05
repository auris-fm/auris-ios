import XCTest

@testable import PocketCastsServer
@testable import PocketCastsUtils
@testable import podcasts

/// ACCOUNT REPLACEMENT, LIVE (reviewer 2ba0220e finding 4).
///
/// The earlier "contrast" built an unrelated `acct-2` store and re-read account 1's queue — it
/// could not have failed if account 2 could actually send account 1's recordings. This control
/// moves the LIVE session instead: one queue, one coordinator, one upload trigger whose identity
/// reader follows the current account, and a real switch from account 1 to account 2 driven by the
/// same `.userLoginDidChange` notification the app posts. The assertion is on the wire: account 2's
/// attempt must never present account 1's recording.
final class VoiceSharingAccountReplacementLiveControls: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AcctReplacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "acct-replacement-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Wire.reset()
        Wire.current = Wire()
    }

    override func tearDown() {
        Wire.current = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    // MARK: - Transport

    /// Records METHOD + path + the bearer presented, and the bytes of any upload body. Always
    /// replies, so a control cannot hang on a request that never completes.
    private final class Wire: URLProtocol {
        static let lock = NSLock()
        static var current: Wire?

        struct Request { let method: String; let path: String; let bearer: String?; let body: Data? }
        private static var requests: [Request] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                stream.close()
                body = data
            }
            let path = request.url?.path ?? "?"
            let method = request.httpMethod ?? "?"
            let bearer = request.value(forHTTPHeaderField: "Authorization")?
                .replacingOccurrences(of: "Bearer ", with: "")
            Wire.lock.lock()
            Wire.requests.append(Request(method: method, path: path, bearer: bearer, body: body))
            Wire.lock.unlock()

            if path == CloudAuthTokenProvider.tokenPath {
                reply(200, ["access_token": "tok-\(bearer ?? "none")", "refresh_token": "chain-1",
                            "expires_in": 900, "token_type": "Bearer"])
            } else if path == VoiceSharingAccountClient.projectionPath {
                reply(200, ["schema_version": 1, "membership_revision": "rev-x", "plan": "free",
                            "voice_sharing_enrolled": true, "enrollment_epoch": "epoch-1",
                            "accepted_disclosure_version": "voice-sharing-v1",
                            "withdrawal_state": "active"])
            } else {
                // Any upload route: refuse, so the attempt is refused rather than settled as
                // accepted — the control is about WHICH account may attempt, not about acceptance.
                reply(503, [:])
            }
        }

        private func reply(_ status: Int, _ object: [String: Any]) {
            guard let url = request.url else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        static func reset() { lock.lock(); requests = []; lock.unlock() }
        static func recorded() -> [Request] { lock.lock(); defer { lock.unlock() }; return requests }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Wire.self]
        return URLSession(configuration: configuration)
    }

    /// The credential is whatever ACCOUNT the live session currently names, so a request's bearer
    /// identifies the account that sent it.
    private final class LiveAccountTokens: CloudTokenProviding {
        private let account: () -> String?
        init(account: @escaping () -> String?) { self.account = account }
        func token() async -> String? { account().map { "tok-\($0)" } }
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    @discardableResult
    private func makeReadyEntry(_ queue: VoiceSharingUploadQueue) throws
        -> VoiceSharingUploadQueue.Entry {
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
        let entry = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
        try queue.finalize(entry)
        return entry
    }

    // MARK: - The control

    /// Account 1 records; the live session then becomes account 2 through the real notification.
    /// Account 2 must not be able to send account 1's recording under its own credential.
    func test_afterTheLiveSessionBecomesAccountTwoItCannotSendAccountOnesRecording() async throws {
        let previousEmail = ServerSettings.syncingEmail()
        let previousUserID = ServerSettings.userId
        defer {
            ServerSettings.setSyncingEmail(email: previousEmail)
            ServerSettings.userId = previousUserID
        }

        // Account 1 is the live session.
        var liveAccount = "acct-1"
        ServerSettings.setSyncingEmail(email: "one@auris.test")
        ServerSettings.userId = "acct-1"

        // ONE store whose scope FOLLOWS the live session — so the switch really moves it, rather
        // than the control constructing a second, unrelated store.
        let store = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { liveAccount },
            sessionIdentityProvider: { liveAccount })
        store.setLocalOptIn(true)
        XCTAssertTrue(store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: "rev-1", plan: .free, voiceSharingEnrolled: true,
                enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "voice-sharing-v1",
                withdrawalState: .active),
            readUnder: try XCTUnwrap(store.projectionToken())))

        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let entry = try makeReadyEntry(queue)
        XCTAssertEqual(queue.readyEntries(), [entry], "account 1 has one ready recording")

        let coordinator = VoiceSharingCoordinator(enrollmentStore: store, scheduledWorkObserver: .init { _ in })
        let trigger = VoiceControlAssembly().makeVoiceSharingUploadTrigger(
            queue: queue,
            isAuthorized: { store.consentAllowsCollection },
            // The identity reader follows the LIVE account, as production's does.
            currentIdentity: {
                VoiceSharingUploadIdentity(accountScope: liveAccount, enrollmentEpoch: "epoch-1")
            },
            baseURLProvider: { "https://unit.test" },
            tokenProvider: LiveAccountTokens(account: { liveAccount }),
            session: makeSession())

        let center = RecordingNotificationCenter()
        let uninstall = coordinator.installIdentityInvalidation(
            onNotificationCenter: center,
            startupAuthReadable: { true },
            scheduledRefreshClient: VoiceSharingAccountClient(
                baseURLProvider: { "https://unit.test" },
                tokenProvider: LiveAccountTokens(account: { liveAccount }),
                session: makeSession(), sessionIdentity: { liveAccount }, membershipStore: store),
            loginStateReadable: { liveAccount != "" })
        defer { uninstall() }
        await coordinator.settleObservedWork()

        // THE SWITCH: the live session becomes account 2, and the app posts the real notification.
        Wire.reset()
        liveAccount = "acct-2"
        ServerSettings.userId = "acct-2"
        ServerSettings.setSyncingEmail(email: "two@auris.test")
        XCTAssertGreaterThan(center.post(name: .userLoginDidChange), 0,
                             "the coordinator registered for the identity notification")
        await coordinator.settleObservedWork()

        // ---------------------------------------------------------------------------------
        // POSITIVE CONTROL FIRST (reviewer fa9db8e9): the SAME observation must be able to SEE an
        // owning-account send. Without this, "no upload route observed" proves nothing — a filter
        // matching the wrong path would pass the negative assertion too.
        // ---------------------------------------------------------------------------------
        // Back to account 1, which owns the recording and still holds its own consent.
        liveAccount = "acct-1"
        ServerSettings.userId = "acct-1"
        ServerSettings.setSyncingEmail(email: "one@auris.test")
        XCTAssertTrue(center.post(name: .userLoginDidChange) > 0)
        await coordinator.settleObservedWork()

        Wire.reset()
        trigger.triggerDrainIfPermitted()
        var spins = 0
        while Wire.recorded().isEmpty && spins < 200_000 { await Task.yield(); spins += 1 }
        for _ in 0..<200_000 { await Task.yield() }
        let owningSend = Wire.recorded().filter { $0.path == VoiceSharingUploadTransport.uploadPath }
        XCTAssertEqual(owningSend.count, 1,
                       "the owning account's recording DOES reach the upload route — the observation works")
        XCTAssertEqual(owningSend.first?.bearer, "tok-acct-1",
                       "sent under the owning account's own credential")

        // ---------------------------------------------------------------------------------
        // THE NEGATIVE, now that the same observation is proven able to fail.
        // ---------------------------------------------------------------------------------
        liveAccount = "acct-2"
        ServerSettings.userId = "acct-2"
        ServerSettings.setSyncingEmail(email: "two@auris.test")
        XCTAssertTrue(center.post(name: .userLoginDidChange) > 0)
        await coordinator.settleObservedWork()

        Wire.reset()
        trigger.triggerDrainIfPermitted()
        var spins2 = 0
        while Wire.recorded().isEmpty && spins2 < 200_000 { await Task.yield(); spins2 += 1 }
        for _ in 0..<200_000 { await Task.yield() }

        let afterSwitch = Wire.recorded()
        // 1. Account 2's session never presents account 1's credential, for anything.
        XCTAssertFalse(afterSwitch.contains { $0.bearer == "tok-acct-1" },
                       "account 2's session must never present account 1's credential: \(afterSwitch.map { "\($0.method) \($0.path) \($0.bearer ?? "-")" })")
        // 2. Account 1's recording never reaches the REAL upload route under account 2.
        let uploads = afterSwitch.filter { $0.path == VoiceSharingUploadTransport.uploadPath }
        XCTAssertTrue(uploads.isEmpty,
                      "account 2 must not attempt account 1's recording: \(uploads.map { "\($0.method) \($0.path) \($0.bearer ?? "-")" })")
        // 3. The queue's own binding refuses the attempt before any request is built.
        XCTAssertEqual(queue.readyEntries().count, 1,
                       "the recording is retained, not moved or destroyed by the switch")

        // Account 2 has no collection permission of its own just because account 1 had one.
        XCTAssertFalse(store.consentAllowsCollection,
                       "account 2 does not inherit account 1's collection permission")
        let accountTwoState = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-2" },
            sessionIdentityProvider: { "acct-2" })
        XCTAssertFalse(accountTwoState.currentState.localOptIn,
                       "account 2 does not inherit account 1's recorded choice")
        // And switching BACK restores account 1's own state — the choice was never destroyed.
        let accountOneState = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-1" },
            sessionIdentityProvider: { "acct-1" })
        XCTAssertTrue(accountOneState.currentState.localOptIn,
                      "account 1's choice survives the replacement round-trip")
    }
}
