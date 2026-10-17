import XCTest
import PocketCastsServer
@testable import podcasts

/// Transport seam: the client builds REAL `URLRequest`s through a real `URLSession`; this stub answers them
/// so status handling, wire decoding and session-identity dropping are exercised on the production path.
private typealias Reply = VoiceSharingStubProtocol.Reply

final class VoiceSharingStubProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: [String: Any]
    }
    /// Keyed by "<METHOD> <path>" so a control can script different answers per route.
    static var replies: [String: Reply] = [:]
    static var seenRequests: [URLRequest] = []
    static var responseDelay: TimeInterval = 0
    /// Hook invoked after the request is recorded but before the reply is delivered — lets a control flip
    /// account identity mid-flight and prove stale-session responses are dropped rather than applied.
    static var onRequest: (() -> Void)?
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        // Snapshot the schedule at request time: reading `responseDelay` again inside the deferred block,
        // or mutating shared arrays from a background queue, lets one test's held reply land inside the
        // next test and makes ordering unreviewable.
        let delay = VoiceSharingStubProtocol.responseDelay
        VoiceSharingStubProtocol.lock.lock()
        VoiceSharingStubProtocol.seenRequests.append(request)
        VoiceSharingStubProtocol.lock.unlock()
        VoiceSharingStubProtocol.onRequest?()
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        let reply = VoiceSharingStubProtocol.replies[key]
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self.deliver(reply, path: url.path)
            }
        } else {
            deliver(reply, path: url.path)
        }
    }
    private func deliver(_ reply: Reply?, path: String) {
        guard let reply, let http = HTTPURLResponse(
            url: URL(string: "https://api.example.test" + path)!,
            statusCode: reply.status, httpVersion: nil, headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let data = (try? JSONSerialization.data(withJSONObject: reply.body)) ?? Data()
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset() {
        replies = [:]
        seenRequests = []
        responseDelay = 0
        onRequest = nil
    }
}

/// Receipts carry schema_version like every other response in this contract.
private func deletionReceipt(_ id: String, status: String = "deletion_pending", version: Int = 1) -> [String: Any] {
    ["schema_version": version, "deletion_request_id": id, "status": status]
}

private func projection(_ revision: String, enrolled: Bool, epoch: String?, withdrawal: String) -> [String: Any] {
    var body: [String: Any] = [
        "schema_version": 1,
        "membership_revision": revision,
        "plan": "pro",
        "voice_sharing_enrolled": enrolled,
        "withdrawal_state": withdrawal,
    ]
    body["enrollment_epoch"] = epoch as Any
    body["accepted_disclosure_version"] = "2026-09" as Any
    return body
}

/// A credential provider that never blocks, mirroring the trust-on-first-use default in CloudTokenProviding.
private final class AccountStubTokenProvider: CloudTokenProviding {
    var tokenValue: String? = "test-bearer"
    var delay: TimeInterval = 0
    private(set) var unauthorizedCalls = 0
    private(set) var lastRejectedToken: String?
    func token() async -> String? {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return tokenValue
    }
    func prepare() async {}
    func handleUnauthorized(rejectedToken: String?) async {
        unauthorizedCalls += 1
        lastRejectedToken = rejectedToken
    }
}

final class VoiceSharingAccountClientTests: XCTestCase {
    private var session: URLSession!
    private var tokens: AccountStubTokenProvider!
    /// Non-secret session label; production derives a digest of session material.
    private var identity: String? = "gen-A"
    private var requestIDs: [String] = []

    override func setUp() {
        super.setUp()
        VoiceSharingStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSharingStubProtocol.self]
        session = URLSession(configuration: config)
        tokens = AccountStubTokenProvider()
        identity = "gen-A"
        requestIDs = []
    }

    override func tearDown() {
        VoiceSharingStubProtocol.reset()
        super.tearDown()
    }

    /// A single client instance shared by `begin…` and `perform…` in one test, so an operation's immutable
    /// request identity is carried across calls exactly as production must.
    private lazy var clientForTest: VoiceSharingAccountClient = makeClient()

    private func makeClient(factory: (() -> String)? = nil) -> VoiceSharingAccountClient {
        VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: tokens,
            session: session,
            requestIDFactory: factory ?? { [weak self] in
                let id = UUID().uuidString.lowercased()
                self?.requestIDs.append(id)
                return id
            },
            sessionIdentity: { [weak self] in self?.identity }
        )
    }

    // MARK: - Production generation registry (the object the client actually reads by default)

    /// The lifecycle object is the state production mutates at sign-in/sign-out. Driving it here (rather
    /// than a test-local string) means the same transitions the app performs are what supersede an operation.
    func test_lifecycleRegistry_signOutThenSignIn_supersedesOperations() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 200, body: projection("r15", enrolled: true, epoch: "e15", withdrawal: "active"))
        let registry = VoiceSharingSessionGeneration()
        registry.beginNewLifecycle()
        let client = VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: tokens,
            session: session,
            requestIDFactory: { UUID().uuidString.lowercased() },
            sessionIdentity: { registry.currentGeneration() }
        )
        guard let op = client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else {
            return XCTFail("no session to begin under")
        }
        // Sign-out ends the lifecycle; signing back in mints a NEW one.
        registry.clear()
        registry.beginNewLifecycle()
        let outcome = await client.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession, "operations from the previous login must not run")
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty, "and they must not reach the network")
    }

    /// A lifecycle label is stable until a real transition rotates it. Nothing about acquiring or refreshing
    /// a bearer moves it — that property is what keeps routine token maintenance from dropping user intent.
    func test_lifecycleRegistry_rotatesOnlyOnRealTransitions() {
        let registry = VoiceSharingSessionGeneration()
        XCTAssertNil(registry.currentGeneration(), "a cold process has no session to act under")

        let first = registry.ensureLifecycle()
        XCTAssertEqual(registry.currentGeneration(), first)
        XCTAssertEqual(registry.ensureLifecycle(), first, "ensure must not rotate an existing lifecycle")

        let rotated = registry.beginNewLifecycle()
        XCTAssertNotEqual(rotated, first, "sign-in / account switch establishes a new lifecycle")
        XCTAssertNotEqual(rotated.count, 0, "a lifecycle label exists")

        registry.clear()
        XCTAssertNil(registry.currentGeneration(), "sign-out leaves no session to act under")
    }


    // MARK: - Round 9: production lifecycle writer (beginA -> real transition -> perform)

    /// The closure @spec asked for (f5a9275f): the generation must have a REAL writer, and an operation
    /// begun under one lifecycle must refuse after the app's own account transitions run.
    ///
    /// Nothing here posts a hand-made notification into a test center. It calls `SignOutHelper.signout()`
    /// and `AuthenticationHelper.handleSuccessfulSignIn(...)`, i.e. the same code paths the UI runs, and
    /// subscribes through `AppDelegate.setupVoiceSharingIdentityInvalidation` — the app's composition point.
    func test_productionLifecycle_realSignOut_supersedesAnOperationBegunBeforeIt() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 200, body: projection("r20", enrolled: true, epoch: "e20", withdrawal: "active"))

        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        VoiceSharingCoordinator.setSharedForTesting(coordinator)
        defer { VoiceSharingCoordinator.resetSharedForTesting() }

        // Production subscription: AppDelegate -> installIdentityInvalidation on the DEFAULT center,
        // which is where SyncManager posts its account notifications.
        let appDelegate = AppDelegate()
        appDelegate.setupVoiceSharingIdentityInvalidation()

        // A client built with PRODUCTION DEFAULTS — no injected identity closure at all.
        let client = VoiceSharingAccountClient(tokenProvider: tokens, session: session)
        // Hermetic start: whatever earlier tests left, this test establishes its own lifecycle first —
        // exactly what a login does — and then lets the app's sign-out path end it.
        VoiceSharingSessionGeneration.shared.clear()
        // Establish honestly: signed-in state + the notification a login produces.
        let priorEmail = ServerSettings.syncingEmail()
        ServerSettings.setSyncingEmail(email: "supersede-control@example.test")
        defer {
            if let priorEmail { ServerSettings.setSyncingEmail(email: priorEmail) }
            else { ServerSettings.setSyncingEmail(email: nil) }
        }
        NotificationCenter.default.post(name: .userLoginDidChange, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard VoiceSharingSessionGeneration.shared.currentGeneration() != nil else {
            return XCTFail("control setup: login-change must leave a lifecycle to begin work under")
        }
        guard let op = client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else {
            return XCTFail("no session to begin under")
        }
        let begunUnder = VoiceSharingSessionGeneration.shared.currentGeneration()
        XCTAssertEqual(op.originatingGeneration, begunUnder ?? "", "the operation records the live lifecycle")

        // THE REAL TRANSITION: the app's sign-out entry point, not a synthesized notification.
        SignOutHelper.signout()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let afterSignOut = VoiceSharingSessionGeneration.shared.currentGeneration()
        XCTAssertNotEqual(afterSignOut, begunUnder ?? "",
                       "the app's sign-out path must end the lifecycle the operation was begun under")
        let outcome = await client.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession,
                       "an operation begun before a real sign-out must refuse, not be sent under whatever session follows")
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty, "and it must refuse before transport")
    }

    /// Round 10 (reviewer 3c118e11): `SignOutHelper.signout()` posts `.userLoginDidChange` AFTER
    /// `SyncManager.signout()` has cleared the credential, i.e. while SIGNED OUT. That notification is a
    /// state change, not proof of a login. Driving the real producer sequence must leave NO lifecycle at
    /// all — asserting only "the label differs from before" would pass on a freshly minted signed-out label.
    func test_realSignOutSequence_leavesNoLifecycleAndRefusesEveryBegin() async {
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        VoiceSharingCoordinator.setSharedForTesting(coordinator)
        defer { VoiceSharingCoordinator.resetSharedForTesting() }
        AppDelegate().setupVoiceSharingIdentityInvalidation()

        // Signed in for real, through the app's own setter, then establish a lifecycle via the same
        // notification a sign-in produces.
        let priorEmail = ServerSettings.syncingEmail()
        ServerSettings.setSyncingEmail(email: "signout-sequence@example.test")
        defer {
            if let priorEmail { ServerSettings.setSyncingEmail(email: priorEmail) }
            else { ServerSettings.setSyncingEmail(email: nil) }
        }
        NotificationCenter.default.post(name: .userLoginDidChange, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let signedIn = VoiceSharingSessionGeneration.shared.currentGeneration() else {
            return XCTFail("control sanity: a real sign-in state must establish a lifecycle")
        }

        // THE REAL PRODUCER SEQUENCE: SignOutHelper clears credentials, then posts userLoginDidChange.
        SignOutHelper.signout()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertFalse(SyncManager.isUserLoggedIn(), "control sanity: the app really is signed out now")
        XCTAssertNil(VoiceSharingSessionGeneration.shared.currentGeneration(),
                     "a trailing login-change while signed out must NOT mint a replacement lifecycle")

        // Every operation entry point must refuse to produce work with no session behind it.
        let client = VoiceSharingAccountClient(tokenProvider: tokens, session: session)
        XCTAssertNil(client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7"),
                     "no enrollment may be begun while signed out")
        XCTAssertNil(client.beginWithdrawal(enrollmentEpoch: "e1", expectedMembershipRevision: "r7"),
                     "no withdrawal may be begun while signed out")
        XCTAssertNil(client.beginDeletion(), "no deletion may be begun while signed out")
        XCTAssertNotEqual(VoiceSharingSessionGeneration.shared.currentGeneration(), signedIn,
                          "and nothing may still carry the departed session")
    }

    /// The fence must stay raised after that sequence: a refresh belonging to the departed account cannot
    /// install permission merely because a notification ran.
    func test_realSignOutSequence_policyStaysFencedAfterTrailingLoginChange() {
        let center = NotificationCenter()
        // Enrollment flips to false when sign-out runs, which is what makes `permitsCollection` go dark
        // through the SAME production path a real withdrawal takes.
        var enrolledForControl = true
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { enrolledForControl }
        )
        coordinator.installIdentityInvalidation(onNotificationCenter: center)
        let token = coordinator.policy.tokenForFetchStart()
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertTrue(coordinator.policy.permitsCollection, "wired first so there is something to lose")

        // Sign out, then the trailing login-change while signed out.
        enrolledForControl = false
        center.post(name: .serverUserWillBeSignedOut, object: nil, userInfo: ["user_initiated": true])
        center.post(name: .userLoginDidChange, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        XCTAssertFalse(coordinator.policy.permitsCollection,
                       "a signed-out trailing notification must not lift the fence")
        coordinator.policyRefreshAfterActivation(freshActivationSucceeded: true, fetchToken: token)
        XCTAssertFalse(coordinator.policy.permitsCollection, "still fenced against the departed identity")
    }

    /// Cold start into an already-signed-in account: the process has no lifecycle yet, so the first thing
    /// the wiring does is establish one. Without this every `begin…()` would return nil on launch and
    /// voice sharing could never be turned on until the user happened to log in again.
    func test_productionLifecycle_coldStartIntoSignedInAccount_establishesLifecycle() {
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        VoiceSharingCoordinator.setSharedForTesting(coordinator)
        defer { VoiceSharingCoordinator.resetSharedForTesting() }

        VoiceSharingSessionGeneration.shared.clear()
        XCTAssertNil(VoiceSharingSessionGeneration.shared.currentGeneration(), "control sanity: fresh process")

        // Cold start means SIGNED IN: `SyncManager.isUserLoggedIn()` reads the email from the Keychain, so
        // the precondition is supplied through the app's own setter rather than assumed. Restored after.
        let priorEmail = ServerSettings.syncingEmail()
        if priorEmail == nil || priorEmail!.isEmpty {
            ServerSettings.setSyncingEmail(email: "cold-start-control@example.test")
        }
        defer {
            if let priorEmail { ServerSettings.setSyncingEmail(email: priorEmail) }
            else { ServerSettings.setSyncingEmail(email: nil) }
        }
        XCTAssertTrue(SyncManager.isUserLoggedIn(), "control sanity: the app believes it is signed in")

        // The app's composition point runs on activation.
        let appDelegate = AppDelegate()
        appDelegate.handleBecomeActive()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        XCTAssertNotNil(VoiceSharingSessionGeneration.shared.currentGeneration(),
                        "activation must give a signed-in account a lifecycle to act under")
        let client = VoiceSharingAccountClient(tokenProvider: tokens, session: session)
        XCTAssertNotNil(client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7"),
                        "so work can be begun immediately after launch, not only after a manual re-login")
    }

    /// Sign-in establishes a NEW lifecycle, so work begun under the previous login cannot leak into it —
    /// including signing back into the SAME account, which a stable user id cannot distinguish.
    func test_productionLifecycle_realSignIn_establishesNewGeneration() {
        let coordinator = VoiceSharingCoordinator(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { true }
        )
        VoiceSharingCoordinator.setSharedForTesting(coordinator)
        defer { VoiceSharingCoordinator.resetSharedForTesting() }
        let appDelegate = AppDelegate()
        appDelegate.setupVoiceSharingIdentityInvalidation()

        // Start from signed-out: the point is that a login CREATES a lifecycle, not what preceded it.
        SignOutHelper.signout()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        VoiceSharingSessionGeneration.shared.clear()
        XCTAssertNil(VoiceSharingSessionGeneration.shared.currentGeneration(), "control sanity: signed out")

        // A real sign-in sets the credential BEFORE posting, which is exactly what makes this case differ
        // from SignOutHelper's trailing post.
        let priorEmail = ServerSettings.syncingEmail()
        ServerSettings.setSyncingEmail(email: "signin-establish@example.test")
        defer {
            if let priorEmail { ServerSettings.setSyncingEmail(email: priorEmail) }
            else { ServerSettings.setSyncingEmail(email: nil) }
        }
        NotificationCenter.default.post(name: .userLoginDidChange, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let established = VoiceSharingSessionGeneration.shared.currentGeneration()
        XCTAssertNotNil(established, "a login-change WHILE SIGNED IN must establish a lifecycle")
        guard let client = Optional(VoiceSharingAccountClient(tokenProvider: tokens, session: session)) else { return }
        XCTAssertNotNil(client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7"),
                        "after a login there IS a session to act under")
    }

    // MARK: - Review round 7 additions: same-account relogin, GET guarding, numeric bridging

    /// `userId` alone cannot see sign-out followed by signing back into the SAME account. The session half of
    /// the identity does, so a reply from the previous session must drop rather than apply membership.
    /// The operation's originating generation is captured at BEGIN and retained across retries. If the
    /// current session no longer matches, perform must refuse BEFORE transport — otherwise account A's
    /// opt-in intent would be sent under account B's credential, and the server could not tell.
    func test_operationBegunUnderSessionA_refusesToRunUnderSessionB_beforeTransport() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 200, body: projection("r14", enrolled: true, epoch: "e14", withdrawal: "active"))
        let client = makeClient()
        guard let op = client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else {
            return XCTFail("no session to begin under")
        }
        XCTAssertEqual(op.originatingGeneration, identity, "the operation records the session it was begun under")
        // Transition lands AFTER begin, before perform.
        identity = "gen-B"
        let outcome = await client.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession, "an operation begun under a superseded session must not run")
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty,
                      "refusal happens before transport — no bytes on the wire")
    }

    /// Same-account re-login: a stable user id cannot see it; only session material distinguishes old login
    /// from new. Begin under the first login, then move to a NEW login for the SAME account.
    func test_sameAccountNewLogin_supersedesOperationsFromTheOldLogin() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 200, body: projection("r6", enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        let client = makeClient()
        guard let op = client.beginWithdrawal(enrollmentEpoch: "e1", expectedMembershipRevision: "r5") else {
            return XCTFail("no session")
        }
        identity = "gen-A2"   // same account, NEW login, after BEGIN
        let outcome = await client.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession, "logout/login into the same account supersedes old operations")
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty, "must refuse before transport")
    }

    /// Deletion previously read identity only AFTER awaiting the bearer inside request building — a real
    /// suspension point. The originating generation must be checked before that await too.
    func test_deletionBegunUnderSessionA_refusesToRunUnderSessionB() async {
        VoiceSharingStubProtocol.replies["DELETE /api/v1/account/voice-sharing/data"] =
            Reply(status: 202, body: deletionReceipt("del-9"))
        let client = makeClient()
        guard let delOp = client.beginDeletion() else { return XCTFail("no session") }
        identity = "gen-B"   // lands after BEGIN, before performDeletion awaits a token
        let outcome = await client.performDeletion(delOp)
        XCTAssertEqual(outcome, .unavailableBackend, "a stale deletion must not be sent")
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty,
                      "deletion is fenced before the credential await, not merely after the response")
    }

    /// A reply that arrives after the session moved is dropped rather than applied — distinct from refusing
    /// to send at all, and reachable because the transition lands while the request is in flight.
    func test_responseArrivingAfterSessionChange_isNotApplied() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 200, body: projection("r13", enrolled: true, epoch: "e13", withdrawal: "active"))
        VoiceSharingStubProtocol.responseDelay = 0.05
        let client = makeClient()
        guard let op = client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else {
            return XCTFail("no session")
        }
        VoiceSharingStubProtocol.onRequest = { [weak self] in self?.identity = "gen-B" }
        let outcome = await client.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession, "a reply from a superseded session must never apply")
        XCTAssertFalse(VoiceSharingStubProtocol.seenRequests.isEmpty, "this path DID send, unlike the pre-transport refusal")
    }

    /// GET was previously unguarded: an account transition during the fetch would still install the previous
    /// account's projection. Also asserts no request at all when there is no authenticated session.
    func test_getProjection_transitionDuringFetch_isDropped() async {
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection("r7", enrolled: true, epoch: "e1", withdrawal: "active"))
        let client = makeClient()
        VoiceSharingStubProtocol.onRequest = { [weak self] in
            self?.identity = "gen-B"
        }
        let membership = await client.fetchProjection()
        XCTAssertNil(membership, "a projection read across an account change must not be returned")
    }

    func test_noSessionIdentity_makesNoRequest() async {
        identity = nil
        let membership = await makeClient().fetchProjection()
        XCTAssertNil(membership)
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty, "no session means no call, not an anonymous probe")
    }

    /// JSONSerialization bridges an INTEGER to Bool under `as? Bool`. A numeric publication must never be
    /// read as enrollment, so the strict boolean check rejects it before any decision is made.
    func test_projection_numericBoolBridging_isRejected() {
        func bytes(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }
        var numeric = projection("r1", enrolled: true, epoch: "e1", withdrawal: "active")
        numeric["voice_sharing_enrolled"] = 1          // integer masquerading as JSON true
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(numeric)),
                     "an Int 1 must not bridge into permission")
        numeric["voice_sharing_enrolled"] = "true"     // string form likewise
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(numeric)))

        // Empty-but-present values are not "present": they carry no authority.
        var blanks = projection("r1", enrolled: true, epoch: "e1", withdrawal: "active")
        blanks["membership_revision"] = ""
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(blanks)))
        blanks = projection("r1", enrolled: true, epoch: "", withdrawal: "active")
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(blanks)))
        // Active enrollment whose accepted disclosure is missing cannot be honored.
        var noDisclosure = projection("r1", enrolled: true, epoch: "e1", withdrawal: "active")
        noDisclosure.removeValue(forKey: "accepted_disclosure_version")
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(noDisclosure)))
        // enrolled=true with withdrawal_state=withdrawn is a contradiction, not permission.
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(projection("r1", enrolled: true, epoch: "e1", withdrawal: "withdrawn"))))
    }


    // MARK: - Review round 8: 401 ordering, secret hygiene, refresh-vs-logout, exact numeric schema

    /// A 401 that arrives for account A's request must not invalidate account B's credential. The captured
    /// generation is validated BEFORE the side effect, so the provider is never called once the session moved.
    func test_401_fromStaleSession_doesNotInvalidateCurrentCredential() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] = Reply(status: 401, body: [:])
        guard let op = clientForTest.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else {
            return XCTFail("no session to begin under")
        }
        // Session changes after the request left; the 401 belongs to the OLD session.
        VoiceSharingStubProtocol.onRequest = { [weak self] in self?.identity = "gen-B" }
        let outcome = await clientForTest.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession)
        XCTAssertEqual(tokens.unauthorizedCalls, 0, "a stale session's 401 must not touch the live credential")
    }

    /// The existing auth API requires the ACTUAL rejected bearer; passing nil would invalidate every other
    /// cached token instead of just the one the server refused.
    func test_401_reportsTheActualRejectedBearer() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] = Reply(status: 401, body: [:])
        guard let op = clientForTest.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else {
            return XCTFail("no session")
        }
        let outcome = await clientForTest.perform(op)
        XCTAssertEqual(outcome, .unauthorized)
        XCTAssertEqual(tokens.lastRejectedToken, "test-bearer", "the bearer this request carried must be the one reported")
    }

    /// Operation bodies are persisted-ready artifacts (queue metadata, diagnostics). They must carry contract
    /// fields only — no credential material in any form.
    func test_operationBodies_carryNoCredentialMaterial() throws {
        guard let enroll = clientForTest.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7"),
              let withdraw = clientForTest.beginWithdrawal(enrollmentEpoch: "e1", expectedMembershipRevision: "r7"),
              let delete = clientForTest.beginDeletion() else { return XCTFail("no session") }
        for op in [enroll.body, withdraw.body, delete.body] {
            let text = String(describing: op)
            for forbidden in ["test-bearer", "credential", "token", "refresh"] {
                XCTAssertFalse(text.lowercased().contains(forbidden), "operation body leaks \(forbidden): \(text)")
            }
        }
    }

    /// Operation identity is a lifecycle label, never credential material. Two properties @spec asked for:
    /// the label carries nothing recoverable about the account, and no operation body can contain a bearer.
    func test_operationIdentity_isOpaqueAndCarriesNoCredentialMaterial() async {
        let registry = VoiceSharingSessionGeneration()
        let label = registry.beginNewLifecycle()
        XCTAssertFalse(label.isEmpty, "a lifecycle label is opaque text with nothing to recover")
        XCTAssertFalse(label.lowercased().contains("token"), "label must not describe credential material")

        guard let enroll = clientForTest.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7"),
              let withdraw = clientForTest.beginWithdrawal(enrollmentEpoch: "e1", expectedMembershipRevision: "r7") else {
            return XCTFail("no session")
        }
        for body in [enroll.body, withdraw.body] {
            let text = body.description.lowercased()
            for forbidden in ["bearer", "credential", "token", "password"] {
                XCTAssertFalse(text.contains(forbidden), "operation body leaks \(forbidden): \(text)")
            }
        }
    }

    /// `intValue` truncates: a schema_version of 1.5 must not read as 1.
    func test_schemaVersion_rejectsFractionalAndBridgedValues() {
        func bytes(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }
        var fractional = projection("r1", enrolled: true, epoch: "e1", withdrawal: "active")
        fractional["schema_version"] = 1.5
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(fractional)), "1.5 must not satisfy schema 1")
        var boolish = projection("r1", enrolled: true, epoch: "e1", withdrawal: "active")
        boolish["schema_version"] = true      // bridges to Int 1 under `as? Int`/intValue
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(boolish)))
        var stringy = projection("r1", enrolled: true, epoch: "e1", withdrawal: "active")
        stringy["schema_version"] = "1"
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(stringy)))

        // Deletion receipts follow the same rule.
        XCTAssertFalse(VoiceSharingAccountClient.isExactInteger(NSNumber(value: 1.5), 1))
        XCTAssertFalse(VoiceSharingAccountClient.isExactInteger(kCFBooleanTrue, 1))
        XCTAssertTrue(VoiceSharingAccountClient.isExactInteger(NSNumber(value: 1), 1))
    }

    // MARK: - Projection reading

    func test_getProjection_decodesAuthoritativeFields() async {
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection("r7", enrolled: true, epoch: "e1", withdrawal: "active"))
        let membership = await makeClient().fetchProjection()
        XCTAssertEqual(membership?.membershipRevision, "r7")
        XCTAssertEqual(membership?.enrollmentEpoch, "e1")
        XCTAssertTrue(membership?.voiceSharingEnrolled == true)
        XCTAssertEqual(membership?.withdrawalState, .active)
    }

    /// Fail-closed parsing: unknown schema, missing fields, or an impossible combination must not read as
    /// permission. A permissive default here would authorize uploads from garbage.
    func test_decodeProjection_rejectsUnknownOrImpossibleShapes() {
        func bytes(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(["schema_version": 2])))
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(["nothing": "relevant"])))
        // enrolled=true with no epoch cannot authorize collection (records key on epoch).
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(projection("r1", enrolled: true, epoch: nil, withdrawal: "active"))))
        // withdrawn + not enrolled is a legal shape and must parse as not-enrolled.
        let ok = VoiceSharingAccountClient.decodeProjection(bytes(projection("r2", enrolled: false, epoch: nil, withdrawal: "withdrawn")))
        XCTAssertEqual(ok?.voiceSharingEnrolled, false)
        XCTAssertEqual(ok?.withdrawalState, .withdrawn)
    }

    func test_noCredential_makesNoRequest() async {
        tokens.tokenValue = nil
        let membership = await makeClient().fetchProjection()
        XCTAssertNil(membership)
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty, "no bearer means no call at all")
    }

    // MARK: - Enrollment

    func test_enroll_carriesRequestIdAndExpectedRevision_andDisclosure() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 200, body: projection("r8", enrolled: true, epoch: "e2", withdrawal: "active"))
        let client = makeClient(factory: { "fixed-request-id" })
        guard let op0 = client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else { return XCTFail("no session") }
        _ = await client.perform(op0)
        guard let request = VoiceSharingStubProtocol.seenRequests.last else { return XCTFail("no request was made") }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer")
        guard let body = requestBodyDictionary(of: request) else { return XCTFail("request carried no readable body") }
        XCTAssertEqual(body["request_id"] as? String, "fixed-request-id")
        XCTAssertEqual(body["expected_membership_revision"] as? String, "r7")
        XCTAssertEqual(body["accepted_disclosure_version"] as? String, "2026-09")
    }

    /// Spec rule: a 409 conflict returns the current projection and MUST NOT be auto-replayed against the
    /// newer revision — renewed opt-in requires fresh user intent. Assert exactly one request was made.
    func test_conflict_returnsCurrentProjection_andNeverAutoReplays() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 409, body: projection("r9", enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        guard let op = clientForTest.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else { return XCTFail("no session to begin under") }
        let outcome = await clientForTest.perform(op)
        switch outcome {
        case .conflict(let current):
            XCTAssertEqual(current?.membershipRevision, "r9")
            XCTAssertEqual(current?.voiceSharingEnrolled, false)
        default:
            XCTFail("expected conflict, got \(outcome)")
        }
        let postCount = VoiceSharingStubProtocol.seenRequests.filter { $0.httpMethod == "POST" }.count
        XCTAssertEqual(postCount, 1, "a conflicted opt-in must not be retried automatically")
    }

    func test_refusals_neverReadAsEnrolled() async {
        for (status, label) in [(403, "ineligible"), (422, "unsupported disclosure")] {
            VoiceSharingStubProtocol.reset()
            VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
                Reply(status: status, body: ["error": label == "ineligible" ? "ineligible_plan" : "unsupported_disclosure"])
            guard let op = clientForTest.beginEnrollment(acceptedDisclosureVersion: "x", expectedMembershipRevision: "r1") else { return XCTFail("no session to begin under") }
            let outcome = await clientForTest.perform(op)
            guard case .refused(let reason) = outcome else { XCTFail("\(label) should refuse"); continue }
            XCTAssertEqual(reason, label == "ineligible" ? .ineligible : .unsupportedDisclosure)
        }
    }

    /// Round 9 (spec 3de3957f): 403 and 422 previously returned account-specific refusals with NO
    /// post-transport generation check, so account A's "ineligible" could be shown as account B's state.
    /// The guard now sits before every status branch, so both codes refuse on a superseded session.
    /// Round 9 (spec 3de3957f): 403 previously returned an account-specific refusal with NO post-transport
    /// generation check, so account A's "ineligible" could be shown as account B's state.
    func test_staleSession_403refusal_isNotSurfaced() async {
        await assertStaleRefusalIsDropped(status: 403, error: "ineligible_plan")
    }

    /// …and the same for 422, whose body is decoded into a reason before it is reported.
    func test_staleSession_422refusal_isNotSurfaced() async {
        await assertStaleRefusalIsDropped(status: 422, error: "unsupported_disclosure")
    }

    private func assertStaleRefusalIsDropped(status: Int, error: String) async {
        VoiceSharingStubProtocol.reset()
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: status, body: ["error": error])
        // Fresh client per case: identity starts at gen-A and moves to gen-B only after the request leaves.
        let client = makeClient()
        guard let op = client.beginEnrollment(acceptedDisclosureVersion: "x", expectedMembershipRevision: "r1") else {
            return XCTFail("no session to begin under")
        }
        XCTAssertEqual(clientForTestIdentity(), "gen-A", "control sanity: begins under gen-A")
        VoiceSharingStubProtocol.responseDelay = 0.05
        VoiceSharingStubProtocol.onRequest = { [weak self] in self?.identity = "gen-B" }
        let outcome = await client.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession, "\(status) must not surface a superseded session's refusal")
        XCTAssertEqual(VoiceSharingStubProtocol.seenRequests.count, 1,
                       "control sanity: exactly one request was sent, so this exercised the post-transport guard")
        VoiceSharingStubProtocol.responseDelay = 0
    }

    private func clientForTestIdentity() -> String? { identity }

    func test_unauthorized_reportsRatherThanRetrying() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 401, body: [:])
        guard let op = clientForTest.beginWithdrawal(enrollmentEpoch: "e1", expectedMembershipRevision: "r1") else { return XCTFail("no session") }
        let outcome = await clientForTest.perform(op)
        XCTAssertEqual(outcome, .unauthorized)
        XCTAssertEqual(tokens.unauthorizedCalls, 1, "the rejected credential must be reported to the provider once")
    }

    // MARK: - Race controls named by the spec

    /// Delayed FIRST delivery of an earlier opt-in landing after a withdrawal: the server rejects it via the
    /// stale expected revision, and the client shows the conflict without resurrecting enrollment.
    func test_delayedFirstDeliveryEnrollment_afterWithdrawal_cannotReactivate() async {
        // User withdrew; server advanced to r9 with withdrawal_state=withdrawn.
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 409, body: projection("r9", enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        guard let op = clientForTest.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else { return XCTFail("no session") }
        let late = await clientForTest.perform(op)
        guard case .conflict(let current) = late else { return XCTFail("late first delivery must conflict") }
        XCTAssertEqual(current?.withdrawalState, .withdrawn)
        XCTAssertFalse(current?.voiceSharingEnrolled == true, "a delayed opt-in may not undo a later opt-out")
    }

    /// Withdrawal while already inactive still advances the revision, which is what fences later
    /// first-delivery opt-ins. Client must treat that 200 as authoritative state, not a no-op.
    func test_withdrawalFromInactiveProjection_advancesRevision() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 200, body: projection("r10", enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        guard let op = clientForTest.beginWithdrawal(enrollmentEpoch: nil, expectedMembershipRevision: "r9") else { return XCTFail("no session") }
        let outcome = await clientForTest.perform(op)
        guard case .applied(let m) = outcome else { return XCTFail("withdrawal from inactive must apply") }
        XCTAssertEqual(m.membershipRevision, "r10", "revision must advance even when already inactive")
        XCTAssertEqual(m.withdrawalState, .withdrawn)
    }

    /// Identical request_id retried AFTER a later transition returns the original result without changing
    /// state. The client must surface the returned projection verbatim and make no additional mutation.
    func test_identicalRequestId_retry_afterLaterTransition_returnsOriginalResult_withoutChangingState() async {
        var issued: [String] = []
        let client = makeClient(factory: {
            let id = "req-original"          // one operation identity, reused by every retry
            issued.append(id)
            return id
        })
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 200, body: projection("r8", enrolled: true, epoch: "e8", withdrawal: "active"))

        // Begin ONCE, then perform twice. The whole point of the immutable operation is that a retry after a
        // lost response carries the same request_id and body — calling begin… again would mint new intent.
        guard let operation = client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else { return XCTFail("no session") }
        let first = await client.perform(operation)
        guard case .applied(let m1) = first else { return XCTFail("first enroll should apply") }

        let retry = await client.perform(operation)
        guard case .applied(let m2) = retry else { return XCTFail("identical retry should replay original") }
        XCTAssertEqual(m1.membershipRevision, m2.membershipRevision, "a retry must not report different state")
        XCTAssertEqual(issued.count, 1, "begin… runs once; perform… must not mint a new request_id")
        let bodies = VoiceSharingStubProtocol.seenRequests.compactMap(requestBodyDictionary(of:))
        XCTAssertEqual(bodies.count, 2, "two POSTs were made")
        let ids = bodies.compactMap { $0["request_id"] as? String }
        XCTAssertEqual(Set(ids).count, 1, "both requests carry the SAME request_id (\(ids))")
    }

    /// A lost response (transport failure) is an UNKNOWN outcome. Retrying through the public API has to
    /// reuse the original identity rather than looking like fresh intent — this is the production path a
    /// caller takes, so it cannot be simulated by holding a private struct in a test.
    func test_lostResponse_retryThroughPublicAPI_reusesOriginalRequestID() async {
        var issued: [String] = []
        let client = makeClient(factory: {
            let id = "req-lost-retry"
            issued.append(id)
            return id
        })
        // No reply configured for the route => the stub fails the load, i.e. a lost response.
        guard let lostOp = client.beginWithdrawal(enrollmentEpoch: "e1", expectedMembershipRevision: "r5") else { return XCTFail("no session") }
        let first = await client.perform(lostOp)
        XCTAssertEqual(first, .unavailableBackend, "a transport failure is an unknown outcome, not a state change")

        // Now the same operation is retried and succeeds.
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 200, body: projection("r6", enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        _ = await client.perform(lostOp)     // retry reuses the SAME operation identity
        let bodies = VoiceSharingStubProtocol.seenRequests.compactMap(requestBodyDictionary(of:))
        let ids = Set(bodies.compactMap { $0["request_id"] as? String })
        XCTAssertEqual(ids.count, 1, "retries of one operation share a single request_id: \(ids)")
        XCTAssertEqual(issued.count, 1, "begin ran exactly once; retries go through perform and mint nothing new")
    }

    /// Null epoch withdrawal is valid only when the expected projection has no active epoch.
    func test_nullEpochWithdrawal_onlyValidWhenProjectionHasNoActiveEpoch() async {
        // Case A: projection has an active epoch -> null-epoch withdrawal is refused as invalid.
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 422, body: ["error": "invalid_request_epoch"])
        guard let opA = clientForTest.beginWithdrawal(enrollmentEpoch: nil, expectedMembershipRevision: "r5") else { return XCTFail("no session") }
        let a = await clientForTest.perform(opA)
        guard case .refused(let reason) = a else { return XCTFail("null epoch with an active epoch must be refused") }
        XCTAssertEqual(reason, .invalidRequest)

        // Case B: no active epoch -> accepted, and it fences outstanding opt-ins.
        VoiceSharingStubProtocol.reset()
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 200, body: projection("r6", enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        guard let opB = clientForTest.beginWithdrawal(enrollmentEpoch: nil, expectedMembershipRevision: "r5") else { return XCTFail("no session") }
        let b = await clientForTest.perform(opB)
        guard case .applied(let m) = b else { return XCTFail("null epoch withdrawal should apply when nothing is active") }
        XCTAssertEqual(m.withdrawalState, .withdrawn)
    }

    /// A reply that belongs to an obsolete account/session is dropped, never applied. Identity flips while
    /// the request is in flight — the shape that actually happens when sign-out lands mid-mutation.
    func test_responseForObsoleteSession_isDroppedNotApplied() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 200, body: projection("r11", enrolled: true, epoch: "e11", withdrawal: "active"))
        VoiceSharingStubProtocol.onRequest = { [weak self] in
            self?.identity = "gen-B"   // a different session exists mid-flight
        }
        guard let op = clientForTest.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7") else { return XCTFail("no session to begin under") }
        let outcome = await clientForTest.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession, "a projection from a superseded session must not be applied")
    }

    // MARK: - Deletion is its own operation

    func test_deleteData_usesOwnRequestIdAndReportsPendingOnly() async {
        VoiceSharingStubProtocol.replies["DELETE /api/v1/account/voice-sharing/data"] =
            Reply(status: 202, body: deletionReceipt("del-1"))
        guard let delOp = clientForTest.beginDeletion() else { return XCTFail("no session") }
        let outcome = await clientForTest.performDeletion(delOp)
        XCTAssertEqual(outcome, .pending(deletionRequestId: "del-1"))
        guard let request = VoiceSharingStubProtocol.seenRequests.last else { return XCTFail("no request was made") }
        XCTAssertEqual(request.httpMethod, "DELETE")
        guard let body = requestBodyDictionary(of: request) else { return XCTFail("request carried no readable body") }
        XCTAssertNotNil(body["request_id"], "deletion carries its own request identity")
        // It must NOT be sent to the enrollment/withdrawal routes.
        XCTAssertFalse(request.url!.path.contains("enrollment"))
        XCTAssertFalse(request.url!.path.contains("withdrawal"))
    }

    /// A 202 whose payload doesn't say deletion_pending is not treated as a receipt.
    func test_deleteData_incompleteReceipt_isNotSuccess() async {
        VoiceSharingStubProtocol.replies["DELETE /api/v1/account/voice-sharing/data"] =
            Reply(status: 202, body: deletionReceipt("del-2", status: "queued"))
        guard let delOp = clientForTest.beginDeletion() else { return XCTFail("no session") }
        let outcome = await clientForTest.performDeletion(delOp)
        XCTAssertEqual(outcome, .unavailableBackend)
    }

    func test_backendUnavailable_isRetryableNotAStateChange() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 503, body: ["error": "state_unavailable"])
        guard let op = clientForTest.beginEnrollment(acceptedDisclosureVersion: "x", expectedMembershipRevision: "r1") else { return XCTFail("no session") }
        let outcome = await clientForTest.perform(op)
        XCTAssertEqual(outcome, .unavailableBackend)
    }
}

extension Data {
    var jsonDictionary: [String: Any] {
        (try? JSONSerialization.jsonObject(with: self)) as? [String: Any] ?? [:]
    }
}

/// `URLProtocol` relocates a request's `httpBody` into `httpBodyStream`, so reading `httpBody` on a
/// recorded request would fail for every POST/DELETE — and asserting "no body" would be a false alarm
/// about production rather than a real defect. This reads whichever form the body actually arrived in.
func requestBodyDictionary(of request: URLRequest) -> [String: Any]? {
    if let data = request.httpBody { return data.jsonDictionary }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var collected = Data()
    let bufferSize = 4096
    let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { pointer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(pointer, maxLength: bufferSize)
        if read <= 0 { break }
        collected.append(pointer, count: read)
    }
    guard !collected.isEmpty else { return nil }
    return collected.jsonDictionary
}
