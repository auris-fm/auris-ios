import Foundation
import XCTest
import ObjectiveC
@testable import podcasts

/// Shared URLProtocol stub for cloud route SSE client/sink tests.
enum CloudRouteTestStub {
    case complete(status: Int, headers: [String: String], body: Data)
    case dropAfter(body: Data, error: Error)
    case slowChunks(body: Data, chunkDelayNanoseconds: UInt64)
}

final class CloudRouteTestURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> CloudRouteTestStub)?
    static var onRequest: ((URLRequest, Data?) -> Void)?
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData = Self.readBody(from: request)
        Self.lock.lock()
        Self._requestCount += 1
        Self.lock.unlock()
        Self.onRequest?(request, bodyData)

        let handler: ((URLRequest) throws -> CloudRouteTestStub)?
        Self.lock.lock()
        handler = Self.requestHandler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            switch try handler(request) {
            case let .complete(status, headers, body):
                let response = Self.httpResponse(url: request.url!, status: status, headers: headers, body: body)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !body.isEmpty {
                    client?.urlProtocol(self, didLoad: body)
                }
                client?.urlProtocolDidFinishLoading(self)

            case let .dropAfter(body, error):
                let response = Self.httpResponse(
                    url: request.url!,
                    status: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    body: body
                )
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                // Defer failure so AsyncBytes can observe the loaded prefix first.
                let protocolClient = client
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    protocolClient?.urlProtocol(self, didFailWithError: error)
                }

            case let .slowChunks(body, delay):
                let response = Self.httpResponse(
                    url: request.url!,
                    status: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    body: body
                )
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                let chunks = Self.chunkSSE(body)
                let protocolClient = client
                Task {
                    for chunk in chunks {
                        try? await Task.sleep(nanoseconds: delay)
                        protocolClient?.urlProtocol(self, didLoad: chunk)
                    }
                    protocolClient?.urlProtocolDidFinishLoading(self)
                }
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}


    /// Responds with a non-SSE JSON body (e.g. the prefetch 202).
    static func stubJSON(status: Int, body: String) {
        let data = Data(body.utf8)
        lock.lock()
        _requestCount = 0
        requestHandler = { _ in
            .complete(
                status: status,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }
        lock.unlock()
    }

    /// Number of requests handled since the last `stubJSON`/`reset`.
    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    private static var _requestCount = 0

    static func reset() {
        lock.lock()
        requestHandler = nil
        onRequest = nil
        _requestCount = 0
        lock.unlock()
    }

    private static func httpResponse(
        url: URL,
        status: Int,
        headers: [String: String],
        body: Data
    ) -> HTTPURLResponse {
        var fields = headers
        fields["Content-Length"] = "\(body.count)"
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }

    private static func chunkSSE(_ data: Data) -> [Data] {
        let text = String(data: data, encoding: .utf8) ?? ""
        let parts = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        if parts.count <= 1 { return [data] }
        return parts.map { Data(($0 + "\n\n").utf8) }
    }
}

/// Fixed-credential provider: the route client needs *a* token, and these
/// cases are about the transport rather than the credential.
struct StubTokenProvider: CloudTokenProviding {
    let token: String?
    func token() async -> String? { token }
    func handleUnauthorized(rejectedToken: String?) async {}
}

/// A test case whose sut builds its client through `CloudRouteClient.stubbed`,
/// so the case can assert on the frames the client *sent*. Held per instance
/// rather than in a process-wide global, which would leak between tests.
class SocketCapturingTestCase: XCTestCase {
    var capturedTask: StubWebSocketTask?
}

// MARK: - Per-case fixture handoff

