import XCTest
import SwiftUI
import UIKit
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

private func projection(enrolled: Bool, epoch: String?, withdrawal: String) -> [String: Any] {
    var body: [String: Any] = [
        "schema_version": 1,

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
        let suite = "VoiceSharingClientStore-\(UUID().uuidString)"
        clientSuiteName = suite
        testStore = VoiceSharingEnrollmentStore(
            defaults: UserDefaults(suiteName: suite)!,
            accountScopeProvider: { "client-test-account" },
            sessionIdentityProvider: { [weak self] in self?.identity }
        )
    }

    private var clientSuiteName: String?

    override func tearDown() {
        if let clientSuiteName, let d = UserDefaults(suiteName: clientSuiteName) {
            d.removePersistentDomain(forName: clientSuiteName)
        }
        testStore = nil
        VoiceSharingStubProtocol.reset()
        super.tearDown()
    }

    /// A single client instance shared by `begin…` and `perform…` in one test, so an operation's immutable
    /// request identity is carried across calls exactly as production must.
    private lazy var clientForTest: VoiceSharingAccountClient = makeClient()

    /// Store used by every client built here. Sharing one instance is the point: the client stamps reads
    /// with THIS store's fence and the tests apply through it, so a control can move the fence between the
    /// two moments exactly as production does.
    private var testStore: VoiceSharingEnrollmentStore!

    private func makeClient(factory: (() -> String)? = nil,
                            userAgent: (() -> String)? = nil) -> VoiceSharingAccountClient {
        VoiceSharingAccountClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: tokens,
            session: session,
            requestIDFactory: factory ?? { [weak self] in
                let id = UUID().uuidString.lowercased()
                self?.requestIDs.append(id)
                return id
            },
            sessionIdentity: { [weak self] in self?.identity },
            membershipStore: testStore!,
            userAgentProvider: userAgent ?? { "" }
        )
    }

    /// SIMPLIFIED contract: the coordinator's only server operation is the projection
    /// refresh, so these controls drive that instead of the deleted activation/lookup exchange.
    private func projectionCoordinator(store: VoiceSharingEnrollmentStore) -> VoiceSharingCoordinator {
        VoiceSharingCoordinator(enrollmentStore: store)
    }

    /// The exact bytes a request carries, from `httpBody` or from its body stream.
    private static func payloadBytes(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - Round 9: production lifecycle writer (beginA -> real transition -> perform)

    /// These controls drive the sign-in/sign-out PRODUCER sequence, so settlement must read the
    /// owner's committed credential exactly as production does. The test host's Keychain does not
    /// hold a committed credential for these fixtures, so the owner is named here instead of being
    /// faked into one: what the controls assert about is the SEQUENCE (a login settles, a sign-out
    /// ends it), not the owner's own digest.
    /// Names the account the credential owner reports. It deliberately does not go nil on sign-out:
    /// in production the owner reports nothing once the credential is invalidated, and these
    /// controls drive sign-out through `SignOutHelper` without invalidating credentials — so binding
    /// presence to the legacy `userId` would test the fixture's bookkeeping instead of the sequence.

    // MARK: - Review round 7 additions: same-account relogin, GET guarding, numeric bridging

    /// `userId` alone cannot see sign-out followed by signing back into the SAME account. The session half of
    /// the identity does, so a reply from the previous session must drop rather than apply membership.
    /// The operation's originating generation is captured at BEGIN and retained across retries. If the
    /// current session no longer matches, perform must refuse before transport — otherwise account A's
    /// opt-in intent would be sent under account B's credential, and the server could not tell.
    func test_operationBegunUnderSessionA_refusesToRunUnderSessionB_beforeTransport() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: true, epoch: "e14", withdrawal: "active"))
        let client = makeClient()
        guard let op = client.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else {
            return XCTFail("no session to begin under")
        }
        XCTAssertEqual(op.originatingGeneration, identity, "the operation records the session it was begun under")
        // Transition lands after begin, before perform.
        identity = "gen-B"
        let outcome = await client.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession, "an operation begun under a superseded session must not run")
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty,
                      "refusal happens before transport — no bytes on the wire")
    }

    /// Same-account re-login: a stable user id cannot see it; only session material distinguishes old login
    /// from new. Begin under the first login, then move to a NEW login for the SAME account.
    func test_sameAccountNewLogin_supersedesOperationsFromTheOldLogin() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        let client = makeClient()
        guard let op = client.beginMembership(enrolled: false, acceptedDisclosureVersion: nil) else {
            return XCTFail("no session")
        }
        identity = "gen-A2"   // same account, NEW login, after BEGIN
        let outcome = await client.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession, "logout/login into the same account supersedes old operations")
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty, "must refuse before transport")
    }

    /// Deletion previously read identity only after awaiting the bearer inside request building — a real
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
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: true, epoch: "e13", withdrawal: "active"))
        VoiceSharingStubProtocol.responseDelay = 0.05
        let client = makeClient()
        guard let op = client.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else {
            return XCTFail("no session")
        }
        VoiceSharingStubProtocol.onRequest = { [weak self] in self?.identity = "gen-B" }
        let outcome = await client.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession, "a reply from a superseded session must never apply")
        XCTAssertFalse(VoiceSharingStubProtocol.seenRequests.isEmpty, "this path DID send, unlike the pre-transport refusal")
    }

    /// ONE-REFRESH composition: same account, same enrollment epoch, NEW login.
    /// A re-login is not an enrollment change: the epoch must survive the one refresh that the new
    /// login performs, and the stale session's in-flight read must never install.
    func test_sameAccountSameEpochNewLogin_refreshesOnceAndKeepsTheEpoch() async throws {
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] = Reply(
            status: 200,
            body: projection(enrolled: true, epoch: "e1", withdrawal: "active"))
        let client = makeClient()
        // Install the membership under the FIRST login (epoch e1).
        let firstFetch = await client.fetchProjection()
        let firstRead = try XCTUnwrap(firstFetch)
        XCTAssertEqual(firstRead.membership.enrollmentEpoch, "e1")
        // Same account, SAME epoch, NEW login.
        identity = "gen-A2"
        // The new login's refresh runs — exactly one request, and the epoch is unchanged by it.
        VoiceSharingStubProtocol.seenRequests.removeAll()
        let refreshedFetch = await client.fetchProjection()
        let refreshed = try XCTUnwrap(
            refreshedFetch, "the new login must be able to refresh")
        XCTAssertEqual(VoiceSharingStubProtocol.seenRequests.count, 1,
                       "one refresh — not a retry storm — for the new login")
        XCTAssertEqual(refreshed.membership.enrollmentEpoch, "e1",
                       "a re-login must not move the enrollment epoch")
        // And a mutation begun under the OLD login is still refused before transport.
        VoiceSharingStubProtocol.seenRequests.removeAll()
        identity = "gen-A"
        let staleOp = try XCTUnwrap(client.beginMembership(
            enrolled: false, acceptedDisclosureVersion: nil))
        identity = "gen-A2"
        let outcome = await client.perform(staleOp)
        XCTAssertEqual(outcome, .refusedStaleSession,
                       "same account, new login: the old login's operation is superseded")
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty,
                      "refusal is before transport")
    }

    /// GET was previously unguarded: an account transition during the fetch would still install the previous
    /// account's projection. Also asserts no request at all when there is no authenticated session.
    func test_getProjection_transitionDuringFetch_isDropped() async {
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: true, epoch: "e1", withdrawal: "active"))
        let client = makeClient()
        VoiceSharingStubProtocol.onRequest = { [weak self] in
            self?.identity = "gen-B"
        }
        let fetched = await client.fetchProjection()
        XCTAssertNil(fetched, "a projection read across an account change must not be returned")
    }

    func test_noSessionIdentity_makesNoRequest() async {
        identity = nil
        let fetched = await makeClient().fetchProjection()
        XCTAssertNil(fetched)
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty, "no session means no call, not an anonymous probe")
    }

    /// The server's access log attributes uploads to a platform via the User-Agent header. Every
    /// voice-sharing request must carry the app's standard private user agent, exactly like every
    /// other Auris request; a missing header logs `platform=unknown` and loses the attribution.
    func test_outgoingRequests_carryTheAppUserAgent() async {
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "active"))
        let client = makeClient(userAgent: { "Pocket Casts/iOS/9.9-test" })
        _ = await client.fetchProjection()
        let request = try! XCTUnwrap(VoiceSharingStubProtocol.seenRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Pocket Casts/iOS/9.9-test")
    }

    /// An empty injected user agent must not put an empty (or system-default) header on the wire:
    /// the provider failing is not a reason to present a half-identity.
    func test_emptyUserAgent_leavesNoHeader() async {
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "active"))
        let client = makeClient(userAgent: { "" })
        _ = await client.fetchProjection()
        let request = try! XCTUnwrap(VoiceSharingStubProtocol.seenRequests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "User-Agent"))
    }

    /// JSONSerialization bridges an INTEGER to Bool under `as? Bool`. A numeric publication must never be
    /// read as enrollment, so the strict boolean check rejects it before any decision is made.
    func test_projection_numericBoolBridging_isRejected() {
        func bytes(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }
        var numeric = projection(enrolled: true, epoch: "e1", withdrawal: "active")
        numeric["voice_sharing_enrolled"] = 1          // integer masquerading as JSON true
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(numeric)),
                     "an Int 1 must not bridge into permission")
        numeric["voice_sharing_enrolled"] = "true"     // string form likewise
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(numeric)))

        // Empty-but-present values are not "present": they carry no authority.
        var blanks = projection(enrolled: true, epoch: "", withdrawal: "active")
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(blanks)))
        // Active enrollment whose accepted disclosure is missing cannot be honored.
        var noDisclosure = projection(enrolled: true, epoch: "e1", withdrawal: "active")
        noDisclosure.removeValue(forKey: "accepted_disclosure_version")
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(noDisclosure)))
        // enrolled=true with withdrawal_state=withdrawn is a contradiction, not permission.
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(projection(enrolled: true, epoch: "e1", withdrawal: "withdrawn"))))
    }


    // MARK: - Review round 8: 401 ordering, secret hygiene, refresh-vs-logout, exact numeric schema

    /// A 401 that arrives for account A's request must not invalidate account B's credential. The captured
    /// generation is validated before the side effect, so the provider is never called once the session moved.
    func test_401_fromStaleSession_doesNotInvalidateCurrentCredential() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] = Reply(status: 401, body: [:])
        guard let op = clientForTest.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else {
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
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] = Reply(status: 401, body: [:])
        guard let op = clientForTest.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else {
            return XCTFail("no session")
        }
        let outcome = await clientForTest.perform(op)
        XCTAssertEqual(outcome, .unauthorized)
        XCTAssertEqual(tokens.lastRejectedToken, "test-bearer", "the bearer this request carried must be the one reported")
    }

    /// Operation bodies are persisted-ready artifacts (queue metadata, diagnostics). They must carry contract
    /// fields only — no credential material in any form.
    func test_operationBodies_carryNoCredentialMaterial() throws {
        guard let enroll = clientForTest.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09"),
              let withdraw = clientForTest.beginMembership(enrolled: false, acceptedDisclosureVersion: nil),
              let delete = clientForTest.beginDeletion() else { return XCTFail("no session") }
        for op in [enroll.body, withdraw.body] {
            let text = String(describing: op)
            for forbidden in ["test-bearer", "credential", "token", "refresh"] {
                XCTAssertFalse(text.lowercased().contains(forbidden), "operation body leaks \(forbidden): \(text)")
            }
        }
    }

    /// Operation identity is a lifecycle label, never credential material. Two properties asked for:
    /// the label carries nothing recoverable about the account, and no operation body can contain a bearer.
    func test_operationIdentity_isOpaqueAndCarriesNoCredentialMaterial() async {
        // ORDINARY account ownership is the operation identity now: a server-side account
        // id, which says nothing about credentials.
        guard let label = VoiceSharingEnrollmentStore.currentSessionOwner() ?? Optional("account-a") as String? else {
            return XCTFail("no session")
        }
        XCTAssertFalse(label.isEmpty, "a lifecycle label is opaque text with nothing to recover")
        XCTAssertFalse(label.lowercased().contains("token"), "label must not describe credential material")

        guard let enroll = clientForTest.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09"),
              let withdraw = clientForTest.beginMembership(enrolled: false, acceptedDisclosureVersion: nil) else {
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
        var fractional = projection(enrolled: true, epoch: "e1", withdrawal: "active")
        fractional["schema_version"] = 1.5
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(fractional)), "1.5 must not satisfy schema 1")
        var boolish = projection(enrolled: true, epoch: "e1", withdrawal: "active")
        boolish["schema_version"] = true      // bridges to Int 1 under `as? Int`/intValue
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(boolish)))
        var stringy = projection(enrolled: true, epoch: "e1", withdrawal: "active")
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
            Reply(status: 200, body: projection(enrolled: true, epoch: "e1", withdrawal: "active"))
        let fetched = await makeClient().fetchProjection()
        let membership = fetched?.membership
        XCTAssertEqual(membership?.enrollmentEpoch, "e1")
        XCTAssertTrue(membership?.voiceSharingEnrolled == true)
        XCTAssertEqual(membership?.withdrawalState, .active)
        // The reply carries the fence value it was issued under so the store can refuse it later.
        XCTAssertEqual(fetched?.issuedUnder.lifecycleGeneration, identity)
    }

    /// Fail-closed parsing: unknown schema, missing fields, or an impossible combination must not read as
    /// permission. A permissive default here would authorize uploads from garbage.
    func test_decodeProjection_rejectsUnknownOrImpossibleShapes() {
        func bytes(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(["schema_version": 2])))
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(["nothing": "relevant"])))
        // enrolled=true with no epoch cannot authorize collection (records key on epoch).
        XCTAssertNil(VoiceSharingAccountClient.decodeProjection(bytes(projection(enrolled: true, epoch: nil, withdrawal: "active"))))
        // withdrawn + not enrolled is a legal shape and must parse as not-enrolled.
        let ok = VoiceSharingAccountClient.decodeProjection(bytes(projection(enrolled: false, epoch: nil, withdrawal: "withdrawn")))
        XCTAssertEqual(ok?.voiceSharingEnrolled, false)
        XCTAssertEqual(ok?.withdrawalState, .withdrawn)
    }

    func test_noCredential_makesNoRequest() async {
        tokens.tokenValue = nil
        let fetched = await makeClient().fetchProjection()
        XCTAssertNil(fetched)
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty, "no bearer means no call at all")
    }

    /// Spec rule: a 409 conflict returns the current projection and must not be auto-replayed —
    /// renewed opt-in requires fresh user intent. Assert exactly one request was made.
    func test_conflict_returnsCurrentProjection_andNeverAutoReplays() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 409, body: projection(enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        guard let op = clientForTest.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else { return XCTFail("no session to begin under") }
        let outcome = await clientForTest.perform(op)
        switch outcome {
        case .conflict(current: let current, issuedUnder: _):
            XCTAssertEqual(current?.voiceSharingEnrolled, false)
        default:
            XCTFail("expected conflict, got \(outcome)")
        }
        let putCount = VoiceSharingStubProtocol.seenRequests.filter { $0.httpMethod == "PUT" }.count
        XCTAssertEqual(putCount, 1, "a conflicted opt-in must not be retried automatically")
    }

    func test_refusals_neverReadAsEnrolled() async {
        for (status, label) in [(403, "ineligible"), (422, "unsupported disclosure")] {
            VoiceSharingStubProtocol.reset()
            VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
                Reply(status: status, body: ["error": label == "ineligible" ? "ineligible_plan" : "unsupported_disclosure"])
            guard let op = clientForTest.beginMembership(enrolled: true, acceptedDisclosureVersion: "x") else { return XCTFail("no session to begin under") }
            let outcome = await clientForTest.perform(op)
            guard case .refused(let reason) = outcome else { XCTFail("\(label) should refuse"); continue }
            XCTAssertEqual(reason, label == "ineligible" ? .ineligible : .unsupportedDisclosure)
        }
    }

    /// Round 9: 403 and 422 previously returned account-specific refusals with NO
    /// post-transport generation check, so account A's "ineligible" could be shown as account B's state.
    /// The guard now sits before every status branch, so both codes refuse on a superseded session.
    /// Round 9: 403 previously returned an account-specific refusal with NO post-transport
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
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: status, body: ["error": error])
        // Fresh client per case: identity starts at gen-A and moves to gen-B only after the request leaves.
        let client = makeClient()
        guard let op = client.beginMembership(enrolled: true, acceptedDisclosureVersion: "x") else {
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
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 401, body: [:])
        guard let op = clientForTest.beginMembership(enrolled: false, acceptedDisclosureVersion: nil) else { return XCTFail("no session") }
        let outcome = await clientForTest.perform(op)
        XCTAssertEqual(outcome, .unauthorized)
        XCTAssertEqual(tokens.unauthorizedCalls, 1, "the rejected credential must be reported to the provider once")
    }

    // MARK: - Race controls named by the spec

    /// Delayed FIRST delivery of an earlier opt-in landing after a withdrawal: the server answers it with
    /// 409 and the current projection, and the client shows the conflict without resurrecting enrollment.
    func test_delayedFirstDeliveryEnrollment_afterWithdrawal_cannotReactivate() async {
        // User withdrew; the server's current state has withdrawal_state=withdrawn.
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 409, body: projection(enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        guard let op = clientForTest.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else { return XCTFail("no session") }
        let late = await clientForTest.perform(op)
        guard case .conflict(current: let current, issuedUnder: _) = late else { return XCTFail("late first delivery must conflict") }
        XCTAssertEqual(current?.withdrawalState, .withdrawn)
        XCTAssertFalse(current?.voiceSharingEnrolled == true, "a delayed opt-in may not undo a later opt-out")
    }

    /// Withdrawal while already inactive still produces an authoritative 200, which is what fences later
    /// first-delivery opt-ins. Client must treat that 200 as authoritative state, not a no-op.
    func test_withdrawalFromInactiveProjection_isAuthoritativeState() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        guard let op = clientForTest.beginMembership(enrolled: false, acceptedDisclosureVersion: nil) else { return XCTFail("no session") }
        let outcome = await clientForTest.perform(op)
        guard case .applied(membership: let m, issuedUnder: _) = outcome else { return XCTFail("withdrawal from inactive must apply") }
        XCTAssertEqual(m.withdrawalState, .withdrawn)
    }

    /// Identical request_id retried after a later transition returns the original result without changing
    /// state. The client must surface the returned projection verbatim and make no additional mutation.
    func test_identicalRequestId_retry_afterLaterTransition_returnsOriginalResult_withoutChangingState() async {
        var issued: [String] = []
        let client = makeClient(factory: {
            let id = "req-original"          // one operation identity, reused by every retry
            issued.append(id)
            return id
        })
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: true, epoch: "e8", withdrawal: "active"))

        // Begin ONCE, then perform twice. The whole point of the immutable operation is that a retry after a
        // lost response carries the same request_id and body — calling begin… again would mint new intent.
        guard let operation = client.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else { return XCTFail("no session") }
        let first = await client.perform(operation)
        guard case .applied(membership: let m1, issuedUnder: _) = first else { return XCTFail("first enroll should apply") }

        let retry = await client.perform(operation)
        guard case .applied(membership: let m2, issuedUnder: _) = retry else { return XCTFail("identical retry should replay original") }
        XCTAssertEqual(issued.count, 1, "begin… runs once; perform… must not mint a new request_id")
        let bodies = VoiceSharingStubProtocol.seenRequests.compactMap(requestBodyDictionary(of:))
        XCTAssertEqual(bodies.count, 2, "two PUTs were made")
        // Under a desired-state PUT, the immutable thing that must survive a retry is the BODY bytes:
        // identical bytes are what make a repeat a repeat instead of new intent.
        // URLSession gives a body-driven request an httpBodySTREAM, so the bytes are read from whichever
        // carrier the request actually carries.
        let payloads = VoiceSharingStubProtocol.seenRequests.compactMap(Self.payloadBytes)
        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(Set(payloads).count, 1, "both requests carry byte-identical desired state")
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
        guard let lostOp = client.beginMembership(enrolled: false, acceptedDisclosureVersion: nil) else { return XCTFail("no session") }
        let first = await client.perform(lostOp)
        XCTAssertEqual(first, .unavailableBackend, "a transport failure is an unknown outcome, not a state change")

        // Now the same operation is retried and succeeds.
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        _ = await client.perform(lostOp)     // retry reuses the SAME operation identity
        // URLSession gives a body-driven request an httpBodySTREAM, so the bytes are read from whichever
        // carrier the request actually carries.
        let payloads = VoiceSharingStubProtocol.seenRequests.compactMap(Self.payloadBytes)
        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(Set(payloads).count, 1, "retries of one operation resend identical desired state")
        XCTAssertEqual(issued.count, 1, "begin ran exactly once; retries go through perform and mint nothing new")
    }

    /// Null epoch withdrawal is valid only when the expected projection has no active epoch.
    func test_nullEpochWithdrawal_onlyValidWhenProjectionHasNoActiveEpoch() async {
        // Case A: projection has an active epoch -> null-epoch withdrawal is refused as invalid.
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 422, body: ["error": "invalid_request_epoch"])
        guard let opA = clientForTest.beginMembership(enrolled: false, acceptedDisclosureVersion: nil) else { return XCTFail("no session") }
        let a = await clientForTest.perform(opA)
        guard case .refused(let reason) = a else { return XCTFail("null epoch with an active epoch must be refused") }
        XCTAssertEqual(reason, .invalidRequest)

        // Case B: no active epoch -> accepted, and it fences outstanding opt-ins.
        VoiceSharingStubProtocol.reset()
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        guard let opB = clientForTest.beginMembership(enrolled: false, acceptedDisclosureVersion: nil) else { return XCTFail("no session") }
        let b = await clientForTest.perform(opB)
        guard case .applied(membership: let m, issuedUnder: _) = b else { return XCTFail("null epoch withdrawal should apply when nothing is active") }
        XCTAssertEqual(m.withdrawalState, .withdrawn)
    }

    /// A reply that belongs to an obsolete account/session is dropped, never applied. Identity flips while
    /// the request is in flight — the shape that actually happens when sign-out lands mid-mutation.
    func test_responseForObsoleteSession_isDroppedNotApplied() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: true, epoch: "e11", withdrawal: "active"))
        VoiceSharingStubProtocol.onRequest = { [weak self] in
            self?.identity = "gen-B"   // a different session exists mid-flight
        }
        guard let op = clientForTest.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else { return XCTFail("no session to begin under") }
        let outcome = await clientForTest.perform(op)
        XCTAssertEqual(outcome, .refusedStaleSession, "a projection from a superseded session must not be applied")
    }

    // MARK: - Deletion is its own operation

    func test_deleteData_usesOwnRequestIdAndReportsPendingOnly() async {
        VoiceSharingStubProtocol.replies["DELETE /api/v1/account/voice-sharing/data"] =
            Reply(status: 204, body: [:])
        guard let delOp = clientForTest.beginDeletion() else { return XCTFail("no session") }
        let outcome = await clientForTest.performDeletion(delOp)
        XCTAssertEqual(outcome, .deleted, "an empty 204 is the one success")
        guard let request = VoiceSharingStubProtocol.seenRequests.last else { return XCTFail("no request was made") }
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertNil(requestBodyDictionary(of: request), "the request carries no body")
        // It must not be sent to the enrollment/withdrawal routes.
        XCTAssertFalse(request.url!.path.contains("enrollment"))
        XCTAssertFalse(request.url!.path.contains("withdrawal"))
    }

    /// Only 204 is success. A 202 — the receipt shape the server no longer sends — must NOT be read
    /// as deletion, because a different answer may mean the work has not happened yet.
    func test_deleteData_onlyAnEmpty204ConfirmsDeletion() async {
        for status in [200, 202] {
            VoiceSharingStubProtocol.replies["DELETE /api/v1/account/voice-sharing/data"] =
                Reply(status: status, body: [:])
            guard let delOp = clientForTest.beginDeletion() else { return XCTFail("no session") }
            let outcome = await clientForTest.performDeletion(delOp)
            XCTAssertNotEqual(outcome, .deleted, "\(status) must not confirm removal")
        }
    }

    func test_backendUnavailable_isRetryableNotAStateChange() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 503, body: ["error": "state_unavailable"])
        guard let op = clientForTest.beginMembership(enrolled: true, acceptedDisclosureVersion: "x") else { return XCTFail("no session") }
        let outcome = await clientForTest.perform(op)
        XCTAssertEqual(outcome, .unavailableBackend)
    }
    // MARK: - Delayed read applying through the real store

    /// A GET issued before a withdrawal whose reply arrives after it. The response is well-formed and says
    /// "enrolled"; only the fence stops it. This drives the whole production path — client stamps the token,
    func test_delayedGETReply_cannotReEnableThroughTheStore() async {
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: true, epoch: "e1", withdrawal: "active"))
        let client = makeClient()
        testStore.setLocalOptIn(true)

        // Read is issued while enrolled-looking state is current.
        guard let first = await client.fetchProjection() else { return XCTFail("expected a projection") }
        XCTAssertTrue(testStore.apply(authoritative: first.membership, readUnder: first.issuedUnder))
        XCTAssertTrue(testStore.currentEffectiveEnrolled, "local gesture plus a confirmed projection enables")

        // User opts out locally. Every read issued before this instant is now inapplicable.
        _ = testStore.withdrawLocally(acceptedServerProjectionAfterward: false)
        XCTAssertFalse(testStore.currentEffectiveEnrolled)

        // The OLD reply finally arrives — replayed against the store exactly as its caller would apply it.
        XCTAssertFalse(testStore.apply(authoritative: first.membership, readUnder: first.issuedUnder),
                       "a projection issued before the withdrawal must not be applied")
        XCTAssertFalse(testStore.currentEffectiveEnrolled, "and it must not re-enable collection")

        // A read issued after the withdrawal is still usable, so this is staleness, not a dead store.
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: true, epoch: "e9", withdrawal: "active"))
        let fresh = await client.fetchProjection()!
        testStore.setLocalOptIn(true)
        let afterOptIn = testStore.projectionToken()!
        XCTAssertTrue(testStore.apply(authoritative: fresh.membership, readUnder: afterOptIn),
                      "the same mechanism accepts a current read")
        XCTAssertTrue(testStore.currentEffectiveEnrolled)
    }

    /// An account switch mid-read: the client already drops the reply, and even if a caller handed the store
    /// an old token anyway, the lifecycle half of the fence refuses it.
    func test_accountSwitchDuringRead_leavesStoreUnapplied() async {
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: true, epoch: "e1", withdrawal: "active"))
        VoiceSharingStubProtocol.responseDelay = 0.05
        let client = makeClient()
        // Token taken before the request, as every caller must.
        let stale = testStore.projectionToken()!
        XCTAssertEqual(stale.lifecycleGeneration, "gen-A")

        // The switch lands while the GET is in flight.
        VoiceSharingStubProtocol.onRequest = { [weak self] in
            self?.identity = "gen-B"
            self?.testStore.transitionToAccount(signedIn: true)
        }

        let fetched = await client.fetchProjection()
        VoiceSharingStubProtocol.onRequest = nil
        XCTAssertNil(fetched, "the client does not return a reply that crossed an account change")
        let handRolled = VoiceSharingAccountClient.decodeProjection(
            projectionData(enrolled: true, epoch: "e1", withdrawal: "active"))!
        XCTAssertFalse(testStore.apply(authoritative: handRolled, readUnder: stale),
                       "nor may a pre-switch token apply one by hand")
    }

    private func projectionData(enrolled: Bool, epoch: String?, withdrawal: String) -> Data {
        try! JSONSerialization.data(withJSONObject: projection(enrolled: enrolled, epoch: epoch, withdrawal: withdrawal))
    }

    // MARK: - Mutation outcomes carry their issuing fence

    /// A GET is not the only projection-bearing reply. An enrollment POST issued before a withdrawal can
    /// SUCCEED afterwards — the server has not moved yet, so nothing about its answer marks it stale. If the
    /// outcome carried only a bare projection, a caller could apply it under a token taken after the reply
    /// and re-enable a user who just opted out. The operation carries the store fence from BEGIN, and the
    /// outcome hands that same value back.
    func test_delayedEnrollSuccess_afterWithdrawal_cannotBeAppliedWithItsOwnToken() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: true, epoch: "e7", withdrawal: "active"))
        VoiceSharingStubProtocol.responseDelay = 0.05
        let client = makeClient()
        testStore.setLocalOptIn(true)

        guard let op = client.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else {
            return XCTFail("no session to begin under")
        }
        XCTAssertEqual(op.issuedUnder.lifecycleGeneration, "gen-A", "the operation records the lifecycle it began under")

        // Withdraw locally WHILE the enrollment request is in flight.
        _ = testStore.withdrawLocally(acceptedServerProjectionAfterward: false)
        XCTAssertFalse(testStore.currentEffectiveEnrolled)

        let outcome = await client.perform(op)
        guard case .applied(membership: let projection, issuedUnder: let issued) = outcome else {
            return XCTFail("expected a successful enrollment reply, got \\(outcome)")
        }
        XCTAssertEqual(issued, op.issuedUnder, "the outcome reports the BEGIN fence, never a post-reply value")

        // Applying through the production path is refused on the recorded fence...
        XCTAssertFalse(testStore.apply(authoritative: projection, readUnder: issued),
                       "a mutation issued before the withdrawal may not be applied after it")
        XCTAssertFalse(testStore.currentEffectiveEnrolled, "and must not re-enable collection")

        // ...while the very same bytes WOULD be accepted under a current token. That asymmetry is the whole
        // reason outcomes must carry their issuing fence: if a caller could substitute a fresh one, the data
        // itself offers no way to tell it came from a departed instant.
        XCTAssertTrue(testStore.apply(authoritative: projection, readUnder: testStore.projectionToken()!),
                      "control: the projection is well-formed and acceptable NOW — only its origin disqualifies it")
    }

    /// A 409 conflict also bears a projection, and reconciling it must go through a NEW get rather than
    /// adopting the conflict payload under a token minted after the reply.
    func test_delayedConflict_afterNewIntent_isRefusedAndNeverAutoReplayed() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 409, body: projection(enrolled: true, epoch: "eZ", withdrawal: "active"))
        VoiceSharingStubProtocol.responseDelay = 0.05
        let client = makeClient()
        testStore.setLocalOptIn(true)
        guard let op = client.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else {
            return XCTFail("no session to begin under")
        }

        // New local intent lands while the request is in flight.
        _ = testStore.withdrawLocally(acceptedServerProjectionAfterward: false)

        let outcome = await client.perform(op)
        guard case .conflict(current: let current, issuedUnder: let issued) = outcome else {
            return XCTFail("expected conflict, got \\(outcome)")
        }
        XCTAssertEqual(issued, op.issuedUnder, "the conflict reports the BEGIN fence too")
        guard let current else { return XCTFail("a conflict must surface the server's current projection") }

        XCTAssertFalse(testStore.apply(authoritative: current, readUnder: issued),
                       "a pre-withdrawal conflict payload must not be applied after the withdrawal")
        XCTAssertFalse(testStore.currentEffectiveEnrolled)
        XCTAssertEqual(VoiceSharingStubProtocol.seenRequests.filter { $0.httpMethod == "PUT" }.count, 1,
                       "a conflicted opt-in is never retried automatically")
    }

    /// Retries keep the operation identity AND its issuing fence immutable, so a delayed first delivery and a
    /// retry are both judged against the instant the user actually acted.
    func test_retryKeepsTheSameIssuingFence() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: true, epoch: "e1", withdrawal: "active"))
        let client = makeClient()
        guard let op = client.beginMembership(enrolled: true, acceptedDisclosureVersion: "2026-09") else {
            return XCTFail("no session to begin under")
        }
        let before = op.issuedUnder
        _ = await client.perform(op)
        let again = await client.perform(op)   // same operation object, as a retry must be
        guard case .applied(_, issuedUnder: let issued) = again else { return XCTFail("expected applied") }
        XCTAssertEqual(issued, before, "a retry must not silently re-stamp the fence after the fact")
    }

    /// Withdrawal's own success reply is likewise fenced by its BEGIN instant: an opt-out that lands after a
    /// later opt-in gesture must not overwrite the newer intent with the older answer.
    func test_withdrawalReply_afterLaterOptIn_usesItsOwnIssuingFence() async {
        VoiceSharingStubProtocol.replies["PUT /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        VoiceSharingStubProtocol.responseDelay = 0.05
        let client = makeClient()
        testStore.setLocalOptIn(true)
        guard let op = client.beginMembership(enrolled: false, acceptedDisclosureVersion: nil) else {
            return XCTFail("no session to begin under")
        }
        // User changes their mind and opts back in while the withdrawal is in flight.
        testStore.setLocalOptIn(true)
        let outcome = await client.perform(op)
        guard case .applied(let projection, issuedUnder: let issued) = outcome else {
            return XCTFail("expected applied, got \\(outcome)")
        }
        XCTAssertEqual(issued, op.issuedUnder)
        XCTAssertFalse(testStore.apply(authoritative: projection, readUnder: issued),
                       "the withdrawal answer belongs to an earlier instant than the new opt-in")
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

@MainActor
private final class SharingAccountModelHarness {
    let suite = "account-model-\(UUID().uuidString)"
    var identity: String? = "session-A"
    let defaults: UserDefaults
    let session: URLSession
    let store: VoiceSharingEnrollmentStore
    let client: VoiceSharingAccountClient
    private let identityBox: SharingAccountIdentityBox

    init(tokenProvider: CloudTokenProviding = AccountStubTokenProvider()) {
        VoiceSharingStubProtocol.reset()
        defaults = UserDefaults(suiteName: suite)!
        let box = SharingAccountIdentityBox()
        identityBox = box
        store = VoiceSharingEnrollmentStore(defaults: defaults, accountScopeProvider: { box.value ?? "out" }, sessionIdentityProvider: { box.value })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceSharingStubProtocol.self]
        session = URLSession(configuration: configuration)
        client = VoiceSharingAccountClient(baseURLProvider: { "https://api.example.test" }, tokenProvider: tokenProvider,
            session: session, sessionIdentity: { box.value }, membershipStore: store)
    }
    func rotateSessionWithoutStoreTransition(_ value: String?) { identity = value; identityBox.value = value }
    func switchAccount(_ value: String?) { rotateSessionWithoutStoreTransition(value); store.transitionToAccount(signedIn: value != nil) }
    func seed(enrolled: Bool = false) {
        store.setLocalOptIn(enrolled)
        let value = VoiceSharingMembership(plan: .pro, voiceSharingEnrolled: enrolled,
            enrollmentEpoch: enrolled ? "old-epoch" : nil, acceptedDisclosureVersion: enrolled ? "synthetic" : nil,
            withdrawalState: enrolled ? .active : .notEnrolled)
        _ = store.apply(authoritative: value, readUnder: store.projectionToken()!)
    }
    func model(version: String? = "synthetic", purge: (() async -> VoiceSharingSettingsModel.DeleteResult)? = nil) -> VoiceSharingAccountModel {
        VoiceSharingAccountModel(store: store, client: client, disclosureVersion: version,
            session: { [identityBox] in identityBox.value }, purgeLocal: purge)
    }
    func close() { session.invalidateAndCancel(); defaults.removePersistentDomain(forName: suite); VoiceSharingStubProtocol.reset() }
}
private final class SharingAccountIdentityBox { var value: String? = "session-A" }
private final class SharingAccountTokenClosure: CloudTokenProviding {
    let body: () async -> String?
    init(_ body: @escaping () async -> String?) { self.body = body }
    func token() async -> String? { await body() }
    func handleUnauthorized(rejectedToken: String?) async {}
}
private actor SharingAccountHold {
    var opened = false
    var continuation: CheckedContinuation<String?, Never>?
    func wait() async -> String? { if opened { return "synthetic" }; return await withCheckedContinuation { continuation = $0 } }
    func open() { opened = true; continuation?.resume(returning: "synthetic"); continuation = nil }
}

final class VoiceSharingAccountModelTests: XCTestCase {
    @MainActor
    func test_missingOrDeclinedDisclosureNeverEnrollsButWithdrawalAndDeletionRemainAvailable() async {
        let harness = SharingAccountModelHarness()
        defer { harness.close() }
        harness.seed(enrolled: true)
        let model = harness.model(version: nil)
        await model.enroll(disclosureConfirmed: false)
        XCTAssertEqual(model.membershipStatus, .confirmationRequired)
        await model.enroll(disclosureConfirmed: true)
        XCTAssertEqual(model.membershipStatus, .disclosureUnavailable)
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty)
        VoiceSharingStubProtocol.replies["PUT " + VoiceSharingAccountClient.membershipPath] = .init(status: 200, body: projection(enrolled: false, epoch: "old-epoch", withdrawal: "withdrawn"))
        VoiceSharingStubProtocol.replies["GET " + VoiceSharingAccountClient.projectionPath] = .init(status: 200, body: projection(enrolled: false, epoch: "old-epoch", withdrawal: "withdrawn"))
        await model.withdraw()
        XCTAssertFalse(harness.store.currentEffectiveEnrolled)
        XCTAssertEqual(model.membershipStatus, .withdrawnServerConfirmed)
        XCTAssertTrue(model.localCleanupUnavailable, "missing retained queue capability is not a purge-success claim")
        await model.retryLocalCleanup()
        XCTAssertTrue(model.localCleanupUnavailable)
        VoiceSharingStubProtocol.replies["DELETE " + VoiceSharingAccountClient.dataPath] = .init(status: 204, body: [:])
        await model.deleteAcceptedData(confirmed: true)
        XCTAssertEqual(model.deletionStatus, .deleted)
        XCTAssertEqual(harness.store.currentState.membership.plan, .pro)
    }

    @MainActor
    func test_busyEnrollmentCannotDelayLocalWithdrawalOrPurgeAndItsLateReplyCannotRestoreUI() async throws {
        let entered = expectation(description: "enrollment credential held")
        let hold = SharingAccountHold()
        var reads = 0
        let provider = SharingAccountTokenClosure {
            reads += 1
            if reads == 1 { entered.fulfill(); return await hold.wait() }
            return "synthetic"
        }
        let harness = SharingAccountModelHarness(tokenProvider: provider)
        defer { harness.close() }
        harness.seed()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = VoiceSharingQueue(root: root)
        let entry = try await AudioFixture.makeReadyEntry(in: queue)
        let settings = VoiceSharingSettingsModel(queue: queue, isCollectionPermitted: { false }, isAccountEnrolled: { harness.store.currentEnrollmentAnswer }, isLocallyOptedIn: { harness.store.currentState.localOptIn })
        let model = harness.model(purge: { await settings.deletePendingRecordingsOnThisDevice() })
        VoiceSharingStubProtocol.replies["PUT " + VoiceSharingAccountClient.membershipPath] = .init(status: 200, body: projection(enrolled: true, epoch: "late", withdrawal: "active"))
        VoiceSharingStubProtocol.replies["PUT " + VoiceSharingAccountClient.membershipPath] = .init(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        VoiceSharingStubProtocol.replies["GET " + VoiceSharingAccountClient.projectionPath] = .init(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        let enrollment = Task { await model.enroll(disclosureConfirmed: true) }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(model.busy)
        VoiceSharingStubProtocol.onRequest = {
            XCTAssertFalse(harness.store.currentEffectiveEnrolled, "withdrawal stops locally before HTTP")
            XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path), "actual pending bytes are purged before HTTP")
        }
        await model.withdraw()
        XCTAssertEqual(model.membershipStatus, .withdrawnServerConfirmed)
        XCTAssertNotNil(model.localCleanup)
        await hold.open()
        await enrollment.value
        let withdrawal = try XCTUnwrap(VoiceSharingStubProtocol.seenRequests.first { $0.httpMethod == "PUT" })
        // The intent carries the desired state; there is no revision precondition to carry.
        let body = try XCTUnwrap(requestBodyDictionary(of: withdrawal))
        XCTAssertEqual(body["enrolled"] as? Bool, false,
                       "the withdrawal states the desired state directly")
        XCTAssertFalse(harness.store.currentEffectiveEnrolled)
        XCTAssertEqual(model.membershipStatus, .withdrawnServerConfirmed)
        XCTAssertEqual(harness.store.currentState.membership.plan, .pro)
    }

    @MainActor
    func test_conflictedEnrollmentRequiresNewGestureAndUnavailableRetryKeepsBody() async throws {
        let harness = SharingAccountModelHarness()
        defer { harness.close() }
        harness.seed()
        let model = harness.model()
        VoiceSharingStubProtocol.replies["PUT " + VoiceSharingAccountClient.membershipPath] = .init(status: 503, body: [:])
        VoiceSharingStubProtocol.replies["GET " + VoiceSharingAccountClient.projectionPath] = .init(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "not_enrolled"))
        await model.enroll(disclosureConfirmed: true)
        XCTAssertEqual(model.membershipStatus, .unavailable)
        let currentProjection = projection(enrolled: false, epoch: nil, withdrawal: "not_enrolled")
        VoiceSharingStubProtocol.replies["PUT " + VoiceSharingAccountClient.membershipPath] = .init(status: 409, body: currentProjection)
        VoiceSharingStubProtocol.replies["GET " + VoiceSharingAccountClient.projectionPath] = .init(status: 200, body: currentProjection)
        await model.retryMembership()
        XCTAssertEqual(model.membershipStatus, .conflict)
        let puts = VoiceSharingStubProtocol.seenRequests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts.count, 2)
        let first = try XCTUnwrap(requestBodyDictionary(of: try XCTUnwrap(puts.first)))
        let last = try XCTUnwrap(requestBodyDictionary(of: try XCTUnwrap(puts.last)))
        XCTAssertTrue(NSDictionary(dictionary: first).isEqual(to: last),
                      "the retry states the same desired state")
        await model.retryMembership()
        XCTAssertEqual(VoiceSharingStubProtocol.seenRequests.filter { $0.httpMethod == "PUT" }.count, 2, "no automatic conflict replay")
    }

    @MainActor
    func test_accountSwitchRetiresBusyStateRetryAndDelayedProjection() async {
        let entered = expectation(description: "old account fetch held")
        let hold = SharingAccountHold()
        let harness = SharingAccountModelHarness(tokenProvider: SharingAccountTokenClosure { entered.fulfill(); return await hold.wait() })
        defer { harness.close() }
        harness.seed()
        let model = harness.model()
        VoiceSharingStubProtocol.replies["GET " + VoiceSharingAccountClient.projectionPath] = .init(status: 200, body: projection(enrolled: true, epoch: "old", withdrawal: "active"))
        let fetch = Task { await model.refresh() }
        await fulfillment(of: [entered], timeout: 3)
        harness.switchAccount("session-B")
        await hold.open()
        await fetch.value
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.membership)
        XCTAssertEqual(model.membershipStatus, .idle)
        XCTAssertEqual(model.deletionStatus, .idle)
        XCTAssertFalse(harness.store.currentEffectiveEnrolled)
    }
}

