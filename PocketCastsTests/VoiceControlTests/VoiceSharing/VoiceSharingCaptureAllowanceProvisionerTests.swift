import XCTest
@testable import podcasts

/// Controls for the minimal CONNECTED capture entry: one real allowance request
/// whose validated response becomes the collector's admission authority.
final class VoiceSharingCaptureAllowanceProvisionerTests: XCTestCase {
    private let requestID = "11111111-1111-4111-8111-111111111111"
    private let batchA = "22222222-2222-4222-8222-222222222222"
    private let window = "33333333-3333-4333-8333-333333333333"

    private final class StubTokens: CloudTokenProviding {
        func token() async -> String? { "test-token" }
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    private func makeBody(requestID: String, epoch: String = "epoch-1",
                          disposition: String = "issued", batch: String? = nil,
                          validForMS: Int = 60_000) -> Data {
        let object: [String: Any] = [
            "schema_version": 1,
            "request_id": requestID,
            "window_id": window,
            "batch_id": batch ?? batchA,
            "enrollment_epoch": epoch,
            "disposition": disposition,
            "valid_for_ms": 60_000,
            "batch_max_records": 4,
            "batch_max_bytes": 4 * 1_985_580,
            "max_clip_ms": 60_000,
            "max_clip_bytes": 1_920_044,
            "max_metadata_bytes": 65_536,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Status/body-driven stub so one helper serves accept and refusal controls.
    private func client(replies: @escaping (URLRequest) -> (Int, Data))
        -> VoiceSharingCaptureAllowanceClient {
        final class Stub: URLProtocol {
            static var replies: ((URLRequest) -> (Int, Data))?
            static var requestCount = 0
            /// The REAL request body the client sent, echoed back so validation sees a live id.
            static var lastBody: Data?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Self.requestCount += 1
                Self.lastBody = Self.readBody(request)
                var (status, body) = Self.replies!(request)
                // Echo the REAL request's request_id into the canned body, exactly
                // as the server does; a canned id would fail validation.
                if let data = Stub.readBody(request),
                   let reqObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let rid = reqObject["request_id"] as? String,
                   var parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                    parsed["request_id"] = rid
                    body = try! JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys])
                }
                let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
            static func readBody(_ request: URLRequest) -> Data? {
                if let body = request.httpBody { return body }
                guard let stream = request.httpBodyStream else { return nil }
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                return data
            }
            override func stopLoading() {}
        }
        Stub.replies = replies
        Stub.requestCount = 0
        Self.lastStub = Stub.self
        Self.lastStubCount = { Stub.requestCount }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return VoiceSharingCaptureAllowanceClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" })
    }
    private static var staticRequestID = ""
    private static var lastStub: URLProtocol.Type?
    private static var lastStubCount: () -> Int = { 0 }

    private func provisioner(client: VoiceSharingCaptureAllowanceClient,
                             epoch: @escaping () -> String? = { "epoch-1" },
                             account: @escaping () -> String? = { "acct-1" },
                             policyGeneration: @escaping () -> Int = { 7 },
                             session: @escaping () -> String? = { "sess-1" })
        -> VoiceSharingCaptureAllowanceProvisioner {
        VoiceSharingCaptureAllowanceProvisioner(
            client: client,
            accountProvider: account,
            enrollmentEpochProvider: epoch,
            stampProvider: {
                guard let sess = session() else { return nil }
                return VoiceSharingCaptureStamp(session: sess, epoch: epoch() ?? "",
                                                policyGeneration: policyGeneration())
            },
            ledger: VoiceSharingCaptureLedger(root: ledgerRoot),
            requestIdentityRoot: requestRoot,
            log: { Self.logs.append($0) })
    }
    private static var logs: [String] = []
    /// Durable accounting + persisted request identity for these controls: a real temp directory, so
    /// restart/replay/missing-ledger behaviour is proven on the real ledger, not a stub.
    private var testRoot: URL!
    private var ledgerRoot: URL { testRoot.appendingPathComponent("usage") }
    private var ledger: VoiceSharingCaptureLedger { VoiceSharingCaptureLedger(root: ledgerRoot) }
    private var requestRoot: URL { testRoot.appendingPathComponent("requests") }