/// Lets a case keep its `event:`/`data:` fixture literal while the transport it
/// is delivered over changes from HTTP to the socket.
///
/// A case sets `pendingFixture` before building its sink; the sink reads it once
/// per client it makes, so a case exercising several turns assigns again between
/// them (as the per-case stub it replaced did).
extension XCTestCase {
    var pendingFixture: String? {
        get { objc_getAssociatedObject(self, &pendingFixtureKey) as? String }
        set { objc_setAssociatedObject(self, &pendingFixtureKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// Returning the fixture (rather than `pendingFixture` directly) keeps a
    /// client built with no fixture from reusing the previous turn's frames.
    func nextFixture() -> String {
        let fixture = pendingFixture ?? ""
        pendingFixture = nil
        return fixture
    }
}

private nonisolated(unsafe) var pendingFixtureKey: UInt8 = 0

// MARK: - WebSocket test client

extension CloudRouteClient {
    /// A client whose transport is a stub socket carrying `fixture`.
    ///
    /// The fixture keeps the `event:`/`data:` shape the cases were written
    /// against; only the transport under it changed.
    static func stubbed(
        baseURL: String = "https://cloud.test",
        userId: String = "user_test",
        token: String? = "test_token",
        fixture: String
    ) -> (client: CloudRouteClient, task: StubWebSocketTask) {
        let task = StubWebSocketTask(textFrames: StubWebSocketTask.frames(fromFixture: fixture))
        let client = CloudRouteClient(
            baseURL: baseURL,
            userId: userId,
            requestTimeoutSeconds: 15,
            tokenProvider: StubTokenProvider(token: token),
            webSocketTaskFactory: { _ in task }
        )
        return (client, task)
    }
}

/// An open/closed latch shared between a test and the stub socket it stalls.
///
/// A latch rather than a semaphore: the socket asks before *every* frame, so a
/// single permit would let the first frame through and stall the second — which
/// is a hung turn, not a held one. `release()` opens it for the rest of the turn.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    /// Waits for the latch to open. Throws `CancellationError` if the waiting
    /// task is cancelled — a transport that ignores cancellation cannot be
    /// superseded, and swallowing the error here would hide that (as well as
    /// spin a cancelled task forever).
    func wait() async throws {
        while true {
            lock.lock()
            let open = isOpen
            lock.unlock()
            if open { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func release() {
        lock.lock()
        isOpen = true
        lock.unlock()
    }
}

extension StubWebSocketTask {
    /// Waits briefly for the socket to be closed.
    ///
    /// The closure happens in the client's producer task, while the consumer that
    /// drained the stream returns on another — the consumer can win that race, so
    /// a bare assertion here reads `nil` intermittently. Poll rather than race.
    func awaitCancellation(timeout: TimeInterval = 1) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if cancelled != nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cancelled != nil
    }

    /// The auth frame the client sent, as a JSON object.
    var sentAuthFrame: [String: Any]? {
        guard let first = sentTextFrames.first,
              let data = first.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - WebSocket transport double

/// Drives the route client's real transport in tests.
///
/// `URLProtocol` does not sit in front of `URLSessionWebSocketTask`, so a
/// URLProtocol stub cannot reach the transport the app ships. These tests drive
/// the client through `CloudRouteClient.WebSocketTasking` instead — the same
/// seam, and the same frames the server would send.
final class StubWebSocketTask: CloudRouteClient.WebSocketTasking {
    private var incoming: [URLSessionWebSocketTask.Message]
    private(set) var sent: [URLSessionWebSocketTask.Message] = []
    private(set) var cancelled: (code: URLSessionWebSocketTask.CloseCode, reason: Data?)?
    var receiveError: Error?

    init(_ incoming: [URLSessionWebSocketTask.Message]) {
        self.incoming = incoming
    }

    convenience init(textFrames: [String]) {
        self.init(textFrames.map { .string($0) })
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sent.append(message)
    }

    /// Holds delivery until `release()`, so a test can keep one turn in flight
    /// while another supersedes it. Without a way to stall a turn, a stub that
    /// answers instantly cannot express "A is still open when B starts".
    private var gate: Gate?

    func holdUntilReleased(_ gate: Gate) {
        self.gate = gate
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if let gate { try await gate.wait() }
        if let receiveError { throw receiveError }
        guard !incoming.isEmpty else {
            // A closed socket: the server ended the stream without a terminal
            // event, which the client must surface rather than treat as success.
            throw URLError(.badServerResponse)
        }
        return incoming.removeFirst()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = (closeCode, reason)
    }

    /// The JSON payloads the client sent, decoded for assertions.
    var sentTextFrames: [String] {
        sent.compactMap { message in
            if case let .string(text) = message { return text }
            return nil
        }
    }
}

extension StubWebSocketTask {
    /// Turn a legacy `event:`/`data:` fixture into the text frames the socket
    /// now carries, so a migrated case keeps its fixture readable.
    static func frames(fromFixture fixture: String) -> [String] {
        var frames: [String] = []
        var eventName: String?
        for rawLine in fixture.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                eventName = nil
                continue
            }
            if let rest = line.dropPrefix("event: ") ?? line.dropPrefix("event:") {
                eventName = rest.trimmingCharacters(in: .whitespaces)
            } else if let rest = line.dropPrefix("data: ") ?? line.dropPrefix("data:"), let eventName {
                let payload = rest.trimmingCharacters(in: .whitespaces)
                // The socket frames carry the type inside the JSON. `data:` is
                // already the full object except for its `type`, so merge it in
                // rather than rewrite every fixture.
                if payload.hasPrefix("{"), payload.hasSuffix("}") {
                    let body = payload.dropFirst().dropLast()
                    frames.append(#"{"type":"\#(eventName)","# + body + "}")
                } else {
                    frames.append(#"{"type":"\#(eventName)","text":"\#(payload)"}"#)
                }
            }
        }
        return frames
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
