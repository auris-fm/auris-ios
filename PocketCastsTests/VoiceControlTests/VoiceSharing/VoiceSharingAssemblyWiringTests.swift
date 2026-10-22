import XCTest
@testable import podcasts

/// Assembly-level controls for the PRODUCTION chain shape: the same wiring VoiceControlAssembly
/// performs (transport fed by a real credential provider, uploader gated by the live policy,
/// serialized scheduler), exercised end-to-end with the network intercepted.
///
/// What these prove (spec 18:38Z): no request leaves without eligibility AND a credential; the
/// receipt-before-release discipline holds through the production composition; revocation cannot
/// be overridden by a successor or a late response.
final class VoiceSharingAssemblyWiringTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        AssemblyIntercept.requestCount = 0
        AssemblyIntercept.responder = nil
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsassembly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Mirrors the production wiring in VoiceControlAssembly with an intercepted session and an
    /// injected policy switch — every other element is the real production type.
    private func makeChain(
        policyPermits: @escaping () -> Bool,
        tokenProvider: CloudTokenProviding
    ) -> (queue: VoiceSharingUploadQueue, scheduler: VoiceSharingUploadScheduler) {
        let queue = VoiceSharingUploadQueue(rootDirectory: root)
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: tokenProvider,
            session: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [AssemblyIntercept.self]
                return URLSession(configuration: configuration)
            }())
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(
                retryBaseDelay: 1, retryMaximumDelay: 60, random: { 0 }),
            isAuthorized: policyPermits,
            endpoint: { transport.endpoint },
            transport: { [transport] request in
                await transport.send(request: request)
            })
        let scheduler = VoiceSharingUploadScheduler(
            queue: queue, uploader: uploader, isAuthorized: policyPermits)
        return (queue, scheduler)
    }

    private func makeReadyEntry(_ queue: VoiceSharingUploadQueue) throws
        -> VoiceSharingUploadQueue.Entry {
        let samples: [Float] = [0, 0.25, -0.5, 0.5]
        let event = VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(),
            enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
            retainedSamples: samples.count, truncated: false, droppedSpans: [],
            originalSampleCount: nil, audio: samples, isGateControl: false)
        let provenance = VoiceSharingContributionEncoder.Provenance(
            platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
            models: .init(vad: nil, wakeword: nil, asr: nil, translation: nil, router: nil),
            conversionVersion: "v1")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event, provenance: provenance, observations: [:])
        let entry = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
        try queue.finalize(entry)
        return entry
    }

    /// STRICT metadata extraction (reviewer aa84564a / spec 0414c13d): isolate the EXACT multipart
    /// part named "metadata", parse the WHOLE envelope JSON, and read `record.capture_id` plus the
    /// envelope's `record_sha256`. No first-brace slicing, no fallbacks: anything unexpected
    /// throws, and callers XCTFail rather than manufacturing an identity.
    static func attemptedIdentity(from request: URLRequest) throws -> (captureID: String, sha: String) {
        let body = try XCTUnwrap(request.httpBody, "no body")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        guard let boundaryRange = contentType.range(of: "boundary=") else {
            throw NSError(domain: "fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no multipart boundary"])
        }
        let boundary = "--" + contentType[boundaryRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        // The body is multipart with BINARY audio bytes, so the full body is not valid UTF-8 by
        // design. Decode the JSON envelope with a byte search instead: locate the metadata part's
        // payload between its boundary and the next boundary, then parse exactly those bytes.
        let raw = [UInt8](body)
        let boundaryBytes = [UInt8](boundary.utf8)
        guard let firstBoundary = findBytes(boundaryBytes, in: raw, from: 0) else {
            throw NSError(domain: "fixture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "no boundary in body"])
        }
        var cursor = firstBoundary + boundaryBytes.count
        while cursor < raw.count {
            guard let nextBoundary = findBytes(boundaryBytes, in: raw, from: cursor) else { break }
            let part = Array(raw[cursor..<nextBoundary])
            if let headerEnd = findBytes([13, 10, 13, 10], in: part, from: 0) {
                let headers = String(decoding: part[0..<headerEnd], as: UTF8.self)
                if headers.contains("name=\"metadata\"") {
                    let payload = Array(part[(headerEnd + 4)..<part.count])
                    let object = try XCTUnwrap(
                        try JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any],
                        "metadata part is not a JSON object")
                    let sha = try XCTUnwrap(object["record_sha256"] as? String,
                                            "envelope has no record_sha256")
                    let record = try XCTUnwrap(object["record"] as? [String: Any],
                                               "envelope has no record")
                    let captureID = try XCTUnwrap(record["capture_id"] as? String,
                                                  "record has no capture_id")
                    return (captureID, sha)
                }
            }
            cursor = nextBoundary + boundaryBytes.count
        }
        throw NSError(domain: "fixture", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "no metadata part"])
    }

    /// First index of `needle` in `haystack` at or after `from`.
    static func findBytes(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var index = from
        while index + needle.count <= haystack.count {
            if Array(haystack[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }
    /// A valid, identity-matching 201 receipt for whatever entry the request actually carries.
    static func acceptedReceiptResponder() -> (URLRequest) -> (HTTPURLResponse, Data) {
        { request in
            guard let identity = try? Self.attemptedIdentity(from: request) else {
                XCTFail("fixture could not extract the attempted entry's identity")
                return (HTTPURLResponse(url: request.url!, statusCode: 500,
                                        httpVersion: nil, headerFields: nil)!, Data())
            }
            let receipt: [String: Any] = [
                "schema_version": 1,
                "capture_id": identity.captureID,
                "record_sha256": identity.sha,
                "status": "accepted",
                "receipt_id": "rcpt-ok",
                "accepted_at": "2026-10-22T14:00:00Z",
                "retention_expires_at": "2026-11-22T14:00:00Z",
            ]
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                    headerFields: nil)!,
                    try! JSONSerialization.data(withJSONObject: receipt))
        }
    }

    private func waitForEmptyQueue(_ queue: VoiceSharingUploadQueue) async throws {
        for _ in 0..<400 where !queue.readyEntries().isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeTrigger(
        _ chain: (queue: VoiceSharingUploadQueue, scheduler: VoiceSharingUploadScheduler),
        surfaceEnabled: @escaping () -> Bool,
        isAuthorized: @escaping () -> Bool
    ) -> VoiceSharingUploadTrigger {
        VoiceSharingUploadTrigger(
            scheduler: chain.scheduler,
            surfaceEnabled: surfaceEnabled,
            isAuthorized: isAuthorized)
    }

    /// PRODUCTION INVOCATION via the guarded trigger (spec 7dcf0b01/0414c13d): reached through
    /// `triggerDrainIfPermitted()` — the lifecycle path — and asserted through SETTLEMENT.
    func test_productionTriggerDeliversAndSettlesWhenAllGatesPermit() async throws {
        let chain = makeChain(policyPermits: { true },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        let trigger = makeTrigger(chain, surfaceEnabled: { true }, isAuthorized: { true })
        AssemblyIntercept.responder = Self.acceptedReceiptResponder()
        defer { AssemblyIntercept.responder = nil }
        _ = try makeReadyEntry(chain.queue)
        trigger.triggerDrainIfPermitted()
        for _ in 0..<400 where AssemblyIntercept.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 1,
                       "the guarded trigger must drive the real chain")
        try await waitForEmptyQueue(chain.queue)
        XCTAssertTrue(chain.queue.readyEntries().isEmpty,
                      "an accepted receipt must SETTLE the entry, not merely be sent")
    }

    /// TWO SUCCESSIVE completed drains both run (reviewer aa84564a): a completed task must not
    /// block the trigger for its lifetime.
    func test_successiveTriggersEachDrain() async throws {
        let chain = makeChain(policyPermits: { true },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        let trigger = makeTrigger(chain, surfaceEnabled: { true }, isAuthorized: { true })
        AssemblyIntercept.responder = Self.acceptedReceiptResponder()
        defer { AssemblyIntercept.responder = nil }
        _ = try makeReadyEntry(chain.queue)
        trigger.triggerDrainIfPermitted()
        for _ in 0..<400 where AssemblyIntercept.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 1, "first trigger drains")
        try await waitForEmptyQueue(chain.queue)
        XCTAssertTrue(chain.queue.readyEntries().isEmpty, "first entry settled")
        _ = try makeReadyEntry(chain.queue)
        trigger.triggerDrainIfPermitted()
        for _ in 0..<400 where AssemblyIntercept.requestCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 2,
                       "a completed drain must not block later triggers")
        try await waitForEmptyQueue(chain.queue)
        XCTAssertTrue(chain.queue.readyEntries().isEmpty, "second entry settled too")
    }

    /// OVERLAPPING triggers stay single-flight.
    func test_overlappingTriggersStaySingleFlight() async throws {
        let chain = makeChain(policyPermits: { true },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        let trigger = makeTrigger(chain, surfaceEnabled: { true }, isAuthorized: { true })
        let base = Self.acceptedReceiptResponder()
        let lock = NSLock()
        var inFlight = 0
        var peak = 0
        AssemblyIntercept.responder = { request in
            lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock()
            Thread.sleep(forTimeInterval: 0.03)
            lock.lock(); inFlight -= 1; lock.unlock()
            return base(request)
        }
        defer { AssemblyIntercept.responder = nil }
        _ = try makeReadyEntry(chain.queue)
        _ = try makeReadyEntry(chain.queue)
        trigger.triggerDrainIfPermitted()
        trigger.triggerDrainIfPermitted()
        trigger.triggerDrainIfPermitted()
        try await waitForEmptyQueue(chain.queue)
        XCTAssertEqual(peak, 1, "overlapping triggers must never run two passes concurrently")
    }

    /// The compiled-off surface constant gates FIRST: even fully eligible and credentialed, a
    /// lifecycle trigger does NOTHING while `surfaceEnabled` is false.
    func test_productionTriggerIsSilentWhileTheSurfaceIsCompiledOff() async throws {
        let chain = makeChain(policyPermits: { true },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        let trigger = makeTrigger(chain, surfaceEnabled: { false }, isAuthorized: { true })
        _ = try makeReadyEntry(chain.queue)
        trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(AssemblyIntercept.requestCount, 0,
                       "compiled-off means the trigger is unreachable, full stop")
    }

    /// The live policy gate is re-read at trigger time.
    func test_productionTriggerRespectsLiveWithdrawal() async throws {
        var permitted = true
        let chain = makeChain(policyPermits: { permitted },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        let trigger = makeTrigger(chain, surfaceEnabled: { true },
                                  isAuthorized: { permitted })
        _ = try makeReadyEntry(chain.queue)
        permitted = false
        trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(AssemblyIntercept.requestCount, 0,
                       "withdrawal silences the trigger at trigger time")
    }

    /// NO ELIGIBILITY: with the policy refusing, a drain pass issues NOTHING — zero network
    /// activity, entries untouched.
    func test_noRequestWithoutEligibility() async throws {
        var permitted = false
        let chain = makeChain(policyPermits: { permitted },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        _ = try makeReadyEntry(chain.queue)
        let outcome = await chain.scheduler.drainOnce()
        guard case .idle = outcome else {
            return XCTFail("an ineligible pass must be idle, got \(outcome)")
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 0, "no bytes without eligibility")
    }

    /// NO CREDENTIAL: eligibility present but the provider has no token — the transport's
    /// fail-closed rule keeps everything on the device.
    func test_noRequestWithoutCredential() async throws {
        let chain = makeChain(policyPermits: { true },
                              tokenProvider: StaticTokenProvider(token: nil))
        _ = try makeReadyEntry(chain.queue)
        let outcome = await chain.scheduler.drainOnce()
        // The pass runs but every attempt comes back unavailable (refused admission of bytes).
        guard case .drained(let results) = outcome else {
            return XCTFail("expected a drained pass, got \(outcome)")
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 0, "no bearer, no request")
        for (_, outcome) in results {
            // A missing credential is a TRANSPORT failure (unknown, retryable) — never a verdict
            // on the record, never a deletion.
            guard case .retry = outcome else {
                return XCTFail("credential-less attempts must be unknown/retryable, got \(outcome)")
            }
        }
        // The entry is RETAINED: a missing credential is not a verdict on the recording.
        guard case .known(let ready) = chain.queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertEqual(ready.count, 1)
    }

    /// WITH eligibility AND credential: the pass actually delivers, and the entry is gone.
    func test_eligibleAndCredentialedPassDelivers() async throws {
        AssemblyIntercept.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                             headerFields: nil)!,
             Data("{\"schema_version\":1,\"code\":\"ignored\"}".utf8))
        }
        defer { AssemblyIntercept.responder = nil }
        // A full receipt requires the record identity; capture it from the request's metadata part
        // — but simpler: use an identity-mismatch-proof approach by reading what we queued.
        let chain = makeChain(policyPermits: { true },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        let entry = try makeReadyEntry(chain.queue)
        let identity = try chain.queue.boundIdentity(of: entry)
        AssemblyIntercept.responder = { request in
            let body = request.httpBody ?? Data()
            // Find the metadata JSON inside the multipart body and build a matching receipt.
            let text = String(decoding: body, as: UTF8.self)
            let receipt: [String: Any] = [
                "schema_version": 1,
                "capture_id": identity.captureID,
                "record_sha256": identity.recordSHA256,
                "status": "accepted",
                "receipt_id": "rcpt-1",
                "accepted_at": "2026-10-22T14:00:00Z",
                "retention_expires_at": "2026-11-22T14:00:00Z",
            ]
            _ = text
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                    headerFields: nil)!,
                    try! JSONSerialization.data(withJSONObject: receipt))
        }
        let outcome = await chain.scheduler.drainOnce()
        guard case .drained(let results) = outcome, results.count == 1 else {
            return XCTFail("expected one drained result, got \(outcome)")
        }
        guard case .delivered = results[0].outcome else {
            return XCTFail("expected delivery through the production shape, got \(results[0].outcome)")
        }
        guard case .known(let ready) = chain.queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(ready.isEmpty, "delivered entries leave the serving set")
    }

    /// REVOCATION mid-pass with a LATE SUCCESSFUL response (spec 7980bf44): the withdrawal lands
    /// while a valid 201 receipt is in flight — the late success must NOT complete the entry, the
    /// pass stops, and a successor instance cannot borrow the attempt either.
    func test_lateSuccessCannotCompleteARevokedEntry() async throws {
        var permitted = true
        let chain = makeChain(policyPermits: { permitted },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        _ = try makeReadyEntry(chain.queue)
        _ = try makeReadyEntry(chain.queue)
        AssemblyIntercept.responder = { request in
            // Withdrawal lands while a VALID receipt is on the wire. Identity is the ACTUAL
            // attempted entry's (strict parse; fixture failure rather than a made-up id).
            permitted = false
            guard let identity = try? Self.attemptedIdentity(from: request) else {
                XCTFail("fixture could not extract the attempted entry's identity")
                return (HTTPURLResponse(url: request.url!, statusCode: 500,
                                        httpVersion: nil, headerFields: nil)!, Data())
            }
            let receipt: [String: Any] = [
                "schema_version": 1,
                "capture_id": identity.captureID,
                "record_sha256": identity.sha,
                "status": "accepted",
                "receipt_id": "rcpt-late",
                "accepted_at": "2026-10-22T14:00:00Z",
                "retention_expires_at": "2026-11-22T14:00:00Z",
            ]
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                    headerFields: nil)!,
                    try! JSONSerialization.data(withJSONObject: receipt))
        }
        let outcome = await chain.scheduler.drainOnce()
        guard case .drained(let results) = outcome, results.count == 1 else {
            return XCTFail("revocation must end the pass after one attempt, got \(outcome)")
        }
        guard case .revoked = results[0].outcome else {
            return XCTFail("a late 2xx must not beat revocation, got \(results[0].outcome)")
        }
        // A SUCCESSOR instance on the same disk: with consent still revoked it must attempt
        // NOTHING — the late receipt neither delivered the entry nor left it borrowable.
        AssemblyIntercept.requestCount = 0
        let successor = makeChain(policyPermits: { permitted },
                                  tokenProvider: StaticTokenProvider(token: "tok"))
        let successorOutcome = await successor.scheduler.drainOnce()
        guard case .idle = successorOutcome else {
            return XCTFail("a successor must not serve under revocation, got \(successorOutcome)")
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 0, "no bytes from the successor either")
    }
}

/// Token provider double for assembly controls.
private final class StaticTokenProvider: CloudTokenProviding {
    private let token: String?
    init(token: String?) { self.token = token }
    func token() async -> String? { token }
    func handleUnauthorized(rejectedToken: String?) async {}
}

/// Network intercept for the assembly controls: counts requests, serves canned responses.
private final class AssemblyIntercept: URLProtocol {
    static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        AssemblyIntercept.requestCount += 1
        guard let responder = AssemblyIntercept.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        // URLProtocol receives upload bodies as a STREAM, not `httpBody`: materialize it so
        // fixtures can read the exact bytes that were sent.
        let (response, data) = responder(Self.materialized(request))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession strips `httpBody` and hands URLProtocol an `httpBodyStream`. Fixtures parse the
    /// body, so it is drained here and re-attached (reviewer aa84564a's strict-parse controls
    /// depend on seeing the real multipart bytes).
    static func materialized(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        var copy = request
        copy.httpBody = data
        return copy
    }
}