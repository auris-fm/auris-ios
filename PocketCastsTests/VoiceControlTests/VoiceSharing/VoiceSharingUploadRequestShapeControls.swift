import XCTest
@testable import podcasts

/// What actually leaves the device: the request the server is asked to parse.
final class VoiceSharingUploadRequestShapeControls: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsreq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// The server refuses an undeclared body before it parses anything. A chunked upload carries no
    /// length, so this asserts the header is present AND equals the bytes actually sent — a header
    /// that merely exists while the body is streamed is not what was asked for.
    func test_theRequestDeclaresItsExactBodyLengthAndIsNotChunked() async throws {
        RecordingWire.shared.reset()
        let queue = VoiceSharingQueue(root: root, log: { _ in })
        _ = await queue.publish(audio: Data(repeating: 7, count: 4_096),
                          metadata: Data(#"{"enrollment_epoch":"epoch-1"}"#.utf8),
                          name: "one")
        let published = await queue.entries()
        let entry = try XCTUnwrap(published.first)

        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: RecordingTokens(),
            session: RecordingWire.session)
        let answer = await transport.send(entry: entry)
        XCTAssertEqual(answer, .response(status: 201))

        let request = try XCTUnwrap(RecordingWire.shared.request, "the request reached the wire")
        let declared = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Length"),
                                     "an undeclared body is refused before parsing")
        let sent = try XCTUnwrap(RecordingWire.shared.bodyLength,
                                 "the body must be present and fully materialised, not streamed")
        XCTAssertEqual(Int(declared), sent, "the declared length is the length actually sent")
        XCTAssertNil(request.value(forHTTPHeaderField: "Transfer-Encoding"),
                     "no chunked encoding")
    }

    /// The server's access log attributes uploads to a platform via the User-Agent header; uploads
    /// must carry the app's user agent exactly like the account-surface requests.
    func test_theUploadCarriesTheAppUserAgent() async throws {
        RecordingWire.shared.reset()
        let queue = VoiceSharingQueue(root: root, log: { _ in })
        _ = await queue.publish(audio: Data(repeating: 7, count: 4_096),
                          metadata: Data(#"{"enrollment_epoch":"epoch-1"}"#.utf8),
                          name: "ua")
        let published = await queue.entries()
        let entry = try XCTUnwrap(published.first)

        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: RecordingTokens(),
            session: RecordingWire.session,
            userAgentProvider: { "Pocket Casts/iOS/9.9-test" })
        let answer = await transport.send(entry: entry)
        XCTAssertEqual(answer, .response(status: 201))

        let request = try XCTUnwrap(RecordingWire.shared.request, "the request reached the wire")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Pocket Casts/iOS/9.9-test")
    }

    /// A STOP cancels the attempt it was asked to cancel and nothing after it. Once the user turns
    /// sharing back on, the very next send must reach the wire: a stop that also refused every later
    /// transfer would leave the feature permanently unable to upload, and nothing would report it.
    func test_aCancelledAttemptDoesNotRefuseTheNextOne() async throws {
        RecordingWire.shared.reset()
        let queue = VoiceSharingQueue(root: root, log: { _ in })
        _ = await queue.publish(audio: Data(repeating: 5, count: 1_024),
                          metadata: Data(#"{"enrollment_epoch":"epoch-1"}"#.utf8),
                          name: "one")
        let published = await queue.entries()
        let entry = try XCTUnwrap(published.first)

        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: RecordingTokens(),
            session: RecordingWire.session)

        // A stop while nothing is in flight must not poison the transport.
        transport.cancelInFlight()

        let answer = await transport.send(entry: entry)
        XCTAssertEqual(answer, .response(status: 201),
                       "a send after a stop is a fresh attempt, not a cancelled one")
        XCTAssertNotNil(RecordingWire.shared.request, "the request reached the wire after the stop")
    }

    /// A STOP THAT HAS ALREADY HAPPENED. Permission is read inside the same critical section that
    /// creates and publishes the transfer, and the transfer is created ONLY if that read permits it.
    /// So a stop cannot be overtaken: it either makes this read refuse, in which case nothing is ever
    /// created, or it arrives after publication, in which case `cancelInFlight()` reaches the task.
    /// There is no third ordering in which a transfer exists and nothing can cancel it.
    ///
    /// Two things must hold of the refused path, not one: nothing reaches the wire, AND the call
    /// returns. Refusing without sending is the visible half; an attempt that never returned would
    /// also pass a "no request" assertion while blocking its caller forever. The bounded wrapper
    /// below turns that into a failure instead of a hung suite.
    func test_aStopBeforeTheAttemptNeitherSendsNorStrandsTheAttempt() async throws {
        RecordingWire.shared.reset()
        let queue = VoiceSharingQueue(root: root, log: { _ in })
        _ = await queue.publish(audio: Data(repeating: 3, count: 512),
                          metadata: Data(#"{"enrollment_epoch":"epoch-1"}"#.utf8),
                          name: "one")
        let published = await queue.entries()
        let entry = try XCTUnwrap(published.first)

        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: RecordingTokens(),
            session: RecordingWire.session)
        let box = VoiceSharingPermissionBox()
        box.consentHeld = false   // the user withdrew before this attempt began
        let answer = await Self.bounded(seconds: 5) {
            await transport.send(entry: entry, stillPermitted: {
                box.wasAsked = true
                return box.consentHeld
            })
        }

        XCTAssertNil(RecordingWire.shared.request,
                     "a withdrawal must not let the recording reach the network")
        let settled = try XCTUnwrap(answer,
                                    "the refused attempt must finish, not leave a transfer waiting")
        XCTAssertNotEqual(settled, .response(status: 201), "a stopped attempt is not reported as a reply")
        XCTAssertTrue(box.wasAsked, "permission is consulted before anything is registered")
    }

    /// A STOP THAT LANDS AFTER THE START. The transfer is already published, so the cancel reaches it:
    /// it must not send, and it must finish. A gate that ignored cancellation would leave the transfer
    /// yielding forever, which is why the second assertion is not optional.
    func test_aStopAfterTheTransferIsPublishedEndsItWithoutSending() async throws {
        RecordingWire.shared.reset()
        let queue = VoiceSharingQueue(root: root, log: { _ in })
        _ = await queue.publish(audio: Data(repeating: 4, count: 256),
                          metadata: Data(#"{"enrollment_epoch":"epoch-1"}"#.utf8),
                          name: "one")
        let published = await queue.entries()
        let entry = try XCTUnwrap(published.first)

        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: RecordingTokens(),
            session: RecordingWire.session)
        // Withdrawal order, reproduced: sharing goes off first, then the transport is asked to stop.
        let box = VoiceSharingPermissionBox()
        box.consentHeld = false
        transport.cancelInFlight()

        let answer = await Self.bounded(seconds: 5) {
            await transport.send(entry: entry, stillPermitted: { box.consentHeld })
        }
        XCTAssertNil(RecordingWire.shared.request, "a stopped transport must not send")
        XCTAssertNotNil(answer, "the refused attempt must finish")
    }

    /// Runs `work` but gives up after `seconds`, so a stranded transfer fails the control rather than
    /// hanging the suite.
    private static func bounded<T: Sendable>(seconds: Double,
                                             _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Both parts arrive, in the order the server reads them, with `metadata` carrying no filename:
    /// its whole value is the record JSON.
    func test_thePartsArriveInOrderAndMetadataCarriesNoFilename() async throws {
        RecordingWire.shared.reset()
        let queue = VoiceSharingQueue(root: root, log: { _ in })
        let record = #"{"enrollment_epoch":"epoch-1","wake_required":true}"#
        _ = await queue.publish(audio: Data(repeating: 9, count: 256),
                          metadata: Data(record.utf8),
                          name: "one")
        let published = await queue.entries()
        let entry = try XCTUnwrap(published.first)

        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: RecordingTokens(),
            session: RecordingWire.session)
        _ = await transport.send(entry: entry)

        let body = try XCTUnwrap(RecordingWire.shared.body)
        let text = String(decoding: body, as: UTF8.self)
        let metadataAt = try XCTUnwrap(text.range(of: "name=\"metadata\""))
        let audioAt = try XCTUnwrap(text.range(of: "name=\"audio\""))
        XCTAssertLessThan(metadataAt.lowerBound, audioAt.lowerBound,
                          "metadata is read first, so it is sent first")
        XCTAssertTrue(text.contains(#"name="metadata""# + "\r\nContent-Type: application/json\r\n\r\n" + record),
                      "metadata is a plain field whose value is the record, with no filename")
        XCTAssertFalse(text.contains(#"name="metadata"; filename="#),
                       "a filename would make the server read it as a file, not the record value")
        XCTAssertTrue(text.contains("filename=\"recording.wav\""), "the WAV is named for the server")
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
    }
}

// MARK: - A wire that records what was sent

private final class RecordingWire: URLProtocol {
    static let shared = RecordingWireStore()
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingWire.self]
        return URLSession(configuration: config)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `httpBody` is emptied once a request is handed to the protocol; `httpBodyStream` is the
        // only reliable view here, and reading it is what proves the body was not streamed onward.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            body = RecordingWire.drain(stream)
        }
        RecordingWire.shared.record(request: request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: 201,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func drain(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func stopLoading() {}
}

private final class RecordingWireStore {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody: Data?

    var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return storedRequest }
    var body: Data? { lock.lock(); defer { lock.unlock() }; return storedBody }
    var bodyLength: Int? { body?.count }

    func record(request: URLRequest, body: Data?) {
        lock.lock(); defer { lock.unlock() }
        storedRequest = request
        storedBody = body
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        storedRequest = nil
        storedBody = nil
    }
}

private final class RecordingTokens: CloudTokenProviding {
    func token() async -> String? { "tok-acct-1" }
    func prepare() async {}
    func handleUnauthorized(rejectedToken: String?) async {}
}

/// Stands in for live consent, and records that the transport consulted it.
private final class VoiceSharingPermissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var held = true
    private var asked = false
    var consentHeld: Bool {
        get { lock.lock(); defer { lock.unlock() }; return held }
        set { lock.lock(); held = newValue; lock.unlock() }
    }
    var wasAsked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return asked }
        set { lock.lock(); asked = newValue; lock.unlock() }
    }
}
