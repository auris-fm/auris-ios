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

    /// Installs NO responder, so the URLProtocol fails every request it loads
    /// (`didFailWithError(.unknown)`). This is how a control asks for "the exchange cannot be
    /// answered" — `onRequest` is only an observer and cannot express it.
    static func clearStubHandler() {
        lock.lock()
        requestHandler = nil
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
        // A process-wide observer surviving into the next test would report another test's sends
        // as this one's, which is worse than no diagnostic at all.
        StubWebSocketTask.onSendObservation = nil
        // The sink diagnostic hooks are @MainActor and are NOT touched here: `reset()` is
        // nonisolated, so assigning them from it is a concurrency violation. Each diagnostic
        // method starts from nil and clears on every exit instead.
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
    /// The account this stub's credential authenticates. Defaulted only so the many transport
    /// cases that never inspect ownership keep reading as "some account"; a case that asserts on
    /// the journaled owner passes it explicitly.
    var accountId: String = "test-owner"

    func token() async -> String? { token }

    /// EXPLICIT. This provider previously inherited the protocol's `nil` default, so every
    /// transport case silently ran unauthenticated — which is what "unauthorized" was doing in
    /// the client suite. A stub with no token has no session, and says so here rather than by
    /// omission.
    func authenticatedSession() async -> CloudAuthenticatedSession? {
        // An EMPTY account is "no principal", not an account named "". A session with a blank
        // owner would satisfy `authenticatedSession != nil` while naming nobody, which is the
        // fabricated-identity shape this whole change exists to prevent.
        guard let token, !accountId.isEmpty else { return nil }
        return CloudAuthenticatedSession(accountId: accountId, accessToken: token)
    }

    func handleUnauthorized(rejectedToken: String?) async {}
}

/// A provider whose VALIDATED acquisition completes only when the test releases it. Proves the
/// sink AWAITS the acquisition instead of sampling it: sampling binds an empty owner to a turn
/// that subsequently authenticates perfectly well, and that window is invisible in a case whose
/// subject is something else.
final class DelayedAcquisitionTokenProvider: CloudTokenProviding, @unchecked Sendable {
    private let credential: String
    private let accountId: String
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var acquisitions = 0

    init(credential: String, accountId: String) {
        self.credential = credential
        self.accountId = accountId
    }

    var acquisitionCount: Int { lock.lock(); defer { lock.unlock() }; return acquisitions }

    func release() { gate.signal() }

    func token() async -> String? {
        withLock { acquisitions += 1 }
        while gate.wait(timeout: .now() + 0.02) == .timedOut {}
        return credential
    }

    /// The paired snapshot, arriving late. Transport falls back to `token()` only when this is
    /// nil, so this path also proves the credential presented is the snapshot's own.
    func authenticatedSession() async -> CloudAuthenticatedSession? {
        withLock { acquisitions += 1 }
        while gate.wait(timeout: .now() + 0.02) == .timedOut {}
        return CloudAuthenticatedSession(accountId: accountId, accessToken: credential)
    }

    func transportCredential() async -> String? {
        while gate.wait(timeout: .now() + 0.02) == .timedOut {}
        return credential
    }

    func handleUnauthorized(rejectedToken: String?) async {}

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
}

/// A test case whose sut builds its client through `CloudRouteClient.stubbed`,
/// so the case can assert on the frames the client *sent*. Held per instance
/// rather than in a process-wide global, which would leak between tests.
/// Completion flag for the BOUNDED probe below: an INDEPENDENT signal set by a detached watcher,
/// so the probe can poll it under a bound without awaiting the watched task's value.
///
/// Lives here, beside the only user, rather than privately inside one suite: the probe used to
/// reference a flag that was `private` to a DIFFERENT file, and moving the consumer without its
/// dependency is what made the shared helper fail to compile.
final class ProbeCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() { lock.lock(); done = true; lock.unlock() }
    var isSet: Bool { lock.lock(); let d = done; lock.unlock(); return d }
}

