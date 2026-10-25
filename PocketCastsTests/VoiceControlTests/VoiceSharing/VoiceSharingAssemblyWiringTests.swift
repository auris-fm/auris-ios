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
        AssemblyIntercept.reset(for: name)
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
            transport: { [transport] request, _, _ in
                await transport.send(request: request)
            })
        let scheduler = VoiceSharingUploadScheduler(
            queue: queue, uploader: uploader, isAuthorized: policyPermits)
        return (queue, scheduler)
    }

    /// ACCOUNT-POLICY WITHDRAWAL through the PRODUCTION registry (spec task73 follow-on): a policy
    /// refresh that observes withdrawal must fire the coordinator's real gate-lost fan-out, which is
    /// what (a) bumps the sink's revocation generation, (b) purges the durable queue, and (c) — via the
    /// same live policy reader every attempt consults — stops any further upload. This drives the
    /// production registry, not a hand-called purge.
    func test_aPolicyWithdrawalFansOutThroughTheProductionRegistry() async throws {
        let store = VoiceSharingEnrollmentStore.State()
        var state = store
        state.localOptIn = true
        state.hasAuthoritativeProjection = true
        state.membership = VoiceSharingMembership(
            membershipRevision: "rev", plan: .pro, voiceSharingEnrolled: true,
            enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09",
            withdrawalState: .active)
        var membership = state
        let policy = VoiceSharingPolicy(
            clock: StubMonotonicClock(time: 1_000),
            readRemoteSwitch: { .valid(true) },
            isAccountEnrolled: { membership.effectiveEnrolled })
        policy.identityBecameReadable()
        _ = policy.refreshAfterActivation(
            freshActivationSucceeded: true, fetchToken: policy.tokenForFetchStart())
        XCTAssertTrue(policy.permitsCollection, "premise: collection is permitted before withdrawal")

        let coordinator = VoiceSharingCoordinator()
        // The PRODUCTION registry, exactly as VoiceControlAssembly registers it.
        var revocationSeen = false
        var purged = false
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        _ = try makeReadyEntry(queue)
        let subscription = coordinator.registerGateLostHandler {
            revocationSeen = true
            purged = (try? queue.purgeAll()) != nil
        }
        defer { _ = subscription }

        // WITHDRAW in the account's own projection, then let the real refresh observe it.
        membership.membership = VoiceSharingMembership(
            membershipRevision: "rev2", plan: .pro, voiceSharingEnrolled: true,
            enrollmentEpoch: "epoch-1", acceptedDisclosureVersion: "2026-09",
            withdrawalState: .withdrawn)
        // Drive the PRODUCTION fan-out, not the test helper: `consentGateLost()` is the private
        // snapshot-and-invoke every real consent loss goes through. `fireGateLostHandlersForTesting()`
        // has its own inline loop, so driving IT would pass even if the production path were gutted.
        coordinator.consentGateLostForTesting()

        XCTAssertTrue(revocationSeen, "withdrawal must reach the sink's revocation through the registry")
        XCTAssertTrue(purged, "withdrawal must purge the durable queue through the registry")
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(after.isEmpty, "no entry survives an account-policy withdrawal")
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

    /// EPOCH RETIREMENT DURING REFRESH, through the PRODUCTION pin: the gate is
    /// `VoiceSharingUploadIdentityPin`, exactly the type the assembly uses. The older version of
    /// this control flipped a local flag that the chain never read — it asserted nothing.
    func test_epochRetirementDuringRefreshBlocksTheRetry() async throws {
        let tokens = RefreshingTokenProvider(tokens: ["stale-token", "fresh-token"])
        var epoch: String? = "epoch-1"
        let account = "acct-A"
        let pin = VoiceSharingUploadIdentityPin(
            accountScope: { account }, enrollmentEpoch: { epoch })
        var now = Date()
        let chain = makeChain(policyPermits: { pin.isCurrent }, tokenProvider: tokens,
                              attemptLimits: .init(maxUploadAttempts: 4), now: { now })
        let entry = try makeReadyEntry(chain.queue)
        // SHARED-STATE DISCIPLINE (the cause of the intermittent full-suite failure): the
        // intercepted session runs on URLSession's own threads, so a fixture that mutates its
        // state from the responder and then OBSERVES it on the test thread is racing. Both sides
        // take the host lock, which is what makes the post-drain assertion meaningful instead of
        // dependent on whether the URLSession thread had run yet.
        let hostLock = AssemblyIntercept.diagnosticLock
        AssemblyIntercept.responder = { request in
            let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
                .replacingOccurrences(of: "Bearer ", with: "")
            if token == "stale-token" {
                hostLock.lock()
                epoch = "epoch-2"   // the account re-enrolls while the credential refreshes
                hostLock.unlock()
                return (HTTPURLResponse(url: request.url!, statusCode: 401,
                                        httpVersion: nil, headerFields: nil)!,
                        Data("{\"schema_version\":1,\"code\":\"invalid_token\"}".utf8))
            }
            return Self.acceptedReceiptResponder()(request)
        }
        defer { AssemblyIntercept.responder = nil }
        // SYNCHRONOUS PROBE BEFORE THE AWAIT (diagnostic): distinguishes "the pass never had a
        // servable entry" from "it had one and the attempt produced no request".
        let readyBefore = chain.queue.readyEntries().count
        let heldBefore = String(describing: chain.queue.readyEntriesReportingUnknownCoverage())
        let pinBefore = pin.isCurrent
        let firstPass = await chain.scheduler.drainOnce()
        XCTAssertEqual(AssemblyIntercept.requestCount, 1,
                       "the first attempt went out (count last reset by \(AssemblyIntercept.resetBy ?? "?"), "
                       + "hosts=\(AssemblyIntercept.seenHosts); pass=\(firstPass) "
                       + "readyBefore=\(readyBefore) heldBefore=\(heldBefore) pinBefore=\(pinBefore) "
                       + "readyAfter=\(chain.queue.readyEntries().count) "
                       + "pinAfter=\(pin.isCurrent) "
                       + "idleDecision=\(chain.scheduler.lastIdleDecisionByDiagnostic.map { $0.discovery } ?? "-") "
                       + "refused=\(String(describing: chain.scheduler.lastRefusedPassByDiagnostic)) "
                       + "queueDiag=\(chain.queue.lastDiscoveryDiagnostic ?? "-"))")
        hostLock.lock()
        let epochAtObservation = epoch
        hostLock.unlock()
        XCTAssertFalse(pin.isCurrent,
                       "precondition: the epoch moved during the refresh (epoch read=\(epochAtObservation ?? "nil"))")

        // Past the back-off the retry would otherwise fire — the pin must hold it.
        now = now.addingTimeInterval(500)
        let pass = await chain.scheduler.drainOnce()
        guard case .idle = pass else {
            return XCTFail("a retired epoch must hold the retry, got \(pass)")
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 1,
                       "no retry is sent once the enrollment epoch has moved")
        XCTAssertTrue(chain.queue.readyEntries().contains { $0.name == entry.name },
                      "the entry is retained, not delivered and not silently dropped")
    }

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

        var currentTime = Date()
        // DIAGNOSTIC: recording WHERE the pin diverges, and also memoizing the last TRUE answer so
        // a transient `false` (whatever produced it) cannot be mistaken for a settled refusal.
        let isoBefore = store.currentEffectiveEnrolled && authority() == pinned
        var isoCalls = 0
        var isoFalseAt: String? = nil
        var isoTrueSeen = isoBefore
        let chain = makeChain(
            policyPermits: {
                isoCalls += 1
                let isoNow = store.currentEffectiveEnrolled && authority() == pinned
                if isoNow != isoBefore, isoFalseAt == nil, isoCalls > 1 {
                    let probe = VoiceSharingEnrollmentStore(defaults: defaults,
                                                           accountScopeProvider: { accountID },
                                                           sessionIdentityProvider: { "gen-1" })
                    isoFalseAt = "call#\(isoCalls) -> \(isoNow); sameStoreEpoch=\(String(describing: store.activeEnrollmentEpoch)) "
                        + "reopenedEpoch=\(String(describing: probe.activeEnrollmentEpoch)) "
                        + "reopenedEffective=\(probe.currentEffectiveEnrolled)"
                }
                if isoNow { isoTrueSeen = true }
                return isoNow
            },
            tokenProvider: StaticTokenProvider(token: "tok"),
            attemptLimits: .init(maxUploadAttempts: 4),
            now: { currentTime })
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

        // SYNCHRONOUS PROBE, taken BEFORE any await (diagnostic for the intermittent full-suite
        // failure): if the pass below reports `.idle` with a ready entry, this says whether the
        // refusal came from a live authorization signal or from the queue's own view of the entry.
        var readyBeforePass = -1
        var heldBeforePass = "n/a"
        do {
            readyBeforePass = chain.queue.readyEntries().count
            heldBeforePass = String(describing: chain.queue.readyEntriesReportingUnknownCoverage())
        }
        let firstPass = await chain.scheduler.drainOnce()
        // The assertion message carries the evidence, so a failing run explains itself. (A stray
        // `print` is not reliably captured in the xcodebuild log.)
        let pinNow = authority()
        let diag = "counting=\(AssemblyIntercept.requestCount) "
            + "ready=\(chain.queue.readyEntries().count) "
            + "held=\(chain.queue.readyEntriesReportingUnknownCoverage()) "
            + "pass=\(firstPass) pin=\(String(describing: pinNow)) pinned=\(String(describing: pinned)) "
            + "enrolled=\(store.currentEffectiveEnrolled) isoBefore=\(isoBefore) "
            + "isoCalls=\(isoCalls) isoFalseAt=\(isoFalseAt ?? "-") isoTrueSeen=\(isoTrueSeen) "
            + "readyBeforePass=\(readyBeforePass) heldBeforePass=\(heldBeforePass) "
            + "isoAtSync=\(store.currentEffectiveEnrolled && authority() == pinned) "
            + "idleDecision=\(chain.scheduler.lastIdleDecisionByDiagnostic.map { $0.discovery } ?? "-") "
            + "discoveryDiag=\(chain.queue.lastDiscoveryDiagnostic) "
            + "refused=\(String(describing: chain.scheduler.lastRefusedPassByDiagnostic))"
        XCTAssertEqual(AssemblyIntercept.requestCount, 1,
                       "the first attempt reached the wire (count last reset by \(AssemblyIntercept.resetBy ?? "?"), "
                       + "hosts=\(AssemblyIntercept.seenHosts); \(diag))")

        // The account's epoch moves: same account, re-enrolled under a new epoch.
        try applyMembership(to: store, revision: "rev-2", epoch: "epoch-2")
        XCTAssertEqual(authority(), "acct-A|epoch-2", "the identity really moved")
        XCTAssertEqual(store.activeEnrollmentEpoch, "epoch-2")

        // Past the back-off: the retained entry must not be sent under the old authority.
        currentTime = currentTime.addingTimeInterval(500)
        let secondPass = await chain.scheduler.drainOnce()
        guard case .idle = secondPass else {
            return XCTFail("a moved account/epoch must hold the retry, got \(secondPass)")
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 1,
                       "no second request under the previous identity's authority")
        XCTAssertTrue(chain.queue.readyEntries().contains { $0.name == entry.name },
                      "the entry is retained: neither sent nor dropped")
    }

    /// THE PRODUCTION PIN (spec 724577f3): `VoiceSharingUploadIdentityPin` is the type the assembly
    /// now uses. It must invalidate on an epoch move, on an account switch, and stay invalid when no
    /// epoch is known — and it must do so by itself, with no fixture-supplied closure.
    func test_identityPinInvalidatesOnEpochMoveAndAccountSwitch() {
        var account = "acct-A"
        var epoch: String? = "epoch-1"
        let pin = VoiceSharingUploadIdentityPin(
            accountScope: { account }, enrollmentEpoch: { epoch })
        XCTAssertTrue(pin.isCurrent, "the identity it was pinned under is the live one")

        epoch = "epoch-2"
        XCTAssertFalse(pin.isCurrent, "a re-enrollment under a new epoch must invalidate the pin")

        epoch = "epoch-1"
        account = "acct-B"
        XCTAssertFalse(pin.isCurrent,
                       "another account's identical epoch string must not satisfy the pin")

        // Unknown epoch is never a valid identity — fail closed rather than pin to "no epoch".
        epoch = nil
        let unknown = VoiceSharingUploadIdentityPin(
            accountScope: { account }, enrollmentEpoch: { epoch })
        XCTAssertFalse(unknown.isCurrent, "an absent epoch cannot authorize uploads")
        epoch = ""
        XCTAssertFalse(unknown.isCurrent, "an empty epoch cannot authorize uploads")
    }

    /// CREDENTIAL-AWAIT WINDOW (reviewer 78f23dca / ee5b4547): the identity is intact at the
    /// uploader's launch fence, then moves WHILE the REAL transport is acquiring the credential.
    /// The transport must re-fence at that boundary with THIS attempt's admitted snapshot and
    /// emit no request — a post-response refusal cannot repair the disclosure.
    func test_identityChangeDuringCredentialAwaitEmitsNoRequest() async throws {
        let sharedRoot = root!
        let box = IdentityBox(VoiceSharingUploadIdentity(
            accountScope: "acct-A", enrollmentEpoch: "epoch-1"))
        let owned = VoiceSharingUploadQueue(
            rootDirectory: sharedRoot, currentIdentity: { box.current })
        let entry = try makeReadyEntryOwned(owned, root: sharedRoot)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssemblyIntercept.self]
        let realTransport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: SuspendingTokenProvider {
                // The move lands INSIDE the credential await, provably.
                box.current = VoiceSharingUploadIdentity(
                    accountScope: "acct-A", enrollmentEpoch: "epoch-2")
            },
            session: URLSession(configuration: configuration))

        AssemblyIntercept.responder = { _ in
            XCTFail("no request may reach the wire during a credential-await identity move")
            return (HTTPURLResponse(url: URL(string: "https://unit.test/x")!, statusCode: 500,
                                    httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { AssemblyIntercept.responder = nil }

        let admitted = try XCTUnwrap(try owned.admitAttempt(entry))
        let request = URLRequest(url: URL(string: "https://unit.test/api/v1/voice-recordings")!)
        let result = await realTransport.send(
            request: request, admittedIdentity: admitted.identity,
            identityFence: { box.current })

        guard case .transportFailure = result else {
            return XCTFail("a moved identity at the credential boundary must send nothing, got \(result)")
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 0,
                       "the real transport emitted no request")
        try owned.applyAttemptResult(entry, lease: admitted.lease, outcome: .retryableFailure)
        XCTAssertTrue(owned.readyEntries().contains { $0.name == entry.name },
                      "the entry is retained for its owning identity")
    }

    /// FINAL PRE-LAUNCH WINDOW (reviewer 1244fd5e / 376a2518): the transport's own
    /// baseURLProvider/endpoint resolution runs AFTER the credential-boundary check. Flipping the
    /// identity inside baseURLProvider lands the move between the credential fence and the
    /// launch; the FINAL fence (after request building, before receive) must stop it.
    func test_identityChangeInsideBaseURLProviderEmitsNoRequest() async throws {
        let sharedRoot = root!
        let box = IdentityBox(VoiceSharingUploadIdentity(
            accountScope: "acct-A", enrollmentEpoch: "epoch-1"))
        let owned = VoiceSharingUploadQueue(
            rootDirectory: sharedRoot, currentIdentity: { box.current })
        let entry = try makeReadyEntryOwned(owned, root: sharedRoot)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssemblyIntercept.self]
        let realTransport = VoiceSharingUploadTransport(
            baseURLProvider: {
                // This callback runs between the two fences — exactly where a move must be caught.
                box.current = VoiceSharingUploadIdentity(
                    accountScope: "acct-A", enrollmentEpoch: "epoch-2")
                return "https://unit.test"
            },
            tokenProvider: StaticTokenProvider(token: "tok"),
            session: URLSession(configuration: configuration))

        AssemblyIntercept.responder = { _ in
            XCTFail("no request may reach the wire for a baseURLProvider-window move")
            return (HTTPURLResponse(url: URL(string: "https://unit.test/x")!, statusCode: 500,
                                    httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { AssemblyIntercept.responder = nil }

        let admitted = try XCTUnwrap(try owned.admitAttempt(entry))
        let request = URLRequest(url: URL(string: "https://unit.test/api/v1/voice-recordings")!)
        let result = await realTransport.send(
            request: request, admittedIdentity: admitted.identity,
            identityFence: { box.current })

        guard case .transportFailure = result else {
            return XCTFail("a move inside baseURLProvider must send nothing, got \(result)")
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 0,
                       "the real transport emitted no request")
        try owned.applyAttemptResult(entry, lease: admitted.lease, outcome: .retryableFailure)
        XCTAssertTrue(owned.readyEntries().contains { $0.name == entry.name })
    }

    /// ASSEMBLED CREDENTIAL-WINDOW CONTROL (reviewer 1244fd5e): the direct-send test above proves
    /// the transport check; this one drives the PRODUCTION path — assembly-built uploader and
    /// transport, real admission, real fence forwarding — with the move inside the token await.
    func test_assembledUploadStopsWhenIdentityMovesDuringCredentialAwait() async throws {
        let sharedRoot = root!
        let box = IdentityBox(VoiceSharingUploadIdentity(
            accountScope: "acct-A", enrollmentEpoch: "epoch-1"))
        let queue = VoiceSharingUploadQueue(
            rootDirectory: sharedRoot, currentIdentity: { box.current })
        let entry = try makeReadyEntryOwned(queue, root: sharedRoot)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssemblyIntercept.self]
        let realTransport = VoiceSharingUploadTransport(
            baseURLProvider: { "https://unit.test" },
            tokenProvider: SuspendingTokenProvider {
                box.current = VoiceSharingUploadIdentity(
                    accountScope: "acct-A", enrollmentEpoch: "epoch-2")
            },
            session: URLSession(configuration: configuration))
        // Rebuild the uploader exactly as the assembly does, but with the real transport — the
        // production closure signature forwards snapshot + fence unchanged.
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(
                retryBaseDelay: 1, retryMaximumDelay: 60, random: { 0 }),
            isAuthorized: { true }, currentIdentity: { box.current },
            endpoint: { realTransport.endpoint },
            transport: { request, admitted, fence in
                await realTransport.send(
                    request: request, admittedIdentity: admitted, identityFence: fence)
            })

        AssemblyIntercept.responder = { _ in
            XCTFail("assembled path: no request may reach the wire during the credential await")
            return (HTTPURLResponse(url: URL(string: "https://unit.test/x")!, statusCode: 500,
                                    httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { AssemblyIntercept.responder = nil }

        let outcome = await uploader.upload(entry)
        // The transport refusal surfaces as .retry; the uploader's own post-await fence then
        // escalates the SAME move to .revoked — either way nothing was sent (asserted below).
        guard case .revoked = outcome else {
            return XCTFail("the assembled upload must be revoked on a credential-window move, got \(outcome)")
        }
        XCTAssertEqual(AssemblyIntercept.requestCount, 0,
                       "assembled path emitted no request")
        XCTAssertTrue(queue.readyEntries().contains { $0.name == entry.name },
                      "the entry is retained for its owning identity")
    }

    /// Token provider that runs a hook inside `token()` — proves a move happens while the
    /// credential await is in flight.
    private final class SuspendingTokenProvider: CloudTokenProviding {
        private let onAcquire: () -> Void
        init(onAcquire: @escaping () -> Void) { self.onAcquire = onAcquire }
        func token() async -> String? { onAcquire(); return "tok" }
        func prepare() async {}
        func handleUnauthorized(rejectedToken: String?) async {}
    }

    /// A ready entry on a SPECIFIC identity-bound queue.
    private func makeReadyEntryOwned(_ queue: VoiceSharingUploadQueue, root: URL) throws
        -> VoiceSharingUploadQueue.Entry {
        let samples: [Float] = [0, 0.25, -0.5, 0.5]
        let event = VoiceSharingCollector.SegmentEvent(
            kind: .completed, captureID: UUID(),
            enrollmentEpoch: "epoch-1", authorizationSession: "acct-A",
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

    /// IdentityBox for fence controls.
    private final class IdentityBox {
        private let lock = NSLock()
        private var value: VoiceSharingUploadIdentity?
        init(_ initial: VoiceSharingUploadIdentity?) { value = initial }
        var current: VoiceSharingUploadIdentity? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
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

    /// CONSTRUCTED UPLOADER → REAL LOCAL HTTP → VALIDATED RECEIPT → SETTLEMENT (spec 18:06Z ask).
    /// Unlike the URLProtocol controls elsewhere in this file, this drives a REAL TCP connection to a
    /// local listener. The server parses the multipart body it actually received, recomputes the record
    /// digest from those bytes, and only then replies with a receipt — so delivery cannot be faked by a
    /// stubbed response, and the client's settlement is accepted against a receipt the server derived
    /// from the client's own upload.
    func test_theConstructedUploaderDeliversOverRealLocalHTTPAndSettlesOnAValidatedReceipt() async throws {
        var acceptedBody: Data?
        var servedReceiptDigest: String?
        var observedPort: UInt16 = 0
        let serverQueue = DispatchQueue(label: "vs-local-http")
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state {
                observedPort = listener?.port?.rawValue ?? 0
                ready.signal()
            }
        }
        let acceptedConnections = ConnectionHolder()
        listener.newConnectionHandler = { connection in
            acceptedConnections.store(connection)
            connection.stateUpdateHandler = { [weak connection] state in
                guard case .ready = state, let connection else { return }
                // ACCUMULATE the whole request: a single receive() returns as soon as ANY bytes arrive,
                // which truncates a multipart upload. Read until the declared Content-Length is met.
                var accumulated = Data()
                func drain() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                        content, _, isComplete, _ in
                        if let content { accumulated.append(content) }
                        if let expected = Self.declaredContentLength(accumulated),
                            accumulated.count >= expected {
                            acceptedBody = accumulated
                            servedReceiptDigest = Self.receiptDigest(in: accumulated)
                            let response = self.receiptFor(accumulated)
                            connection.send(
                                content: response,
                                completion: .contentProcessed { _ in connection.cancel() })
                            return
                        }
                        if isComplete {
                            acceptedBody = accumulated
                            servedReceiptDigest = Self.receiptDigest(in: accumulated)
                            let response = self.receiptFor(accumulated)
                            connection.send(
                                content: response,
                                completion: .contentProcessed { _ in connection.cancel() })
                            return
                        }
                        drain()
                    }
                }
                drain()
            }
            connection.start(queue: serverQueue)
        }
        listener.start(queue: serverQueue)
        guard ready.wait(timeout: .now() + 5) == .success, observedPort != 0 else {
            return XCTFail("the local HTTP server did not start")
        }
        defer {
            listener.cancel()
            acceptedConnections.current?.cancel()
        }

        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let entry = try makeReadyEntry(queue)
        let identity = try queue.boundIdentity(of: entry)
        let plainConfiguration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: plainConfiguration)
        defer { session.invalidateAndCancel() }
        let transport = VoiceSharingUploadTransport(
            baseURLProvider: { "http://127.0.0.1:\(observedPort)" },
            tokenProvider: StaticTokenProvider(token: "tok"), session: session)
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(
                retryBaseDelay: 1, retryMaximumDelay: 60, random: { 0 }),
            isAuthorized: { true },
            endpoint: { transport.endpoint },
            transport: { [transport] request, _, _ in await transport.send(request: request) })
        let scheduler = VoiceSharingUploadScheduler(
            queue: queue, uploader: uploader, isAuthorized: { true })

        let outcome = await scheduler.drainOnce()
        guard case .drained(let results) = outcome, results.count == 1 else {
            return XCTFail("expected one drained result, got \(outcome)")
        }
        guard case .delivered = results[0].outcome else {
            return XCTFail("a valid receipt over real HTTP must settle as delivered, got \(results[0].outcome)")
        }
        // NON-VACUITY: the server derived its receipt from the UPLOADED bytes, and that derived digest
        // is the entry's own. If this fails, a server answering with an unrelated identity would still
        // have settled the entry here — the control would then prove transport, not validated settlement.
        XCTAssertEqual(servedReceiptDigest, identity.recordSHA256,
                       "the receipt must be derived from the uploaded record's own digest")
        // The server saw a real multipart body carrying this entry's identity.
        guard let body = acceptedBody else { return XCTFail("the server received no body") }
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains(identity.recordSHA256),
                      "the uploaded bytes must carry the entry's record digest")
        XCTAssertTrue(bodyText.contains(identity.captureID),
                      "the uploaded bytes must carry the entry's capture id")
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(after.isEmpty, "the settled entry no longer serves")
    }

    /// The record digest the server's receipt answered with, derived the same way receiptFor derives it.
    static func receiptDigest(in raw: Data) -> String? {
        let bytes = [UInt8](raw)
        guard let headEnd = findBytes([13, 10, 13, 10], in: bytes, from: 0) else { return nil }
        let head = String(decoding: bytes[0..<headEnd], as: UTF8.self)
        guard let contentTypeLine = head.split(separator: "\r\n").first(where: {
            $0.lowercased().hasPrefix("content-type:")
        }) else { return nil }
        var request = URLRequest(url: URL(string: "http://127.0.0.1/")!)
        request.httpBody = raw.subdata(in: (headEnd + 4)..<raw.count)
        request.setValue(String(contentTypeLine), forHTTPHeaderField: "Content-Type")
        return (try? attemptedIdentity(from: request))?.sha
    }

    /// The total byte count the request declares (head + body), from its own Content-Length header.
    static func declaredContentLength(_ raw: Data) -> Int? {
        let bytes = [UInt8](raw)
        guard let headEnd = findBytes([13, 10, 13, 10], in: bytes, from: 0) else { return nil }
        let head = String(decoding: bytes[0..<headEnd], as: UTF8.self)
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            let value = line.split(separator: ":", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces)
            guard let bodyLength = Int(value) else { return nil }
            return headEnd + 4 + bodyLength
        }
        return nil
    }

    /// Builds a valid receipt for the multipart body the server actually received. It reuses the SAME
    /// strict extractor the other controls use (no ad-hoc string search): the identity is read out of the
    /// metadata part and the envelope digest, exactly as a real intake would.
    private func receiptFor(_ raw: Data) -> Data {
        func failure() -> Data {
            let body = Data("{\"schema_version\":1,\"code\":\"malformed_record\"}".utf8)
            var response = Data("HTTP/1.1 400 Bad Request\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            return response
        }
        // Split the request head from the body to recover the Content-Type boundary.
        guard let headEnd = Self.findBytes([13, 10, 13, 10], in: [UInt8](raw), from: 0) else {
            return failure()
        }
        let head = String(decoding: [UInt8](raw)[0..<headEnd], as: UTF8.self)
        guard let contentTypeLine = head.split(separator: "\r\n").first(where: {
            $0.lowercased().hasPrefix("content-type:")
        }) else { return failure() }
        let contentType = String(contentTypeLine)
        let body = raw.subdata(in: (headEnd + 4)..<raw.count)
        var request = URLRequest(url: URL(string: "http://127.0.0.1/")!)
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        guard let identity = try? Self.attemptedIdentity(from: request) else {
            return failure()
        }
        let receipt: [String: Any] = [
            "schema_version": 1,
            "capture_id": identity.captureID,
            "record_sha256": identity.sha,
            "status": "accepted",
            "receipt_id": "rcpt-local-1",
            "accepted_at": "2026-10-22T14:00:00Z",
            "retention_expires_at": "2026-11-22T14:00:00Z",
        ]
        let receiptBody = try! JSONSerialization.data(withJSONObject: receipt)
        var response = Data("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n".utf8)
        response.append(Data("Content-Length: \(receiptBody.count)\r\nConnection: close\r\n\r\n".utf8))
        response.append(receiptBody)
        return response
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
        AssemblyIntercept.reset(for: name + " (mid-test: successor)")
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
    /// WHICH test last reset the counter. Two wiring tests in a full run both drove the count to 0
    /// mid-flight; recording the resetter makes the interference claim checkable instead of a guess.
    static var resetBy: String?
    /// The URL host each intercepted request was actually built for, so a route/keying bug is
    /// visible rather than inferred.
    static var seenHosts: [String] = []

    /// One place that mutates the shared diagnostics, so the count and the resetter can never
    /// disagree about ordering.
    static let diagnosticLock = NSLock()
    static func record(_ request: URLRequest) {
        diagnosticLock.lock()
        requestCount += 1
        if let host = request.url?.host { seenHosts.append(host) }
        diagnosticLock.unlock()
    }

    static func reset(for test: String) {
        diagnosticLock.lock()
        requestCount = 0
        resetBy = test
        seenHosts = []
        diagnosticLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        AssemblyIntercept.record(request)
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

// MARK: - The REAL trigger's follow-up handoff (reviewer 44d39ef8)

/// These drive `VoiceSharingUploadTrigger` itself — the production consumer — with a scheduler pass
/// held open from the outside. The held pass is what makes "would-be immediate retries" provably
/// happen while the owner is still running: the control holds the owner until a trigger has been
/// fired and (for the busy case) a second trigger too, then releases and asserts the follow-up
/// arrives WITHOUT any manual drain.
final class VoiceSharingTriggerFollowUpTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vstrigger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A transport that HOLDS the first pass inside the upload and counts every attempt.
    private final class HeldTransport {
        private let lock = NSLock()
        private let started = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private var attempts = 0
        private var holdFirst = true

        func waitForFirstAttempt() -> DispatchTimeoutResult { started.wait(timeout: .now() + 10) }
        func releaseHeldPass() { release.signal() }
        var attemptCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }
        /// Let later passes through instantly once the held one is released.
        func stopHolding() { lock.lock(); holdFirst = false; lock.unlock() }

        func handle() -> VoiceSharingUploader.TransportResult {
            lock.lock()
            attempts += 1
            let shouldHold = holdFirst
            lock.unlock()
            started.signal()
            if shouldHold {
                _ = release.wait(timeout: .now() + 10)
            }
            return .transportFailure
        }
    }

    private func makeTrigger(_ transport: HeldTransport)
        -> (queue: VoiceSharingUploadQueue, scheduler: VoiceSharingUploadScheduler,
            trigger: VoiceSharingUploadTrigger) {
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(
                retryBaseDelay: 1, retryMaximumDelay: 60, random: { 0 }),
            isAuthorized: { true },
            endpoint: { URL(string: "https://unit.test/upload") },
            transport: { _, _, _ in transport.handle() })
        let scheduler = VoiceSharingUploadScheduler(
            queue: queue, uploader: uploader, isAuthorized: { true })
        let trigger = VoiceSharingUploadTrigger(
            scheduler: scheduler, surfaceEnabled: { true }, isAuthorized: { true })
        return (queue, scheduler, trigger)
    }

    /// NEW WORK DURING THE TRIGGER'S OWN PASS. The trigger is fired while its own drain is held, so
    /// the event reaches the trigger's guard (not the scheduler) — the exact gap the reviewer named.
    /// After release, the automatic follow-up must serve the work with NO manual drain.
    func test_newWorkDuringTheTriggersOwnDrainIsServedByTheAutomaticFollowUp() async throws {
        let transport = HeldTransport()
        let chain = makeTrigger(transport)
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)

        chain.trigger.triggerDrainIfPermitted()
        XCTAssertEqual(transport.waitForFirstAttempt(), .success, "the first pass is in flight")

        // WORK ARRIVES while the trigger's drain is running: this hits the trigger's own guard.
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)
        chain.trigger.triggerDrainIfPermitted()

        transport.stopHolding()
        transport.releaseHeldPass()
        await chain.trigger.awaitCurrentDrainForTesting()

        // The follow-up is started by the completion handoff; give it a chance to run and land.
        for _ in 0..<40 where transport.attemptCount < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThanOrEqual(transport.attemptCount, 2,
                                    "the work that arrived during the drain must reach the wire "
                                    + "via the automatic follow-up, without another manual drain")
    }

    /// A SCHEDULER PASS HELD FROM OUTSIDE (not by this trigger): the trigger's first attempt is
    /// refused with `.busy`, and the follow-up must still deliver once the owner releases.
    ///
    /// The held work runs on its OWN plain thread, not the cooperative pool: the transport blocks
    /// its thread, and starving the pool deadlocks this control rather than exercising the trigger.
    func test_aBusyRefusalStillEndsInADeliveredFollowUp() async throws {
        let transport = HeldTransport()
        let chain = makeTrigger(transport)
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)

        // The OWNER: a pass on a dedicated thread, held inside the transport.
        let ownerHeld = DispatchSemaphore(value: 0)
        var ownerHeldSignalled = false
        let ownerThread = Thread {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                _ = await chain.scheduler.drainOnce()
                semaphore.signal()
            }
            ownerHeldSignalled = semaphore.wait(timeout: .now() + 15) == .success
            ownerHeld.signal()
        }
        ownerThread.start()
        XCTAssertEqual(transport.waitForFirstAttempt(), .success, "the owner holds the scheduler")

        // The trigger fires while the owner is held: it gets `.busy` and must remember the work.
        chain.trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.attemptCount, 1, "the refused trigger attempted nothing itself")

        transport.stopHolding()
        transport.releaseHeldPass()
        XCTAssertEqual(ownerHeld.wait(timeout: .now() + 15), .success, "the owner finished")
        XCTAssertTrue(ownerHeldSignalled, "the owner thread's drain must have returned, not timed out")

        for _ in 0..<60 where transport.attemptCount < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThanOrEqual(transport.attemptCount, 2,
                                    "the busy refusal must be recovered by the follow-up, not dropped")
    }

    /// NO UNBOUNDED RETRY WHILE THE OWNER STAYS HELD (reviewer 280f4c52). With the owner held for a
    /// long, fixed interval, the trigger must settle into a WAIT, not a re-offer loop: total
    /// attempts stay at the owner's single one for the whole hold, and the trigger is not spinning.
    func test_aRefusedTriggerWaitsInsteadOfPollingWhileTheOwnerStaysHeld() async throws {
        let transport = HeldTransport()
        let chain = makeTrigger(transport)
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)

        let ownerHeld = DispatchSemaphore(value: 0)
        var ownerHeldSignalled = false
        let ownerThread = Thread {
            let done = DispatchSemaphore(value: 0)
            Task {
                _ = await chain.scheduler.drainOnce()
                done.signal()
            }
            ownerHeldSignalled = done.wait(timeout: .now() + 20) == .success
            ownerHeld.signal()
        }
        ownerThread.start()
        XCTAssertEqual(transport.waitForFirstAttempt(), .success, "the owner holds the scheduler")

        chain.trigger.triggerDrainIfPermitted()
        // Hold for ~1s and sample: a poll loop would keep attempting; a wait attempts nothing.
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(transport.attemptCount, 1,
                           "the refused trigger must NOT keep re-attempting while the owner holds")
        }

        transport.stopHolding()
        transport.releaseHeldPass()
        XCTAssertEqual(ownerHeld.wait(timeout: .now() + 20), .success, "owner finished")
        XCTAssertTrue(ownerHeldSignalled, "the owner thread's drain must have returned, not timed out")
        for _ in 0..<60 where transport.attemptCount < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThanOrEqual(transport.attemptCount, 2,
                                    "and when the owner releases, the registered waiter delivers it")
    }

    /// CANCELLATION while the trigger is alive: a cancelled trigger must neither send nor keep a
    /// pending registration.
    func test_cancellingTheTriggerDropsItsRegistrationAndSendsNothing() async throws {
        let transport = HeldTransport()
        let chain = makeTrigger(transport)
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)

        let ownerHeld = DispatchSemaphore(value: 0)
        var ownerHeldSignalled = false
        let ownerThread = Thread {
            let done = DispatchSemaphore(value: 0)
            Task {
                _ = await chain.scheduler.drainOnce()
                done.signal()
            }
            ownerHeldSignalled = done.wait(timeout: .now() + 20) == .success
            ownerHeld.signal()
        }
        ownerThread.start()
        XCTAssertEqual(transport.waitForFirstAttempt(), .success, "the owner holds the scheduler")

        chain.trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 150_000_000)
        chain.trigger.cancelForTesting()
        XCTAssertFalse(chain.trigger.isDrainingForTesting, "the slot is released on cancellation")

        transport.stopHolding()
        transport.releaseHeldPass()
        XCTAssertEqual(ownerHeld.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(ownerHeldSignalled, "the owner thread's drain must have returned, not timed out")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(transport.attemptCount, 1,
                       "a cancelled trigger must not run its follow-up")
    }

    /// A STALE COMPLETION CALLBACK CHANGES NOTHING (reviewer 2a570a0b #4): the barrier holds the
    /// scheduler at the EXACT moment the callback is about to be taken; the trigger is cancelled in
    /// that window; releasing the gate then fires the callback into a dead era. It must be a no-op.
    /// No sleeps stand in for the race.
    func test_aCompletionCallbackFiringAfterCancellationIsANoop() async throws {
        let transport = HeldTransport()
        let chain = makeTrigger(transport)
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)

        let callbackAboutToFire = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        // The gate must not silently continue: a timeout is recorded and asserted.
        var gateTimedOut = false
        let gateLock = NSLock()
        chain.scheduler.ownerCompletionFireGateForTesting = {
            callbackAboutToFire.signal()
            if releaseCallback.wait(timeout: .now() + 20) == .timedOut {
                gateLock.lock(); gateTimedOut = true; gateLock.unlock()
            }
        }
        defer {
            // Signals a still-held gate so a failing assertion cannot hang the worker; joining is
            // by bounded waits in the test body.
            releaseCallback.signal()
            chain.scheduler.ownerCompletionFireGateForTesting = nil
        }

        let ownerHeld = DispatchSemaphore(value: 0)
        var ownerHeldSignalled = false
        let ownerThread = Thread {
            let done = DispatchSemaphore(value: 0)
            Task {
                _ = await chain.scheduler.drainOnce()
                done.signal()
            }
            ownerHeldSignalled = done.wait(timeout: .now() + 20) == .success
            ownerHeld.signal()
        }
        ownerThread.start()
        XCTAssertEqual(transport.waitForFirstAttempt(), .success, "the owner holds the scheduler")

        chain.trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 150_000_000) // let the refusal register
        transport.stopHolding()
        transport.releaseHeldPass()
        // ORDER (reviewer b8991889): wait for the CALLBACK to be taken first (ownerHeld can only
        // fire AFTER the gate releases, since the owner's defer is blocked in the gate), then
        // cancel inside the window, then release.
        XCTAssertEqual(callbackAboutToFire.wait(timeout: .now() + 20), .success,
                       "the barrier proves the callback is taken, not guessed")
        chain.trigger.cancelForTesting()
        releaseCallback.signal()
        XCTAssertEqual(ownerHeld.wait(timeout: .now() + 20), .success, "the owner drain finishes")
        XCTAssertTrue(ownerHeldSignalled, "the owner thread's drain must have returned, not timed out")
        gateLock.lock(); let timedOut = gateTimedOut; gateLock.unlock()
        XCTAssertFalse(timedOut, "the fire gate must not have driven the race by timing out")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(transport.attemptCount, 1,
                       "the stale callback must not re-offer after cancellation")
        XCTAssertFalse(chain.trigger.isDrainingForTesting, "and the slot stays released")
    }

    /// STOP BETWEEN COMPLETION AND RE-OFFER (reviewer b8991889 #2): the completion callback
    /// clears the slot under the lock, unlocks, THEN re-offers. A stop in that window must
    /// refuse the follow-up via the cancellation generation read atomically with slot clearing.
    /// The fire gate holds the callback BEFORE it runs; we stop the trigger while it is held
    /// (bumping the generation), then release: the callback's era check makes it a no-op, and
    /// even a callback that passed its era check would be refused at re-offer admission.
    func test_aStopBetweenCompletionAndItsReofferRefusesTheFollowUp() async throws {
        let transport = HeldTransport()
        let chain = makeTrigger(transport)
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)

        let callbackAboutToFire = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        var gateTimedOut = false
        let gateLock = NSLock()
        chain.scheduler.ownerCompletionFireGateForTesting = {
            callbackAboutToFire.signal()
            if releaseCallback.wait(timeout: .now() + 30) == .timedOut {
                gateLock.lock(); gateTimedOut = true; gateLock.unlock()
            }
        }
        defer {
            // Signals a still-held gate so a failing assertion cannot hang the worker; joining is
            // by bounded waits in the test body.
            releaseCallback.signal()
            chain.scheduler.ownerCompletionFireGateForTesting = nil
        }

        let ownerHeld = DispatchSemaphore(value: 0)
        var ownerHeldSignalled = false
        let ownerThread = Thread {
            let done = DispatchSemaphore(value: 0)
            Task {
                _ = await chain.scheduler.drainOnce()
                done.signal()
            }
            ownerHeldSignalled = done.wait(timeout: .now() + 30) == .success
            ownerHeld.signal()
        }
        ownerThread.start()
        XCTAssertEqual(transport.waitForFirstAttempt(), .success, "the owner holds the scheduler")

        // Refused arrival: the trigger registers for the owner's completion with workPending set
        // (a second arrival coalesces into the same era).
        chain.trigger.triggerDrainIfPermitted()
        chain.trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 150_000_000)

        transport.stopHolding()
        transport.releaseHeldPass()
        // The callback is TAKEN (gate), then we stop INSIDE the completion window.
        XCTAssertEqual(callbackAboutToFire.wait(timeout: .now() + 30), .success)
        chain.trigger.cancelForTesting()
        releaseCallback.signal()
        XCTAssertEqual(ownerHeld.wait(timeout: .now() + 30), .success, "the owner drain finishes")
        XCTAssertTrue(ownerHeldSignalled, "the owner thread's drain must have returned, not timed out")
        gateLock.lock(); let timedOut = gateTimedOut; gateLock.unlock()
        XCTAssertFalse(timedOut, "the fire gate must not have driven the race by timing out")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(transport.attemptCount, 1,
                       "the follow-up decided by the completed era must be refused after stop")
        XCTAssertFalse(chain.trigger.isDrainingForTesting, "and no new era may open")
    }

    /// A callback whose drain was SUPERSEDED must not clobber the newer state (reviewer 4377e2bd):
    /// after a cancellation, a fresh era must work independently of the old registration.
    func test_aSupersededCallbacksFiringDoesNotClobberTheNewerDrain() async throws {
        let transport = HeldTransport()
        let chain = makeTrigger(transport)
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)

        let ownerHeld = DispatchSemaphore(value: 0)
        var ownerHeldSignalled = false
        let ownerThread = Thread {
            let done = DispatchSemaphore(value: 0)
            Task {
                _ = await chain.scheduler.drainOnce()
                done.signal()
            }
            ownerHeldSignalled = done.wait(timeout: .now() + 30) == .success
            ownerHeld.signal()
        }
        ownerThread.start()
        XCTAssertEqual(transport.waitForFirstAttempt(), .success, "the owner holds the scheduler")

        // First arrival: refused, registers for owner completion.
        chain.trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 100_000_000)
        // Cancel ends the first era; its registration becomes inert. Release the owner, then a
        // fresh arrival must deliver normally despite the old registration having fired or not.
        chain.trigger.cancelForTesting()
        transport.stopHolding()
        transport.releaseHeldPass()
        XCTAssertEqual(ownerHeld.wait(timeout: .now() + 30), .success)
        XCTAssertTrue(ownerHeldSignalled, "the owner thread's drain must have returned, not timed out")
        chain.trigger.triggerDrainIfPermitted()
        for _ in 0..<120 where transport.attemptCount < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(transport.attemptCount, 2,
                       "a fresh era after cancellation delivers normally (old registration inert)")
    }

    /// PUBLICATION PRECEDES REGISTRATION (reviewer 2a570a0b #1): by the time the busy refusal has
    /// returned, the trigger's registration identity is already published, so the scheduler can
    /// never invoke a callback whose identity is not yet visible.
    func test_theRegistrationIdentityIsPublishedBeforeTheOwnerCanFire() async throws {
        let transport = HeldTransport()
        let chain = makeTrigger(transport)
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)

        let ownerHeld = DispatchSemaphore(value: 0)
        var ownerHeldSignalled = false
        let ownerThread = Thread {
            let done = DispatchSemaphore(value: 0)
            Task {
                _ = await chain.scheduler.drainOnce()
                done.signal()
            }
            ownerHeldSignalled = done.wait(timeout: .now() + 30) == .success
            ownerHeld.signal()
        }
        ownerThread.start()
        XCTAssertEqual(transport.waitForFirstAttempt(), .success, "the owner holds the scheduler")

        chain.trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(chain.trigger.hasPublishedCompletionRegistrationForTesting,
                      "the registration identity is visible the moment the refusal returned")
        transport.stopHolding()
        transport.releaseHeldPass()
        XCTAssertEqual(ownerHeld.wait(timeout: .now() + 30), .success)
        XCTAssertTrue(ownerHeldSignalled, "the owner thread's drain must have returned, not timed out")
        for _ in 0..<120 where transport.attemptCount < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThanOrEqual(transport.attemptCount, 2, "and the wakeup is not lost")
    }

    /// THE EXACT RE-OFFER WINDOW (reviewer b8991889 #2, isolated): the callback runs with a live
    /// era, clears the slot, and is paused immediately before re-offer admission. A stop() inside
    /// that window bumps the generation, and the already-decided follow-up must be refused.
    func test_aStopInTheReofferWindowRefusesTheAlreadyDecidedFollowUp() async throws {
        let transport = HeldTransport()
        let chain = makeTrigger(transport)
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)

        let reofferWindowEntered = DispatchSemaphore(value: 0)
        let closeReofferWindow = DispatchSemaphore(value: 0)
        var hookTimedOut = false
        let hookLock = NSLock()
        chain.trigger.preReofferHookForTesting = {
            reofferWindowEntered.signal()
            if closeReofferWindow.wait(timeout: .now() + 30) == .timedOut {
                hookLock.lock(); hookTimedOut = true; hookLock.unlock()
            }
        }
        defer {
            // Signals a still-held gate so a failing assertion cannot hang the worker; joining is
            // by bounded waits in the test body.
            closeReofferWindow.signal()
            chain.trigger.preReofferHookForTesting = nil
        }

        let ownerHeld = DispatchSemaphore(value: 0)
        var ownerHeldSignalled = false
        let ownerThread = Thread {
            let done = DispatchSemaphore(value: 0)
            Task {
                _ = await chain.scheduler.drainOnce()
                done.signal()
            }
            ownerHeldSignalled = done.wait(timeout: .now() + 30) == .success
            ownerHeld.signal()
        }
        ownerThread.start()
        XCTAssertEqual(transport.waitForFirstAttempt(), .success, "the owner holds the scheduler")

        chain.trigger.triggerDrainIfPermitted()
        try await Task.sleep(nanoseconds: 150_000_000)
        transport.stopHolding()
        transport.releaseHeldPass()
        // The callback runs with a LIVE era and pauses in the re-offer window.
        XCTAssertEqual(reofferWindowEntered.wait(timeout: .now() + 30), .success)
        chain.trigger.cancelForTesting()  // bump the generation inside the window
        closeReofferWindow.signal()
        XCTAssertEqual(ownerHeld.wait(timeout: .now() + 30), .success)
        XCTAssertTrue(ownerHeldSignalled, "the owner thread's drain must have returned, not timed out")
        hookLock.lock(); let timedOut = hookTimedOut; hookLock.unlock()
        XCTAssertFalse(timedOut, "the window must not have been driven by timeout")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(transport.attemptCount, 1,
                       "the follow-up decided before the stop must be refused")
        XCTAssertFalse(chain.trigger.isDrainingForTesting, "and no new era opens")
    }

    /// STOP BEFORE THE TASK BODY STARTS (reviewer b8991889 #1): a cancelled task must not enter
    /// drainOnce at all — the pre-entry check, not the post-await one, prevents the send.
    func test_aStopBeforeTheTaskBodyStartsPreventsTheDrain() async throws {
        let transport = HeldTransport()
        let chain = makeTrigger(transport)
        _ = try AudioFixture.makeReadyEntry(in: chain.queue)

        let bodyEntered = DispatchSemaphore(value: 0)
        let releaseBody = DispatchSemaphore(value: 0)
        var gateTimedOut = false
        let gateLock = NSLock()
        chain.trigger.preDrainGateForTesting = {
            bodyEntered.signal()
            if releaseBody.wait(timeout: .now() + 30) == .timedOut {
                gateLock.lock(); gateTimedOut = true; gateLock.unlock()
            }
        }
        // Gates only SIGNAL here; the worker itself is JOINED below by awaiting the captured
        // task, so a failure cannot leave either side hanging.
        defer {
            releaseBody.signal()
            chain.trigger.preDrainGateForTesting = nil
        }

        chain.trigger.triggerDrainIfPermitted()
        // The task body is HELD before its cancellation check: the stop cannot race the check.
        XCTAssertEqual(bodyEntered.wait(timeout: .now() + 30), .success,
                       "the barrier proves the body is held before the check")
        // Capture the live handle BEFORE cancellation (which clears the storage), so completion
        // of the released body can be observed rather than assumed from a sleep.
        let capturedTask = chain.trigger.drainTaskForTesting
        chain.trigger.cancelForTesting()
        releaseBody.signal()
        // BOUNDED COMPLETION PROOF (reviewer f39bc70d): the released body must actually finish —
        // zero attempts plus a cleared slot are otherwise observable before it even resumes.
        if let capturedTask {
            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask { _ = await capturedTask.value; return true }
                group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return false }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
            XCTAssertTrue(finished, "the released drain task must complete, not hang")
        } else {
            XCTFail("no live drain task was captured to prove completion")
        }
        gateLock.lock(); let timedOut = gateTimedOut; gateLock.unlock()
        XCTAssertFalse(timedOut, "the gate must not have driven the race by timing out")
        XCTAssertEqual(transport.attemptCount, 0,
                       "a cancelled trigger must never reach the transport")
        XCTAssertFalse(chain.trigger.isDrainingForTesting, "and the slot stays released")
    }

    /// AUTHORIZATION IS RE-READ AT THE FOLLOW-UP: revocation between the arrival and the follow-up
    /// must prevent the second pass.
    func test_theFollowUpRechecksAuthorization() async throws {
        let transport = HeldTransport()
        var permitted = true
        let queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        let uploader = VoiceSharingUploader(
            queue: queue,
            retryPolicy: VoiceSharingRetryPolicy(
                retryBaseDelay: 1, retryMaximumDelay: 60, random: { 0 }),
            isAuthorized: { permitted },
            endpoint: { URL(string: "https://unit.test/upload") },
            transport: { _, _, _ in transport.handle() })
        let scheduler = VoiceSharingUploadScheduler(
            queue: queue, uploader: uploader, isAuthorized: { permitted })
        let trigger = VoiceSharingUploadTrigger(
            scheduler: scheduler, surfaceEnabled: { true }, isAuthorized: { permitted })
        _ = try AudioFixture.makeReadyEntry(in: queue)

        trigger.triggerDrainIfPermitted()
        XCTAssertEqual(transport.waitForFirstAttempt(), .success)
        _ = try AudioFixture.makeReadyEntry(in: queue)
        trigger.triggerDrainIfPermitted()      // records pending work
        permitted = false                      // revoked before the follow-up

        transport.stopHolding()
        transport.releaseHeldPass()
        await trigger.awaitCurrentDrainForTesting()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(transport.attemptCount, 1,
                       "a revoked follow-up must not send")
        XCTAssertFalse(trigger.isDrainingForTesting,
                       "and it must not wedge the trigger's slot shut")
    }
}

/// Entry construction shared by the scheduler/trigger controls: encode a real contribution and
/// publish it, so those paths are driven with the same artifacts production uses.
enum AudioFixture {
    static func makeReadyEntry(in queue: VoiceSharingUploadQueue) throws -> VoiceSharingUploadQueue.Entry {
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
}
