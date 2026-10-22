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

    /// Extracts a string field from the multipart body's metadata JSON part.
    static func metadataField(_ key: String, from multipart: String) -> String? {
        guard let metadataStart = multipart.range(of: "name=\"metadata\""),
            let jsonStart = multipart.range(of: "{", range: metadataStart.upperBound..<multipart.endIndex),
            let jsonEnd = multipart.range(of: "}", range: jsonStart.lowerBound..<multipart.endIndex)
        else { return nil }
        let json = String(multipart[jsonStart.lowerBound...jsonEnd.lowerBound])
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }

    /// PRODUCTION INVOCATION via the guarded trigger (spec 7dcf0b01): the SAME VoiceControlAssembly
    /// chain types, but reached through `VoiceSharingUploadTrigger.triggerDrainIfPermitted()` — the
    /// path a lifecycle event actually hits — not a hand-built drainOnce call.
    func test_productionTriggerDeliversWhenAllGatesPermit() async throws {
        var permitted = true
        let chain = makeChain(policyPermits: { permitted },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        let trigger = VoiceSharingUploadTrigger(
            scheduler: chain.scheduler,
            surfaceEnabled: { true },
            isAuthorized: { permitted })
        _ = try makeReadyEntry(chain.queue)
        trigger.triggerDrainIfPermitted()
        // The drain is asynchronous; poll for the single request to appear.
        for _ in 0..<200 where AssemblyIntercept.requestCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 1,
                       "the guarded trigger must drive the real chain")
    }

    /// The compiled-off surface constant gates FIRST: even fully eligible and credentialed, a
    /// lifecycle trigger does NOTHING while `surfaceEnabled` is false.
    func test_productionTriggerIsSilentWhileTheSurfaceIsCompiledOff() async throws {
        var permitted = true
        let chain = makeChain(policyPermits: { permitted },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        let trigger = VoiceSharingUploadTrigger(
            scheduler: chain.scheduler,
            surfaceEnabled: { false },
            isAuthorized: { permitted })
        _ = try makeReadyEntry(chain.queue)
        trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(AssemblyIntercept.requestCount, 0,
                       "compiled-off means the trigger is unreachable, full stop")
    }

    /// The live policy gate re-read at trigger time: withdrawal between events silences the
    /// trigger even though the surface is enabled.
    func test_productionTriggerRespectsLiveWithdrawal() async throws {
        var permitted = true
        let chain = makeChain(policyPermits: { permitted },
                              tokenProvider: StaticTokenProvider(token: "tok"))
        let trigger = VoiceSharingUploadTrigger(
            scheduler: chain.scheduler,
            surfaceEnabled: { true },
            isAuthorized: { permitted })
        _ = try makeReadyEntry(chain.queue)
        permitted = false
        trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 100_000_000)
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
            // Withdrawal lands while a VALID receipt is on the wire. The receipt identity is
            // bound to the entry the request ACTUALLY carries (reviewer 0a80e1c6): the metadata
            // part is parsed out of the outgoing multipart body, never assumed from creation
            // order — ready order is age-based, not creation-based.
            permitted = false
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let captureID = Self.metadataField("capture_id", from: body)
                ?? UUID().uuidString
            let recordSHA = Self.metadataField("record_sha256", from: body)
                ?? String(repeating: "0", count: 64)
            let receipt: [String: Any] = [
                "schema_version": 1,
                "capture_id": captureID,
                "record_sha256": recordSHA,
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
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

}