class SocketCapturingTestCase: XCTestCase {
    /// STABLE LABEL for the task the client actually dispatched on, recorded by the transport
    /// itself. `capturedTask` is overwritten by EVERY factory call, so on a multi-turn test it
    /// answers "which task was built last", not "which task received the frame". Those are
    /// different questions, and conflating them is how a submitted frame looked unsent.
    var dispatchedTaskLabel: String?
    var capturedTask: StubWebSocketTask?
    /// The client built for the most recent turn, so a control can hand a PRIOR turn its own
    /// transport instead of the live one.
    var capturedClient: CloudRouteClient?
    /// The sink a control hooked, so a first-frame hook can reach the object it is asserting on.
    /// Hoisted here because more than one suite needs it and a per-suite `private` copy is how it
    /// came to be referenced from the wrong class.
    var hookedSink: CloudRouteSink?

    /// BOUNDED completion probe: an INDEPENDENT completion flag set by a detached watcher; the
    /// probe polls the flag under a bound and NEVER awaits the watched task's value inside the
    /// group (a cancelled probe must not hang on the underlying wait).
    func timeoutProbe<T>(_ task: Task<T, Never>, nanoseconds: UInt64) async throws -> Bool {
        let flag = ProbeCompletionFlag()
        let watcher = Task.detached { _ = await task.value; flag.set() }
        var completed = false
        var elapsed: UInt64 = 0
        while elapsed < nanoseconds {
            if flag.isSet { completed = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
            elapsed += 50_000_000
        }
        if !completed { watcher.cancel() } // benign leak: the watcher cannot free the underlying wait
        return completed
    }
}

/// A valid prepared conversation for envelope construction in tests. Each call
/// mints a FRESH admitted id unless a literal is supplied — mirroring the
/// production rule that every turn carries its own admitted UUID identity.

/// ONE IDENTITY (reviewer c580c42b): client tests that don't assert wire identity still must
/// pass an EXPLICIT prepared turn — the convenience mint is gone from production.
func testTurnEnvelope(
    requestId: String = "7f9c24e5-8b1a-4c02-9e6d-31b5a0f47c88",
    conversationId: String = "1c4b9a70-6d2e-4f38-a511-9b7c2d0e54a3",
    mode: String = "create"
) -> CloudTurnEnvelope {
    CloudTurnEnvelope.make(
        capabilities: [],
        routeHint: nil,
        recentConversation: [],
        conversation: CloudPreparedConversation(
            requestId: requestId,
            conversationId: conversationId,
            mode: mode
        )
    )
}

func testPreparedConversation(
    requestId: String = UUID().uuidString,
    conversationId: String = UUID().uuidString,
    mode: String = "create"
) -> CloudPreparedConversation {
    CloudPreparedConversation(requestId: requestId, conversationId: conversationId, mode: mode)
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
        audioPayloads: [Data] = [],
        prepareTask: @Sendable (StubWebSocketTask) -> Void = { _ in },
        /// The token provider the client actually acquires from — the ONE seam an owner can come
        /// from. A control that asserts on the journaled owner passes a provider whose credential
        /// AND account are the same fixture, so the pair travels together through the real
        /// acquisition instead of being re-attached to the socket afterwards.
        ///
        /// `nil` means "derive it from `token`", keeping every existing case unchanged. Stated as
        /// an explicit absence rather than defaulted inline so `token` cannot silently apply while
        /// a provider is also supplied.
        tokenProvider: (any CloudTokenProviding)? = nil
    ) -> (client: CloudRouteClient, task: StubWebSocketTask) {
        var messages: [URLSessionWebSocketTask.Message] = []
        let textFrames = StubWebSocketTask.frames(fromFixture: fixture)
        // Interleave: deliver each audio payload, then the text frames that follow it. With no
        // payloads this is exactly the previous text-only behaviour.
        messages.append(contentsOf: audioPayloads.map { .data($0) })
        messages.append(contentsOf: textFrames.map { .string($0) })
        let task = StubWebSocketTask(messages)
        // Install holds BEFORE the client exists: the producer parks at its FIRST receive, so a
        // cancellation-insensitive park cannot be raced by stream end.
        prepareTask(task)
        let client = CloudRouteClient(
            baseURL: baseURL,
            userId: userId,
            requestTimeoutSeconds: 15,
            tokenProvider: tokenProvider ?? StubTokenProvider(token: token),
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
/// Control-only handle to the REAL owning task, bound after the task exists. The gate lands
/// cancellation here exactly as an external caller would; the sink's control seam invokes it, so
/// there is no synthesized flag and no path where cancellation is observed but never lands.
final class ControlCanceller: @unchecked Sendable {
    private let lock = NSLock()

    func bind<Success>(_ task: Task<Success, Never>) {
        lock.lock()
        cancelBox = { task.cancel() }
        lock.unlock()
    }

    private var cancelBox: (() -> Void)?

    func cancel() {
        lock.lock(); let box = cancelBox; lock.unlock()
        box?()
    }
}

/// EXPLICIT-RELEASE-ONLY effect hold. Deliberately has NO task-cancellation handling of any
/// kind (unlike `Gate`): owner cancellation can NEVER release it — only `release()` does.
/// Controls assert `released` to probe that the waiter is still held before explicit release.
/// A one-shot promise: resolves exactly once, from whichever task gets there first. Used so a
/// bounded wait can be raced against an unbounded suspension WITHOUT leaving a task-group child
/// blocked on that suspension (the group would then never drain).
final class Promise<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    func resolve(_ value: Value) {
        lock.lock()
        guard self.value == nil, waiter != nil || true, !resolvedFlag else { lock.unlock(); return }
        resolvedFlag = true
        self.value = value
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: value)
    }

    private var resolvedFlag = false

    /// Test-only: marks the promise as settled by a CLOSE rather than by its resolver, so a
    /// blocking seam can wait for the close itself to have run. Distinct from `resolve` so a
    /// control can both signal "close requested" and observe "close done" on one object.
    private var closedFlag = false
    var didClose: Bool {
        lock.lock(); defer { lock.unlock() }
        return closedFlag
    }
    func markClosed() {
        lock.lock(); closedFlag = true; lock.unlock()
    }

    func value() async -> Value {
        await withCheckedContinuation { (cont: CheckedContinuation<Value, Never>) in
            lock.lock()
            if let v = value {
                lock.unlock()
                cont.resume(returning: v)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }
}

final class HoldLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var resume: (() -> Void)?

    /// True once `release()` has run — the still-held probe for controls.
    var released: Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    /// Suspends until explicit release. Registers under the same lock as the open check so a
    /// release landing during registration cannot be lost. No onCancel path exists.
    func waitUntilReleased() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if open {
                lock.unlock()
                cont.resume()
            } else {
                resume = cont.resume
                lock.unlock()
            }
        }
    }

