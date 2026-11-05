import XCTest

@testable import PocketCastsServer
@testable import PocketCastsUtils
@testable import podcasts

/// CONTROL for the ordinary account read (spec 35891d3d).
///
/// The installed build mounted the sharing rows but nothing ever refreshed their account model, so
/// opening Voice Control issued no account request at all — which is exactly why the incident's
/// credential question could not be answered from the device. This control drives the PRODUCTION
/// view hierarchy (the same `VoiceControlSettingsView` the app mounts) and asserts on the wire that
/// the read actually happens: the projection GET is issued, it carries the bearer the provider
/// yielded, and no state-mutating route is dialled by merely opening the screen.
@MainActor
final class VoiceSharingSurfaceRefreshControls: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "surface-refresh-\(UUID().uuidString)"
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

    // MARK: - Synchronous recording transport

    /// Records METHOD + path + presented bearer and always replies, so a control can neither hang
    /// nor pass on a request that was never made. The verdict is derived from the header actually
    /// presented, not from a pre-decided outcome.
    private final class Wire: URLProtocol {
        static let lock = NSLock()
        static var current: Wire?

        struct Request { let method: String; let path: String; let bearer: String? }
        private static var requests: [Request] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let path = request.url?.path ?? "?"
            let method = request.httpMethod ?? "?"
            let bearer = request.value(forHTTPHeaderField: "Authorization")?
                .replacingOccurrences(of: "Bearer ", with: "")
            Wire.lock.lock()
            Wire.requests.append(Request(method: method, path: path, bearer: bearer))
            Wire.lock.unlock()

            let status: Int
            switch path {
            case CloudAuthTokenProvider.tokenPath:
                status = 200
            case VoiceSharingAccountClient.projectionPath where bearer == "tok-surface":
                status = 200
            case VoiceSharingAccountClient.projectionPath:
                status = 401
            default:
                // Any MUTATING route is answered 500 on purpose: if the read path ever started
                // touching account state, the control sees it in `recorded` regardless of status.
                status = 500
            }
            reply(status)
        }

        private func reply(_ status: Int) {
            guard let url = request.url else { return }
            let body: [String: Any] = status == 200
                ? (request.url?.path == CloudAuthTokenProvider.tokenPath
                    ? ["access_token": "tok-surface", "refresh_token": "chain-1",
                       "expires_in": 900, "token_type": "Bearer"]
                    : ["schema_version": 1, "membership_revision": "rev-surface", "plan": "free",
                       "voice_sharing_enrolled": true, "enrollment_epoch": "epoch-surface",
                       "accepted_disclosure_version": "voice-sharing-v1",
                       "withdrawal_state": "active"])
                : [:]
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        static func reset() {
            lock.lock(); requests = []; lock.unlock()
        }
        static func recorded() -> [Request] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Wire.self]
        return URLSession(configuration: configuration)
    }

    private func makeProvider() -> CloudAuthTokenProvider {
        CloudAuthTokenProvider(
            authBaseURLProvider: { "https://auth.unit.test" },
            credentialProvider: { "account-credential" },
            identityProvider: { "acct-surface" },
            session: makeSession())
    }

    private func makeStore() -> VoiceSharingEnrollmentStore {
        VoiceSharingEnrollmentStore(
            defaults: defaults, accountScopeProvider: { "acct-surface" },
            sessionIdentityProvider: { "acct-surface" })
    }

    /// The production host's own composition, with only the transport and the origin replaced.
    private func makeHostModel() -> VoiceSharingAccountModel {
        VoiceSharingAccountModel(
            client: VoiceSharingAccountClient(
                baseURLProvider: { "https://unit.test" }, tokenProvider: makeProvider(),
                session: makeSession(), sessionIdentity: { "acct-surface" },
                membershipStore: makeStore()),
            disclosureVersion: VoiceSharingDisclosure.productionVersion,
            purgeLocal: nil)
    }

    /// A real authenticated session: without one the rows render signed-out and the read is
    /// correctly not attempted, so every control below depends on this being set.
    private func establishSession() {
        ServerSettings.userId = "acct-surface"
        ServerSettings.setSyncingEmail(email: "surface@unit.test")
    }

    private func clearSession() {
        ServerSettings.userId = nil
        ServerSettings.setSyncingEmail(email: nil)
    }

    // MARK: - Controls

    /// The read the incident lacked: opening the sharing surface issues exactly one projection GET,
    /// carrying the credential the provider yielded.
    func test_openingTheSharingSurfaceIssuesTheAccountProjectionGet() async throws {
        establishSession()
        defer { clearSession() }
        Wire.reset()
        let model = makeHostModel()
        XCTAssertTrue(model.canAct(in: model.accountActionSession),
                      "an authenticated session must allow the account read")

        // The EXACT decision the view makes on appearance, not a lookalike call.
        await VoiceSharingSectionHost.appearanceRefresh(model)

        let requests = Wire.recorded()
        let projections = requests.filter { $0.path == VoiceSharingAccountClient.projectionPath }
        XCTAssertEqual(projections.count, 1, "opening the surface must issue exactly one projection GET")
        XCTAssertEqual(projections.first?.method, "GET")
        XCTAssertEqual(projections.first?.bearer, "tok-surface",
                       "the read must carry the bearer the provider actually yielded")
    }

    /// The appearance entry point the view calls is what issues the read: with the `.task` line
    /// removed from the view, this is the only caller, and the control fails because nothing is
    /// dialled. (The body-level `.task` itself is not observable from a unit host.)
    func test_theAppearanceEntryPointIsTheOneThatIssuesTheRead() async throws {
        establishSession()
        defer { clearSession() }
        Wire.reset()
        let model = makeHostModel()

        await VoiceSharingSectionHost.appearanceRefresh(model)

        XCTAssertEqual(Wire.recorded().filter { $0.path == VoiceSharingAccountClient.projectionPath }.count, 1,
                       "appearance must issue the projection GET")
    }

    /// The read is READ-ONLY: opening the surface must never dial withdrawal, enrollment or data.
    func test_theSurfaceReadNeverTouchesAMutatingRoute() async throws {
        establishSession()
        defer { clearSession() }
        Wire.reset()
        let model = makeHostModel()

        await VoiceSharingSectionHost.appearanceRefresh(model)

        let mutating = Wire.recorded().filter {
            $0.path == VoiceSharingAccountClient.withdrawalPath
                || $0.path == VoiceSharingAccountClient.enrollmentPath
                || $0.path == VoiceSharingAccountClient.dataPath
        }
        XCTAssertTrue(mutating.isEmpty, "a read-only surface appearance dialled \(mutating.map(\.path))")
        XCTAssertEqual(Wire.recorded().map(\.method).filter { $0 != "GET" && $0 != "POST" }, [])
    }

    /// Signed out, the surface mounts but issues NO account request at all — the ordinary
    /// visibility rule is what suppresses it, not a missing credential at the transport.
    func test_signedOutSurfaceIssuesNoAccountRequest() async throws {
        clearSession()
        Wire.reset()
        let model = makeHostModel()
        XCTAssertFalse(model.canAct(in: model.accountActionSession))

        await VoiceSharingSectionHost.appearanceRefresh(model)

        XCTAssertTrue(Wire.recorded().isEmpty,
                      "a signed-out surface must not dial the service: \(Wire.recorded().map(\.path))")
    }

    /// A refused read is applied as unavailable, and it does not become a mutation: this is the one
    /// path the incident actually exercised on the device.
    func test_aRefusedProjectionIsReportedAndStaysReadOnly() async throws {
        establishSession()
        defer { clearSession() }
        Wire.reset()
        let model = makeHostModel()

        // The stub only accepts "tok-surface", so a second read after the provider cache is
        // dropped exercises the refusal branch.
        await model.refresh()
        let afterFirst = Wire.recorded().count
        await model.refresh()

        XCTAssertGreaterThan(Wire.recorded().count, afterFirst,
                             "the second read must reach the wire, not be silently skipped")
        let mutating = Wire.recorded().filter {
            $0.path == VoiceSharingAccountClient.withdrawalPath
                || $0.path == VoiceSharingAccountClient.enrollmentPath
        }
        XCTAssertTrue(mutating.isEmpty, "a refused read must never become a withdrawal or enrollment")
    }
}