    override func tearDown() {
        if let testRoot { try? FileManager.default.removeItem(at: testRoot) }
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("allowance-provisioner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        Self.logs = []
        Self.staticRequestID = requestID
        Self.replyDisposition = "issued"
        Self.lastSentRequestID = nil
    }

    /// A valid ISSUED response installs: the sync admission path returns an authority
    /// for the CURRENT stamp, and the log surfaces the installed batch.
    func test_provision_installedResponse_becomesAdmissionAuthority() async {
        let p = provisioner(client: client(replies: { _ in (200, self.makeBody(requestID: Self.staticRequestID)) }))
        await p.provision()
        let authority = p.currentAuthorization()
        XCTAssertNotNil(authority, "issued response must install an admission authority")
        XCTAssertEqual(authority?.batchId, batchA)
        XCTAssertEqual(authority?.consent.epoch, "epoch-1")
        XCTAssertEqual(authority?.consent.policyGeneration, 7)
        XCTAssertTrue(Self.logs.contains { $0.contains("installed") && $0.contains(batchA) },
                      "installed batch must be surfaced: \(Self.logs)")
    }

    /// A typed refusal surfaces its cause and installs NOTHING (fail-closed).
    func test_provision_refusal_surfacesAndInstallsNothing() async {
        let p = provisioner(client: client(replies: { _ in (410, Data("{}".utf8)) }))
        await p.provision()
        XCTAssertNil(p.currentAuthorization(), "a refusal must not install")
        XCTAssertTrue(Self.logs.contains { $0.lowercased().contains("refused") && $0.contains("windowExpired") },
                      "refusal cause must surface: \(Self.logs)")
    }

    /// An unavailable outcome installs nothing.
    func test_provision_unavailable_installsNothing() async {
        let p = provisioner(client: client(replies: { _ in (503, Data()) }))
        await p.provision()
        XCTAssertNil(p.currentAuthorization())
    }

    /// An installed authority does not trigger a second network request.
    func test_provision_alreadyInstalled_makesNoSecondRequest() async {
        let p = provisioner(client: client(replies: { _ in (200, self.makeBody(requestID: Self.staticRequestID)) }))
        await p.provision()
        await p.provision()
        XCTAssertEqual(Self.lastStubCount(), 1, "exactly one request while installed")
    }

    /// An installed response issued under a DIFFERENT enrollment epoch must not admit.
    func test_installed_authorityDoesNotSurviveEpochChange() async {
        var epoch = "epoch-1"
        let p = provisioner(client: client(replies: { _ in (200, self.makeBody(requestID: Self.staticRequestID)) }),
                            epoch: { epoch })
        await p.provision()
        XCTAssertNotNil(p.currentAuthorization())
        epoch = "epoch-2"
        XCTAssertNil(p.currentAuthorization(),
                     "a batch issued under epoch-1 must not admit under epoch-2")
    }

    /// No account or no enrollment epoch = no request at all, nothing installed.
    func test_provision_missingAccountOrEpoch_makesNoRequest() async {
        var account: String? = "acct-1"
        var epoch: String? = "epoch-1"
        let p = provisioner(client: client(replies: { _ in (200, self.makeBody(requestID: Self.staticRequestID)) }),
                            epoch: { epoch },
                            account: { account })
        account = nil
        await p.provision()
        XCTAssertNil(p.currentAuthorization())
        epoch = nil
        await p.provision()
        XCTAssertNil(p.currentAuthorization())
        XCTAssertTrue(Self.logs.contains { $0.contains("skipped") }, "missing inputs must be surfaced: \(Self.logs)")
    }
    // MARK: - Allocation reuse across restarts (spec a6d71a42)

    /// The request identity is persisted, so a RESTART replays it instead of minting a new one. The
    /// stub echoes back whatever request id it was sent, which is what the server does for a replay.
    func test_restart_replaysThePersistedAllocationRequest() async {
        let echo = client(replies: { request in
            let id = Self.requestIDInBody(request) ?? ""
            return (200, self.makeBody(requestID: id))
        })
        await provisioner(client: echo).provision()
        let first = Self.lastSentRequestID
        XCTAssertNotNil(first)

        // A second provisioner over the SAME durable roots is a fresh process.
        await provisioner(client: echo).provision()
        XCTAssertEqual(Self.lastSentRequestID, first,
                       "a restart must replay the persisted request identity, not mint a new one")
    }

    /// A refresh must reuse the batch this device already accounts for: its usage survives the
    /// restart, so the four-capture budget is shared rather than reset.
    func test_refresh_adoptsExistingLedger_andUsageSurvivesTheRestart() async {
        let echo = client(replies: { request in
            let id = Self.requestIDInBody(request) ?? ""
            return (200, self.makeBody(requestID: id))
        })
        /// One process lifetime: provision (issuing or replaying), then admit one capture.
        func lifetime() async -> Bool {
            let p = provisioner(client: echo)
            await p.provision()
            guard let authority = p.currentAuthorization() else { return false }
            return ledger.charge(authority)
        }
        var admitted = 0
        for _ in 0..<6 where await lifetime() { admitted += 1 }
        print("RT admitted=\(admitted)")
        XCTAssertEqual(admitted, 4,
                       "usage is durable across restarts: four captures per batch, not four per launch")
    }

    /// A REPLAY whose ledger is missing refuses: it must never recreate unused capacity. The server
    /// answers `replayed` here — the batch exists — so only the absent accounting can refuse.
    func test_replayWithMissingLedger_refusesInsteadOfRecreatingCapacity() async {
        let echo = client(replies: { request in
            let id = Self.requestIDInBody(request) ?? ""
            guard Self.replyDisposition == "replayed" else { return (200, self.makeBody(requestID: id)) }
            return (200, self.makeBody(requestID: id, disposition: "replayed"))
        })
        await provisioner(client: echo).provision()
        try? FileManager.default.removeItem(at: ledgerRoot)
        Self.replyDisposition = "replayed"
        let after = provisioner(client: echo)
        await after.provision()
        XCTAssertNil(after.currentAuthorization(),
                     "a replayed batch with no durable accounting must not install")
        XCTAssertTrue(Self.logs.contains { $0.contains("ledger unavailable") },
                      "the refusal must name the ledger: \(Self.logs)")
    }

    /// Only a server-confirmed expiry mints a new allocation identity; every other refusal — including
    /// exhaustion, which the server reports with no batch and no id — keeps the persisted identity.
    func test_onlyServerConfirmedExpiry_mintsANewIdentity() async {
        var reply: (Int, Data) = (429, Data("{}".utf8))
        let stub = client { request in
            Self.noteSentRequestID(request)
            return reply
        }
        await provisioner(client: stub).provision()
        let first = Self.lastSentRequestID
        XCTAssertNotNil(first)
        await provisioner(client: stub).provision()
        XCTAssertEqual(Self.lastSentRequestID, first, "exhaustion must re-send the same request identity")
        reply = (500, Data())
        await provisioner(client: stub).provision()
        XCTAssertEqual(Self.lastSentRequestID, first,
                       "an unclassifiable failure proves nothing about the batch; the identity is kept")
        // A SERVER-confirmed expired window is the one refusal that mints a new allocation, and the
        // NEW identity is what goes out on the following request.
        reply = (410, Data("{}".utf8))
        await provisioner(client: stub).provision()
        reply = (500, Data())
        await provisioner(client: stub).provision()
        XCTAssertNotEqual(Self.lastSentRequestID, first,
                          "a server-confirmed expired window must mint a new allocation identity")
        XCTAssertNotNil(Self.lastSentRequestID)
    }

    /// Set by the controls that need the stub to answer with a non-`issued` disposition.
    static var replyDisposition = "issued"

    private let prohibitedRequestID = "44444444-4444-4444-8444-444444444444"

    static var lastSentRequestID: String?
    private static func noteSentRequestID(_ request: URLRequest) {
        _ = requestIDInBody(request)
    }
    private static func requestIDInBody(_ request: URLRequest) -> String? {
        guard let data = request.httpBody ?? request.httpBodyStream.map({ readAll($0) }),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["request_id"] as? String else { return lastSentRequestID }
        lastSentRequestID = id
        return id
    }
    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