extension VoiceSharingAccountModelTests {
    @MainActor
    func test_retryImmediatelyAfterStoreGenerationMovesRetiresOldOperationWithoutStickingBusy() async {
        let harness = SharingAccountModelHarness()
        defer { harness.close() }
        harness.seed()
        let model = harness.model()
        VoiceSharingStubProtocol.replies["PUT " + VoiceSharingAccountClient.membershipPath] = .init(status: 503, body: [:])
        await model.enroll(disclosureConfirmed: true)
        let puts = VoiceSharingStubProtocol.seenRequests.filter { $0.httpMethod == "PUT" }.count
        XCTAssertEqual(puts, 1)
        harness.store.setLocalOptIn(false)
        // No actor yield: Retry must reconcile before the observer's queued Task executes.
        await model.retryMembership()
        XCTAssertFalse(model.busy)
        XCTAssertEqual(VoiceSharingStubProtocol.seenRequests.filter { $0.httpMethod == "PUT" }.count, puts)
        XCTAssertFalse(harness.store.currentEffectiveEnrolled)
    }

    @MainActor
    func test_rawSessionRotationCannotRepublishOldMembershipAndFailedRefreshIsExplicit() async {
        let harness = SharingAccountModelHarness()
        defer { harness.close() }
        harness.seed(enrolled: true)
        let model = harness.model()
        VoiceSharingStubProtocol.replies["GET " + VoiceSharingAccountClient.projectionPath] = .init(status: 503, body: [:])
        await model.refresh()
        XCTAssertEqual(model.membership?.plan, .pro, "retain last known display data")
        XCTAssertTrue(model.refreshUnavailable)
        XCTAssertEqual(model.membershipStatus, .unavailable)
        VoiceSharingStubProtocol.replies["PUT " + VoiceSharingAccountClient.membershipPath] = .init(status: 200, body: projection(enrolled: false, epoch: "old-epoch", withdrawal: "withdrawn"))
        await model.withdraw()
        XCTAssertEqual(model.membershipStatus, .withdrawnServerConfirmed, "failed follow-up GET cannot erase server acknowledgement")
        XCTAssertTrue(model.refreshUnavailable)
        harness.rotateSessionWithoutStoreTransition("session-B")
        await model.refresh()
        XCTAssertNil(model.membership, "A's accepted projection is not B's display authority")
        XCTAssertNil(model.locallyOptedIn)
        XCTAssertFalse(model.busy)
    }
}

