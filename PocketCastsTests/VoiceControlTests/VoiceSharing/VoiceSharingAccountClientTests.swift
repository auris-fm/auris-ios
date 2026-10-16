import XCTest
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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        VoiceSharingStubProtocol.seenRequests.append(request)
        VoiceSharingStubProtocol.onRequest?()
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        let reply = VoiceSharingStubProtocol.replies[key]
        if VoiceSharingStubProtocol.responseDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + VoiceSharingStubProtocol.responseDelay) {
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
    private(set) var unauthorizedCalls = 0
    func token() async -> String? { tokenValue }
    func prepare() async {}
    func handleUnauthorized(rejectedToken: String?) async { unauthorizedCalls += 1 }
}

final class VoiceSharingAccountClientTests: XCTestCase {
    private var session: URLSession!
    private var tokens: AccountStubTokenProvider!
    private var identity: VoiceSharingAccountClient.SessionIdentity? = .init(account: "account-A", generationKey: "cred-1")
    private var requestIDs: [String] = []

    override func setUp() {
        super.setUp()
        VoiceSharingStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceSharingStubProtocol.self]
        session = URLSession(configuration: config)
        tokens = AccountStubTokenProvider()
        identity = .init(account: "account-A", generationKey: "cred-1")
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


    // MARK: - Review round 7 additions: same-account relogin, GET guarding, numeric bridging

