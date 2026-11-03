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
            expectedEnrollmentEpoch: "epoch-1", requestStartMonotonicMS: 10_000, elapsedMS: 1_500))
        XCTAssertEqual(response.deadlineMonotonicMS, 70_000,
                       "the ORIGINAL deadline is retained, not re-anchored at parse time")
        XCTAssertTrue(response.stillValid(monotonicNowMS: 69_999))
        XCTAssertFalse(response.stillValid(monotonicNowMS: 70_000),
                       "delayed installation is judged against the original deadline")
        XCTAssertFalse(response.stillValid(monotonicNowMS: 9_999),
                       "a backward clock read cannot restore validity before the original start")
        XCTAssertFalse(response.stillValid(monotonicNowMS: -1))
        XCTAssertEqual(response.disposition, VoiceSharingCaptureAllowanceDisposition.issued)
        XCTAssertEqual(response.validForMSRemaining, 58_500, "interval is anchored to the request-start instant")
        XCTAssertEqual(response.batchID, batchA)
    }

    func test_elapsedInterval_refusesFailClosed() throws {
        let json = makeBody(requestID: "11111111-1111-4111-8111-111111111111", validFor: 1_000)
        XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
            json: json, expectedRequestID: "11111111-1111-4111-8111-111111111111",
            expectedEnrollmentEpoch: "epoch-1", requestStartMonotonicMS: 10_000, elapsedMS: 1_000),
            "an interval already elapsed must never install authority")
        // A backward clock must refuse, never extend validity.
        XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
            json: json, expectedRequestID: "11111111-1111-4111-8111-111111111111",
            expectedEnrollmentEpoch: "epoch-1", requestStartMonotonicMS: 10_000, elapsedMS: -5),
            "negative elapsed (clock moved backward) must refuse")
    }

    func test_echoMismatch_andOversizedValues_refuse() {
        let requestID = "11111111-1111-4111-8111-111111111111"
        // Wrong echoed request/epoch: not the answer to THIS request.
        XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
            json: makeBody(requestID: requestID, epoch: "epoch-OTHER"),
            expectedRequestID: requestID, expectedEnrollmentEpoch: "epoch-1", requestStartMonotonicMS: 0, elapsedMS: 0))
        XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
            json: makeBody(requestID: requestID, epoch: "epoch-1"),
            expectedRequestID: "99999999-9999-4999-8999-999999999999",
            expectedEnrollmentEpoch: "epoch-1", requestStartMonotonicMS: 0, elapsedMS: 0))
        // Ceiling-raising values clamp by refusal — never accepted.
        for (key, value) in [("max_clip_ms", 61_000), ("max_clip_bytes", 1_920_045),
                             ("max_metadata_bytes", 65_537), ("valid_for_ms", 300_001),
                             ("batch_max_records", 5)] {
            let json = makeBody(requestID: requestID, overrides: ["__remove__": "", key: value])
            XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
                json: json, expectedRequestID: requestID,
                expectedEnrollmentEpoch: "epoch-1", requestStartMonotonicMS: 0, elapsedMS: 0),
                "\(key) above the compiled ceiling must refuse")
        }
        // Invalid opaque identifiers.
        for (key, value) in [("batch_id", "not-a-uuid"), ("window_id", "also-not")] {
            let json = makeBody(requestID: requestID, overrides: ["__remove__": "", key: value])
            XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
                json: json, expectedRequestID: requestID,
                expectedEnrollmentEpoch: "epoch-1", requestStartMonotonicMS: 0, elapsedMS: 0))
        }
        // Booleans posing as numbers must be rejected (NSNUMBERS bridge too freely).
        for key in ["schema_version", "valid_for_ms", "batch_max_records", "max_clip_ms",
                    "max_clip_bytes", "max_metadata_bytes", "batch_max_bytes"] {
            let json = makeBody(requestID: requestID, overrides: ["__remove__": "", key: true])
            XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
                json: json, expectedRequestID: requestID,
                expectedEnrollmentEpoch: "epoch-1", requestStartMonotonicMS: 0, elapsedMS: 0),
                "\(key) as a JSON boolean must refuse")
        }
        // Floats posing as integers must be rejected too.
        let float = makeBody(requestID: requestID, overrides: ["__remove__": "", "valid_for_ms": 1000.5])
        XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
            json: float, expectedRequestID: requestID,
            expectedEnrollmentEpoch: "epoch-1", requestStartMonotonicMS: 0, elapsedMS: 0))
        // Unknown disposition.
        let json = makeBody(requestID: requestID, disposition: "gifted")
        XCTAssertNil(VoiceSharingCaptureAllowanceResponse(
            json: json, expectedRequestID: requestID,
            expectedEnrollmentEpoch: "epoch-1", requestStartMonotonicMS: 0, elapsedMS: 0))
    }

    // MARK: Transport

    /// A transport that only COUNTS, for the missing-origin controls: a request built without an
    /// origin must never reach it, and a configured origin must reach exactly one real route.
    final class CountingTransport: URLProtocol {
        static var seen: [URLRequest] = []
        static func reset() { seen = [] }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.seen.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func stubbedClient(replies: @escaping (URLRequest) -> (Int, Data),
                               monotonicNowMS: @escaping () -> Int = { 0 }) -> VoiceSharingCaptureAllowanceClient {
        final class Stub: URLProtocol {
            static var reply: ((URLRequest) -> (Int, Data))?
            /// Incremental delivery control: each element is loaded as its own chunk.
            static var chunks: ((URLRequest) -> (Int, [Data]))?
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
                let (status, payload): (Int, [Data])
                if let chunks = Self.chunks {
                    (status, payload) = chunks(mutable)
                } else {
                    let (singleStatus, single) = Self.reply!(mutable)
                    (status, payload) = (singleStatus, [single])
                }
                let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                for chunk in payload { client?.urlProtocol(self, didLoad: chunk) }
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        Stub.reply = replies
        Stub.chunks = nil
        Stub.seen = []
        let client = VoiceSharingCaptureAllowanceClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" },
            monotonicNowMS: monotonicNowMS)
        return client
    }

    private let requestID = "11111111-1111-4111-8111-111111111111"

    /// Polls (cancellation is asynchronous) up to 2 s for the flag.
    private func waitForFlag(_ flag: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if flag() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return flag()
    }

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

    /// MISSING ORIGIN, observed at the TRANSPORT (spec's open item; @cloud: a request that never
    /// leaves the device is invisible server-side, so the check has to watch the client).
    ///
    /// Two failing shapes are controlled here, and both are the kind that would look fine from a
    /// server log:
    ///  * a missing origin that still DIALS something (an empty base + path is a relative URL that
    ///    URLSession can resolve against nothing, or worse, against a stale host);
    ///  * a missing origin that reports the same outcome as a transport failure, so the caller cannot
    ///    tell "never asked" from "asked and failed" — those have different retry rules.
    func test_missingOrigin_isRefusedBeforeTheTransportIsTouched() async {
        CountingTransport.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingTransport.self]
        let session = URLSession(configuration: config)
        for origin in ["", "   ", "not a url"] {
            let client = VoiceSharingCaptureAllowanceClient(
                baseURLProvider: { origin },
                tokenProvider: StubTokens(),
                session: session,
                sessionIdentity: { "gen-A" })
            let outcome = await client.perform(makeRequest())
            XCTAssertEqual(outcome, .unavailable,
                           "origin [\(origin)] has nowhere to dial: the outcome must be unavailability")
        }
        XCTAssertTrue(CountingTransport.seen.isEmpty,
                      "no origin means NO request is issued - asserted at the transport, not from a body")
    }

    /// The rule is shared, so one control covers every sharing route that builds a URL from the
    /// configured origin: the allowance client, the account client and the upload transport.
    /// Each of the three previously concatenated the origin and accepted whatever `URL` returned.
    func test_sharedOriginRule_refusesEverySharingRouteWithoutADialableOrigin() {
        for path in ["/api/v1/account/voice-sharing/capture-allowance",
                     "/api/v1/account/voice-sharing",
                     "/api/v1/account/voice-sharing/utterances"] {
            XCTAssertNil(VoiceSharingOrigin.url(origin: "", path: path), "no origin ⇒ no URL")
            XCTAssertNil(VoiceSharingOrigin.url(origin: "  ", path: path), "blank origin ⇒ no URL")
            XCTAssertNil(VoiceSharingOrigin.url(origin: "api.example.test", path: path),
                         "a host without a scheme is not dialable")
            XCTAssertNil(VoiceSharingOrigin.url(origin: "ftp://api.example.test", path: path),
                         "only http(s) is a sharing origin")
            XCTAssertEqual(VoiceSharingOrigin.url(origin: "https://api.example.test", path: path)?.absoluteString,
                           "https://api.example.test" + path, "a real origin resolves the real path")
            XCTAssertEqual(VoiceSharingOrigin.url(origin: " https://api.example.test ", path: path)?.absoluteString,
                           "https://api.example.test" + path, "surrounding whitespace is not part of the origin")
        }
    }

    /// The positive half of the same control: a configured origin DOES reach the transport, so the
    /// assertion above cannot pass merely because this client never dials anything.
    func test_configuredOrigin_reachesTheTransport() async {
        CountingTransport.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingTransport.self]
        let session = URLSession(configuration: config)
        let client = VoiceSharingCaptureAllowanceClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: session,
            sessionIdentity: { "gen-A" })
        _ = await client.perform(makeRequest())
        XCTAssertEqual(CountingTransport.seen.count, 1, "a configured origin issues exactly one request")
        XCTAssertEqual(CountingTransport.seen.first?.url?.absoluteString,
                       "https://api.example.test/api/v1/account/voice-sharing/capture-allowance",
                       "and it is the real route, not a placeholder")
    }

    func test_transport_refusals_classify() async {
        for (status, body, expected) in [(410, "{}", VoiceSharingCaptureAllowanceClient.VoiceSharingCaptureAllowanceRefusal.windowExpired),
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

    /// Incremental oversized delivery: bytes arrive in small chunks totaling > 8 KiB. The
    /// bounded read must stop at limit+1 and return unavailable — never buffer, never parse.
    static let oversizedChunk = Data(repeating: 0x61, count: 512)

    func test_transport_incrementalOversizedDelivery_refusesWithoutBuffering() async {
        final class Stub2: URLProtocol {
            static var loaded = 0
            static var cancelled = false
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                // PACED delivery: chunks beyond the 8 KiB bound are held pending so the
                // consumer's stop at bound+1 is observable — later chunks must never load.
                DispatchQueue.global().async { [weak self] in
                    for index in 0..<24 {
                        guard let self, !Self.cancelled else { return } // stopLoading halts delivery
                        Self.loaded += VoiceSharingCaptureAllowanceClientTests.oversizedChunk.count
                        self.client?.urlProtocol(self, didLoad: VoiceSharingCaptureAllowanceClientTests.oversizedChunk)
                        Thread.sleep(forTimeInterval: 0.002)
                        _ = index
                    }
                    self?.client?.urlProtocolDidFinishLoading(self!)
                }
            }
            override func stopLoading() { Self.cancelled = true }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub2.self]
        Stub2.loaded = 0
        Stub2.cancelled = false
        let client = VoiceSharingCaptureAllowanceClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" })
        let outcome = await client.perform(makeRequest())
        XCTAssertEqual(outcome, .unavailable, "oversized envelope must refuse")
        XCTAssertTrue(waitForFlag { Stub2.cancelled },
                      "exceeding the bound must stop the connection")
        XCTAssertLessThan(Stub2.loaded, 24 * 512,
                          "cancellation must stop further delivery before all chunks load")
    }

    /// A SINGLE huge chunk (12 KiB in one didLoad) must be capped at limit+1, never
    /// buffered whole.
    func test_transport_singleLargeChunk_isCappedAtLimit() async {
        final class Stub4: URLProtocol {
            static var cancelled = false
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                // One 12 KiB didLoad — larger than the whole allowance.
                client?.urlProtocol(self, didLoad: Data(repeating: 0x62, count: 12 * 1024))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() { Self.cancelled = true }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub4.self]
        Stub4.cancelled = false
        let client = VoiceSharingCaptureAllowanceClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" })
        let outcome = await client.perform(makeRequest())
        XCTAssertEqual(outcome, .unavailable, "single oversized chunk must refuse")
    }

    /// Caller-cancellation while delivery is pending propagates to the session task.
    func test_transport_callerCancellation_terminatesThePendingTransfer() async throws {
        final class Stub5: URLProtocol {
            static var cancelled = false
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(repeating: 0x63, count: 64))
                // The rest is never delivered — the caller cancels while pending.
            }
            override func stopLoading() { Self.cancelled = true }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub5.self]
        Stub5.cancelled = false
        let client = VoiceSharingCaptureAllowanceClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" })
        let task = Task { await client.perform(makeRequest()) }
        try await Task.sleep(nanoseconds: 100_000_000) // delivery pending
        task.cancel()
        _ = await task.value
        XCTAssertTrue(waitForFlag { Stub5.cancelled },
                      "caller cancellation must terminate the pending session task")
    }

    final class TaggedStub: URLProtocol {
        static var entered = Set<String>()
        static var stopped = Set<String>()
        static var finished = Set<String>()
        static var releases: [String: DispatchSemaphore] = [:]
        private var finishedLoading = false
        class func tag(_ request: URLRequest) -> String {
            request.url?.host ?? "?"
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let tag = Self.tag(request)
            Self.entered.insert(tag)
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            // BOTH transfers are left open on return: startLoading must not block
            // (blocking this thread serializes other loads). Completion for each is
            // delivered later from a detached thread on its own release.
            // JSON-whitespace filler: the pending partial bytes must remain a valid
            // prefix of the envelope B eventually completes with.
            client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: 64))
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                while !Self.stopped.contains(tag) {
                    if Self.releases[tag]?.wait(timeout: .now() + 0.05) == .success { break }
                }
                self.client?.urlProtocol(self, didLoad: VoiceSharingCaptureAllowanceClientTests.validReply)
                self.finishedLoading = true
                Self.finished.insert(tag)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() {
            // Only a cancellation (not the ordinary post-completion invalidation stop)
            // marks the transfer as stopped.
            if !finishedLoading { Self.stopped.insert(Self.tag(request)) }
        }
    }
    static var validReply: Data = Data()

    func test_transport_overlappingRequests_cancellationIsPerInvocation() async {
        TaggedStub.entered = []
        TaggedStub.stopped = []
        TaggedStub.finished = []
        TaggedStub.releases = ["a.test": DispatchSemaphore(value: 0),
                               "b.test": DispatchSemaphore(value: 0)]
        Self.validReply = makeBody(requestID: requestID) // valid allowance body

        func clientFor(_ host: String) -> VoiceSharingCaptureAllowanceClient {
            let fresh = URLSessionConfiguration.ephemeral
            fresh.protocolClasses = [TaggedStub.self]
            fresh.timeoutIntervalForRequest = 10
            return VoiceSharingCaptureAllowanceClient(
                baseURLProvider: { "https://\(host)" },
                tokenProvider: StubTokens(),
                session: URLSession(configuration: fresh),
                sessionIdentity: { "gen-A" })
        }
        let a = Task { await clientFor("a.test").perform(makeRequest()) }
        let b = Task { await clientFor("b.test").perform(makeRequest()) }
        // Entry barrier: both transfers are actually pending before any cancellation.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, TaggedStub.entered.count < 2 { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(TaggedStub.entered.count, 2, "both transfers must be pending")

        a.cancel()
        let aOutcome = await a.value
        XCTAssertEqual(aOutcome, .unavailable, "cancelled A must refuse")
        XCTAssertTrue(waitForFlag { TaggedStub.stopped.contains("a.test") },
                      "A's transfer must be stopped")
        XCTAssertFalse(TaggedStub.stopped.contains("b.test"),
                       "cancelling A must NOT stop B's transfer")
        XCTAssertFalse(TaggedStub.finished.contains("b.test"),
                       "B must still be PENDING (unfinished) when A is cancelled — a shared handle defect would have stopped or already-cleared B here")

        // Release B's pending transfer: only then does it complete with acceptance.
        TaggedStub.releases["b.test"]?.signal()
        // B completes normally with a valid acceptance — shared cancellation state
        // (the defect under test) would have cancelled B with A.
        let bOutcome = await b.value
        guard case .accepted(let response) = bOutcome else {
            return XCTFail("untouched B must still accept, got \(bOutcome)")
        }
        XCTAssertEqual(response.batchID, batchA)
    }

    /// Remembered cancellation, deterministically: cancel the handle BEFORE any task
    /// exists, then bind a real (unresumed) task — it must be cancelling immediately.
    func test_handle_cancelledBeforeBind_isAppliedAtBindTime() {
        let handle = VoiceSharingCaptureAllowanceClient.Handle()
        handle.cancelTask() // before any task exists
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: URL(string: "https://api.example.test/x")!)
        XCTAssertNotEqual(task.state, .canceling, "sanity: task starts uncancelled")
        handle.bind(task) // bind AFTER cancellation — must apply immediately
        XCTAssertTrue(waitForFlag { task.state == .canceling },
                      "remembered cancellation must cancel at bind time")
        task.cancel()
    }

    /// A response that reaches EXACTLY limit+1 bytes and then pauses indefinitely must
    /// still be refused — the boundary itself counts as exceeded.
    func test_transport_exactLimitBoundary_pauseIsRefused() async {
        final class Stub7: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                // Exactly 8 KiB + 1 byte, then NOTHING (no finish, ever).
                client?.urlProtocol(self, didLoad: Data(repeating: 0x65, count: 8 * 1024 + 1))
            }
            override func stopLoading() {}
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub7.self]
        let client = VoiceSharingCaptureAllowanceClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" })
        let outcome = await client.perform(makeRequest())
        XCTAssertEqual(outcome, .unavailable,
                       "retained bytes at exactly limit+1 must cancel and refuse")
    }

    func test_transport_errorStatus_oversizedBody_isBounded() async {
        final class Stub3: URLProtocol {
            static var cancelled = false
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let http = HTTPURLResponse(url: request.url!, statusCode: 410,
                                           httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                DispatchQueue.global().async { [weak self] in
                    for _ in 0..<24 {
                        guard let self, !Self.cancelled else { return }
                        self.client?.urlProtocol(self, didLoad: VoiceSharingCaptureAllowanceClientTests.oversizedChunk)
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    self?.client?.urlProtocolDidFinishLoading(self!)
                }
            }
            override func stopLoading() { Self.cancelled = true }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub3.self]
        Stub3.cancelled = false
        let client = VoiceSharingCaptureAllowanceClient(
            baseURLProvider: { "https://api.example.test" },
            tokenProvider: StubTokens(),
            session: URLSession(configuration: config),
            sessionIdentity: { "gen-A" })
        let outcome = await client.perform(makeRequest())
        // The bounded read still classifies the STATUS (captured before the body) while the
        // oversized body itself is never fully buffered — the task is explicitly cancelled.
        XCTAssertEqual(outcome, .refused(.windowExpired))
        XCTAssertTrue(waitForFlag { Stub3.cancelled })
    }

    // MARK: Disposition-driven provisioning connection (reviewer 80ef8b5f.5)

    func test_issuedResponse_provisionsThroughTheRealLedgerPath_replayedNeverDoes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = VoiceSharingCaptureLedger(root: root)
        let issued = try XCTUnwrap(VoiceSharingCaptureAllowanceResponse(
            json: makeBody(requestID: requestID, disposition: "issued"),
            expectedRequestID: requestID, expectedEnrollmentEpoch: "epoch-1",
            requestStartMonotonicMS: 0, elapsedMS: 0))
        let replayed = try XCTUnwrap(VoiceSharingCaptureAllowanceResponse(
            json: makeBody(requestID: requestID, disposition: "replayed"),
            expectedRequestID: requestID, expectedEnrollmentEpoch: "epoch-1",
            requestStartMonotonicMS: 0, elapsedMS: 0))
        let consent = VoiceSharingCaptureStamp(session: "gen-A", epoch: "epoch-1", policyGeneration: 1)

        // REPLAYED against a MISSING ledger: no provisioning path exists for it — burned.
        XCTAssertNil(VoiceSharingCaptureAllowanceInstallation.provisioningAuthority(
            account: "acct", response: replayed),
            "replayed cannot establish a replacement zero-usage ledger")

        // ISSUED provisions through the REAL ledger.
        let provision = try XCTUnwrap(VoiceSharingCaptureAllowanceInstallation.provisioningAuthority(
            account: "acct", response: issued))
        XCTAssertTrue(ledger.provision(provision))
        let admission = try XCTUnwrap(VoiceSharingCaptureAllowanceInstallation.admissionAuthority(
            account: "acct", response: issued, consent: consent))
        XCTAssertTrue(ledger.charge(admission), "issued batch admits and charges durably")

        // REPLAYED against the now-INTACT ledger: the second admission derives from the
        // PARSED REPLAYED response itself and reopens the ledger with existing usage.
        let replayedAdmission = try XCTUnwrap(VoiceSharingCaptureAllowanceInstallation.admissionAuthority(
            account: "acct", response: replayed, consent: consent))
        XCTAssertTrue(ledger.charge(replayedAdmission),
                      "replayed refresh reopens the existing ledger with existing usage")

        // A LOWERED max_clip_bytes binds admission independently of duration (both limits).
        let byteCapped = try XCTUnwrap(VoiceSharingCaptureAllowanceResponse(
            json: makeBody(requestID: requestID, overrides: ["__remove__": "", "max_clip_bytes": 2_044]),
            expectedRequestID: requestID, expectedEnrollmentEpoch: "epoch-1",
            requestStartMonotonicMS: 0, elapsedMS: 0))
        let capped = try XCTUnwrap(VoiceSharingCaptureAllowanceInstallation.admissionAuthority(
            account: "acct", response: byteCapped, consent: consent))
        XCTAssertEqual(capped.limits.clipSamples, (2_044 - 44) / 2,
                       "samples derive from the BYTE ceiling (2 B/sample + 44 B header), not just duration")
        XCTAssertEqual(capped.limits.reservationBytes,
                       UInt64(capped.limits.clipSamples * 2 + 44 + capped.limits.metadataBytes))
        // …and the real ledger charges under the capped reservation.
        XCTAssertTrue(ledger.charge(capped))
    }

    func test_replayedResponse_cannotReprovisionAfterLedgerLoss() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = VoiceSharingCaptureLedger(root: root)
        let replayed = try XCTUnwrap(VoiceSharingCaptureAllowanceResponse(
            json: makeBody(requestID: requestID, disposition: "replayed"),
            expectedRequestID: requestID, expectedEnrollmentEpoch: "epoch-1",
            requestStartMonotonicMS: 0, elapsedMS: 0))
        let consent = VoiceSharingCaptureStamp(session: "gen-A", epoch: "epoch-1", policyGeneration: 1)
        XCTAssertNil(VoiceSharingCaptureAllowanceInstallation.provisioningAuthority(
            account: "acct", response: replayed))
        let admission = VoiceSharingCaptureAllowanceInstallation.admissionAuthority(
            account: "acct", response: replayed, consent: consent)
        // Even when a caller fabricates an authority, the MISSING ledger refuses ordinary admission.
        if let admission {
            XCTAssertFalse(ledger.charge(admission), "lost ledger burns the batch")
        }
    }

    func test_transport_elapsedInterval_neverAccepts() async {
        final class Clock { var now = 0 }
        let clock = Clock()
        let client = stubbedClient(replies: { _ in
            clock.now = 300 // response ARRIVAL past the interval end
            return (200, self.makeBody(requestID: self.requestID, validFor: 100))
        }, monotonicNowMS: { clock.now })
        let outcome = await client.perform(makeRequest()) // request start: clock.now == 0
        XCTAssertEqual(outcome, VoiceSharingCaptureAllowanceClient.Outcome.unavailable,
                       "transit time cannot extend the server interval")
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
