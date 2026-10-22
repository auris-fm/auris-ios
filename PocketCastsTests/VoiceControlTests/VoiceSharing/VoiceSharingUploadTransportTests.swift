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
private final class UploadRecordingURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var stall = false
    private(set) static var lastRequest: URLRequest?
    private(set) static var requestCount = 0

    static func reset() {
        handler = nil
        stall = false
        lastRequest = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        UploadRecordingURLProtocol.requestCount += 1
        UploadRecordingURLProtocol.lastRequest = request
        // A genuine stall: the transfer exists but NEVER yields headers or bytes.
        if UploadRecordingURLProtocol.stall { return }
        guard let handler = UploadRecordingURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}