    /// Suspends until explicit release OR an external retirement predicate becomes true (the
    /// wake-on-cancel semantics a real transport cancellation gives a parked receive). The
    /// WAITING task's own cancellation never releases it — only `release()` or the predicate
    /// does. Wake is delivered by `notifyRetired()` under the SAME lock that guards the
    /// registered waiter, so there is no poll and no lost wake: a retirement that lands before
    /// the waiter registers is observed at registration.
    func wait(untilRetired isRetired: @escaping @Sendable () -> Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            // Predicate is installed and evaluated under the same lock as the open check, so a
            // retirement that already happened cannot be missed by a waiter that arrives late.
            retiredCheck = isRetired
            if open {
                lock.unlock()
                cont.resume()
            } else if let f = retiredCheck, f() {
                open = true
                openedByRetirement = true
                lock.unlock()
                cont.resume()
            } else {
                resume = cont.resume
                lock.unlock()
            }
        }
    }

    /// Wake every parked `wait(untilRetired:)` because the retirement predicate fired (the
    /// production onCancel path ran). Called by the control at the retirement seam.
    func notifyRetired() {
        lock.lock()
        guard !open else { lock.unlock(); return }
        open = true
        openedByRetirement = true
        let r = resume
        resume = nil
        lock.unlock()
        r?()
    }

    private var retiredCheck: (@Sendable () -> Bool)?

    /// True when the latch opened because the external retirement predicate fired (socket was
    /// cancelled) rather than an explicit test `release()`. Only latches armed with
    /// `wait(untilRetired:)` can report this.
    var releasedByRetirement: Bool {
        lock.lock(); defer { lock.unlock() }
        return openedByRetirement
    }
    private var openedByRetirement = false

    func release() {
        lock.lock()
        open = true
        let r = resume
        resume = nil
        lock.unlock()
        r?()
    }
}

