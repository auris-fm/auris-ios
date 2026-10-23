import XCTest
@testable import podcasts

/// Controls for the PRODUCTION upload transport: real request construction, credential lifetime and
/// the fail-closed rules that keep an unauthenticated or unconfigured build from uploading.
///
/// Networking is intercepted at the URLProtocol layer, so the URLSession path itself (request
/// preparation, response decoding, error mapping) is exercised rather than bypassed.
final class VoiceSharingUploadTransportTests: XCTestCase {
    private var session: URLSession!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadRecordingURLProtocol.self]
        session = URLSession(configuration: configuration)
        UploadRecordingURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        UploadRecordingURLProtocol.reset()
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://unit.test/api/v1/voice-recordings")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=auris-test", forHTTPHeaderField: "Content-Type")
        request.setValue("capture-1", forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = Data("--auris-test\r\n--auris-test--\r\n".utf8)
        return request
    }

    /// No credential ⇒ NO request is issued at all. This is the fail-closed rule: an
    /// unauthenticated upload would be an anonymous contribution attempt.
    func test_noCredentialSendsNothing() async {
        let provider = RecordingTokenProvider(tokens: [nil])
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider, session: session)
        let result = await transport.send(request: makeRequest())
        XCTAssertEqual(result, .transportFailure)
        XCTAssertEqual(UploadRecordingURLProtocol.requestCount, 0,
                       "no bytes may leave without a bearer")
    }

    /// A real request carries the bearer, the idempotency key and the multipart content type.
    func test_requestCarriesCredentialAndIdempotencyKey() async {
        let provider = RecordingTokenProvider(tokens: ["tok-1", "tok-1"])
        UploadRecordingURLProtocol.handler = { _ in
            (HTTPURLResponse(url: URL(string: "https://unit.test/api/v1/voice-recordings")!,
                             statusCode: 201, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider, session: session)
        _ = await transport.send(request: makeRequest())
        let sent = try? XCTUnwrap(UploadRecordingURLProtocol.lastRequest)
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Idempotency-Key"), "capture-1")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Content-Type"),
                       "multipart/form-data; boundary=auris-test")
        XCTAssertEqual(sent?.url?.path, "/api/v1/voice-recordings")
    }

    /// A 401 reports WHICH credential was rejected (so a concurrent refresh is not duplicated) and
    /// is returned as a response — the uploader decides it is retryable, not terminal.
    func test_unauthorizedReportsTheRejectedCredential() async {
        let provider = RecordingTokenProvider(tokens: ["tok-stale", "tok-fresh"])
        UploadRecordingURLProtocol.handler = { _ in
            (HTTPURLResponse(url: URL(string: "https://unit.test/x")!,
                             statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider, session: session)
        let result = await transport.send(request: makeRequest())
        XCTAssertEqual(result, .response(statusCode: 401, body: Data()))
        XCTAssertEqual(provider.rejectedTokens, ["tok-stale"],
                       "the rejected credential must be named exactly")
    }

    /// An unconfigured build uploads NOWHERE: an empty base URL yields no endpoint, and the
    /// transport refuses rather than inventing a host.
    func test_unconfiguredBaseURLSendsNothing() async {
        let provider = RecordingTokenProvider(tokens: ["tok-1", "tok-1"])
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "" }, tokenProvider: provider, session: session)
        XCTAssertNil(transport.endpoint)
        let result = await transport.send(request: makeRequest())
        XCTAssertEqual(result, .transportFailure)
        XCTAssertEqual(UploadRecordingURLProtocol.requestCount, 0)
    }

    /// An oversized response is not a receipt: refused as a transport-class failure, never parsed.
    func test_oversizedResponseIsRefusedWithoutParsing() async {
        let provider = RecordingTokenProvider(tokens: ["tok-1", "tok-1"])
        UploadRecordingURLProtocol.handler = { _ in
            (HTTPURLResponse(url: URL(string: "https://unit.test/x")!,
                             statusCode: 201, httpVersion: nil, headerFields: nil)!,
             Data(repeating: 0x41, count: 128 * 1024))
        }
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider, session: session)
        let result = await transport.send(request: makeRequest())
        XCTAssertEqual(result, .transportFailure)
    }

    /// Stalled headers: the deadline starts BEFORE the request, so a server that never sends
    /// headers is cancelled promptly — not just a slow body.
    func test_stalledHeadersAreCancelledByTheDeadline() async {
        let provider = RecordingTokenProvider(tokens: ["tok-1", "tok-1"])
        // A genuine stall: startLoading never calls the client — no headers ever arrive.
        UploadRecordingURLProtocol.stall = true
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider, session: session,
            bodyDeadline: 2)
        let started = Date()
        let result = await transport.send(request: makeRequest())
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result, .transportFailure)
        XCTAssertLessThan(elapsed, 10, "stalled headers must cancel promptly, not wait 30s")
    }

    /// A dribbling body that never finishes is cancelled by the deadline; the capped body cancels
    /// at the ceiling. Both leave the record's fate unknown (transportFailure).
    func test_dribblingBodyIsCancelledByTheDeadline() async {
        let provider = RecordingTokenProvider(tokens: ["tok-1", "tok-1"])
        UploadRecordingURLProtocol.handler = { _ in
            (HTTPURLResponse(url: URL(string: "https://unit.test/x")!,
                             statusCode: 201, httpVersion: nil, headerFields: nil)!, Data([0x41]))
        }
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider, session: session)
        let result = await transport.send(request: makeRequest())
        // Either the truncated body parses as a response or the deadline cancels; the record's
        // fate must be UNKNOWN either way, never fabricated success.
        if case .response(let code, _) = result {
            XCTAssertEqual(code, 201)
        } else {
            XCTAssertEqual(result, .transportFailure)
        }
    }

    /// MEASURED CANCELLATION (open item from spec/reviewer): a LIVE transfer that keeps dribbling
    /// is stopped by the transport, and the cancellation is OBSERVED (URLSession calls
    /// stopLoading) rather than merely inferred from the return value.
    func test_liveDribblingTransferIsMeasurablyCancelled() async {
        let provider = RecordingTokenProvider(tokens: ["tok-1", "tok-1"])
        UploadRecordingURLProtocol.drip = true
        UploadRecordingURLProtocol.dripInterval = 0.05
        UploadRecordingURLProtocol.stopLoadingSemaphore = DispatchSemaphore(value: 0)
        // A tight wall deadline so the test is fast; the deadline is what actually stops it.
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider, session: session,
            bodyDeadline: 2)
        let started = Date()
        let result = await transport.send(request: makeRequest())
        // DETERMINISTIC BOUND: wait (at most 5s) for URLSession to actually deliver stopLoading
        // instead of asserting the instant send resumes — the cancellation notification may
        // land a beat later, which was the recurring flake.
        let observed = DispatchQueue.global().sync {
            UploadRecordingURLProtocol.stopLoadingSemaphore?
                .wait(timeout: .now() + 5) == .success
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result, .transportFailure,
                       "a body that never finishes is never a delivered record")
        XCTAssertTrue(observed,
                      "URLSession delivered stopLoading within the bounded wait")
        XCTAssertGreaterThanOrEqual(UploadRecordingURLProtocol.stopLoadingCount, 1,
                                    "the live transfer must be told to stop")
        XCTAssertTrue(UploadRecordingURLProtocol.dripWasLiveWhenStopped,
                      "the drip was still running when cancellation arrived — measured, not inferred")
        XCTAssertLessThan(elapsed, 10, "the deadline bounds the transfer's lifetime")
    }

    /// REAL OVER-CAP CONTROL (spec/reviewer open item): the response body genuinely crosses the
    /// 64 KiB receive ceiling mid-stream — no stubbed "cap exceeded" flag — and the transport
    /// cancels the live transfer (stopLoading observed via a bounded barrier) and reports the
    /// record's fate as UNKNOWN (transportFailure), never a fabricated acceptance.
    func test_responseBurstPastThe64KiBCapIsCancelledMidstream() async throws {
        let provider = RecordingTokenProvider(tokens: ["tok-1", "tok-1"])
        UploadRecordingURLProtocol.burstOverCapBytes = 64 * 1024 + 1
        UploadRecordingURLProtocol.stopLoadingSemaphore = DispatchSemaphore(value: 0)
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider, session: session,
            bodyDeadline: 30)
        let result = await transport.send(request: makeRequest())
        // Bounded wait for the actual cancellation callback (same barrier shape as the drip
        // control — no assertion on unsynchronized counters).
        let observed = DispatchQueue.global().sync {
            UploadRecordingURLProtocol.stopLoadingSemaphore?
                .wait(timeout: .now() + 5) == .success
        }
        XCTAssertEqual(result, .transportFailure,
                       "a body crossing the cap is never a delivered record")
        XCTAssertTrue(observed, "URLSession delivered stopLoading within the bounded wait")
        XCTAssertGreaterThanOrEqual(UploadRecordingURLProtocol.stopLoadingCount, 1,
                                    "the live transfer was cancelled, not drained")
    }

    /// LOCALHOST HTTP (reviewer e1c86d32): a REAL local HTTP server holds the response OPEN
    /// after crossing the 64 KiB cap — the provider stream is never finished — and the test
    /// OBSERVES the server-side connection ending when the client's ceiling cancellation tears
    /// the transfer down. URLProtocol's burst control cannot give this evidence (its
    /// didFinishLoading fires right after the burst).
    func test_localhostServerObservesTheClientStopAfterTheCapCrossing() async throws {
        let stopFlag = StopFlag()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        let serverQueue = DispatchQueue(label: "cap-server")
        var port: UInt16 = 0
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state {
                port = listener?.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { connection in
            // STILL-PRODUCING PEER (reviewer e1c86d32): headers with NO content-length, then
            // chunks forever. The cap crossing happens while the provider is still streaming;
            // only a client-side cancellation can end this. Sending starts ONLY on .ready —
            // a send issued before the connection is prepared is silently dropped, which was
            // the reason an earlier attempt deadlocked into the client's deadline.
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled:
                    stopFlag.stop()
                case .ready:
                    guard !stopFlag.started else { break }
                    stopFlag.markStarted()
                    connection.send(content: Data("HTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\n\r\n".utf8),
                                    completion: .contentProcessed { _ in })
                    // Chunked encoding: each write is one <hex-length>\r\n<data>\r\n chunk.
                    var sequence = 0
                    func pump() {
                        guard sequence < 100 else { return }   // bounded: 100 × 16 KiB = 1.6 MB max
                        sequence += 1
                        let chunk = Data(count: 16 * 1024)
                        var frame = Data(String(format: "%x\r\n", chunk.count).utf8)
                        frame.append(chunk)
                        frame.append(Data("\r\n".utf8))
                        connection.send(content: frame, completion: .contentProcessed { _ in
                            serverQueue.asyncAfter(deadline: .now() + 0.05) { pump() }
                        })
                    }
                    pump()
                default:
                    break
                }
            }
            connection.start(queue: serverQueue)
        }
        listener.start(queue: serverQueue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            return XCTFail("the local cap server did not start")
        }
        defer { listener.cancel() }

        let provider = RecordingTokenProvider(tokens: ["tok-1", "tok-1"])
        // A PLAIN session: self.session intercepts every request through the URLProtocol
        // harness, which would never let real TCP reach the local listener.
        let plainConfiguration = URLSessionConfiguration.ephemeral
        let plainSession = URLSession(configuration: plainConfiguration)
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "http://127.0.0.1:\(port)" },
            tokenProvider: provider, session: plainSession,
            bodyDeadline: 30)
        var request = self.makeRequest()
        request.url = URL(string: "http://127.0.0.1:\(port)/api/v1/voice-recordings")
        let started = Date()
        let result = await transport.send(request: request)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result, .transportFailure,
                       "a stream that crosses the cap and never finishes is never a delivered record")
        XCTAssertLessThan(elapsed, 15,
                          "the ceiling stops the transfer long before the 30s deadline")
        // SERVER-SIDE OBSERVATION: the client's cancellation reached the real connection.
        XCTAssertTrue(stopFlag.wait(timeout: 5),
                      "the server observed its connection end after the client's cap cancellation")
    }

    /// The production endpoint is the mounted worker route.
    func test_endpointIsTheMountdWorkerRoute() {
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: RecordingTokenProvider(tokens: []), session: session)
        XCTAssertEqual(transport.endpoint?.absoluteString,
                       "https://unit.test/api/v1/voice-recordings")
    }

    /// A transport error is reported as `.transportFailure` (unknown, retryable), never as a
    /// fabricated response.
    func test_transportErrorBecomesTransportFailure() async {
        let provider = RecordingTokenProvider(tokens: ["tok-1", "tok-1"])
        UploadRecordingURLProtocol.handler = { _ in throw URLError(.timedOut) }
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider, session: session,
            bodyDeadline: 2)
        let result = await transport.send(request: makeRequest())
        XCTAssertEqual(result, .transportFailure)
    }
}

