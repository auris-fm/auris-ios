import XCTest

@testable import PocketCastsServer
@testable import PocketCastsUtils
@testable import podcasts

/// KNOWN-OUTCOME RETRY CONTROLS (reviewer 2ba0220e, 4546a238, fa9db8e9).
///
/// The retry paths were the defect surface: a resume that suspends on a credential, then decides
/// what to do with an operation whose outcome is UNKNOWN. These controls drive only the PUBLIC
/// actions — there is no test-only state setter — and compare what actually went on the wire.
final class VoiceSharingDelayedCredentialRetryControls: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "delayed-credential-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Wire.reset()
        Wire.current = Wire()
    }

    override func tearDown() {
        Wire.current = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A credential source a control can hold open or make temporarily unavailable. `token()`
    /// suspends until released when gated, which is the window an account transition can land in.
    private final class GatedTokens: CloudTokenProviding, @unchecked Sendable {
        private let gate = NSCondition()
        private var open = true
        private var value: String? = "tok"
        private var started = false

        func close(_ next: String?) {
            gate.lock(); open = false; value = next; started = false; gate.unlock()
        }
        func release(_ next: String?) {
            gate.lock(); open = true; value = next; gate.broadcast(); gate.unlock()
        }
        func hasStarted() -> Bool { gate.lock(); defer { gate.unlock() }; return started }
        func token() async -> String? {
            gate.lock()
            started = true
            while !open { gate.wait() }
            let v = value; gate.unlock()
            return v
        }
        func handleUnauthorized(rejectedToken: String?) async {}
    }

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
        /// Every DELETE the client actually sent, serialized, in order.
        static func deletionBodies() -> [[String: Any]] {
            recorded().filter { $0.method == "DELETE" }.compactMap {
                guard let body = $0.body else { return nil }
                return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Wire.self]
        return URLSession(configuration: configuration)
    }

    /// EVERY identity reader follows the live session (reviewer b4d5eb71). Pinning the client's
    /// `sessionIdentity` to a constant made an account move invisible to the client's own token
    /// fence, which is exactly the fence this control is meant to exercise.
    @MainActor
    private func makeModel(tokens: CloudTokenProviding)
        -> (VoiceSharingAccountModel, VoiceSharingEnrollmentStore) {
        let store = VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { ServerSettings.userId ?? "signed-out" },
            sessionIdentityProvider: { ServerSettings.userId })
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://unit.test" }, tokenProvider: tokens,
            session: makeSession(), sessionIdentity: { ServerSettings.userId }, membershipStore: store)
        // The session reader follows `ServerSettings.userId`, as production's does. Pinning it to a
        // constant made the transition in the control invisible to the model's own fences, which is
        // why an earlier version could not have caught a stale completion.
        let model = VoiceSharingAccountModel(
            store: store, client: client,
            disclosureVersion: VoiceSharingDisclosure.productionVersion,
            session: { ServerSettings.userId })
        return (model, store)
    }

    /// Saves and restores the process-wide account globals to their PREVIOUS values.
    private func withAccount(_ body: () async throws -> Void) async rethrows {
        let previousEmail = ServerSettings.syncingEmail()
        let previousUserID = ServerSettings.userId
        ServerSettings.userId = "acct-1"
        defer {
            ServerSettings.setSyncingEmail(email: previousEmail)
            ServerSettings.userId = previousUserID
        }
        try await body()
    }

    // MARK: - Controls

    /// An UNKNOWN deletion outcome retains the operation, and an identical retry re-sends the SAME
    /// serialized request — compared on the wire, not on the model's stored copy.
    @MainActor
    func test_unknownDeletionOutcomeReSendsTheIdenticalSerializedRequest() async throws {
        try await withAccount {
            Wire.reset()
            Wire.mutationStatus = 503  // the server did not answer ⇒ outcome unknown
            let (model, _) = makeModel(tokens: GatedTokens())

            // The PUBLIC action, not a manufactured state.
            await model.deleteAcceptedData(confirmed: true)
            let firstAttempts = Wire.deletionBodies()
            XCTAssertEqual(firstAttempts.count, 1, "the first deletion reached the wire")
            XCTAssertNotNil(model.pendingDeletionRequestIDForTesting,
                            "an unknown outcome keeps the operation for an identical retry")

            await model.retryDeletion()
            let attempts = Wire.deletionBodies()
            XCTAssertEqual(attempts.count, 2, "the retry dialled again")
            XCTAssertEqual(attempts[0] as NSDictionary, attempts[1] as NSDictionary,
                           "the identical retry re-sends the SAME serialized request (ID and cutoff)")
        }
    }

    /// A TEMPORARY missing credential must not discard the operation; once a credential is
    /// available again, the SAME serialized request is sent.
    @MainActor
    func test_temporaryMissingCredentialRetainsTheOperationAndRecovers() async throws {
        try await withAccount {
            Wire.reset()
            Wire.mutationStatus = 503
            let tokens = GatedTokens()
            let (model, _) = makeModel(tokens: tokens)

            await model.deleteAcceptedData(confirmed: true)
            let first = Wire.deletionBodies()
            XCTAssertEqual(first.count, 1)

            // The credential goes away, and a retry runs in that window.
            tokens.close(nil)
            let retry = Task { await model.retryDeletion() }
            tokens.release(nil)      // still no credential
            await retry.value

            XCTAssertNotNil(model.pendingDeletionRequestIDForTesting,
                            "a missing credential is TEMPORARY: the operation must be retained")

            // Recovery: the credential comes back and the retry succeeds in being sent.
            tokens.close("tok")
            let recovery = Task { await model.retryDeletion() }
            tokens.release("tok")
            await recovery.value

            let attempts = Wire.deletionBodies()
            XCTAssertEqual(attempts.count, 2, "the recovered retry reached the wire")
            XCTAssertEqual(attempts[0] as NSDictionary, attempts[1] as NSDictionary,
                           "recovery re-sends the SAME request identity")
        }
    }

    /// A deletion attempt that suspends on the credential while the SESSION changes must not apply
    /// its completion. The suspension is real; the transition is a genuine account move through the
    /// store, not a manufactured status.
    ///
    /// What this control is careful NOT to claim: the earlier version expected `.sending` and failed
    /// with `.unavailable`, because the model's own `storeChanged()` (an observer hop, not the
    /// completion path) already adjusted the status when the transition landed. The property that
    /// matters is that the STALE COMPLETION wrote nothing: the durable operation was retired with
    /// the old session, and the returned result never touched it.
    @MainActor
    func test_anAccountTransitionDuringTheCredentialAwaitDoesNotApplyTheStaleCompletion() async throws {
        try await withAccount {
            Wire.reset()
            Wire.mutationStatus = 700  // never reached: the credential is held open until after the move
            let tokens = GatedTokens()
            let (model, store) = makeModel(tokens: tokens)

            tokens.close("tok")
            let inflight = Task { await model.deleteAcceptedData(confirmed: true) }
            while !tokens.hasStarted() { await Task.yield() }

            // THE TRANSITION lands inside the await: the LIVE session moves to another account.
            ServerSettings.userId = "acct-2"
            store.transitionToAccount(signedIn: true)
            tokens.release("tok")
            await inflight.value

            XCTAssertNil(model.pendingDeletionRequestIDForTesting,
                         "the operation belonged to the retired session and was not resurrected")
            // NO RETIRED DELETE REACHED THE WIRE: the client's token fence must have refused it,
            // not merely the model's state.
            let deletes = Wire.deletionBodies()
            XCTAssertTrue(deletes.isEmpty,
                          "the retired session's DELETE must not be sent: \(deletes)")
            // The STALE COMPLETION specifically: the retired attempt returned `.unavailableBackend`
            // (its session moved), which RETAINS an operation. If that branch were applied, the
            // retired deletion would still be pending now. It must not be.
            XCTAssertEqual(model.deletionStatus, .idle,
                           "the stale completion wrote nothing over the retired session's state")
        }
    }
}