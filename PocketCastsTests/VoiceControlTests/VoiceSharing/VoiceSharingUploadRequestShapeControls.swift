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

    /// WITHDRAWAL IN THE START WINDOW. Permission is answered and the transfer is registered inside ONE
    /// critical section, so no stop can land between them: if one does, `cancelInFlight()` finds nothing
    /// registered and the recording leaves without permission ever being re-read.
    ///
    /// The seam runs at exactly that instant — after the answer, before registration — and withdraws.
    /// With the check inside the section the withdrawal has already been recorded when the send would
    /// begin, so nothing leaves; with the check hoisted above the lock the transfer starts anyway.
    func test_aStopBetweenThePermissionAnswerAndRegistrationStillStopsTheUpload() async throws {
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
        transport.afterPermissionBeforeRegistrationForTesting = {
            // The user withdraws in the gap the old code left open.
            box.consentHeld = false
        }
        let answer = await transport.send(entry: entry, stillPermitted: {
            box.wasAsked = true
            return box.consentHeld
        })

        XCTAssertNil(RecordingWire.shared.request,
                     "a withdrawal in the start window must not let the recording reach the network")
        XCTAssertNotEqual(answer, .response(status: 201), "a stopped attempt is not reported as a reply")
        XCTAssertTrue(box.wasAsked, "the hook is consulted before anything is registered")
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