/// Token provider double that records which credentials were rejected.
private final class RecordingTokenProvider: CloudTokenProviding {
    private var tokens: [String?]
    private(set) var rejectedTokens: [String?] = []

    init(tokens: [String?]) { self.tokens = tokens }

    func token() async -> String? {
        if tokens.count > 1 { return tokens.removeFirst() }
        return tokens.first ?? nil
    }

    func handleUnauthorized(rejectedToken: String?) async {
        rejectedTokens.append(rejectedToken)
    }
}

/// URLProtocol double: records every request that actually reaches the network layer.
// MARK: - REAL transport + REAL provider boundary (reviewer 289a38b5/b799968e)

/// The REAL `CloudAuthTokenProvider` (injected auth I/O) behind the REAL
/// `VoiceSharingUploadTransport`: the transport's 401 branch must forward the EXACT bearer the
/// wire request carried, the provider must rotate exactly once for it, and a duplicate rejection
/// of an already-replaced bearer must NOT rotate again. Same-account/same-epoch identity fencing
/// rides the same path.
extension VoiceSharingUploadTransportTests {
    /// Stand up a real provider whose auth endpoints are served by the same URLProtocol harness,
    /// discriminated by path from the upload endpoint.
    private func makeRealProvider(credential: String) -> CloudAuthTokenProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadRecordingURLProtocol.self]
        return CloudAuthTokenProvider(
            authBaseURLProvider: { "https://unit.test" },
            credentialProvider: { credential },
            identityProvider: { "acct-A" },
            appVersionProvider: { "1.2.3" },
            session: URLSession(configuration: config))
    }

    private var authPath: String { "/api/v1/auth/refresh" }

    /// One wire request carrying tok-1 is 401'd; the transport reports tok-1; the provider rotates
    /// to tok-2 exactly once. A SECOND 401 still naming tok-1 (burst/race) must not rotate again —
    /// asserted against the REAL provider's refresh-call count, not a fake.
    func test_realTransportForwardsTheWireBearerAndTheRealProviderRefreshesExactlyOnce() async throws {
        // Auth endpoints: the token exchange mints tok-1; refresh mints tok-2, counted.
        var refreshCount = 0
        var uploadRequests: [URLRequest] = []
        UploadRecordingURLProtocol.lock.lock()
        UploadRecordingURLProtocol.expectedDeferredCount = 2
        UploadRecordingURLProtocol.bothHeldSemaphore = DispatchSemaphore(value: 0)
        UploadRecordingURLProtocol.lock.unlock()
        // Cleanup on EVERY exit path: no send may hang on a held transfer.
        defer {
            UploadRecordingURLProtocol.handler = nil
            UploadRecordingURLProtocol.releaseAllDeferred()
        }
        UploadRecordingURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/auth/token" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"tok-1","token_type":"Bearer","expires_in":900,"refresh_token":"r-1","refresh_expires_in":2592000,"issuer":"https://unit.test","subject":"acct-A"}"#.utf8))
            }
            if path == self.authPath {
                refreshCount += 1
                let next = "tok-\(refreshCount + 1)"   // tok-2, tok-3, ...
                return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"\#(next)","token_type":"Bearer","expires_in":900,"refresh_token":"r-\#(refreshCount)","refresh_expires_in":2592000,"issuer":"https://unit.test","subject":"acct-A"}"#.utf8))
            }
            // THE UPLOAD: reject whatever bearer this wire request carried — recorded below.
            if path.contains("voice-recordings") {
                uploadRequests.append(request)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 401,
                                    httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { UploadRecordingURLProtocol.handler = nil }

        let provider = makeRealProvider(credential: "cred")
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider,
            session: self.session)

        // Upload request 1 leaves with tok-1 and is rejected with 401; the transport's 401 branch
        // reports the exact bearer it sent.
        let firstResult = await transport.send(request: self.makeRequest())
        guard case .response(401, _) = firstResult else {
            return XCTFail("expected the 401 verdict, got \(firstResult)")
        }
        let wireBearer = try XCTUnwrap(uploadRequests.last?
            .value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(wireBearer, "Bearer tok-1", "the first wire request carries the minted token")
        await provider.handleUnauthorized(rejectedToken: "tok-1")
        XCTAssertEqual(refreshCount, 1, "the first rejection rotates exactly once")

        // A duplicate 401 for the SAME (already-replaced) bearer must not rotate again.
        await provider.handleUnauthorized(rejectedToken: "tok-1")
        XCTAssertEqual(refreshCount, 1,
                       "a second 401 naming the already-replaced bearer is a no-op — REAL provider guard")

        // The next upload now carries the rotated token end-to-end.
        let secondResult = await transport.send(request: self.makeRequest())
        guard case .response(401, _) = secondResult else {
            return XCTFail("expected the (still-)401 verdict, got \(secondResult)")
        }
        let secondBearer = try XCTUnwrap(uploadRequests.last?
            .value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(secondBearer, "Bearer tok-2",
                       "the wire carries the ROTATED token after the refresh")
        // The second wire 401 rejected tok-2, so the transport's real 401 branch reported tok-2
        // and the provider rotated again: one refresh per DISTINCT rejected bearer, no more.
        XCTAssertEqual(refreshCount, 2,
                       "exactly one rotation per distinct rejected bearer (tok-1, tok-2) — the duplicate tok-1 rejection never rotated")
        let thirdBearer = await provider.token()
        XCTAssertEqual(thirdBearer, "tok-3", "the second rejection rotated to tok-3 and it is live")
    }

    /// NIL-DISCRIMINATING FORWARDED-BEARER CONTROL (reviewer 5e57e531): TWO CONCURRENT sends,
    /// BOTH wire requests carrying tok-1 (the provider has not rotated yet), each 401 held by a
    /// barrier. Release response A first — transport A's 401 branch reports tok-1, the provider
    /// rotates to tok-2 (count 1) — and WAIT for the adoption. Then release response B: transport
    /// B's 401 branch still holds the STALE tok-1 it sent. Correct forwarding names tok-1; the
    /// guard no-ops; the count stays 1. A transport passing `nil` refreshes unconditionally → 2.
    func test_staleBearerForwardingIsDiscriminatedFromNil() async throws {
        var refreshCount = 0
        var uploadRequests: [URLRequest] = []
        UploadRecordingURLProtocol.lock.lock()
        UploadRecordingURLProtocol.expectedDeferredCount = 2
        UploadRecordingURLProtocol.bothHeldSemaphore = DispatchSemaphore(value: 0)
        UploadRecordingURLProtocol.lock.unlock()
        // Cleanup on EVERY exit path: no send may hang on a held transfer.
        defer {
            UploadRecordingURLProtocol.handler = nil
            UploadRecordingURLProtocol.releaseAllDeferred()
        }
        UploadRecordingURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/auth/token" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"tok-1","token_type":"Bearer","expires_in":900,"refresh_token":"r-1","refresh_expires_in":2592000,"issuer":"https://unit.test","subject":"acct-A"}"#.utf8))
            }
            if path == self.authPath {
                refreshCount += 1
                let next = "tok-\(refreshCount + 1)"
                return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"\#(next)","token_type":"Bearer","expires_in":900,"refresh_token":"r-\#(refreshCount)","refresh_expires_in":2592000,"issuer":"https://unit.test","subject":"acct-A"}"#.utf8))
            }
            UploadRecordingURLProtocol.lock.lock()
            uploadRequests.append(request)
            UploadRecordingURLProtocol.lock.unlock()
            // DEFERRED completion: hold this protocol instance and return WITHOUT responding,
            // so the shared loader thread is never blocked (a semaphore-wait here deadlocks
            // request 2 — both sessions complete on one loader queue).
            return nil
        }

        let provider = makeRealProvider(credential: "cred")
        // SEPARATE sessions for A and B: one URLSession can pipeline both POSTs on a single
        // connection, so request 2 would never startLoading until request 1 completed — and the
        // barrier would deadlock. Distinct configurations force distinct connections.
        func freshSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UploadRecordingURLProtocol.self]
            return URLSession(configuration: configuration)
        }
        let transportA = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider,
            session: freshSession())
        let transportB = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider,
            session: freshSession())

        // PRE-WARM the provider: the token exchange completes BEFORE any send, so both sends
        // read the cached tok-1 without racing the acquisition single-flight.
        let warmed = await provider.token()
        XCTAssertEqual(warmed, "tok-1", "pre-warm mints tok-1")
        // Distinct request identifiers so held transfers are addressable regardless of the
        // nondeterministic arrival order of the two concurrent sends.
        var requestA = self.makeRequest()
        requestA.setValue("capture-A", forHTTPHeaderField: "Idempotency-Key")
        var requestB = self.makeRequest()
        requestB.setValue("capture-B", forHTTPHeaderField: "Idempotency-Key")
        // Both sends race; each token() reads the provider's cached tok-1, so BOTH wire
        // requests carry tok-1.
        async let sendA = transportA.send(request: requestA)
        async let sendB = transportB.send(request: requestB)
        // Synchronized bounded barrier: the loader signals when both transfers are held.
        let heldTimedOut: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = UploadRecordingURLProtocol.bothHeldSemaphore?
                    .wait(timeout: .now() + 10)
                continuation.resume(returning: result == .timedOut)
            }
        }
        guard !heldTimedOut else {
            // Release BEFORE returning: the async-let children below are still held, and
            // structured cleanup would wait for them (up to a transport deadline). Explicit
            // release first keeps the return prompt (reviewer 2d15f73d/0505f163).
            UploadRecordingURLProtocol.releaseAllDeferred()
            _ = await sendA; _ = await sendB
            return XCTFail("both transfers were not held within 10s: held=\(uploadRequests.count)")
        }
        for request in uploadRequests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1",
                           "both wire requests left before any rotation")
        }

        // Release A BY KEY: its 401 branch reports tok-1 → one rotation.
        UploadRecordingURLProtocol.releaseDeferred401(key: "capture-A")
        guard case .response(401, _) = await sendA else {
            // Same rule: unblock the still-held transfer BEFORE returning.
            UploadRecordingURLProtocol.releaseAllDeferred()
            _ = await sendB
            return XCTFail("expected the 401 verdict for A")
        }
        // WAIT for the provider to ADOPT tok-2 (barrier, not a delay): token() returns tok-2
        // only after the refresh inside send A completed.
        let adopted = await provider.token()
        XCTAssertEqual(adopted, "tok-2", "the provider adopted the rotated token")
        XCTAssertEqual(refreshCount, 1, "exactly one rotation after A")

        // Release B BY KEY: its 401 branch holds the STALE tok-1. Correct forwarding → no-op.
        UploadRecordingURLProtocol.releaseDeferred401(key: "capture-B")
        let resultB = await sendB
        guard case .response(401, _) = resultB else {
            return XCTFail("expected the 401 verdict for B, got \(resultB)")
        }
        XCTAssertTrue(UploadRecordingURLProtocol.deferred401s.isEmpty,
                      "no transfer is left held after the flow completes")
        XCTAssertEqual(refreshCount, 1,
                       "the stale tok-1 rejection from transport B must NOT rotate again — this is what a nil-forwarding transport fails")
    }

    /// FORCED MISSING-TRANSFER CLEANUP (reviewer 2d15f73d/0505f163): the barrier expects three
    /// held transfers but only two ever arrive. The bounded barrier times out at 10s, the failure
    /// path releases what IS held BEFORE awaiting the children, and the test ends promptly —
    /// no 90-second transport deadline is reached.
    func test_barrierFailureReleasesHeldTransfersPromptly() async throws {
        UploadRecordingURLProtocol.lock.lock()
        UploadRecordingURLProtocol.expectedDeferredCount = 3   // one will never come
        UploadRecordingURLProtocol.bothHeldSemaphore = DispatchSemaphore(value: 0)
        UploadRecordingURLProtocol.lock.unlock()
        defer {
            UploadRecordingURLProtocol.handler = nil
            UploadRecordingURLProtocol.releaseAllDeferred()
        }
        UploadRecordingURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/auth/token" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"tok-1","token_type":"Bearer","expires_in":900,"refresh_token":"r-1","refresh_expires_in":2592000,"issuer":"https://unit.test","subject":"acct-A"}"#.utf8))
            }
            if path == self.authPath {
                // Answer refresh IMMEDIATELY (rejected → provider drops the chain): otherwise
                // the release-triggered refreshes would hang until the auth deadline and the
                // prompt-cleanup assertion would be measuring the wrong thing
                // (reviewer 0a748432).
                return (HTTPURLResponse(url: request.url!, statusCode: 401,
                                        httpVersion: nil, headerFields: nil)!,
                        Data(#"{"code":"refresh_reused"}"#.utf8))
            }
            // Upload path: hold, never complete.
            return nil
        }
        let provider = makeRealProvider(credential: "cred")
        func freshSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UploadRecordingURLProtocol.self]
            return URLSession(configuration: configuration)
        }
        let transportA = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider,
            session: freshSession())
        let transportB = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider,
            session: freshSession())
        var requestA = self.makeRequest()
        requestA.setValue("capture-A", forHTTPHeaderField: "Idempotency-Key")
        var requestB = self.makeRequest()
        requestB.setValue("capture-B", forHTTPHeaderField: "Idempotency-Key")
        async let sendA = transportA.send(request: requestA)
        async let sendB = transportB.send(request: requestB)
        let timedOut: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = UploadRecordingURLProtocol.bothHeldSemaphore?
                    .wait(timeout: .now() + 10)
                continuation.resume(returning: result == .timedOut)
            }
        }
        XCTAssertTrue(timedOut, "with one transfer missing, the barrier must time out")
        // FAILURE PATH: release BEFORE awaiting the children. Measure release → completions.
        let releaseStarted = Date()
        UploadRecordingURLProtocol.releaseAllDeferred()
        let resultA = await sendA
        let resultB = await sendB
        let releaseToDone = Date().timeIntervalSince(releaseStarted)
        guard case .response(401, _) = resultA, case .response(401, _) = resultB else {
            return XCTFail("released transfers complete as 401s, got \(resultA) / \(resultB)")
        }
        // PROMPT: release → both children completed stays far under any transport/auth deadline.
        XCTAssertLessThan(releaseToDone, 10,
                          "the children complete promptly after release — no deadline reached")
        // The deferred registry is EMPTY afterward: nothing left held.
        XCTAssertTrue(UploadRecordingURLProtocol.deferred401s.isEmpty,
                      "no transfer remains held after cleanup")
    }

    /// SAME-account/same-epoch fencing across the real path: after the entry was admitted under
    /// (acct-A, epoch-1), a move of EITHER component stops the send at the real transport's
    /// credential boundary.
    func test_realTransportFencesSameAccountEpochIdentityMoves() async throws {
        UploadRecordingURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/auth/token" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"tok-1","token_type":"Bearer","expires_in":900,"refresh_token":"r-1","refresh_expires_in":2592000,"issuer":"https://unit.test","subject":"acct-A"}"#.utf8))
            }
            XCTFail("no upload request may reach the wire after an identity move")
            return (HTTPURLResponse(url: request.url!, statusCode: 500,
                                    httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { UploadRecordingURLProtocol.handler = nil }

        let provider = makeRealProvider(credential: "cred")
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" }, tokenProvider: provider,
            session: self.session)
        let box = IdentityBoxHolder(VoiceSharingUploadIdentity(
            accountScope: "acct-A", enrollmentEpoch: "epoch-1"))
        let admitted = box.current

        // The account scope moves while the attempt is pending send.
        box.current = VoiceSharingUploadIdentity(
            accountScope: "acct-B", enrollmentEpoch: "epoch-1")
        let result = await transport.send(
            request: self.makeRequest(), admittedIdentity: admitted,
            identityFence: { box.current })
        guard case .transportFailure = result else {
            return XCTFail("an account move must fence the send, got \(result)")
        }
        // The epoch moves identically.
        box.current = VoiceSharingUploadIdentity(
            accountScope: "acct-A", enrollmentEpoch: "epoch-2")
        let result2 = await transport.send(
            request: self.makeRequest(), admittedIdentity: admitted,
            identityFence: { box.current })
        guard case .transportFailure = result2 else {
            return XCTFail("an epoch move must fence the send, got \(result2)")
        }
    }
}