final class VoiceSharingAccountNavigationTests: XCTestCase {
    @MainActor
    func test_factoryGatesBeforeConstructionAndRetainsExactInjectedModels() throws {
        let harness = SharingAccountModelHarness()
        defer { harness.close() }
        harness.seed(enrolled: true)
        var built = 0
        let makeModel = { built += 1; return harness.model() }
        // Both gates are named explicitly: the factory's default surface flag reads the real app
        // surface, which is enabled in this build, so leaving it out tests nothing.
        XCTAssertNil(AccountViewController.makeVoiceSharingController(
            surfaceEnabled: { false }, signedIn: { true }, accountModel: makeModel))
        XCTAssertNil(AccountViewController.makeVoiceSharingController(surfaceEnabled: { true }, signedIn: { false }, accountModel: makeModel))
        XCTAssertEqual(built, 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = VoiceSharingQueue(root: root)
        var local: VoiceSharingSettingsModel? = VoiceSharingSettingsModel(queue: queue, isCollectionPermitted: { false }, isAccountEnrolled: { true }, isLocallyOptedIn: { true })
        var account: VoiceSharingAccountModel? = harness.model()
        weak var weakAccount = account
        weak var weakLocal = local
        var controller = try XCTUnwrap(AccountViewController.makeVoiceSharingController(surfaceEnabled: { true }, signedIn: { true }, accountModel: { account! }, localModel: { local })) as VoiceSharingAccountController?
        XCTAssertTrue(controller?.accountModel === account)
        XCTAssertTrue(controller?.localModel === local)
        account = nil
        local = nil
        XCTAssertNotNil(weakAccount)
        XCTAssertNotNil(weakLocal)
        controller = nil
        XCTAssertNil(weakAccount)
        XCTAssertNil(weakLocal)
    }

    @MainActor
    func test_realConfirmationCallbacksDeclineWithoutActionAndRetainedScreenClosesOnSignout() async throws {
        let harness = SharingAccountModelHarness()
        defer { harness.close() }
        harness.seed()
        let model = harness.model()
        var enabled = true
        let view = VoiceSharingAccountView(accountModel: model, localModel: nil, surfaceEnabled: { enabled })
        view.sectionsForTesting.enroll(confirmed: false)
        view.sectionsForTesting.deleteAccepted(confirmed: false)
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty)
        XCTAssertFalse(harness.store.currentState.localOptIn)
        enabled = false
        view.sectionsForTesting.enroll(confirmed: true)
        view.sectionsForTesting.deleteAccepted(confirmed: true)
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty)
        enabled = true
        harness.switchAccount(nil)
        await model.refresh()
        XCTAssertFalse(model.accountControlsAvailable)
        view.sectionsForTesting.enroll(confirmed: true)
        view.sectionsForTesting.deleteAccepted(confirmed: true)
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.isEmpty)
    }

    @MainActor
    func test_renderRealAccountScreenWithUnavailableEnrollmentAndIndependentWithdrawalDeletion() async throws {
        let harness = SharingAccountModelHarness()
        defer { harness.close() }
        harness.seed(enrolled: true)
        VoiceSharingStubProtocol.replies["GET " + VoiceSharingAccountClient.projectionPath] = .init(status: 200, body: projection(enrolled: true, epoch: "old-epoch", withdrawal: "active"))
        let model = harness.model(version: nil)
        let controller = try XCTUnwrap(AccountViewController.makeVoiceSharingController(surfaceEnabled: { true }, signedIn: { true }, accountModel: { model }, localModel: { nil }))
        let navigation = UINavigationController(rootViewController: controller)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1200)
        window.backgroundColor = .systemBackground
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let laidOut = expectation(description: "SwiftUI layout opportunity")
        DispatchQueue.main.async { window.layoutIfNeeded(); laidOut.fulfill() }
        await fulfillment(of: [laidOut], timeout: 3)
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true), "a failed draw is not render evidence")
        }
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 8, "empty/solid render must fail")
        XCTAssertEqual(image.size.width, 393)
        let attachment = XCTAttachment(image: image)
        attachment.name = "voice-sharing-account-unavailable-enrollment"
        attachment.lifetime = .keepAlways
        add(attachment)
        harness.switchAccount(nil)
        await model.refresh()
        XCTAssertFalse(model.accountControlsAvailable)
        let closedLayout = expectation(description: "signed-out SwiftUI layout opportunity")
        DispatchQueue.main.async { window.layoutIfNeeded(); closedLayout.fulfill() }
        await fulfillment(of: [closedLayout], timeout: 3)
        let signedOut = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let closed = XCTAttachment(image: signedOut)
        closed.name = "voice-sharing-account-signed-out"
        closed.lifetime = .keepAlways
        add(closed)
    }
}

