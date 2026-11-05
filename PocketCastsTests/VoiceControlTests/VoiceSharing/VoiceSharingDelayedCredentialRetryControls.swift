import XCTest

@testable import PocketCastsServer
@testable import PocketCastsUtils
@testable import podcasts

/// DELAYED-CREDENTIAL / UNKNOWN-OUTCOME RETRY CONTROLS (reviewer 2ba0220e + 4546a238).
///
/// The retry paths were the defect surface: a resume awaited a credential, then decided what to do
/// with an operation whose outcome was unknown. These controls hold the credential open so a
/// replacement lands *inside* that await, and assert that a stale retry neither clears nor sends
/// newer work, and that a temporary unavailability keeps the operation and its request identity for
/// an identical retry.
final class VoiceSharingDelayedCredentialRetryControls: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "delayed-credential-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A credential source a control holds open: `token()` blocks until released, which is the
    /// window where an account replacement can land.
    private final class GatedTokens: CloudTokenProviding {
        private let gate = NSCondition()
        private var open = false
        private var value: String?
        private var started = false
        func release(_ token: String?) {
            gate.lock(); value = token; open = true; gate.broadcast(); gate.unlock()
        }
        func hasStarted() -> Bool { gate.lock(); defer { gate.unlock() }; return started }
        func token() async -> String? {
            gate.lock(); started = true; gate.broadcast()
            while !open { gate.wait() }
            let v = value; gate.unlock()
            return v
        }
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    /// A credential source that answers immediately.
    private final class OpenTokens: CloudTokenProviding {
        func token() async -> String? { "tok" }
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    /// Records every request and answers projection reads with a valid body; mutations answer with
    /// a caller-chosen status so an UNKNOWN outcome can be produced deliberately.
    private final class Wire: URLProtocol {
        static let lock = NSLock()
        static var current: Wire?
        struct Request { let method: String; let path: String; let body: Data? }
        private static var requests: [Request] = []
        nonisolated(unsafe) static var mutationStatus = 503
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                stream.close(); body = data
            }
            let path = request.url?.path ?? "?"
            let method = request.httpMethod ?? "?"
            Wire.lock.lock()
            Wire.requests.append(Request(method: method, path: path, body: body))
            let status = (path == CloudAuthTokenProvider.tokenPath || path == VoiceSharingAccountClient.projectionPath)
                ? 200 : Wire.mutationStatus
            Wire.lock.unlock()
            let object: [String: Any] = path == CloudAuthTokenProvider.tokenPath
                ? ["access_token": "tok", "refresh_token": "c1", "expires_in": 900, "token_type": "Bearer"]
                : (path == VoiceSharingAccountClient.projectionPath
                    ? ["schema_version": 1, "membership_revision": "rev-1", "plan": "free",
                       "voice_sharing_enrolled": true, "enrollment_epoch": "epoch-1",
                       "accepted_disclosure_version": "voice-sharing-v1", "withdrawal_state": "active"]
                    : [:])
            guard let url = request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        static func reset() { lock.lock(); requests = []; mutationStatus = 503; lock.unlock() }
        static func recorded() -> [Request] { lock.lock(); defer { lock.unlock() }; return requests }
        static func mutationCount() -> Int { recorded().filter { $0.method != "GET" && $0.path != CloudAuthTokenProvider.tokenPath }.count }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Wire.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    private func makeModel(tokens: CloudTokenProviding) -> (VoiceSharingAccountModel, VoiceSharingEnrollmentStore) {
        let store = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-1" },
            sessionIdentityProvider: { "acct-1" })
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://unit.test" }, tokenProvider: tokens,
            session: makeSession(), sessionIdentity: { "acct-1" }, membershipStore: store)
        let model = VoiceSharingAccountModel(
            store: store, client: client,
            disclosureVersion: VoiceSharingDisclosure.productionVersion,
            session: { "acct-1" })
        return (model, store)
    }

    // MARK: - Controls

    /// A deletion whose outcome is UNKNOWN keeps its operation and its request ID, and an identical
    /// retry re-sends the SAME ID — not a new one.
    @MainActor
    func test_unknownDeletionOutcomeKeepsItsRequestIDForAnIdenticalRetry() async throws {
        ServerSettings.userId = "acct-1"
        defer { ServerSettings.userId = nil }
        Wire.reset()
        // No gate here: this control is about identity preservation across retries, so the
        // credential is simply available.
        let (model, _) = makeModel(tokens: OpenTokens())

        model.beginDeletionForTesting()
        Wire.mutationStatus = 503   // unknown outcome
        await model.retryDeletion()

        let firstID = model.pendingDeletionRequestIDForTesting
        XCTAssertNotNil(firstID, "an unknown outcome keeps the operation for an identical retry")

        Wire.reset(); Wire.mutationStatus = 503
        await model.retryDeletion()
        let secondID = model.pendingDeletionRequestIDForTesting
        XCTAssertEqual(secondID, firstID, "the identical retry re-sends the SAME request ID")
        let bodies = Wire.recorded().filter { $0.method == "DELETE" }.compactMap { $0.body }
        XCTAssertFalse(bodies.isEmpty, "the retry actually dialled")
    }

    /// The credential await is held open while a NEWER deletion replaces the operation. The stale
    /// completion must not write status over the newer one.
    @MainActor
    func test_aReplacementDuringTheCredentialAwaitIsNotOverwrittenByTheStaleCompletion() async throws {
        ServerSettings.userId = "acct-1"
        defer { ServerSettings.userId = nil }
        Wire.reset()
        let tokens = GatedTokens()
        let (model, _) = makeModel(tokens: tokens)

        model.beginDeletionForTesting()
        let staleID = model.pendingDeletionRequestIDForTesting

        // Start the retry; it suspends inside credential acquisition.
        let inflight = Task { await model.retryDeletion() }
        while !tokens.hasStarted() { await Task.yield() }

        // A NEWER deletion replaces it while the credential is still being acquired.
        model.beginDeletionForTesting()
        let newerID = model.pendingDeletionRequestIDForTesting
        XCTAssertNotEqual(staleID, newerID, "the replacement has its own identity")

        tokens.release("tok")
        await inflight.value

        XCTAssertEqual(model.pendingDeletionRequestIDForTesting, newerID,
                       "the stale completion must not replace or clear the newer operation")
    }

    /// A burst of notifications well beyond the old cap still completes and is observable: no
    /// scheduled work is dropped, and every task the observer was handed can be settled.
    func test_aBurstOfNotificationsSchedulesSettleableWork() async throws {
        ServerSettings.userId = "acct-1"
        defer { ServerSettings.userId = nil }
        Wire.reset()
        let store = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-1" },
            sessionIdentityProvider: { "acct-1" })
        let seen = ObservedTasks()
        let coordinator = VoiceSharingCoordinator(
            enrollmentStore: store, scheduledWorkObserver: .init { task in seen.add(task) })
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://unit.test" }, tokenProvider: OpenTokens(),
            session: makeSession(), sessionIdentity: { "acct-1" }, membershipStore: store)
        let center = RecordingNotificationCenter()
        let uninstall = coordinator.installIdentityInvalidation(
            onNotificationCenter: center, startupAuthReadable: { true },
            scheduledRefreshClient: client, loginStateReadable: { true })
        defer { uninstall() }
        await coordinator.settleObservedWork()

        let beforePost = seen.count()
        for _ in 0..<12 { _ = center.post(name: .userLoginDidChange) }
        await coordinator.settleObservedWork()

        XCTAssertEqual(seen.count() - beforePost, 12,
                       "every notification's refresh was scheduled and handed to the observer")
        let projections = Wire.recorded().filter { $0.path == VoiceSharingAccountClient.projectionPath }
        XCTAssertGreaterThanOrEqual(projections.count, 12,
                                    "the burst really reached the wire: \(projections.count)")
    }
}

/// Thread-safe count of the tasks the coordinator handed over.
private final class ObservedTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    func add(_ task: Task<Void, Never>) { lock.lock(); tasks.append(task); lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return tasks.count }
}
