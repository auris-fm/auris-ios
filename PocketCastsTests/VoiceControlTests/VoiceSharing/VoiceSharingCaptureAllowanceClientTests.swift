import CryptoKit
import XCTest
@testable import podcasts

/// Controls for the capture-allowance adapter (spec "Server-issued capture allowance")
/// and the per-batch ledger composition. Every refusal is fail-closed: no authority exists.
final class VoiceSharingCaptureAllowanceClientTests: XCTestCase {

    private let batchA = "22222222-2222-4222-8222-222222222222"
    private let batchB = "33333333-3333-4333-8333-333333333333"
    private let window = "44444444-4444-4444-8444-444444444444"

    private final class StubTokens: CloudTokenProviding {
        var token: String? = "test-bearer"
        func token() async -> String? { token }
        func prepare() async {}
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    private func makeBody(requestID: String, epoch: String = "epoch-1",
                          disposition: String = "issued",
                          validFor: Int = 60_000,
                          overrides: [String: Any] = [:]) -> Data {
        var object: [String: Any] = [
            "schema_version": 1,
            "request_id": requestID,
            "window_id": window,
            "batch_id": batchA,
            "enrollment_epoch": epoch,
            "disposition": disposition,
            "valid_for_ms": validFor,
            "batch_max_records": 4,
            "batch_max_bytes": 4 * 1_985_580,
            "max_clip_ms": 60_000,
            "max_clip_bytes": 1_920_044,
            "max_metadata_bytes": 65_536,
        ]
        for (key, value) in overrides { object[key] = value }
        if let removed = overrides["__remove__"] as? String { object.removeValue(forKey: removed) }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: Response validation

    func test_validIssuedResponse_isAcceptedWithRemainingInterval() throws {
        let json = makeBody(requestID: "11111111-1111-4111-8111-111111111111")
        let response = try XCTUnwrap(VoiceSharingCaptureAllowanceResponse(
            json: json, expectedRequestID: "11111111-1111-4111-8111-111111111111",
            expectedEnrollmentEpoch: "epoch-1", elapsedMS: 1_500))
        XCTAssertEqual(response.disposition, VoiceSharingCaptureAllowanceDisposition.issued)
        XCTAssertEqual(response.validForMS, 58_500, "interval is anchored to the request-start instant")
        XCTAssertEqual(response.batchID, batchA)
    }

    func test_elapsedInterval_refusesFailClosed() throws {
        let json = makeBody(requestID: "11111111-1111-4111-8111-111111111111", validFor: 1_000)
        XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
            json: json, expectedRequestID: "11111111-1111-4111-8111-111111111111",
            expectedEnrollmentEpoch: "epoch-1", elapsedMS: 1_000),
            "an interval already elapsed must never install authority")
    }