final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    /// TICKET-STATE WAITERS. Every `wait` gets its own ticket; ALL of a ticket's mutable state is
    /// touched only under the gate lock, which makes three previously racy transitions exact:
    ///
    ///   - CANCELLATION BEFORE REGISTRATION: `withTaskCancellationHandler` may run `onCancel`
    ///     before the operation body has registered its continuation. A single stored `resume`
    ///     would be nil there, cancellation would be missed, and the later-registered continuation
    ///     would wait forever. A ticket flips its `cancelled` flag under the lock in that window,
    ///     and the body observes the flag at registration time and throws instead of parking.
    ///   - TIMED-OUT OBSERVER LEAKS: a bounded wait's loser is cancelled, and cancellation removes
    ///     that loser's OWN ticket from the waiters table. `release()` then resumes only tickets
    ///     still present, so no timed-out observer is retained (or double-resumed).
    ///   - RELEASE vs CANCELLATION: whichever transition removes the ticket from the table first
    ///     owns the single resume; the other observes the absence and does nothing.
    private final class Ticket {
        var cancelled = false
        var continuation: CheckedContinuation<Void, Error>?
    }
    private var waiters: [ObjectIdentifier: Ticket] = [:]

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

    /// Waits for release WITHOUT polling. The ticket is registered UNDER the same lock
    /// that guards `isOpen`, so a release that lands between the state check and registration
    /// cannot be lost. Throws `CancellationError` on task cancellation (including cancellation
    /// that arrived BEFORE registration — the ticket flag closes that window); `untilCancelled`
    /// lets a parked transport wake on external retirement.
    func wait(untilCancelled isExternallyCancelled: (@Sendable () -> Bool)?) async throws {
        let ticket = Ticket()
        let ticketID = ObjectIdentifier(ticket)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    cont.resume()
                    return
                }
                if ticket.cancelled {
                    // Cancellation landed before this registration ran: honor it NOW instead of
                    // parking a waiter that would never be woken.
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                if let f = isExternallyCancelled, f() {
                    lock.unlock()
                    cont.resume(throwing: URLError(.cancelled))
                    return
                }
                ticket.continuation = cont
                waiters[ticketID] = ticket
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            ticket.cancelled = true
            // Remove OUR ticket only: an observer whose own cancellation fired must not release
            // anyone else, and a released gate has already emptied the table.
            if let t = waiters.removeValue(forKey: ticketID) {
                let c = t.continuation
                t.continuation = nil
                lock.unlock()
                c?.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = [:]
        var resumes: [CheckedContinuation<Void, Error>] = []
        for t in pending.values {
            if let c = t.continuation {
                resumes.append(c)
                t.continuation = nil
            }
        }
        lock.unlock()
        for c in resumes { c.resume(returning: ()) }
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
        let token = ObjectIdentifier(gate)
        cancellationWaiters.append(CancellationWaiter(token: token, fire: { [gate] in gate.release() }))
        snapshotLock.unlock()
        // OWNERSHIP-BASED REMOVAL: however this wait ends — cancellation, timeout, or group
        // teardown — THIS observer's closure leaves the registry. The registry can therefore
        // never accumulate timed-out observers.
        defer { removeCancellationWaiter(token: token) }
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
    /// THE SCRIPTED INBOX IS SHARED STATE. A test appends to it while the producer is looping in
    /// `receive()`, so every read and every append takes this lock; without it the append races the
    /// producer's `removeFirst()`.
    private let inboxLock = NSLock()
    private var incoming: [URLSessionWebSocketTask.Message]
    /// Signals that a control has appended a frame for a live, parked socket. Released ONCE, by the
    /// control, and only when it actually appended — a park that is released for any other reason
    /// (cancellation, retirement, timeout) must NOT be treated as evidence of new data.
    private let appendedFrameLatch = HoldLatch()
    private(set) var sent: [URLSessionWebSocketTask.Message] = []
    private(set) var cancelled: (code: URLSessionWebSocketTask.CloseCode, reason: Data?)?
    var receiveError: Error?


    /// Set by the control: invoked when THIS socket retires (`cancel(with:reason:)`), so a
    /// parked receive wakes from the same retirement instead of polling a predicate.
    var retiredParkNotifier: (() -> Void)?

    init(_ incoming: [URLSessionWebSocketTask.Message]) {
        self.incoming = incoming
    }

    /// THE SERVER SENDS MORE MID-TURN. Appends an inbound frame to a LIVE socket and wakes a
    /// receive parked at the awaited seam, so a control can deliver a genuinely late inbound frame
    /// to a turn that is still running — instead of hand-invoking a testing entry point after every
    /// turn has already ended, which proves nothing about ordering.
    ///
    /// Waking is an APPEND-SPECIFIC signal, not the retirement notifier: the park resumes on it and
    /// serves the appended frame normally, because content is available again. A park released for
    /// any other reason does not set it, so "released" is never confused with "new data arrived".
    func appendInboundText(_ frame: String) {
        inboxLock.lock()
        incoming.append(.string(frame))
        inboxLock.unlock()
        // ONE-TIME, EXPLICIT release of the appended-frame latch. Deliberately NOT the retirement
        // notifier: retirement means "this socket is going away", which is the opposite of "new
        // data arrived", and reusing it made a cancellation look like a delivery.
        appendedFrameLatch.release()
    }

    /// True when the producer is parked and a control has since appended new data for it.
    var didAppendWhileParked: Bool { appendedFrameLatch.released }

    /// Frames actually HANDED to the producer, in order. A control that needs "this exact frame was
    /// consumed" must read this; a positive receive count only proves SOMETHING was read.
    private(set) var servedInboundTexts: [String] = []

    /// Take the head frame, or report the inbox as empty, under the inbox lock.
    private func takeInbound() -> URLSessionWebSocketTask.Message? {
        inboxLock.lock(); defer { inboxLock.unlock() }
        guard !incoming.isEmpty else { return nil }
        let next = incoming.removeFirst()
        switch next {
        case .string(let text): servedInboundTexts.append(text)
        case .data: break
        @unknown default: break
        }
        return next
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

    /// STABLE IDENTITY for this stub task, so a diagnostic can say WHICH task a frame landed on
    /// rather than "the last one a factory happened to build".
    let diagnosticLabel: String = UUID().uuidString.prefix(8).description

    /// DIAGNOSTIC ONLY (test target): called for every frame that reaches the transport, with this
    /// task's label and the frame's `type`. Lets a control observe the send from the RECEIVING
    /// side, which is the only side that can distinguish "dispatched elsewhere" from "never sent".
    static var onSendObservation: (@Sendable (String, String?) -> Void)?

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if throwsBeforeRecording { throw URLError(.notConnectedToInternet) }
        sent.append(message)
        if let observe = Self.onSendObservation {
            var kind: String?
            if case let .string(text) = message,
               let data = text.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                kind = json["type"] as? String
            }
            observe(diagnosticLabel, kind)
        }
        if transmitsThenThrows { throw URLError(.networkConnectionLost) }
    }

    /// Holds delivery until `release()`, so a test can keep one turn in flight
    /// while another supersedes it. Without a way to stall a turn, a stub that
    /// answers instantly cannot express "A is still open when B starts".
    private var holdGate: Gate?

    func holdUntilReleased(_ gate: Gate) {
        self.holdGate = gate
    }

    /// Cancellation-insensitive parking (HoldLatch): the receive stays parked until explicit
    /// release — task cancellation cannot wake it. Used to prove prompt production retirement.
    func holdUntilReleased(_ latch: HoldLatch) {
        self.holdLatch = latch
    }
    private var holdLatch: HoldLatch?

    // MARK: - Explicit transport signals (spec dd2071d3)

    /// OBSERVABLE BOUNDARIES, not inferred ones. A control that infers "the predecessor was parked"
    /// from elapsed time or from a latch expiring cannot distinguish a live predecessor from a
    /// finished one — which is exactly how this file's sibling control passed while proving
    /// nothing. These record the transport's own crossings so a case can assert them directly.

    /// The first `receive()` was entered — the receiver is genuinely live and consuming.
    private(set) var receiveEntered = false
    /// True only for the AWAITED `receive()` park, set inside `receive()` immediately before it
    /// suspends. This — not `declaredParkDidPark` — is the observable proof that the producer is
    /// blocked at the receive seam rather than having finished.
    var didParkInReceive = false
    /// The scripted terminal (`done`/`error`) has been WITHHELD: the receive that would serve it is
    /// parked. This is the state a barge-in must be able to interrupt.
    private(set) var terminalWithheld = false
    /// True when an `interrupt` frame left on THIS socket.
    var sentInterrupt: Bool { sentTextFrames.contains { $0.contains("\"interrupt\"") } }
    /// Set when the terminal has been released and served.
    private(set) var terminalReleased = false

    /// Holds ONLY the FIRST receive until explicit release; every later receive proceeds, so the
    /// scripted events (including the terminal `done`) are served once the test lets go.
    ///
    /// Needed because `holdUntilReleased(_ latch:)` parks EVERY receive: fine for "prove retirement
    /// wakes a parked transport", wrong for "keep this turn in flight, then let it settle
    /// normally", where the turn would never reach its terminal and a control about what happens
    /// AFTER the terminal could never run.
    func holdFirstReceiveUntilReleased(_ latch: HoldLatch) {
        self.firstReceiveHold = latch
    }
    private var firstReceiveHold: HoldLatch?
    private var firstReceiveHeld = false

    /// ARMED AT CREATION, not at the claim boundary. An earlier design armed it from the sink's
    /// `effectEntered` hook, but measurement showed the transport has already served its frames
    /// by then (`pendingArmed=false` on every serve), so the park never intercepted a receive and
    /// the "retirement woke the park" assertion could never be true. The path this seam must
    /// cover is declared per store instead: see `armedReceivePark` below.
    var armReceiveHoldOnEntered: HoldLatch?
    private let armedParkGate = Gate()
    private var pendingArmedReceiveHold = false
    private var armedReceiveLatch: HoldLatch?
    func armReceiveHold() {
        guard let latch = armReceiveHoldOnEntered else { return }
        armedReceiveLatch = latch
        armReceiveHoldOnEntered = nil
        pendingArmedReceiveHold = true
    }

    /// A park that WAITS OUT the turn: `receive()` holds here until `release()` or socket
    /// retirement. Installed at task creation (before the first frame), so the parked receive
    /// genuinely exists when cancellation lands — which is the whole point of the control. It
    /// sits AFTER the action frame in the scripted sequence, so the claim and the effect boundary
    /// are reached first.
    var declaredParkAfterFrames: Int?
    var framesServedForPark = 0
    var armedReceivePark: HoldLatch?
    /// True when the declared park actually parked — a skipped park must be a failure, not a
    /// silent no-op (this is the defect the earlier arming design hid).
    var declaredParkDidPark = false

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

    /// When set, EVERY receive parks until explicit release — used to prove retirement wakes a
    /// parked transport. (Installed post-`entered`, this let the producer's FIRST receive run
    /// ungated and exit normally on stream end; that retired the transport through the drain
    /// path and made the immediate-retirement mutant look green. Closed by the arm-on-entered
    /// seam below.)
    func holdAllReceivesUntilReleased(_ latch: HoldLatch) {
        self.allReceiveHold = latch
    }
    private var allReceiveHold: HoldLatch?

    func receive() async throws -> URLSessionWebSocketTask.Message {
        receiveEntered = true
        // Parked receives must WAKE on socket cancellation: a retired socket cannot keep the
        // producer busy-waiting or holding a closed connection concept open.
        if pendingArmedReceiveHold {
            pendingArmedReceiveHold = false
            if let latch = armedReceiveLatch {
                armedParkGate.release()
                await latch.wait(untilRetired: { self.isCancelledSocket })
            }
        } else if let park = armedReceivePark, framesServedForPark >= (declaredParkAfterFrames ?? 0) {
            // AWAITED park: the producer blocks HERE, inside `receive()`, holding the scripted
            // frames behind it. Set the signal before suspending so a control can observe the
            // hold as a fact about the producer rather than as a timing assumption.
            declaredParkDidPark = true
            didParkInReceive = true
            // Wake on retirement OR on an explicitly appended frame. Both wake paths are explicit
            // events; the appended-frame latch is separate from the retirement notifier so a
            // cancellation is never mistaken for new data.
            await park.wait(untilRetired: { self.isCancelledSocket || self.appendedFrameLatch.released })
            didParkInReceive = false
        } else if let latch = firstReceiveHold, !firstReceiveHeld {
            firstReceiveHeld = true
            terminalWithheld = true
            await latch.waitUntilReleased()
            terminalReleased = true
        } else if let holdLatch {
            // Cancellation-INSENSITIVE park: only explicit release wakes this receive.
            await holdLatch.waitUntilReleased()
        } else if let holdGate {
            // Wake on socket retirement WITHOUT cancelling the consumer task: this is a test
            // transport, and a thrown error here would end the AsyncStream via the producer and
            // blur "socket retired" with "stream terminated". The waiter resumes when cancel
            // runs; we then serve the remaining scripted events normally.
            _ = try? await holdGate.wait(untilCancelled: { self.isCancelledSocket })
        }
        framesServedForPark += 1
        if let receiveError { throw receiveError }
        guard let next = takeInbound() else {
            // A closed socket: the server ended the stream without a terminal
            // event, which the client must surface rather than treat as success.
            throw URLError(.badServerResponse)
        }
        return next
    }

    /// Cancellation observers with OWNERSHIP. Each entry carries its token so the observer that
    /// registered it can remove its own closure when its wait ends by TIMEOUT rather than by
    /// cancellation — a timed-out observer that stayed registered would retain its gate and fire
    /// on a much later cancel. `cancel(with:)` drains the registry it fires; a surviving
    /// observer registered afterwards is unaffected.
    fileprivate struct CancellationWaiter {
        let token: ObjectIdentifier
        let fire: @Sendable () -> Void
    }
    fileprivate var cancellationWaiters: [CancellationWaiter] = []

    /// Test-side inspection of the ACTUAL registry: how many observers are still registered.
    var cancellationWaiterCountForTesting: Int {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return cancellationWaiters.count
    }

    private func removeCancellationWaiter(token: ObjectIdentifier) {
        snapshotLock.lock()
        cancellationWaiters.removeAll { $0.token == token }
        snapshotLock.unlock()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        snapshotLock.lock()
        cancelled = (closeCode, reason)
        let waiters = cancellationWaiters
        cancellationWaiters = []
        snapshotLock.unlock()
        for w in waiters { w.fire() }
        retiredParkNotifier?()
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