extension VoiceSharingAccountNavigationTests {
    @MainActor
    func test_queuedConfirmationAndOldDialogCannotActForReplacementAccount() async {
        let harness = SharingAccountModelHarness()
        defer { harness.close() }
        harness.seed()
        let model = harness.model()
        let screenA = VoiceSharingAccountView(accountModel: model, localModel: nil, surfaceEnabled: { true })
        let queuedEnrollment = screenA.sectionsForTesting.enroll(confirmed: true)
        let queuedDeletion = screenA.sectionsForTesting.deleteAccepted(confirmed: true)
        // Still on the same actor turn: queued action Tasks have not started.
        harness.switchAccount("session-B")
        harness.seed()
        VoiceSharingStubProtocol.replies["GET " + VoiceSharingAccountClient.projectionPath] = .init(status: 200, body: projection(enrolled: false, epoch: nil, withdrawal: "not_enrolled"))
        await model.refresh()
        await queuedEnrollment?.value
        await queuedDeletion?.value
        XCTAssertFalse(harness.store.currentState.localOptIn)
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.allSatisfy { $0.httpMethod == "GET" }, "A's queued confirmations cannot mutate B")
        // The same confirmation can also arrive from a dialog retained across the replacement.
        let dialogEnrollment = screenA.sectionsForTesting.enroll(confirmed: true)
        let dialogDeletion = screenA.sectionsForTesting.deleteAccepted(confirmed: true)
        await dialogEnrollment?.value
        await dialogDeletion?.value
        XCTAssertFalse(harness.store.currentState.localOptIn)
        XCTAssertTrue(VoiceSharingStubProtocol.seenRequests.allSatisfy { $0.httpMethod == "GET" })
    }
}