    func test_echoMismatch_andOversizedValues_refuse() {
        let requestID = "11111111-1111-4111-8111-111111111111"
        // Wrong echoed request/epoch: not the answer to THIS request.
        XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
            json: makeBody(requestID: requestID, epoch: "epoch-OTHER"),
            expectedRequestID: requestID, expectedEnrollmentEpoch: "epoch-1", elapsedMS: 0))
        XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
            json: makeBody(requestID: requestID, epoch: "epoch-1"),
            expectedRequestID: "99999999-9999-4999-8999-999999999999",
            expectedEnrollmentEpoch: "epoch-1", elapsedMS: 0))
        // Ceiling-raising values clamp by refusal — never accepted.
        for (key, value) in [("max_clip_ms", 61_000), ("max_clip_bytes", 1_920_045),
                             ("max_metadata_bytes", 65_537), ("valid_for_ms", 300_001),
                             ("batch_max_records", 5)] {
            let json = makeBody(requestID: requestID, overrides: ["__remove__": "", key: value])
            XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
                json: json, expectedRequestID: requestID,
                expectedEnrollmentEpoch: "epoch-1", elapsedMS: 0),
                "\(key) above the compiled ceiling must refuse")
        }
        // Invalid opaque identifiers.
        for (key, value) in [("batch_id", "not-a-uuid"), ("window_id", "also-not")] {
            let json = makeBody(requestID: requestID, overrides: ["__remove__": "", key: value])
            XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
                json: json, expectedRequestID: requestID,
                expectedEnrollmentEpoch: "epoch-1", elapsedMS: 0))
        }
        // Unknown disposition.
        let json = makeBody(requestID: requestID, disposition: "gifted")
        XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
            json: json, expectedRequestID: requestID,
            expectedEnrollmentEpoch: "epoch-1", elapsedMS: 0))
    }

    // MARK: Transport

    private func stubbedClient(replies: @escaping (URLRequest) -> (Int, Data)) -> VoiceSharingCaptureAllowanceClient {
        final class Stub: URLProtocol {
            static var reply: ((URLRequest) -> (Int, Data))?
            static var seen: [URLRequest] = []
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Self.seen.append(request)
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    let bufferSize = 16 * 1024
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                    defer { buffer.deallocate() }
                    while stream.hasBytesAvailable {
                        let read = stream.read(buffer, maxLength: bufferSize)
                        guard read > 0 else { break }
                        data.append(buffer, count: read)
                    }
                    body = data
                }
                var mutable = request
                mutable.httpBody = body
                Self.seen[Self.seen.count - 1] = mutable
                let (status, data) = Self.reply!(mutable)
                let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        Stub.reply = replies
        Stub.seen = []
        let client = VoiceSharingCaptureAllowanceClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" })
        return client
    }

    private let requestID = "11111111-1111-4111-8111-111111111111"

    private func makeRequest() -> VoiceSharingCaptureAllowanceRequest {
        VoiceSharingCaptureAllowanceRequest(requestID: requestID, enrollmentEpoch: "epoch-1")!
    }

    func test_transport_sendsExactlyRequestIdAndEpoch_andAccepts() async {
        var sentBody: Data?
        let client = stubbedClient { request in
            sentBody = request.httpBody
            return (200, self.makeBody(requestID: self.requestID))
        }
        let outcome = await client.perform(makeRequest())
        guard case .accepted(let response) = outcome else {
            return XCTFail("expected acceptance, got \(outcome)")
        }
        XCTAssertEqual(response.disposition, VoiceSharingCaptureAllowanceDisposition.issued)
        let object = try! JSONSerialization.jsonObject(with: sentBody!, options: []) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["request_id", "enrollment_epoch"],
                       "no caller-supplied capacity, identity, day or object keys")
        XCTAssertEqual(object["request_id"] as? String, requestID)
        XCTAssertEqual(object["enrollment_epoch"] as? String, "epoch-1")
    }

    func test_transport_refusals_classify() async {
        for (status, body, expected) in [(409, #"{"error":"capture_window_expired"}"#, VoiceSharingCaptureAllowanceClient.VoiceSharingCaptureAllowanceRefusal.windowExpired),
                                          (409, #"{"error":"request_conflict"}"#, VoiceSharingCaptureAllowanceClient.VoiceSharingCaptureAllowanceRefusal.requestConflict),
                                          (429, "{}", VoiceSharingCaptureAllowanceClient.VoiceSharingCaptureAllowanceRefusal.exhausted),
                                          (403, "{}", VoiceSharingCaptureAllowanceClient.VoiceSharingCaptureAllowanceRefusal.retiredEnrollment),
                                          (503, "{}", VoiceSharingCaptureAllowanceClient.VoiceSharingCaptureAllowanceRefusal.serverUnavailable)] {
            let client = stubbedClient { _ in (status, Data(body.utf8)) }
            let outcome = await client.perform(makeRequest())
            XCTAssertEqual(outcome, .refused(expected), "status \(status) must classify \(expected)")
        }
        // Oversized response envelope: no trustworthy answer.
        let big = stubbedClient { _ in (200, Data(repeating: 0x61, count: 8 * 1024 + 1)) }
        let oversized = await big.perform(makeRequest())
        XCTAssertEqual(oversized, .unavailable)
    }

    func test_transport_elapsedInterval_neverAccepts() async {
        let client = stubbedClient { _ in (200, self.makeBody(requestID: self.requestID, validFor: 100)) }
        let outcome = await client.perform(makeRequest(), elapsedMS: { 200 })
        XCTAssertEqual(outcome, .unavailable, "transit time cannot extend the server interval")
    }

    // MARK: Per-batch ledger composition

    private func makeLimits() -> VoiceSharingCaptureLimits {
        VoiceSharingCaptureLimits(
            dailyRecords: 4, dailyBytes: 4 * 1_985_580,
            compiledRecordsCeiling: 4, compiledBytesCeiling: 4 * 1_985_580,
            clipSamples: 16_000, metadataBytes: 128,
            compiledClipSamples: 60_000 * 16, compiledMetadataBytes: 65_536)!
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func authority(account: String, window: String, batch: String) -> VoiceSharingCaptureAuthorization {
        VoiceSharingCaptureAuthorization(account: account, establishedWindow: window, batchId: batch,
                                         limits: makeLimits(), consent: .init(session: "gen-A", epoch: "epoch-1", policyGeneration: 1))!
    }

    private func provisioning(account: String, window: String, batch: String) -> VoiceSharingCaptureProvisioningAuthority {
        VoiceSharingCaptureProvisioningAuthority(verifiedFirstProvisioningAccount: account, establishedWindow: window, batchId: batch)!
    }

    func test_issuedFirstProvision_thenReplayRefreshKeepsExistingUsage() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = VoiceSharingCaptureLedger(root: root)
        XCTAssertTrue(ledger.provision(provisioning(account: "acct", window: window, batch: batchA)),
                      "first provisioning is allowed only for a NEWLY ISSUED batch")
        XCTAssertTrue(ledger.charge(authority(account: "acct", window: window, batch: batchA)),
                      "one durable charge on the issued batch")
        // A refreshed batch reopens the EXISTING ledger with the existing usage: the second
        // charge lands on top of the first, and the 4-cap budget is what stops it.
        XCTAssertTrue(ledger.charge(authority(account: "acct", window: window, batch: batchA)))
        XCTAssertTrue(ledger.charge(authority(account: "acct", window: window, batch: batchA)))
        XCTAssertTrue(ledger.charge(authority(account: "acct", window: window, batch: batchA)))
        XCTAssertFalse(ledger.charge(authority(account: "acct", window: window, batch: batchA)),
                       "record capacity is consumed across refreshes — never reset")
    }

    func test_batchesHaveDistinctLedgers_andNewBatchRequiresItsOwnProvisioning() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = VoiceSharingCaptureLedger(root: root)
        XCTAssertTrue(ledger.provision(provisioning(account: "acct", window: window, batch: batchA)))
        XCTAssertTrue(ledger.charge(authority(account: "acct", window: window, batch: batchA)))
        // A DIFFERENT batch cannot reuse batch A's ledger or provisioning.
        XCTAssertFalse(ledger.charge(authority(account: "acct", window: window, batch: batchB)),
                       "ordinary admission cannot establish a new batch's ledger")
        XCTAssertTrue(ledger.provision(provisioning(account: "acct", window: window, batch: batchB)),
                      "a newly issued batch provisions its own zero-usage ledger")
        XCTAssertTrue(ledger.charge(authority(account: "acct", window: window, batch: batchB)))
        // Batch A's usage is untouched by batch B's activity.
        XCTAssertTrue(ledger.charge(authority(account: "acct", window: window, batch: batchA)))
    }

    func test_lostOrCorruptLedger_neverReconstructsCapacity() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = VoiceSharingCaptureLedger(root: root)
        // No provisioning ever happened: ordinary admission must NOT treat loss as first use.
        XCTAssertFalse(ledger.charge(authority(account: "acct", window: window, batch: batchA)))
        // Corrupt usage: refused, never reconstructed.
        XCTAssertTrue(ledger.provision(provisioning(account: "acct", window: window, batch: batchA)))
        let dir = root.appendingPathComponent(digest("acct"))
            .appendingPathComponent(batchA)
        try? "junk".data(using: .utf8)!.write(to: dir.appendingPathComponent("usage.json.next"))
        XCTAssertFalse(ledger.charge(authority(account: "acct", window: window, batch: batchA)))
    }

    func test_windowOrBatchMismatch_refuses() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = VoiceSharingCaptureLedger(root: root)
        XCTAssertTrue(ledger.provision(provisioning(account: "acct", window: window, batch: batchA)))
        XCTAssertFalse(ledger.charge(authority(account: "acct", window: "other-window", batch: batchA)),
                       "a stale-day window binding cannot admit on the new day's batch")
    }

    func test_nonUuidBatchIds_refuseToBind() {
        XCTAssertNil(VoiceSharingCaptureAuthorization(account: "acct", establishedWindow: window,
                                                      batchId: "chosen-label", limits: makeLimits(),
                                                      consent: .init(session: "gen-A", epoch: "epoch-1", policyGeneration: 1)),
                     "batch identity is a server-issued opaque UUID, never a caller label")
        XCTAssertNil(VoiceSharingCaptureProvisioningAuthority(verifiedFirstProvisioningAccount: "acct",
                                                              establishedWindow: window, batchId: ""))
    }
}
