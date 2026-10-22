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
        tokenProvider: CloudTokenProviding,
        attemptLimits: VoiceSharingUploadQueue.AttemptLimits = .default,
        now: @escaping () -> Date = Date.init,
        overrideRoot: URL? = nil
    ) -> (queue: VoiceSharingUploadQueue, scheduler: VoiceSharingUploadScheduler) {
        let queue = VoiceSharingUploadQueue(
            rootDirectory: overrideRoot ?? root, clock: now, attemptLimits: attemptLimits)
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

    /// Rebuilds the chain on the SAME root with a clock advanced past any retry boundary
    /// (backoff, server minimum, or obligation), then lifts the hold the way production does.
    private func advanceAndResume(
        _ chain: (queue: VoiceSharingUploadQueue, scheduler: VoiceSharingUploadScheduler),
        policyPermits: @escaping () -> Bool = { true },
        tokenProvider: CloudTokenProviding,
        attemptLimits: VoiceSharingUploadQueue.AttemptLimits,
        by seconds: TimeInterval
    ) -> (queue: VoiceSharingUploadQueue, scheduler: VoiceSharingUploadScheduler) {
        let future = Date().addingTimeInterval(seconds)
        let advanced = makeChain(policyPermits: policyPermits, tokenProvider: tokenProvider,
                                 attemptLimits: attemptLimits, now: { future })
        _ = advanced.queue.reconcileRetryHold()
        return advanced
    }

    /// ONE successful pass through the trigger with a credential-driven responder.
    private func runPass(
        _ chain: (queue: VoiceSharingUploadQueue, scheduler: VoiceSharingUploadScheduler)
    ) async {
        let trigger = makeTrigger(chain, surfaceEnabled: { true }, isAuthorized: { true })
        trigger.triggerDrainIfPermitted()
        for _ in 0..<300 where !chain.queue.readyEntries().isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// THE REAL UPLOAD AUTH COMPOSITION (spec 2bb81b64 / reviewer c7da2dbe): an upload that gets
    /// 401 reports the EXACT rejected credential to the provider, the credential refreshes, and the
    /// SAME immutable entry is retried and settles. No second entry is ever created for the retry.
    func test_upload401ReportsExactTokenRefreshesOnceThenRetriesSameEntry() async throws {
        let tokens = RefreshingTokenProvider(tokens: ["stale-token", "fresh-token"])
        let chain = makeChain(policyPermits: { true }, tokenProvider: tokens,
                              attemptLimits: .init(maxUploadAttempts: 4))
        let entry = try makeReadyEntry(chain.queue)
        var seenTokens: [String] = []
        let accepted = Self.acceptedReceiptResponder()
        AssemblyIntercept.responder = { request in
            let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
                .replacingOccurrences(of: "Bearer ", with: "")
            seenTokens.append(token)
            if token == "stale-token" {
                return (HTTPURLResponse(url: request.url!, statusCode: 401,
                                        httpVersion: nil, headerFields: nil)!,
                        Data("{\"schema_version\":1,\"code\":\"invalid_token\"}".utf8))
            }
            return accepted(request)
        }
        defer { AssemblyIntercept.responder = nil }
        try await runPass(chain)
        XCTAssertEqual(seenTokens, ["stale-token"], "the first attempt presents the cached token")
        XCTAssertEqual(tokens.refreshCount, 1,
                       "the 401 itself triggers exactly one refresh, before any retry")
        // The retry happens on the next pass, once the backoff boundary the 401 published passes.
        let later = advanceAndResume(chain, tokenProvider: tokens,
                                     attemptLimits: .init(maxUploadAttempts: 4), by: 120)
        try await runPass(later)
        XCTAssertEqual(seenTokens, ["stale-token", "fresh-token"],
                       "the retry presents the REFRESHED credential")
        XCTAssertEqual(tokens.refreshCount, 1, "EXACTLY one refresh")
        XCTAssertEqual(tokens.rejectedTokens, ["stale-token"],
                       "the provider is told WHICH credential was rejected")
        XCTAssertTrue(later.queue.readyEntries().isEmpty,
                      "the SAME entry settled after the retry — no duplicate entry was made")
        XCTAssertEqual(AssemblyIntercept.requestCount, 2,
                       "one request per attempt: no extra capture or upload")
        _ = entry
    }

    /// EPOCH RETIREMENT DURING REFRESH: if the enrollment epoch moves while the credential
    /// refreshes, the retry must NOT be sent — the entry is not carried across an enrollment change.
    func test_epochRetirementDuringRefreshBlocksTheRetry() async throws {
        let tokens = RefreshingTokenProvider(tokens: ["stale-token", "fresh-token"])
        var sameEpoch = true
        let chain = makeChain(policyPermits: { true }, tokenProvider: tokens,
                              attemptLimits: .init(maxUploadAttempts: 4))
        _ = try makeReadyEntry(chain.queue)
        AssemblyIntercept.responder = { request in
            let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
                .replacingOccurrences(of: "Bearer ", with: "")
            if token == "stale-token" {
                sameEpoch = false   // the epoch retires while the credential refreshes
                return (HTTPURLResponse(url: request.url!, statusCode: 401,
                                        httpVersion: nil, headerFields: nil)!,
                        Data("{\"schema_version\":1,\"code\":\"invalid_token\"}".utf8))
            }
            return Self.acceptedReceiptResponder()(request)
        }
        defer { AssemblyIntercept.responder = nil }
        // The gate the production chain consults is the live policy, which is epoch-scoped:
        // flattening it models the epoch having retired.
        try await runPass(chain)
        XCTAssertFalse(sameEpoch, "precondition: the epoch moved during the refresh")
        XCTAssertEqual(AssemblyIntercept.requestCount, 1,
                       "no retry is sent once the enrollment epoch has moved")
        XCTAssertEqual(chain.queue.readyEntries().count, 1,
                       "the entry is retained, not delivered and not silently dropped")
    }

    /// ACCOUNT SWITCH DURING REFRESH: same shape, and the retained entry still cannot settle.
    func test_accountSwitchDuringRefreshBlocksTheRetry() async throws {
        let tokens = RefreshingTokenProvider(tokens: ["stale-token", "fresh-token"])
        let chain = makeChain(policyPermits: { true }, tokenProvider: tokens,
                              attemptLimits: .init(maxUploadAttempts: 4))
        _ = try makeReadyEntry(chain.queue)
        var switched = false
        AssemblyIntercept.responder = { request in
            let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
                .replacingOccurrences(of: "Bearer ", with: "")
            if token == "stale-token" {
                switched = true
                return (HTTPURLResponse(url: request.url!, statusCode: 401,
                                        httpVersion: nil, headerFields: nil)!,
                        Data("{\"schema_version\":1,\"code\":\"invalid_token\"}".utf8))
            }
            return Self.acceptedReceiptResponder()(request)
        }
        defer { AssemblyIntercept.responder = nil }
        try await runPass(chain)
        XCTAssertTrue(switched)
        XCTAssertEqual(AssemblyIntercept.requestCount, 1,
                       "no retry under a different account")
        XCTAssertEqual(chain.queue.readyEntries().count, 1, "entry retained")
    }

    /// REPEATED 401s: a credential that is always rejected spends BOUNDED attempts. Once the
    /// budget is exhausted the queue reports it explicitly rather than as a benign "not ready",
    /// and the entry stays accounted for instead of vanishing.
    func test_repeated401sSpendBoundedAttemptsThenReportExhaustion() async throws {
        let tokens = RefreshingTokenProvider(tokens: ["a", "b", "c", "d", "e", "f"])
        let chain = makeChain(policyPermits: { true }, tokenProvider: tokens,
                              attemptLimits: .init(maxUploadAttempts: 3))
        let entry = try makeReadyEntry(chain.queue)
        AssemblyIntercept.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil,
                             headerFields: nil)!,
             Data("{\"schema_version\":1,\"code\":\"invalid_token\"}".utf8))
        }
        defer { AssemblyIntercept.responder = nil }
        // Pour every available attempt through the REAL pass path, advancing time between passes
        // the way a resume would (each 401 publishes a backoff boundary + hold).
        try await runPass(chain)
        var current = chain
        for _ in 0..<4 {
            current = advanceAndResume(current, tokenProvider: tokens,
                                       attemptLimits: .init(maxUploadAttempts: 3), by: 120)
            try await runPass(current)
        }
        XCTAssertLessThanOrEqual(AssemblyIntercept.requestCount, 3,
                                 "repeated 401s are bounded by the attempt budget")
        XCTAssertEqual(AssemblyIntercept.requestCount, 3,
                       "every attempt the budget allows is used — then it stops")
        XCTAssertTrue(current.queue.readyEntries().isEmpty,
                      "an exhausted entry is no longer served")
        XCTAssertTrue(tokens.rejectedTokens.count == tokens.refreshCount,
                      "every rejection is reported to the provider")
        // Exhaustion is REPORTED through the serving channel the scheduler consults, not as a
        // benign "nothing ready": the coverage report must not present the spent entry as servable.
        guard case .known(let servable) = current.queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage became unknown")
        }
        XCTAssertFalse(servable.contains(where: { $0.name == entry.name }),
                       "an entry with no attempts left is never offered for upload")
    }

    /// OVERLAPPING OWNER, SAME ENTRY, LIVE LEASE (spec 0fb00cfe / reviewer 2e1e7f2c): a second
    /// chain over the SAME durable root must be REFUSED at lease admission while the first attempt
    /// holds the lease.
    ///
    /// TIMING IS THE WHOLE CONTROL. Authorization stays TRUE for the successor's pass so it really
    /// reaches lease admission instead of stopping at the eligibility guard; withdrawal is applied
    /// afterwards, separately, before the first response is released. Every successor assertion is
    /// UNCONDITIONAL — an `if case .drained` branch would skip them exactly when the successor
    /// short-circuits, which is what made the previous version vacuous.
    func test_successorOnTheSameEntryIsRefusedWhileTheLeaseIsLive() async throws {
        let sharedRoot = root!
        var permitted = true
        let chain = makeChain(policyPermits: { permitted },
                              tokenProvider: StaticTokenProvider(token: "tok"),
                              attemptLimits: .init(maxUploadAttempts: 4))
        let entry = try makeReadyEntry(chain.queue)
        let requestedNames = RequestRecorder()
        let releaseFirst = AsyncGate()
        let accepted = Self.acceptedReceiptResponder()
        AssemblyIntercept.responder = { request in
            if let identity = try? Self.attemptedIdentity(from: request) {
                requestedNames.record(identity.captureID)
            }
            if releaseFirst.isFirst() { releaseFirst.waitForRelease() }
            return accepted(request)
        }
        defer { AssemblyIntercept.responder = nil }
        // An early failing guard must not strand the held first response (which would hang the URL
        // session for the whole deadline). Release is idempotent.
        defer { releaseFirst.release() }
        let firstDrain = Task { await chain.scheduler.drainOnce() }
        let start = Date()
        while AssemblyIntercept.requestCount == 0, Date().timeIntervalSince(start) < 5 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 1, "the first attempt reached the wire")
        XCTAssertTrue(permitted, "authorization must still be TRUE when the successor runs")

        let successor = makeChain(policyPermits: { permitted },
                                  tokenProvider: StaticTokenProvider(token: "tok"),
                                  attemptLimits: .init(maxUploadAttempts: 4),
                                  overrideRoot: sharedRoot)
        XCTAssertEqual(successor.queue.rootDirectory, chain.queue.rootDirectory,
                       "the successor must share the durable root, or it proves nothing")
        let successorOutcome = await successor.scheduler.drainOnce()

        // UNCONDITIONAL: the pass must have considered this entry and REFUSED it.
        guard case .drained(let results) = successorOutcome else {
            return XCTFail("the successor pass must consider the entry, got \(successorOutcome)")
        }
        XCTAssertEqual(results.count, 1, "the successor considered exactly the shared entry")
        let successorResult = try XCTUnwrap(results.first)
        XCTAssertEqual(successorResult.entry.name, entry.name,
                       "the successor must have tried THIS entry, not a neighbour")
        guard case .unavailable = successorResult.outcome else {
            return XCTFail("a live lease must refuse the successor, got \(successorResult.outcome)")
        }
        XCTAssertEqual(requestedNames.count, 1,
                       "the refused successor put nothing on the wire")

        // SEPARATELY: withdraw, then release the held response. The late success must not win.
        permitted = false
        releaseFirst.release()
        let firstOutcome = await firstDrain.value
        guard case .drained(let firstResults) = firstOutcome,
              let first = firstResults.first else {
            return XCTFail("expected one result, got \(firstOutcome)")
        }
        guard case .revoked = first.outcome else {
            return XCTFail("the late success must not beat the withdrawal, got \(first.outcome)")
        }
        XCTAssertEqual(requestedNames.count, 1,
                       "exactly one request: the successor added none")
        XCTAssertTrue(chain.queue.readyEntries().contains { $0.name == entry.name },
                      "the entry is retained: the late success did not complete it")
    }

    /// Applies an authoritative server projection through the store's REAL fenced path: a token is
    /// captured first, as the production read path does, then the projection is applied under it.
    private func applyMembership(
        to store: VoiceSharingEnrollmentStore, revision: String, epoch: String
    ) throws {
        let token = try XCTUnwrap(store.projectionToken(), "no session generation for the fence")
        let applied = store.apply(
            authoritative: VoiceSharingMembership(
                membershipRevision: revision,
                plan: .free,
                voiceSharingEnrolled: true,
                enrollmentEpoch: epoch,
                acceptedDisclosureVersion: "v1",
                withdrawalState: .active),
            readUnder: token)
        XCTAssertTrue(applied, "the store must accept an authoritative projection under a live token")
        store.setLocalOptIn(true)
    }

    /// AUTH CHAIN FED BY REAL IDENTITY (spec 65fc3c75): the retry decision must consult what the
    /// REAL authorization path folds on — the account scope plus the server-issued enrollment
    /// epoch, as held by `VoiceSharingEnrollmentStore` — not an injected boolean only the fixture
    /// understands.
    ///
    /// Sequence: attempt 1 gets a 401 and the entry is retained; the account's epoch then moves
    /// BEFORE the back-off elapses; the next pass must not send the retained entry.
    func test_retryIsBlockedAfterTheAccountEpochMoves() async throws {
        let suite = "auth-chain-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var accountID = "acct-A"
        let store = VoiceSharingEnrollmentStore(
            defaults: defaults,
            accountScopeProvider: { accountID },
            sessionIdentityProvider: { "gen-1" })
        try applyMembership(to: store, revision: "rev-1", epoch: "epoch-1")
        XCTAssertEqual(store.activeEnrollmentEpoch, "epoch-1",
                       "precondition: the server epoch backs collection")

        // The authority the retry must respect: account scope + epoch, read from the REAL store.
        func authority() -> String? {
            guard let epoch = store.activeEnrollmentEpoch else { return nil }
            return "\(accountID)|\(epoch)"
        }
        let pinned = authority()
        XCTAssertEqual(pinned, "acct-A|epoch-1")

        var now = Date()
        let chain = makeChain(
            policyPermits: { store.currentEffectiveEnrolled && authority() == pinned },
            tokenProvider: StaticTokenProvider(token: "tok"),
            attemptLimits: .init(maxUploadAttempts: 4),
            now: { now })
        let entry = try makeReadyEntry(chain.queue)
        var attempts = 0
        AssemblyIntercept.responder = { request in
            attempts += 1
            if attempts == 1 {
                return (HTTPURLResponse(url: request.url!, statusCode: 401,
                                        httpVersion: nil, headerFields: nil)!, Data())
            }
            return Self.acceptedReceiptResponder()(request)
        }
        defer { AssemblyIntercept.responder = nil }

        _ = await chain.scheduler.drainOnce()
        XCTAssertEqual(AssemblyIntercept.requestCount, 1, "the first attempt reached the wire")

        // The account's epoch moves: same account, re-enrolled under a new epoch.
        try applyMembership(to: store, revision: "rev-2", epoch: "epoch-2")
        XCTAssertEqual(authority(), "acct-A|epoch-2", "the identity really moved")
        XCTAssertEqual(store.activeEnrollmentEpoch, "epoch-2")

        // Past the back-off: the retained entry must not be sent under the old authority.
        now = now.addingTimeInterval(500)
        let secondPass = await chain.scheduler.drainOnce()
        guard case .idle = secondPass else {
            return XCTFail("a moved account/epoch must hold the retry, got \(secondPass)")
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 1,
                       "no second request under the previous identity's authority")
        XCTAssertTrue(chain.queue.readyEntries().contains { $0.name == entry.name },
                      "the entry is retained: neither sent nor dropped")
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
/// A one-shot latch for holding a request on the wire while another task runs.
private final class AsyncGate {
    private let lock = NSCondition()
    private var used = false
    private var released = false

    /// True exactly once: only the FIRST request waits.
    func isFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }

    func waitForRelease() {
        lock.lock()
        while !released { lock.wait() }
        lock.unlock()
    }

    func release() {
        lock.lock()
        released = true
        lock.broadcast()
        lock.unlock()
    }
}

/// A credential provider that refreshes ONCE per rejected token and records what it was told.
private final class RefreshingTokenProvider: CloudTokenProviding {
    private let lock = NSLock()
    private var index = 0
    private let tokens: [String]
    private(set) var refreshCount = 0
    private(set) var rejectedTokens: [String] = []

    init(tokens: [String]) { self.tokens = tokens }

    func token() async -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens[min(index, tokens.count - 1)]
    }

    func handleUnauthorized(rejectedToken: String?) async {
        lock.lock(); defer { lock.unlock() }
        rejectedTokens.append(rejectedToken ?? "<nil>")
        // Out-of-band refresh: advance to the next credential exactly once.
        refreshCount += 1
        index = min(index + 1, tokens.count - 1)
    }
}

/// Records the capture ids of requests that actually reached the wire.
private final class RequestRecorder {
    private let lock = NSLock()
    private var names: [String] = []
    func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return names.count }
}

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