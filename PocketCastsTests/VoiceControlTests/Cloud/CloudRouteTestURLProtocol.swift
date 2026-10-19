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
        fixture: String,
        /// OPT-IN binary audio. The transport delivers audio as `.data` frames
        /// (`CloudRouteClient` maps `case .data` to `.audioFrame`), but this factory built only
        /// text frames, so no case could put real audio in front of the player and an assertion
        /// about audio output was vacuous. Each entry becomes one `.string`-after-`.data` pair:
        /// the binary payload the transport treats as audio, followed by the text event that
        /// follows it. Empty by default, so every existing text fixture behaves exactly as before.
        audioPayloads: [Data] = []
    ) -> (client: CloudRouteClient, task: StubWebSocketTask) {
        var messages: [URLSessionWebSocketTask.Message] = []
        let textFrames = StubWebSocketTask.frames(fromFixture: fixture)
        // Interleave: deliver each audio payload, then the text frames that follow it. With no
        // payloads this is exactly the previous text-only behaviour.
        messages.append(contentsOf: audioPayloads.map { .data($0) })
        messages.append(contentsOf: textFrames.map { .string($0) })
        let task = StubWebSocketTask(messages)
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
    private var resume: ((Result<Void, Error>) -> Void)?

    /// Waits for the latch to open. Throws `CancellationError` if the waiting
    /// task is cancelled — a transport that ignores cancellation cannot be
    /// superseded, and swallowing the error here would hide that (as well as
    /// spin a cancelled task forever).
    func wait() async throws {
        try await wait(untilCancelled: nil)
    }

    /// Bounded wait used by controls to fail fast instead of hanging a suite.
    func wait(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.wait() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Waits for release WITHOUT polling. The continuation is registered UNDER the same lock
    /// that guards `isOpen`, so a release that lands between the state check and registration
    /// cannot be lost (cancel-before-continuation race closed). Throws `CancellationError` on
    /// task cancellation; `untilCancelled` lets a parked transport wake on external retirement.
    func wait(untilCancelled isExternallyCancelled: (@Sendable () -> Bool)?) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    cont.resume()
                } else if let f = isExternallyCancelled, f() {
                    lock.unlock()
                    cont.resume(throwing: URLError(.cancelled))
                } else {
                    resume = cont.resume   // registered atomically with the open check
                    lock.unlock()
                }
            }
        } onCancel: {
            var r: ((Result<Void, Error>) -> Void)?
            lock.lock(); r = resume; resume = nil; lock.unlock()
            r?(.failure(CancellationError()))
        }
    }

    func release() {
        var r: ((Result<Void, Error>) -> Void)?
        lock.lock()
        isOpen = true
        r = resume
        resume = nil
        lock.unlock()
        r?(.success(()))
    }

    var released: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }
}

extension StubWebSocketTask {
    /// Waits briefly for the socket to be closed.
    ///
    /// The closure happens in the client's producer task, while the consumer that
    /// drained the stream returns on another — the consumer can win that race, so
    /// a bare assertion here reads `nil` intermittently. Poll rather than race.
    /// Continuation-based wait for socket cancellation (no polling): resumes when `cancel(with:)`
    /// runs or the bounded timeout elapses.
    /// Bounded, race-safe wait for socket cancellation. The waiter is registered UNDER the
    /// snapshot lock (so a cancel landing during setup cannot be missed), and the timeout wins
    /// via a racing sleep — no polling loop, no ignored timeout.
    func awaitCancellation(timeout: TimeInterval = 1) async -> Bool {
        let gate = Gate()
        snapshotLock.lock()
        if cancelled != nil {
            snapshotLock.unlock()
            return true
        }
        cancellationWaiters.append({ [gate] in gate.release() })
        snapshotLock.unlock()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await gate.wait(untilCancelled: { self.isCancelledSocket })
                return self.isCancelledSocket
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return self.isCancelledSocket
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first || self.isCancelledSocket
        }
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

    /// When set, a send RECORDS the frame and then throws — the transmit-then-fail case. The frame
    /// demonstrably left, so a client that marked submission only on a successful return would
    /// misclassify this as never-submitted and replay a turn that may have been admitted.
    var transmitsThenThrows = false

    /// When set, a send THROWS WITHOUT RECORDING — the frame never reached the transport, which is
    /// the pre-entry failure that proves it was never submitted and is therefore the one case
    /// automatic recovery may re-drive.
    var throwsBeforeRecording = false

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if throwsBeforeRecording { throw URLError(.notConnectedToInternet) }
        sent.append(message)
        if transmitsThenThrows { throw URLError(.networkConnectionLost) }
    }

    /// Holds delivery until `release()`, so a test can keep one turn in flight
    /// while another supersedes it. Without a way to stall a turn, a stub that
    /// answers instantly cannot express "A is still open when B starts".
    private var gate: Gate?

    func holdUntilReleased(_ gate: Gate) {
        self.gate = gate
    }

    /// True once `cancel(with:reason:)` has run — the observable retirement of the ORIGINAL
    /// registration at the transport level.
    var isCancelledSocket: Bool {
        lockForSnapshot()
        defer { unlockForSnapshot() }
        return cancelled != nil
    }
    private func lockForSnapshot() { snapshotLock.lock() }
    private func unlockForSnapshot() { snapshotLock.unlock() }
    private let snapshotLock = NSLock()

    func receive() async throws -> URLSessionWebSocketTask.Message {
        // Parked receives must WAKE on socket cancellation: a retired socket cannot keep the
        // producer busy-waiting or holding a closed connection concept open.
        if let gate {
            // Wake on socket retirement WITHOUT cancelling the consumer task: this is a test
            // transport, and a thrown error here would end the AsyncStream via the producer and
            // blur "socket retired" with "stream terminated". The waiter resumes when cancel
            // runs; we then serve the remaining scripted events normally.
            _ = try? await gate.wait(untilCancelled: { self.isCancelledSocket })
        }
        if let receiveError { throw receiveError }
        guard !incoming.isEmpty else {
            // A closed socket: the server ended the stream without a terminal
            // event, which the client must surface rather than treat as success.
            throw URLError(.badServerResponse)
        }
        return incoming.removeFirst()
    }

    fileprivate var cancellationWaiters: [@Sendable () -> Void] = []

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        snapshotLock.lock()
        cancelled = (closeCode, reason)
        let waiters = cancellationWaiters
        cancellationWaiters = []
        snapshotLock.unlock()
        for w in waiters { w() }
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