    /// `userId` alone cannot see sign-out followed by signing back into the SAME account. The session half of
    /// the identity does, so a reply from the previous session must drop rather than apply membership.
    func test_sameAccountRelogin_midFlight_isDroppedNotApplied() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 200, body: projection("r12", enrolled: true, epoch: "e12", withdrawal: "active"))
        let client = makeClient()
        VoiceSharingStubProtocol.onRequest = { [weak self] in
            // Same account, NEW session material — exactly what a logout/login cycle produces.
            self?.identity = .init(account: "account-A", generationKey: "cred-2")
        }
        let outcome = await client.perform(client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7"))
        XCTAssertEqual(outcome, .droppedStaleSession, "an old session's reply must not apply even for the same account id")
    }

    /// GET was previously unguarded: an account transition during the fetch would still install the previous
    /// account's projection. Also asserts no request at all when there is no authenticated session.
    func test_getProjection_transitionDuringFetch_isDropped() async {
        VoiceSharingStubProtocol.replies["GET /api/v1/account/voice-sharing"] =
            Reply(status: 200, body: projection("r7", enrolled: true, epoch: "e1", withdrawal: "active"))
        let client = makeClient()
        VoiceSharingStubProtocol.onRequest = { [weak self] in
            self?.identity = .init(account: "account-B", generationKey: "cred-9")
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
        _ = await client.perform(client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7"))
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
        let outcome = await clientForTest.perform(clientForTest.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7"))
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
            let outcome = await clientForTest.perform(clientForTest.beginEnrollment(acceptedDisclosureVersion: "x", expectedMembershipRevision: "r1"))
            guard case .refused(let reason) = outcome else { XCTFail("\(label) should refuse"); continue }
            XCTAssertEqual(reason, label == "ineligible" ? .ineligible : .unsupportedDisclosure)
        }
    }

    func test_unauthorized_reportsRatherThanRetrying() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 401, body: [:])
        let outcome = await clientForTest.perform(clientForTest.beginWithdrawal(enrollmentEpoch: "e1", expectedMembershipRevision: "r1"))
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
        let late = await clientForTest.perform(clientForTest.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7"))
        guard case .conflict(let current) = late else { return XCTFail("late first delivery must conflict") }
        XCTAssertEqual(current?.withdrawalState, .withdrawn)
        XCTAssertFalse(current?.voiceSharingEnrolled == true, "a delayed opt-in may not undo a later opt-out")
    }

    /// Withdrawal while already inactive still advances the revision, which is what fences later
    /// first-delivery opt-ins. Client must treat that 200 as authoritative state, not a no-op.
    func test_withdrawalFromInactiveProjection_advancesRevision() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 200, body: projection("r10", enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        let outcome = await clientForTest.perform(clientForTest.beginWithdrawal(enrollmentEpoch: nil, expectedMembershipRevision: "r9"))
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
        let operation = client.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7")
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
        let first = await client.perform(client.beginWithdrawal(enrollmentEpoch: "e1", expectedMembershipRevision: "r5"))
        XCTAssertEqual(first, .unavailableBackend, "a transport failure is an unknown outcome, not a state change")

        // Now the same operation is retried and succeeds.
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 200, body: projection("r6", enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        let op = client.beginWithdrawal(enrollmentEpoch: "e1", expectedMembershipRevision: "r5")
        _ = await client.perform(op)     // second call reuses `op`'s identity
        let bodies = VoiceSharingStubProtocol.seenRequests.compactMap(requestBodyDictionary(of:))
        let ids = Set(bodies.compactMap { $0["request_id"] as? String })
        XCTAssertEqual(ids.count, 1, "retries of one operation share a single request_id: \(ids)")
        XCTAssertEqual(issued.count, 2, "one begin per operation only")
    }

    /// Null epoch withdrawal is valid only when the expected projection has no active epoch.
    func test_nullEpochWithdrawal_onlyValidWhenProjectionHasNoActiveEpoch() async {
        // Case A: projection has an active epoch -> null-epoch withdrawal is refused as invalid.
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 422, body: ["error": "invalid_request_epoch"])
        let a = await clientForTest.perform(clientForTest.beginWithdrawal(enrollmentEpoch: nil, expectedMembershipRevision: "r5"))
        guard case .refused(let reason) = a else { return XCTFail("null epoch with an active epoch must be refused") }
        XCTAssertEqual(reason, .invalidRequest)

        // Case B: no active epoch -> accepted, and it fences outstanding opt-ins.
        VoiceSharingStubProtocol.reset()
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/withdrawal"] =
            Reply(status: 200, body: projection("r6", enrolled: false, epoch: nil, withdrawal: "withdrawn"))
        let b = await clientForTest.perform(clientForTest.beginWithdrawal(enrollmentEpoch: nil, expectedMembershipRevision: "r5"))
        guard case .applied(let m) = b else { return XCTFail("null epoch withdrawal should apply when nothing is active") }
        XCTAssertEqual(m.withdrawalState, .withdrawn)
    }

    /// A reply that belongs to an obsolete account/session is dropped, never applied. Identity flips while
    /// the request is in flight — the shape that actually happens when sign-out lands mid-mutation.
    func test_responseForObsoleteSession_isDroppedNotApplied() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 200, body: projection("r11", enrolled: true, epoch: "e11", withdrawal: "active"))
        VoiceSharingStubProtocol.onRequest = { [weak self] in
            self?.identity = .init(account: "account-B", generationKey: "cred-2")   // switched mid-flight
        }
        let outcome = await clientForTest.perform(clientForTest.beginEnrollment(acceptedDisclosureVersion: "2026-09", expectedMembershipRevision: "r7"))
        XCTAssertEqual(outcome, .droppedStaleSession, "a projection from a superseded session must not be applied")
    }

    // MARK: - Deletion is its own operation

    func test_deleteData_usesOwnRequestIdAndReportsPendingOnly() async {
        VoiceSharingStubProtocol.replies["DELETE /api/v1/account/voice-sharing/data"] =
            Reply(status: 202, body: deletionReceipt("del-1"))
        let outcome = await clientForTest.performDeletion(clientForTest.beginDeletion())
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
        let outcome = await clientForTest.performDeletion(clientForTest.beginDeletion())
        XCTAssertEqual(outcome, .unavailableBackend)
    }

    func test_backendUnavailable_isRetryableNotAStateChange() async {
        VoiceSharingStubProtocol.replies["POST /api/v1/account/voice-sharing/enrollment"] =
            Reply(status: 503, body: ["error": "state_unavailable"])
        let outcome = await clientForTest.perform(clientForTest.beginEnrollment(acceptedDisclosureVersion: "x", expectedMembershipRevision: "r1"))
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