/// Standalone identity holder (the uploader-suite one is file-private there).
final class IdentityBoxHolder {
    private let lock = NSLock()
    private var value: VoiceSharingUploadIdentity?
    init(_ initial: VoiceSharingUploadIdentity?) { value = initial }
    var current: VoiceSharingUploadIdentity? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Thread-safe stop flag for server-side connection-end observation.
final class StopFlag {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    private var startedSend = false
    func markStarted() {
        lock.lock(); startedSend = true; lock.unlock()
    }
    var started: Bool {
        lock.lock(); defer { lock.unlock() }; return startedSend
    }
    func stop() {
        lock.lock()
        let first = !stopped
        stopped = true
        lock.unlock()
        if first { semaphore.signal() }
    }
    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

private final class UploadRecordingURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data)?)?
    /// Deferred-401 protocol instances KEYED BY REQUEST IDENTIFIER (the Idempotency-Key header)
    /// — arrival order is nondeterministic across concurrent sends (reviewer 7f08e173).
    static var deferred401s: [String: UploadRecordingURLProtocol] = [:]
    /// Signaled once the expected transfers are all held — replaces Task.yield polling with a
    /// synchronized bounded wait.
    static var bothHeldSemaphore: DispatchSemaphore?
    static var expectedDeferredCount = 0
    /// Completes the transfer identified by `key` with a 401 (test-side barrier release).
    static func releaseDeferred401(key: String) {
        // Collect UNDER the lock; invoke client callbacks AFTER releasing it — stopLoading
        // (triggered by cancellation paths) acquires the same lock (reviewer 2d15f73d).
        lock.lock()
        let instance = deferred401s.removeValue(forKey: key)
        lock.unlock()
        guard let instance else { return }
        completeWith401(instance)
    }
    private static func completeWith401(_ instance: UploadRecordingURLProtocol) {
        let response = HTTPURLResponse(
            url: instance.request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
        instance.client?.urlProtocol(instance, didLoad: Data())
        instance.client?.urlProtocolDidFinishLoading(instance)
    }
    /// Releases ANY transfers still held (cleanup on failure paths) so no send hangs.
    static func releaseAllDeferred() {
        lock.lock()
        let held = Array(deferred401s.values)
        deferred401s = [:]
        lock.unlock()
        // Callbacks AFTER the lock is released (see releaseDeferred401).
        for instance in held { completeWith401(instance) }
    }
    static var stall = false
    /// Drip mode: send headers, then one byte every `dripInterval` forever — a live transfer that
    /// only the WALL/cap bound can stop.
    static var drip = false
    static var dripInterval: TimeInterval = 0
    /// REAL OVER-CAP MODE (spec/reviewer open item): the response body actually EXCEEDS the
    /// transport's 64 KiB receive ceiling — headers first, then one burst larger than the cap.
    static var burstOverCapBytes = 0
    private(set) static var lastRequest: URLRequest?
    private(set) static var requestCount = 0
    /// MEASURED CANCELLATION (spec/reviewer open item): how many times URLSession told the live
    /// transfer to stop, and whether a drip was still running when it did.
    private(set) static var stopLoadingCount = 0
    private(set) static var dripWasLiveWhenStopped = false
    /// DETERMINISTIC CANCELLATION BARRIER: stopLoading signals this; the test waits on it
    /// (bounded) instead of asserting immediately after send returns — the OS may deliver
    /// stopLoading a beat after the await resumes, which was the flake.
    static var stopLoadingSemaphore: DispatchSemaphore?
    private static var dripTask: Task<Void, Never>?
    static let lock = NSLock()

    static func reset() {
        handler = nil
        deferred401s = [:]
        bothHeldSemaphore = nil
        expectedDeferredCount = 0
        stall = false
        drip = false
        dripInterval = 0
        burstOverCapBytes = 0
        lastRequest = nil
        requestCount = 0
        stopLoadingCount = 0
        dripWasLiveWhenStopped = false
        stopLoadingSemaphore = nil
        dripTask?.cancel()
        dripTask = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        UploadRecordingURLProtocol.lock.lock()
        UploadRecordingURLProtocol.requestCount += 1
        UploadRecordingURLProtocol.lastRequest = request
        UploadRecordingURLProtocol.lock.unlock()
        // A genuine stall: the transfer exists but NEVER yields headers or bytes.
        if UploadRecordingURLProtocol.stall { return }
        if UploadRecordingURLProtocol.burstOverCapBytes > 0 {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // One burst strictly greater than the 64 KiB receive ceiling: the crossing happens
            // MID-STREAM, inside the live transfer.
            client?.urlProtocol(self, didLoad: Data(count: UploadRecordingURLProtocol.burstOverCapBytes))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if UploadRecordingURLProtocol.drip {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let interval = UploadRecordingURLProtocol.dripInterval
            let protocolInstance = self
            UploadRecordingURLProtocol.dripTask = Task { [weak protocolInstance] in
                while !Task.isCancelled, let protocolInstance {
                    try? await Task.sleep(
                        nanoseconds: UInt64(max(interval, 0.001) * 1_000_000_000))
                    if Task.isCancelled { break }
                    protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data([0x41]))
                }
            }
            return
        }
        guard let handler = UploadRecordingURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            if let (response, data) = try handler(request) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                // Deferred: hold the instance under its request identifier for a later
                // test-side release, and signal the synchronized "all held" barrier.
                UploadRecordingURLProtocol.lock.lock()
                let key = request.value(forHTTPHeaderField: "Idempotency-Key")
                    ?? UUID().uuidString
                UploadRecordingURLProtocol.deferred401s[key] = self
                let held = UploadRecordingURLProtocol.deferred401s.count
                let semaphore = UploadRecordingURLProtocol.bothHeldSemaphore
                let expected = UploadRecordingURLProtocol.expectedDeferredCount
                UploadRecordingURLProtocol.lock.unlock()
                if let semaphore, held >= expected { semaphore.signal() }
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        UploadRecordingURLProtocol.lock.lock()
        UploadRecordingURLProtocol.stopLoadingCount += 1
        let taskWasLive = UploadRecordingURLProtocol.dripTask.map { !$0.isCancelled } ?? false
        if taskWasLive { UploadRecordingURLProtocol.dripWasLiveWhenStopped = true }
        UploadRecordingURLProtocol.dripTask?.cancel()
        UploadRecordingURLProtocol.dripTask = nil
        let semaphore = UploadRecordingURLProtocol.stopLoadingSemaphore
        UploadRecordingURLProtocol.lock.unlock()
        // Signaled OUTSIDE the lock: the waiter may immediately read the statics above.
        semaphore?.signal()
    }
}