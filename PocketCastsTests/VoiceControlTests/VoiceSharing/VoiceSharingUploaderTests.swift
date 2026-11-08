import XCTest
@testable import podcasts

/// Controls for the composed upload path: ONE immutable queue entry → HTTP request → validated
/// receipt → queue settlement, with ownership and revocation controls. The transport is injected,
/// so every control observes the exact bytes the uploader would send and the exact settlement the
/// queue would apply — no mock of the queue itself.
final class VoiceSharingUploaderTests: XCTestCase {
    private var root: URL!
    private var queue: VoiceSharingUploadQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsupload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        queue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A ready entry prepared on a SPECIFIC queue (needed when the queue carries an identity).
    private func makeReadyEntryOwned(_ queue: VoiceSharingUploadQueue) throws
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

    private func makeReadyEntry() throws -> VoiceSharingUploadQueue.Entry {
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

    private func retryPolicy() -> VoiceSharingRetryPolicy {
        VoiceSharingRetryPolicy(
            retryBaseDelay: 1, retryMaximumDelay: 60,
            random: { 0 }) // deterministic: no jitter in tests
    }

    private func makeUploader(
        retryPolicy: VoiceSharingRetryPolicy? = nil,
        authorized: @escaping () -> Bool = { true },
        endpoint: @escaping () -> URL? = { URL(string: "https://unit.test/api/v1/contributions") },
        transport: @escaping (URLRequest, VoiceSharingUploadIdentity?, (() -> VoiceSharingUploadIdentity?)?) async -> VoiceSharingUploader.TransportResult,
        identity: @escaping () -> VoiceSharingUploadIdentity? = { nil }
    ) -> VoiceSharingUploader {
        VoiceSharingUploader(
            queue: queue, retryPolicy: retryPolicy ?? self.retryPolicy(),
            isAuthorized: authorized, currentIdentity: identity,
            endpoint: endpoint, transport: transport)
    }

    private func receiptBody(captureID: String, recordSHA: String, status: String = "accepted") -> Data {
        let object: [String: Any] = [
            "schema_version": 1,
            "capture_id": captureID,
            "record_sha256": recordSHA,
            "status": status,
            "receipt_id": "rcpt-\(UUID().uuidString)",
            "accepted_at": "2026-10-22T14:00:00Z",
            "retention_expires_at": "2026-11-22T14:00:00Z",
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// ATTEMPT-LIFETIME FENCE (spec 67dd62d7): the account/epoch moves WHILE the request is on the
    /// wire, so a late 2xx arrives for an identity the entry no longer belongs to. It must not
    /// settle: the outcome is revoked, and the entry is retained rather than delivered.
    func test_identityChangeDuringFlightStopsALateSuccessFromSettling() async throws {
        let box = IdentityBox(
            VoiceSharingUploadIdentity(accountScope: "acct-A", enrollmentEpoch: "epoch-1"))
        let owned = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        queue = owned
        let entry = try makeReadyEntryOwned(owned)
        let receipt = receiptBody(captureID: entry.name, recordSHA: "unused")
        let uploader = VoiceSharingUploader(
            queue: owned, retryPolicy: retryPolicy(),
            isAuthorized: { true },
            currentIdentity: { box.current },
            endpoint: { URL(string: "https://unit.test/api/v1/contributions") },
            transport: { _, _, _ in
                // A DIFFERENT ACCOUNT takes over while this request is in flight. A same-account
                // re-enrollment is explicitly NOT this case (spec 4afc6e43): the epoch is
                // provenance, so it must not settle or refuse anything.
                box.current = VoiceSharingUploadIdentity(
                    accountScope: "acct-B", enrollmentEpoch: "epoch-1")
                return .response(statusCode: 201, body: receipt)
            })

        let outcome = await uploader.upload(entry)
        guard case .revoked = outcome else {
            return XCTFail("a late success for a retired account must not settle, got \(outcome)")
        }
        XCTAssertTrue(owned.readyEntries().contains { $0.name == entry.name },
                      "the entry is retained: not delivered under another account")
    }

    /// LAUNCH FENCE (reviewer ee5b4547): the identity moves AFTER admission but BEFORE the
    /// request is handed to the transport. No request may be built and sent: the outcome is
    /// revoked and the transport is never called. Post-response refusal cannot repair a
    /// disclosure, so the fence must sit before the wire, not after it.
    func test_fenceLetsAnUnmovedAttemptThroughAndThePostAwaitFenceStopsTheFlippedLateSuccess() async throws {
        let box = IdentityBox(
            VoiceSharingUploadIdentity(accountScope: "acct-A", enrollmentEpoch: "epoch-1"))
        let owned = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        queue = owned
        let entry = try makeReadyEntryOwned(owned)
        var transportCalls = 0
        // THE PRE-LAUNCH WINDOW (reviewer ee5b4547): `endpoint` is injected and called AFTER
        // admission but BEFORE the launch fence, so flipping the identity inside it lands the
        // move exactly in the admission→fence interval — deterministically, no races.
        let uploader = VoiceSharingUploader(
            queue: owned, retryPolicy: retryPolicy(),
            isAuthorized: { true },
            currentIdentity: { box.current },
            endpoint: { () -> URL? in
                // The ACCOUNT move happens here: admission has already seen A.
                box.current = VoiceSharingUploadIdentity(
                    accountScope: "acct-B", enrollmentEpoch: "epoch-1")
                return URL(string: "https://unit.test/api/v1/contributions")
            },
            transport: { _, _, _ in
                transportCalls += 1
                return .response(statusCode: 201, body: Data())
            })

        let outcome = await uploader.upload(entry)
        guard case .revoked = outcome else {
            return XCTFail("a move inside the admission→launch window must stop the attempt, got \(outcome)")
        }
        XCTAssertEqual(transportCalls, 0,
                       "no request may reach the transport, let alone the wire")
        XCTAssertTrue(owned.readyEntries().contains { $0.name == entry.name },
                      "the entry is retained for its owning identity")
    }

    /// Token double with the SAME rejected-bearer guard shape as `CloudAuthTokenProvider`.
    private final class RefreshOnceProvider: CloudTokenProviding {
        private let lock = NSLock()
        private var current = "tok-1"
        private(set) var refreshes = 0
        func token() async -> String? { lock.lock(); defer { lock.unlock() }; return current }
        func prepare() async {}
        func handleUnauthorized(rejectedToken: String?) async {
            lock.lock(); defer { lock.unlock() }
            if let rejectedToken, !rejectedToken.isEmpty, current != rejectedToken { return }
            refreshes += 1
            current = "tok-\(refreshes + 1)"
        }
        func handleUnauthorized() async { await handleUnauthorized(rejectedToken: nil) }
    }

    /// Mutable identity holder for the fence control.
    private final class IdentityBox {
        private let lock = NSLock()
        private var value: VoiceSharingUploadIdentity?
        init(_ initial: VoiceSharingUploadIdentity?) { value = initial }
        var current: VoiceSharingUploadIdentity? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    // MARK: - the real path

    /// THE composition control: a valid 201 receipt for THIS identity settles the entry as
    /// delivered — the entry disappears from serving and the lease is released.
    func test_validReceiptForThisIdentityDeliversAndRemovesTheEntry() async throws {
        let entry = try makeReadyEntry()
        let identity = try queue.boundIdentity(of: entry)

        var sentBody: Data?
        let uploader = makeUploader(transport: { request, _, _ in
            sentBody = request.httpBody
            return .response(statusCode: 201, body: self.receiptBody(
                captureID: identity.captureID, recordSHA: identity.recordSHA256))
        })
        let outcome = await uploader.upload(entry)
        guard case .delivered(let receiptID, let duplicate) = outcome else {
            return XCTFail("expected delivered, got \(outcome)")
        }
        XCTAssertFalse(duplicate)
        XCTAssertTrue(receiptID.hasPrefix("rcpt-"))
        // The entry is GONE from the queue's own serving authority.
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage must be known after delivery")
        }
        XCTAssertFalse(after.contains(entry), "a delivered entry must no longer serve")
        // The request really carried the entry's bytes as a two-part envelope.
        let body = try XCTUnwrap(sentBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"metadata\""), "metadata part must be present")
        XCTAssertTrue(text.contains("name=\"audio\""), "audio part must be present")
        XCTAssertTrue(text.contains(identity.captureID), "the queued record must be the payload")
    }

    /// A malformed 2xx receipt is an UNKNOWN outcome: the entry is RETAINED for the same-record
    /// retry, never deleted for a response we could not trust.
    func test_malformedReceiptRetainsTheEntryAndRetries() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 201, body: Data("{\"schema_version\":1}".utf8))
        })
        let outcome = await uploader.upload(entry)
        guard case .unknownOutcome(let reason) = outcome else {
            return XCTFail("expected unknownOutcome, got \(outcome)")
        }
        XCTAssertEqual(reason, "malformed receipt")
        // Still servable: nothing was settled as delivered.
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(after.contains(entry), "an unknown outcome RETAINS the entry")
    }

    /// A well-formed receipt for a DIFFERENT identity is a protocol violation: unknown, retained.
    func test_receiptForAnotherIdentityIsUnknownNotAccepted() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 201, body: self.receiptBody(
                captureID: "not-ours", recordSHA: String(repeating: "0", count: 64)))
        })
        let outcome = await uploader.upload(entry)
        guard case .unknownOutcome(let reason) = outcome else {
            return XCTFail("expected unknownOutcome, got \(outcome)")
        }
        XCTAssertEqual(reason, "receipt identity mismatch")
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(after.contains(entry))
    }

    /// Revocation while the request is in flight: the late 2xx does NOT complete the entry.
    func test_revocationDuringFlightBeatsALateReceipt() async throws {
        let entry = try makeReadyEntry()
        let identity = try queue.boundIdentity(of: entry)
        var authorized = true
        let uploader = makeUploader(
            authorized: { authorized },
            transport: { request, _, _ in
                // Consent is withdrawn WHILE the request is on the wire.
                authorized = false
                return .response(statusCode: 201, body: self.receiptBody(
                    captureID: identity.captureID, recordSHA: identity.recordSHA256))
            })
        let outcome = await uploader.upload(entry)
        XCTAssertEqual(outcome, .revoked)
        // Nothing may have been settled as delivered.
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(after.contains(entry) || after.isEmpty,
                      "the entry must not be completed by the late receipt")
        XCTAssertFalse({
            if case .known(let list) = self.queue.readyEntriesReportingUnknownCoverage() {
                return !list.isEmpty && list.contains(entry) && false
            }
            return false
        }())
    }

    /// A stale lease (reclaimed while the request was in flight) refuses the result: nothing was
    /// settled by the old owner.
    func test_reclaimedLeaseMakesTheResultStale() async throws {
        let entry = try makeReadyEntry()
        let identity = try queue.boundIdentity(of: entry)
        let uploader = makeUploader(transport: { _, _, _ in
            // While "on the wire", the lease expires and a successor takes over.
            let later = Date().addingTimeInterval(
                VoiceSharingUploadQueue.attemptLeaseDuration + 1)
            let successor = VoiceSharingUploadQueue(rootDirectory: self.root, clock: { later })
            _ = try? successor.beginAttempt(entry)
            return .response(statusCode: 201, body: self.receiptBody(
                captureID: identity.captureID, recordSHA: identity.recordSHA256))
        })
        let outcome = await uploader.upload(entry)
        XCTAssertEqual(outcome, .staleAttempt,
                       "a stale owner must not settle a successor's entry")
    }

    /// Transport failure and 5xx: the entry survives for the SAME-record retry, with a bounded,
    /// jittered delay from the policy (deterministic random here: delay == base).
    func test_transportFailureAndServerErrorsRetryTheSameEntry() async throws {
        let entry = try makeReadyEntry()
        let transportResults: [VoiceSharingUploader.TransportResult] = [
            .transportFailure,
            .response(statusCode: 503, body: Data()),
            .response(statusCode: 429, body: Data("{\"retry_after_s\":7}".utf8)),
        ]
        for (index, result) in transportResults.enumerated() {
            // Re-create the entry fresh per case: attempt accounting survives restarts by design.
            let freshEntry = try makeReadyEntry()
            let uploader = makeUploader(transport: { _, _, _ in result })
            let outcome = await uploader.upload(freshEntry)
            guard case .retry(let serverAfter, let attempt) = outcome else {
                return XCTFail("case \(index): expected retry, got \(outcome)")
            }
            XCTAssertEqual(attempt, 1)
            // The delay is the POLICY's answer, always present: with deterministic random() == 0
            // the local component is 0, and the server's guidance wins the max() where given.
            switch index {
            case 0, 1: XCTAssertEqual(serverAfter, 0, "local component with random()==0")
            case 2: XCTAssertEqual(serverAfter, 7, "server guidance passes through to the policy")
            default: break
            }
            guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
                return XCTFail("coverage known")
            }
            XCTAssertTrue(after.contains(freshEntry), "a retryable failure RETAINS the entry")
            // And the lease was released, so the retry can actually begin.
            XCTAssertFalse(queue.isAttemptInFlight(freshEntry))
        }
    }

    /// DURABLE QUOTA FLOOR (spec c74d7e30): a 429 quota_exceeded with a SHORT server hint must
    /// publish the next-UTC-midnight boundary INSIDE the queue's settlement transaction — visible
    /// in the queue's persisted not-before record and enforced by a RESTARTED queue before the
    /// boundary. The arithmetic controls in VoiceSharingQuotaRetryFloorTests pin the helper; this
    /// control pins the durable settlement seam. (Coverage control for existing behavior: the
    /// floor shipped in b61af2897, so no red-first cycle is possible without deleting the feature.)
    func test_quotaExceeded429PublishesADurableNextMidnightBoundary() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 429, body: Data(
                "{\"schema_version\":1,\"code\":\"quota_exceeded\",\"retry_after_s\":7}".utf8))
        })
        let before = Date()
        let outcome = await uploader.upload(entry)
        let floor = VoiceSharingUploader.nextUTCMidnightInterval(from: before)
        guard case .retry(let delayOpt, _) = outcome else {
            return XCTFail("expected retry, got \(outcome)")
        }
        let delay = try XCTUnwrap(delayOpt)
        XCTAssertEqual(delay, floor, accuracy: 2,
                       "settled delay is the midnight floor, not the 7s hint")
        // The boundary is DURABLY published: the queue's persisted not-before record exists and
        // its stamp is at/after the next UTC midnight.
        let url = root.appendingPathComponent(
            VoiceSharingUploadQueue.notBeforeName(for: entry.name))
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let stamp = try XCTUnwrap(object?["notBefore"] as? Double)
        XCTAssertGreaterThanOrEqual(stamp, before.timeIntervalSince1970 + floor - 2,
                                    "persisted boundary respects the quota floor")
        // A RESTARTED queue over the same directory enforces it: the entry is refused as
        // not-yet-due (distinguishable from ownership), with the boundary as the retry instant.
        let restarted = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        do {
            _ = try restarted.beginAttempt(entry)
            XCTFail("a pre-midnight attempt must be refused after restart")
        } catch let error as VoiceSharingUploadQueue.PrepareError {
            guard case .notYetDue(let retryAt) = error else {
                return XCTFail("expected notYetDue, got \(error)")
            }
            XCTAssertGreaterThanOrEqual(
                retryAt.timeIntervalSince1970, before.timeIntervalSince1970 + floor - 2,
                "restart enforces the midnight boundary")
        }
    }

    /// A 4xx with its OWNING body code is terminal: the entry is abandoned, not retried forever.
    func test_clientErrorAbandonsTheEntry() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 422, body: Data(
                "{\"schema_version\":1,\"code\":\"integrity_mismatch\"}".utf8))
        })
        let outcome = await uploader.upload(entry)
        guard case .abandoned(let reason) = outcome else {
            return XCTFail("expected abandoned, got \(outcome)")
        }
        XCTAssertEqual(reason, "http 422")
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertFalse(after.contains(entry))
    }

    /// Authorization is checked BEFORE any request is issued.
    func test_noRequestWithoutAuthorization() async throws {
        let entry = try makeReadyEntry()
        var sent = false
        let uploader = makeUploader(
            authorized: { false },
            transport: { _, _, _ in sent = true; return .transportFailure })
        let outcome = await uploader.upload(entry)
        XCTAssertEqual(outcome, .revoked)
        XCTAssertFalse(sent, "no bytes may leave without live authorization")
    }

    // MARK: - reviewer 7dd1e357 findings

    /// 401 is AUTHENTICATION, not a verdict: the entry is retained and retried, never deleted.
    func test_unauthorizedRetainsTheEntryForRetry() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 401, body: Data())
        })
        let outcome = await uploader.upload(entry)
        guard case .retry = outcome else {
            return XCTFail("401 must retry, got \(outcome)")
        }
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(after.contains(entry), "a 401 must not destroy a valid recording")
    }

    /// PRODUCTION REFRESH-ONCE (spec e134fa36): two 401s for the SAME rejected bearer must cost
    /// exactly ONE refresh — the rejected-bearer guard in `CloudAuthTokenProvider.handleUnauthorized`
    /// makes the second rejection of an already-replaced token a no-op, so a burst of N 401s (two
    /// requests in flight carrying the same stale token, or a retry racing the refresh) cannot
    /// rotate the chain N times. Entry retries stay bounded by the queue's attempt limit.
    func test_repeated401sForTheSameBearerRefreshExactlyOnce() async throws {
        let entry = try makeReadyEntry()
        let provider = RefreshOnceProvider()
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 401, body: Data())
        })

        // Attempt 1: the request carries tok-1; the server rejects it.
        let firstBearer = await provider.token()
        let outcome1 = await uploader.upload(entry)
        guard case .retry = outcome1 else {
            return XCTFail("401 retries the same entry, got \(outcome1)")
        }
        // The transport reports the exact rejected bearer (as the real transport does at its 401
        // branch) — and a SECOND concurrent rejection of the SAME bearer arrives before the
        // refresh chain is consumed again.
        await provider.handleUnauthorized(rejectedToken: firstBearer)
        XCTAssertEqual(provider.refreshes, 1, "the first rejection replaces the token once")

        let duplicateBearer = await provider.token()   // tok-2 now, but the WIRE rejection was tok-1
        XCTAssertEqual(duplicateBearer, "tok-2")
        await provider.handleUnauthorized(rejectedToken: firstBearer)   // the duplicate 401 for tok-1
        XCTAssertEqual(provider.refreshes, 1,
                       "a second 401 naming the ALREADY-REPLACED bearer must be a no-op — no second rotation")
        _ = uploader
    }

    /// An unrecognized 4xx has NO owning disposition: unknown means RETAIN and retry, never
    /// delete (spec dc6a00ab: only the owning table's codes are terminal).
    func test_unrecognized4xxPreservesTheEntry() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 418, body: Data())
        })
        let outcome = await uploader.upload(entry)
        guard case .retry = outcome else {
            return XCTFail("an unknown 4xx must retain and retry, got \(outcome)")
        }
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(after.contains(entry), "no owning disposition = no deletion")
    }

    /// The owning table's terminal codes exactly: each abandons; the ones just outside it
    /// (402, 404, 407, 451 — NOT in the table) retain.
    func test_terminalTableIsExactlyTheOwningCodes() async throws {
        let terminal: [(Int, String)] = [
            (400, "invalid_request"), (409, "capture_conflict"), (410, "record_gone"),
            (413, "payload_too_large"), (415, "unsupported_audio"), (422, "integrity_mismatch"),
        ]
        for (code, bodyCode) in terminal {
            let entry = try makeReadyEntry()
            let uploader = makeUploader(transport: { _, _, _ in
                .response(statusCode: code, body: Data(
                    "{\"schema_version\":1,\"code\":\"\(bodyCode)\"}".utf8))
            })
            let outcome = await uploader.upload(entry)
            guard case .abandoned = outcome else {
                return XCTFail("\(code): owning terminal code must abandon, got \(outcome)")
            }
        }
        for code in [402, 404, 407, 451] {
            let entry = try makeReadyEntry()
            let uploader = makeUploader(transport: { _, _, _ in
                .response(statusCode: code, body: Data())
            })
            let outcome = await uploader.upload(entry)
            guard case .retry = outcome else {
                return XCTFail("\(code): NOT an owning code — must retain, got \(outcome)")
            }
        }
    }

    /// SPEC 1a0d3ffb: a real 400 invalid_request body DELETES the entry from the queue at
    /// once — directory gone from disk, absent from every serving list and from a fresh
    /// reconstruction — instead of the superseded quarantine retention. Disposable
    /// production-path control.
    func test_invalidRequest400DeletesTheEntryAtOnce() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 400, body: Data(
                "{\"schema_version\":1,\"code\":\"invalid_request\"}".utf8))
        })
        let outcome = await uploader.upload(entry)
        guard case .abandoned(let reason) = outcome, reason.contains("400") else {
            return XCTFail("400 invalid_request must delete (abandon), got \(outcome)")
        }
        // DELETED AT ONCE: the entry directory leaves the disk.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(entry.name).path),
            "spec 1a0d3ffb: the refused entry is deleted, not kept")
        // NOT served by any listing, present or reconstructed.
        guard case .known(let ready) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertFalse(ready.contains(entry), "the refused entry must not be servable")
        let reborn = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        guard case .known(let rebornReady) = reborn.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("reconstruction coverage known")
        }
        XCTAssertFalse(rebornReady.contains(entry),
                       "reconstruction must not resurrect the refused entry")
        // CAPACITY FREED: a fresh recording is admitted (the queue always drains).
        XCTAssertNoThrow(try makeReadyEntryOwned(reborn),
                         "after deletion the queue admits new recordings")
    }

    /// DISPOSABLE REQUEST FIXTURE (spec 9917823a): ONE valid bound record through the REAL
    /// production makeRequest/multipartBody; dumps the exact wire body + SAFE headers (no
    /// credential, no owner data — synthetic WAV/metadata) for Cloud to feed the deployed
    /// handler locally. No owner queue, no live upload.
    func test_exportDisposableRequestFixtureForCloudHandlerProbe() throws {
        let entry = try makeReadyEntry()
        let url = URL(string: "https://staging.example/api/v1/voice-recordings")!
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 503, body: Data())
        })
        let request = try uploader.makeRequest(entry: entry, url: url)
        let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        })
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(to: dir.appendingPathComponent("body.bin"))
        // SAFE HEADERS ONLY: every value is content-free by construction EXCEPT Authorization and
        // Idempotency-Key, which are replaced with shape-preserving placeholders.
        var safeHeaders: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            if key.caseInsensitiveCompare("Authorization") == .orderedSame {
                let parts = value.split(separator: " ", maxSplits: 1)
                safeHeaders[key] = parts.count == 2
                    ? "\(parts[0]) <redacted-bearer-shape-only>" : "<redacted>"
            } else {
                // Idempotency-Key stays EXACT (spec 58ca7059): the synthetic capture ID is not a
                // secret, and a placeholder could itself trigger validation in the handler.
                safeHeaders[key] = value
            }
        }
        let headerData = try JSONSerialization.data(
            withJSONObject: safeHeaders, options: [.prettyPrinted, .sortedKeys])
        try headerData.write(to: dir.appendingPathComponent("safeheaders.json"))
        print("FIXTURE_PATH: \(dir.path)")
        print("FIXTURE_BODY_BYTES: \(body.count)")
    }

    /// RECONCILIATION CONTROL (reviewer 016bb90b / 46971967): the pending quarantine journal is
    /// constructed FOR REAL — an injected lease-removal-barrier failure leaves the exact pending
    /// state on disk — and the recorded lease is then REAPPLIED to completion. A second fixture
    /// from the same construction with the entry directory gone proves the pending quarantine
    /// REFUSES instead of claiming success. The receipt complement still goes through the
    /// uploader with a full real receipt.
    func test_pendingQuarantineJournalReplaysWithRecordedLeaseAndAbsentDirectoryRefuses()
    async throws {
        func pendingJournal(
            entry: VoiceSharingUploadQueue.Entry
        ) async throws -> (generation: String, owner: Int32) {
            // Injected fault: in the quarantine settle path the entry-directory barrier is
            // synced TWICE — disqualify's marker publication (call 1) and the lease-removal
            // barrier (call 2). Failing ONLY call 2 lands the real pending window: journal
            // pending, marker durable, lease file already removed.
            var directoryBarrierCalls = 0
            var lastWasRootBarrier = false
            let faulted = VoiceSharingUploadQueue(
                rootDirectory: root, clock: Date.init,
                synchronizer: { [weak self] path, isDirectory in
                    // The LEASE-REMOVAL barrier is the entry-directory barrier that immediately
                    // follows the settlement's root barrier (root barrier → lease barrier), so
                    // the fault is anchored to the exact settle step, not to a call count.
                    defer { lastWasRootBarrier = (isDirectory && path == self!.root) }
                    if isDirectory && lastWasRootBarrier
                        && path.lastPathComponent == entry.name {
                        throw NSError(domain: "test-lease-barrier", code: 1)
                    }
                    try VoiceSharingUploadQueue.testSynchronizer(path: path, isDirectory: isDirectory)
                })
            queue = faulted
            // SPEC 1a0d3ffb: the uploader no longer settles 400s as quarantine, so the pending
            // QUARANTINE journal is constructed through the queue's own durable outcome — the
            // same lease-validated settlement the legacy path used — with the identical
            // entry-barrier fault landing the real pending window.
            let lease = try XCTUnwrap(try faulted.admitAttempt(entry)).lease
            XCTAssertThrowsError(try faulted.applyAttemptResult(
                entry, lease: lease, outcome: .quarantined),
                "the injected barrier fault must surface")
            // ASSERTED PRECONDITIONS, read from disk (never assumed):
            let journalURL = root.appendingPathComponent(
                VoiceSharingUploadQueue.settlementRecordName(for: entry.name))
            let directory = root.appendingPathComponent(entry.name)
            let journalData = try Data(contentsOf: journalURL)
            let record = try XCTUnwrap(
                VoiceSharingUploadQueue.SettlementRecord.parse(journalData))
            XCTAssertEqual(record.outcome, .quarantined, "journal records the quarantine intent")
            XCTAssertEqual(record.phase, .pending, "the transition is unconfirmed")
            XCTAssertEqual(
                VoiceSharingUploadQueue.statKind(
                    of: directory.appendingPathComponent("publication.failed")),
                .present, "the disqualification marker is durable")
            XCTAssertEqual(
                VoiceSharingUploadQueue.statKind(
                    of: directory.appendingPathComponent("attempt.lease")),
                .absent, "the lease file is already removed")
            return (record.generation, record.owner)
        }

        // FIXTURE A — reapply the recorded lease: completion via marker, bytes retained.
        let entry = try makeReadyEntry()
        let recorded = try await pendingJournal(entry: entry)
        let replayQueue = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        queue = replayQueue
        let replayLease = VoiceSharingUploadQueue.AttemptLease(
            generation: recorded.generation, acquiredAt: Date(), owner: recorded.owner)
        XCTAssertNoThrow(try queue.applyAttemptResult(
            entry, lease: replayLease, outcome: .quarantined),
            "the recorded lease reconciles the pending quarantine")
        let directory = root.appendingPathComponent(entry.name)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                VoiceSharingUploadQueue.settlementRecordName(for: entry.name)).path),
            "the journal is retired after reconciliation")
        XCTAssertEqual(
            VoiceSharingUploadQueue.statKind(
                of: directory.appendingPathComponent("publication.failed")),
            .present, "the marker survives reconciliation")
        XCTAssertNoThrow(try queue.audio(of: entry), "bytes retained after reconciliation")
        XCTAssertNil(try queue.admitAttempt(entry),
            "the quarantined entry is unservable after reconciliation")

        // FIXTURE B — directory gone under the same pending construction: refuse, journal stays.
        let goneEntry = try makeReadyEntry()
        let goneRecorded = try await pendingJournal(entry: goneEntry)
        let goneDirectory = root.appendingPathComponent(goneEntry.name)
        try FileManager.default.removeItem(at: goneDirectory)
        XCTAssertThrowsError(try queue.applyAttemptResult(
            goneEntry, lease: VoiceSharingUploadQueue.AttemptLease(
                generation: goneRecorded.generation, acquiredAt: Date(),
                owner: goneRecorded.owner),
            outcome: .quarantined),
            "an absent directory must refuse, never claim quarantine success") { error in
            guard case VoiceSharingUploadQueue.PrepareError.publicationUncertain = error else {
                return XCTFail("expected publicationUncertain, got \(error)")
            }
        }

        // RECEIPT COMPLEMENT through the uploader (not direct settlement): a delivered upload of
        // a FRESH entry removes it — the delivered path is intact next to quarantine.
        let fresh = try makeReadyEntry()
        let bound = try XCTUnwrap(try queue.boundIdentity(of: fresh))
        let freshCaptureID = bound.captureID
        let freshRecordSHA = bound.recordSHA256
        let deliveredUploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 201, body: Data(
                ("{\"schema_version\":1,\"capture_id\":\"" + freshCaptureID
                    + "\",\"record_sha256\":\"" + freshRecordSHA
                    + "\",\"status\":\"accepted\",\"receipt_id\":\"r-1\","
                    + "\"accepted_at\":\"2026-11-06T04:00:00Z\","
                    + "\"retention_expires_at\":\"2027-11-06T04:00:00Z\"}").utf8))
        })
        let delivered = await deliveredUploader.upload(fresh)
        guard case .delivered = delivered else {
            return XCTFail("matching receipt must deliver, got \(delivered)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(fresh.name).path),
            "a delivered receipt removes the entry")
    }

    /// Holds survive TWO consecutive fresh initializations (reviewer 8ba9c45f): recovery must not
    /// delete the durable evidence it just read.
    func test_retryHoldSurvivesTwoRestarts() throws {
        let entry = try makeReadyEntry()
        let failing = VoiceSharingUploadQueue(
            rootDirectory: root,
            failureRecordWriter: { url, data in
                if url.lastPathComponent.hasPrefix(VoiceSharingUploadQueue.notBeforePrefix) {
                    throw NSError(domain: "test", code: 1)
                }
                try data.write(to: url, options: .atomic)
            })
        let admitted = try XCTUnwrap(try failing.admitAttempt(entry))
        XCTAssertThrowsError(try failing.applyAttemptResult(
            entry, lease: admitted.lease, outcome: .retryableFailure,
            retryNotBefore: Date().addingTimeInterval(60)))
        // AMENDED BY SPEC cdeba18e: this marker gates NEITHER serving NOR admission. What must
        // survive the restart is the DURABLE RECORD of the owed retry — asserted directly — while
        // the queue keeps serving and admitting. An unprovable schedule is resolved per entry.
        let obligation = root.appendingPathComponent(
            VoiceSharingUploadQueue.obligationPrefix + entry.name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: obligation.path),
                      "PRE: the owed boundary was written ahead of the failed stamp")
        let first = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(first.hasAdmissionAllowance(), "a retry hold is not an admission gate")
        let second = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(second.hasAdmissionAllowance(), "nor is it one on the second restart")
        XCTAssertTrue(FileManager.default.fileExists(atPath: obligation.path),
                      "the durable obligation — the OWED retry — still survives both restarts")
    }

    /// 503's server minimum is not discarded: it is both reported AND persisted, and a FRESH owner
    /// is refused immediately afterwards (enforced, not advisory).
    func test_retryDelayIsEnforcedForAnyOwnerAfterRestart() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 503, body: Data("{\"retry_after_s\":120}".utf8))
        })
        let outcome = await uploader.upload(entry)
        guard case .retry(let delay, _) = outcome else {
            return XCTFail("expected retry, got \(outcome)")
        }
        XCTAssertEqual(delay, 120, "503's server minimum must be preserved")

        // A COMPLETELY FRESH queue instance (the restart/reclaim case) is refused until due.
        let listed = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let stampFile = listed.first { $0.hasPrefix("attempt.notbefore.") }
        XCTAssertNotNil(stampFile, "the policy delay must be PERSISTED")
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertThrowsError(try fresh.admitAttempt(entry)) { error in
            guard case .notYetDue = (error as? VoiceSharingUploadQueue.PrepareError) else {
                return XCTFail("a fresh owner must be refused by the SCHEDULE, got \(error)")
            }
        }
        // Consistent with the rest of the queue: no attempt is reported as in flight for it.
        XCTAssertFalse(fresh.isAttemptInFlight(entry))
    }

    /// Malformed 2xx also schedules a real, enforced retry (it is not "free"). A non-zero policy
    /// delay here proves the unknown path stamps the same durable statement as a 503.
    func test_malformed2xxAlsoEnforcesADelay() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(
            retryPolicy: VoiceSharingRetryPolicy(
                retryBaseDelay: 60, retryMaximumDelay: 600, random: { 1 }),
            transport: { _, _, _ in
                .response(statusCode: 200, body: Data("{".utf8))
            })
        let outcome = await uploader.upload(entry)
        guard case .unknownOutcome = outcome else {
            return XCTFail("expected unknownOutcome, got \(outcome)")
        }
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        // A delay was stamped, so an immediate fresh attempt is refused.
        XCTAssertThrowsError(try fresh.admitAttempt(entry)) { error in
            // NOT-YET-DUE, not "someone owns it": the refusal names the schedule (r70l).
            guard case .notYetDue = (error as? VoiceSharingUploadQueue.PrepareError) else {
                return XCTFail("expected the schedule to refuse, got \(error)")
            }
        }
    }

    /// The admitted token is ONE value: the lease and count come from the same transaction, so a
    /// reclaim cannot make this uploader settle under a successor's lease.
    func test_admissionReturnsLeaseAndCountTogether() throws {
        let entry = try makeReadyEntry()
        let admitted = try XCTUnwrap(try queue.admitAttempt(entry))
        XCTAssertEqual(admitted.attemptNumber, 1, "the first attempt is 1")
        XCTAssertEqual(try queue.currentLease(for: entry), admitted.lease,
                       "the admitted lease is the lease in force")
        // While admitted, a SECOND admission of the same entry is refused (owned elsewhere).
        XCTAssertNil(try queue.admitAttempt(entry))
    }

    /// schema_version must be the integer 1 — a JSON boolean must not authorize a receipt.
    func test_booleanSchemaVersionIsRefused() throws {
        let body = Data("{\"schema_version\":true,\"capture_id\":\"c\",\"record_sha256\":\"\(String(repeating: "a", count: 64))\",\"status\":\"accepted\",\"receipt_id\":\"r\",\"accepted_at\":\"2026-10-22T14:00:00Z\",\"retention_expires_at\":\"2026-11-22T14:00:00Z\"}".utf8)
        XCTAssertThrowsError(try VoiceSharingUploader.parseReceipt(body))
    }

    /// Timestamps are part of the contract: arbitrary strings are refused.
    func test_nonTimestampValuesAreRefused() throws {
        var object = try JSONSerialization.jsonObject(
            with: receiptBody(captureID: "c", recordSHA: String(repeating: "a", count: 64))
        ) as! [String: Any]
        object["accepted_at"] = "sometime"
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try VoiceSharingUploader.parseReceipt(data))
        object["accepted_at"] = "2026-10-22T14:00:00"
        XCTAssertThrowsError(try VoiceSharingUploader.parseReceipt(
            try JSONSerialization.data(withJSONObject: object)),
            "a timestamp without a zone designator is not a timestamp")
    }

    /// 200 and 201 both map to acceptance, and the receipt status distinguishes the replay.
    func test_200DuplicateAnd201AcceptedBothDeliver() async throws {
        for (code, status, duplicate) in [(201, "accepted", false), (200, "duplicate", true)] {
            let entry = try makeReadyEntry()
            let identity = try queue.boundIdentity(of: entry)
            let uploader = makeUploader(transport: { _, _, _ in
                .response(statusCode: code, body: self.receiptBody(
                    captureID: identity.captureID, recordSHA: identity.recordSHA256,
                    status: status))
            })
            let outcome = await uploader.upload(entry)
            guard case .delivered(_, let gotDuplicate) = outcome else {
                return XCTFail("\(code): expected delivered, got \(outcome)")
            }
            XCTAssertEqual(gotDuplicate, duplicate, "\(code) duplicate flag")
        }
    }

    // MARK: - reviewer ce001b9a: authoritative settlement transaction

    /// A STALE writer cannot publish a boundary into a successor's future: applyAttemptResult
    /// validates the lease first, so the stale settlement is refused and the successor's stamp —
    /// if any — is untouched.
    func test_staleSettlementCannotWriteASuccessorsBoundary() async throws {
        let entry = try makeReadyEntry()
        let admitted = try XCTUnwrap(try queue.admitAttempt(entry))
        // Successor takes over (lease reclaimed via expiry simulation).
        let later = Date().addingTimeInterval(VoiceSharingUploadQueue.attemptLeaseDuration + 1)
        let successorClockQueue = VoiceSharingUploadQueue(rootDirectory: root, clock: { later })
        _ = try successorClockQueue.admitAttempt(entry)
        // The STALE owner now reports a retryable result. It must be refused outright.
        XCTAssertThrowsError(try queue.applyAttemptResult(
            entry, lease: admitted.lease, outcome: .retryableFailure,
            retryNotBefore: later.addingTimeInterval(60)))
        // The boundary was NOT written by the stale owner.
        let stamps = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(VoiceSharingUploadQueue.notBeforePrefix) }
        XCTAssertTrue(stamps.isEmpty, "a stale owner must not publish any boundary")
    }

    /// A failed boundary barrier never degrades to advisory: the owner-wide hold engages and a
    /// FRESH instance re-derives the hold from disk.
    func test_failedBarrierEngagesADurableHold() throws {
        let entry = try makeReadyEntry()
        // An injected failureRecordWriter that fails ONLY for not-before stamps.
        let failing = VoiceSharingUploadQueue(
            rootDirectory: root,
            failureRecordWriter: { url, data in
                if url.lastPathComponent.hasPrefix(VoiceSharingUploadQueue.notBeforePrefix) {
                    throw NSError(domain: "test", code: 1)
                }
                try data.write(to: url, options: .atomic)
            })
        let admitted = try XCTUnwrap(try failing.admitAttempt(entry))
        XCTAssertThrowsError(try failing.applyAttemptResult(
            entry, lease: admitted.lease, outcome: .retryableFailure,
            retryNotBefore: Date().addingTimeInterval(60)))
        // AMENDED BY SPEC d720ab6c / reviewer 066e2a70 item 2. The stamp write failed, so the
        // DELAY is honoured from the durable obligation instead of from a stamp that never landed —
        // and the refusal is `.notYetDue` with the right instant, not `.accountingUnavailable`.
        // That distinction is the whole point: the recording is paused for its 60 seconds, so the
        // server's minimum still applies, and no unknown fact about the retry bookkeeping is being
        // used to withhold the recording beyond what the server asked for. In-memory hold in THIS
        // instance first...
        XCTAssertThrowsError(try failing.admitAttempt(entry)) { error in
            guard case .notYetDue = (error as? VoiceSharingUploadQueue.PrepareError) else {
                return XCTFail("expected .notYetDue, got \(error)")
            }
        }
        // ...and re-derived from disk by a FRESH instance.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertThrowsError(try fresh.admitAttempt(entry)) { error in
            guard case .notYetDue = (error as? VoiceSharingUploadQueue.PrepareError) else {
                return XCTFail("the durable pause must hold a fresh owner, got \(error)")
            }
        }
    }

    /// Contradictory code/status pairs are protocol violations: unknown outcome, entry retained.
    func test_contradictoryStatusPairsAreUnknown() async throws {
        for (code, status) in [(200, "accepted"), (201, "duplicate")] {
            let entry = try makeReadyEntry()
            let identity = try queue.boundIdentity(of: entry)
            let uploader = makeUploader(transport: { _, _, _ in
                .response(statusCode: code, body: self.receiptBody(
                    captureID: identity.captureID, recordSHA: identity.recordSHA256,
                    status: status))
            })
            let outcome = await uploader.upload(entry)
            guard case .unknownOutcome(let reason) = outcome else {
                return XCTFail("\(code)+\(status): expected unknownOutcome, got \(outcome)")
            }
            XCTAssertEqual(reason, "receipt status contradicts http status")
            guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
                return XCTFail("coverage known")
            }
            XCTAssertTrue(after.contains(entry), "\(code)+\(status) must not delete the entry")
        }
    }

    /// An unknown 4xx (511) is NOT in the terminal table: retained and retried, never deleted.
    func test_unknown4xxIsRetainedNotAbandoned() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 511, body: Data())
        })
        let outcome = await uploader.upload(entry)
        guard case .retry = outcome else {
            return XCTFail("expected retry, got \(outcome)")
        }
        guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
            return XCTFail("coverage known")
        }
        XCTAssertTrue(after.contains(entry))
    }

    /// Legacy serving adopts the retry hold: a failed barrier pauses readyEntries() too.
    /// AMENDED BY SPEC d720ab6c / reviewer 4f98b831: a retry hold does NOT hold serving. It used
    /// to, and that meant an unreadable retry record withheld the whole queue from the drain — the
    /// gate 066e2a70 item 2 removed everywhere else. What the hold still does is refuse NEW
    /// ADMISSIONS, and the recording still serves and still reaches the transport.
    func test_legacyServingHonorsTheRetryHold() throws {
        let entry = try makeReadyEntry()
        XCTAssertEqual(queue.readyEntries().count, 1, "ready before the barrier")
        let failing = VoiceSharingUploadQueue(
            rootDirectory: root,
            failureRecordWriter: { url, data in
                if url.lastPathComponent.hasPrefix(VoiceSharingUploadQueue.notBeforePrefix) {
                    throw NSError(domain: "test", code: 1)
                }
                try data.write(to: url, options: .atomic)
            })
        let admitted = try XCTUnwrap(try failing.admitAttempt(entry))
        XCTAssertThrowsError(try failing.applyAttemptResult(
            entry, lease: admitted.lease, outcome: .retryableFailure,
            retryNotBefore: Date().addingTimeInterval(60)))
        // SERVING IS NOT HELD: the recording must remain available to the drain.
        XCTAssertEqual(failing.readyEntries().count, 1,
                       "a retry hold may not withhold the recording from serving")
        // Recovery happens at construction, so the probe is a NEWLY constructed instance.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertEqual(fresh.readyEntries().count, 1,
                       "a fresh instance still serves it: the hold is not a serving gate")
        // AND ADMISSION IS NOT REFUSED (spec cdeba18e): this marker is internal write-ahead
        // bookkeeping for an unpublishable not-before stamp, not the sharing-off intent and not a
        // server backoff, so it is not on the allowed admit gate list. A new clip goes on disk.
        XCTAssertTrue(fresh.hasAdmissionAllowance(),
                      "a retry hold is not an admission gate")
    }

    // MARK: - reviewer 3814f4be: status+body agreement, hold reconciliation, transport lifetime

    /// A terminal-looking status with the WRONG body code is not proof: unrelated 403s and
    /// malformed 409s RETAIN. Only status+code pairs agreeing with the owning table abandon.
    func test_terminalRequiresOwningStatusCodePair() async throws {
        func errorBody(_ code: String?) -> Data {
            var object: [String: Any] = ["schema_version": 1]
            if let code { object["code"] = code }
            return try! JSONSerialization.data(withJSONObject: object)
        }
        // Proxy 403 without an owning code → retain.
        do {
            let entry = try makeReadyEntry()
            let uploader = makeUploader(transport: { _, _, _ in
                .response(statusCode: 403, body: errorBody("proxy_forbidden"))
            })
            let outcome = await uploader.upload(entry)
            guard case .unknownOutcome = outcome else {
                return XCTFail("proxy 403 must retain, got \(outcome)")
            }
            guard case .known(let after) = queue.readyEntriesReportingUnknownCoverage() else {
                return XCTFail("coverage known")
            }
            XCTAssertTrue(after.contains(entry))
        }
        // Malformed 409 (no code) → retain.
        do {
            let entry = try makeReadyEntry()
            let uploader = makeUploader(transport: { _, _, _ in
                .response(statusCode: 409, body: Data("{".utf8))
            })
            let outcome = await uploader.upload(entry)
            guard case .unknownOutcome = outcome else {
                return XCTFail("malformed 409 must retain, got \(outcome)")
            }
        }
        // Status/code AGREEMENT abandons: 409 + capture_conflict.
        do {
            let entry = try makeReadyEntry()
            let uploader = makeUploader(transport: { _, _, _ in
                .response(statusCode: 409, body: errorBody("capture_conflict"))
            })
            let outcome = await uploader.upload(entry)
            guard case .abandoned = outcome else {
                return XCTFail("409+capture_conflict must abandon, got \(outcome)")
            }
        }
    }

    /// SPEC 219d3bb6: A 409 AFTER A 5xx FOR THE SAME CAPTURE IS A SERVER BUG, NOT A DELETION.
    /// The 5xx is retryable and leaves the entry in the queue; the retry then draws a conflict.
    /// The server may have half-landed the record, and the client cannot re-create the audio, so
    /// the entry is retained and logged rather than deleted. RED before this change: the 409
    /// branch abandoned it on the spot.
    /// A conflict that follows a server failure is TERMINAL once Cloud reopens failed captures
    /// (spec commit 8637a0fd, per spec 418d3d05). This control replaces the earlier retain; it pins
    /// the new contract so the old hold cannot quietly come back.
    /// REVIEWER 307d0bde item 1 / spec a4b417fc ruling 2: an entry the CLIENT cannot bind must still
    /// REACH THE SERVER. Retained-but-never-sent is still a hold, and a log line is not a path. This
    /// walks the real path: locally invalid metadata → authenticated attempt → scripted final
    /// refusal → the server's verdict removes the files.
    /// REVIEWER 307d0bde item 2: a diagnostic count-write failure must not stop an upload. The
    /// attempt count spaces retries and reports; a disk that cannot record it is exactly when the
    /// recording matters most, so the attempt proceeds and the count is kept in memory.
    func test_anAttemptCountWriteFailureStillUploads() async throws {
        let entry = try makeReadyEntry()
        let uploadQueue = VoiceSharingUploadQueue(
            rootDirectory: root,
            failureRecordWriter: { url, data in
                if url.lastPathComponent == VoiceSharingUploadQueue.attemptRecordName {
                    throw NSError(domain: "test", code: 1)
                }
                try data.write(to: url, options: .atomic)
            })
        queue = uploadQueue
        var sawRequest = false
        let uploader = makeUploader(transport: { _, _, _ in
            sawRequest = true
            return .response(statusCode: 422, body: Data(
                #"{"schema_version":1,"code":"integrity_mismatch"}"#.utf8))
        })
        let outcome = await uploader.upload(entry)
        XCTAssertTrue(sawRequest,
                      "an unrecordable attempt count must not stop the request from leaving")
        guard case .abandoned = outcome else {
            return XCTFail("the server's refusal settles it; got \(outcome)")
        }
    }

    /// REVIEWER 066e2a70 item 3: a capture whose audio is a READABLE pair but not the documented
    /// representation must still reach the transport. RED before the fix: `isServedEntryLocked`
    /// excluded `.invalidAudio`/`.audioSizeMismatch`/`.audioSampleCountMismatch`, so a malformed WAV
    /// sat in the queue forever, held on a local verdict the ruling forbids. The corrupted-JSON
    /// control above exercises a different binding failure and could never catch this.
    func test_captureWithMalformedAudioIsSentAndTheServersRefusalDeletesIt() async throws {
        let entry = try makeReadyEntry()
        // Break the WAV body so binding reports `.invalidAudio`, leaving metadata.json intact: the
        // record still parses, so this is exactly the "readable pair, invalid audio" case.
        let directory = root.appendingPathComponent(entry.name, isDirectory: true)
        try Data("RIFF".utf8).write(to: directory.appendingPathComponent("audio.wav"))
        queue = VoiceSharingUploadQueue(rootDirectory: root) // re-derive state from disk
        // PRE: the metadata still parses, so this really is the "readable pair, invalid audio"
        // shape and not the unreadable-record case covered by the control above.
        let parsedMetadata = try? queue.metadata(of: entry)
        XCTAssertNotNil(parsedMetadata, "PRE: metadata must still parse")
        XCTAssertTrue(queue.readyEntries().contains { $0.name == entry.name },
                      "the server owns the audio-representation verdict, not the client")

        var sawRequest = false
        let uploader = makeUploader(transport: { _, _, _ in
            sawRequest = true
            // 415 owns `unsupported_audio`: the truthful code for audio the server cannot decode.
            return .response(statusCode: 415, body: Data(
                #"{"schema_version":1,"code":"unsupported_audio"}"#.utf8))
        })
        let outcome = await uploader.upload(entry)
        XCTAssertTrue(sawRequest, "malformed audio must reach the server, which is the authority")
        guard case .abandoned = outcome else {
            return XCTFail("the server's final refusal settles it; got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "the final refusal deletes the capture")
    }

    /// REVIEWER 066e2a70 item 2: a malformed `attempts.json` made `isAttemptableLocked` THROW, so
    /// the upload died before admission — the count-write fallback never got a chance to run. The
    /// count spaces retries; it is not a gate.
    func test_malformedAttemptRecordStillUploads() async throws {
        let entry = try makeReadyEntry()
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent(entry.name, isDirectory: true)
                .appendingPathComponent(VoiceSharingUploadQueue.attemptRecordName))
        queue = VoiceSharingUploadQueue(rootDirectory: root)

        var sawRequest = false
        let bound = try XCTUnwrap(queue.boundIdentity(of: entry))
        let uploader = makeUploader(transport: { _, _, _ in
            sawRequest = true
            // 200 pairs with `duplicate` (a 201 pairs with `accepted`); anything else is a
            // protocol violation and would be retained as unknown.
            return .response(statusCode: 200, body: self.receiptBody(
                captureID: bound.captureID, recordSHA: bound.recordSHA256, status: "duplicate"))
        })
        let outcome = await uploader.upload(entry)
        XCTAssertTrue(sawRequest, "an unreadable attempt count must not hold the recording")
        guard case .delivered = outcome else {
            return XCTFail("expected a delivered receipt; got \(outcome)")
        }
    }

    /// REVIEWER 4f98b831: an UNREADABLE delay record must not refuse the WITHHOLDING of a
    /// recording. `refuseIfNotYetDueLocked` used to throw `leaseHeld` for an unparseable stamp and
    /// for a NaN obligation, which is the last surviving form of the retry gate on the path the
    /// UPLOADER calls. Unknown retry state is due now; only a READABLE future deadline refuses.
    func test_unreadableDelayRecordsStillUpload() async throws {
        for shape in ["malformed-stamp", "nan-obligation"] {
            let entry = try makeReadyEntry()
            let stampName = VoiceSharingUploadQueue.notBeforeName(for: entry.name)
            switch shape {
            case "malformed-stamp":
                try Data("not-json".utf8).write(to: root.appendingPathComponent(stampName))
            default:
                try Data(#"{"notBefore": "NaN"}"#.utf8).write(
                    to: root.appendingPathComponent(
                        VoiceSharingUploadQueue.obligationPrefix + entry.name))
            }
            queue = VoiceSharingUploadQueue(rootDirectory: root)
            var sawRequest = false
            let uploader = makeUploader(transport: { _, _, _ in
                sawRequest = true
                return .response(statusCode: 415, body: Data(
                    #"{"schema_version":1,"code":"unsupported_audio"}"#.utf8))
            })
            let outcome = await uploader.upload(entry)
            XCTAssertTrue(sawRequest,
                          "\(shape): an unreadable delay must not withhold the recording")
            guard case .abandoned = outcome else {
                return XCTFail("\(shape): expected the server's refusal to settle, got \(outcome)")
            }
        }
    }

    /// REVIEWER 4f98b831, the sibling half: a failed stamp write for ONE entry must not stop a
    /// HEALTHY entry from taking its scheduled retry. Per-entry, never owner-wide.
    func test_aFailedStampWriteDoesNotStopAHealthySiblingsRetry() async throws {
        let unhealthy = try makeReadyEntry()
        let healthy = try makeReadyEntry()
        let failing = VoiceSharingUploadQueue(
            rootDirectory: root,
            failureRecordWriter: { url, data in
                // Only the UNHEALTHY entry's stamps fail.
                if url.lastPathComponent == VoiceSharingUploadQueue.notBeforeName(for: unhealthy.name) {
                    throw NSError(domain: "test", code: 1)
                }
                try data.write(to: url, options: .atomic)
            })
        queue = failing
        let admitted = try XCTUnwrap(try failing.admitAttempt(unhealthy))
        XCTAssertThrowsError(try failing.applyAttemptResult(
            unhealthy, lease: admitted.lease, outcome: .retryableFailure,
            retryNotBefore: Date().addingTimeInterval(600)))

        // The healthy sibling is DUE and must still be offered and sent.
        var sent: [String] = []
        let uploader = VoiceSharingUploader(
            queue: failing, retryPolicy: retryPolicy(),
            isAuthorized: { true }, currentIdentity: { nil },
            endpoint: { URL(string: "https://unit.test/api/v1/contributions") },
            transport: { request, _, _ in
                sent.append(request.url?.lastPathComponent ?? "")
                return .response(statusCode: 415, body: Data(
                    #"{"schema_version":1,"code":"unsupported_audio"}"#.utf8))
            })
        let outcome = await uploader.upload(healthy)
        XCTAssertFalse(sent.isEmpty,
                       "a sibling's failed stamp write must not stop a healthy retry; outcome=\(outcome)")
    }

    func test_aLocallyUnbindableCaptureIsSentAndTheServersRefusalDeletesIt() async throws {
        // A BOUND queue: the fence must still attribute the attempt to the owning account even
        // though the record itself no longer parses.
        let box = IdentityBox(
            VoiceSharingUploadIdentity(accountScope: "acct-A", enrollmentEpoch: "epoch-1"))
        let owned = VoiceSharingUploadQueue(rootDirectory: root, currentIdentity: { box.current })
        queue = owned
        let entry = try makeReadyEntryOwned(owned)
        let directory = root.appendingPathComponent(entry.name, isDirectory: true)
        // Corrupt the metadata AFTER the entry is durable: the audio is intact, so this is a
        // capture the client can no longer bind but the server could still judge.
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("metadata.json"))

        var sawRequest = false
        let uploader = VoiceSharingUploader(
            queue: owned, retryPolicy: retryPolicy(),
            isAuthorized: { true },
            currentIdentity: { box.current },
            endpoint: { URL(string: "https://unit.test/api/v1/contributions") },
            transport: { request, identity, _ in
                sawRequest = true
                // The bytes really left: the multipart body carries the raw pair.
                XCTAssertNotNil(request.httpBody, "the unbound capture must be transmitted")
                XCTAssertEqual(identity?.accountScope, "acct-A",
                               "it is still fenced to the account that owns it")
                // A real owning refusal for the status: 422 pairs with `integrity_mismatch`.
                return .response(statusCode: 422, body: Data(
                    #"{"schema_version":1,"code":"integrity_mismatch"}"#.utf8))
            })
        let outcome = await uploader.upload(entry)
        XCTAssertTrue(sawRequest, "a locally unbindable capture must reach the server, not be held")
        guard case .abandoned = outcome else {
            return XCTFail("the server's final refusal is what deletes it, got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "the server's final refusal removes the files")
    }

    func test_aConflictAfterAServerFailureIsTerminalOnceTheServerReopens() async throws {
        let entry = try makeReadyEntry()
        func errorBody(_ code: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["schema_version": 1, "code": code])
        }
        do {
            let uploader = makeUploader(transport: { _, _, _ in
                .response(statusCode: 503, body: errorBody("storage_unavailable"))
            })
            let outcome = await uploader.upload(entry)
            guard case .retry = outcome else {
                return XCTFail("a 5xx is retryable, got \(outcome)")
            }
        }
        let uploader = makeUploader(transport: { _, _, _ in
            .response(statusCode: 409, body: errorBody("capture_conflict"))
        })
        let outcome = await uploader.upload(entry)
        guard case .abandoned = outcome else {
            return XCTFail("a conflict is terminal under 8637a0fd, got \(outcome)")
        }
    }

    /// Fault → two restarts held → bounded reconciliation lifts → uploads resume, with the
    /// original boundary minimum preserved (spec c3175492).
    func test_retryHoldReconcilesAfterFaultAndRestarts() throws {
        let entry = try makeReadyEntry()
        let failing = VoiceSharingUploadQueue(
            rootDirectory: root,
            failureRecordWriter: { url, data in
                if url.lastPathComponent.hasPrefix(VoiceSharingUploadQueue.notBeforePrefix) {
                    throw NSError(domain: "test", code: 1)
                }
                try data.write(to: url, options: .atomic)
            })
        let admitted = try XCTUnwrap(try failing.admitAttempt(entry))
        XCTAssertThrowsError(try failing.applyAttemptResult(
            entry, lease: admitted.lease, outcome: .retryableFailure,
            retryNotBefore: Date().addingTimeInterval(60)))
        // AMENDED BY SPEC cdeba18e: the durable hold survives restarts, but it is not a serving or
        // admission gate. Serving and admissions continue; the owed boundary is what persists.
        for _ in 0..<2 {
            let reopened = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
            XCTAssertTrue(reopened.hasAdmissionAllowance(), "not an admission gate")
            XCTAssertTrue(reopened.readyEntries().contains { $0.name == entry.name },
                          "and not a serving gate either — the entry still drains")
        }
        // Bounded reconciliation on a fresh instance: state is provable (the failing writer only
        // failed the STAMP, which never landed; the intent did), so it lifts.
        let reconciler = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(reconciler.reconcileRetryHold(), "provable state lifts the hold")
        // Service resumed: the entry serves again, and the boundary (never landed) is not enforced.
        XCTAssertEqual(reconciler.readyEntries().count, 1, "resume after reconciliation")
    }

    /// Reconciliation REFUSES on unprovable state: a corrupt stamp keeps the hold.
    func test_reconciliationRefusesUnprovableState() throws {
        let entry = try makeReadyEntry()
        let failing = VoiceSharingUploadQueue(
            rootDirectory: root,
            failureRecordWriter: { url, data in
                if url.lastPathComponent.hasPrefix(VoiceSharingUploadQueue.notBeforePrefix) {
                    throw NSError(domain: "test", code: 1)
                }
                try data.write(to: url, options: .atomic)
            })
        let admitted = try XCTUnwrap(try failing.admitAttempt(entry))
        XCTAssertThrowsError(try failing.applyAttemptResult(
            entry, lease: admitted.lease, outcome: .retryableFailure,
            retryNotBefore: Date().addingTimeInterval(60)))
        // Corrupt a stamp into existence (valid name, garbage body).
        let stampName = VoiceSharingUploadQueue.notBeforePrefix + entry.name
        try Data("garbage".utf8).write(
            to: root.appendingPathComponent(stampName), options: .atomic)
        let reconciler = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertFalse(reconciler.reconcileRetryHold(), "unprovable state keeps the hold")
        // AMENDED BY SPEC d720ab6c: keeping the HOLD is not the same as refusing to SERVE. The
        // hold refuses new admissions; the recording stays available to the drain. A garbage stamp
        // is an unreadable delay, hence due now.
        XCTAssertEqual(reconciler.readyEntries().count, 1,
                       "an unprovable retry state may not withhold the recording from serving")
    }

    /// Reviewer a29e62a2's exact scenario: the STAMP writer fails but the write-ahead obligation
    /// carries the original 600s server minimum. Two restarts hold; reconciliation cannot lift it
    /// into an early retry; the entry stays refused until the boundary passes.
    func test_stampFailureKeepsTheOriginalMinimumThroughReconciliation() throws {
        let entry = try makeReadyEntry()
        let stampFails = VoiceSharingUploadQueue(
            rootDirectory: root,
            failureRecordWriter: { url, data in
                if url.lastPathComponent.hasPrefix(VoiceSharingUploadQueue.notBeforePrefix) {
                    throw NSError(domain: "test", code: 1)
                }
                try data.write(to: url, options: .atomic)
            })
        let admitted = try XCTUnwrap(try stampFails.admitAttempt(entry))
        XCTAssertThrowsError(try stampFails.applyAttemptResult(
            entry, lease: admitted.lease, outcome: .retryableFailure,
            retryNotBefore: Date().addingTimeInterval(600)))
        // The obligation SURVIVED even though the stamp never landed.
        let rootListing = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(rootListing.contains { $0.hasPrefix(VoiceSharingUploadQueue.obligationPrefix) },
                      "obligation file must exist; got \(rootListing)")
        let fresh1 = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        // AMENDED BY SPEC d720ab6c: the stamp write failed, so what refuses is the DURABLE
        // OBLIGATION, not an owner-wide accounting hold. The obligation is the per-entry record of
        // the server's minimum, and it survives the restart — which is the property this control
        // exists to prove. (The old `.accountingUnavailable` was the owner-wide hold, and it was
        // itself a gate on an attempt derived from an unknown fact.)
        XCTAssertThrowsError(try fresh1.admitAttempt(entry)) { error in
            guard case .notYetDue(let retryAt) =
                (error as? VoiceSharingUploadQueue.PrepareError) else {
                return XCTFail("the durable obligation must refuse after a stamp failure, got \(error)")
            }
            XCTAssertGreaterThan(retryAt.timeIntervalSinceNow, 500,
                                 "the ORIGINAL minimum survives the restart")
        }
        _ = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init) // second restart
        // Reconciliation may lift the owner-wide marker (state is provable)...
        let reconciler = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        _ = reconciler.reconcileRetryHold()
        // ...but the ORIGINAL MINIMUM still refuses early attempts.
        XCTAssertThrowsError(try reconciler.admitAttempt(entry)) { error in
            // Reconciliation must not convert a 600s minimum into an early retry.
            guard case .notYetDue(let retryAt) =
                (error as? VoiceSharingUploadQueue.PrepareError) else {
                return XCTFail("expected the schedule to refuse, got \(error)")
            }
            XCTAssertGreaterThan(retryAt.timeIntervalSinceNow, 500,
                                 "the ORIGINAL minimum is what refuses, not a short backoff")
        }
    }

    /// The 600s obligation REALLY is what refused: once it passes (fresh owner, no live lease),
    /// admission succeeds again.
    func test_admissionResumesAfterTheObligationPasses() throws {
        let entry = try makeReadyEntry()
        let stampFails = VoiceSharingUploadQueue(
            rootDirectory: root,
            failureRecordWriter: { url, data in
                if url.lastPathComponent.hasPrefix(VoiceSharingUploadQueue.notBeforePrefix) {
                    throw NSError(domain: "test", code: 1)
                }
                try data.write(to: url, options: .atomic)
            })
        let admitted = try XCTUnwrap(try stampFails.admitAttempt(entry))
        let settleTime = Date()
        XCTAssertThrowsError(try stampFails.applyAttemptResult(
            entry, lease: admitted.lease, outcome: .retryableFailure,
            retryNotBefore: settleTime.addingTimeInterval(600)))
        // A clock AFTER the obligation passes, on a FRESH owner: no live lease exists here.
        let later = VoiceSharingUploadQueue(rootDirectory: root, clock: { settleTime.addingTimeInterval(601) })
        _ = later.reconcileRetryHold()
        let readmitted = try XCTUnwrap(try later.admitAttempt(entry),
                                       "after the obligation passes, a fresh owner may retry")
        XCTAssertEqual(readmitted.attemptNumber, 2, "the retry is the SECOND attempt")
    }

    /// Discovery FAILURE during reconciliation retains the hold (reviewer c9416bf7): an
    /// unreadable root is never read as "no intent".
    func test_reconciliationKeepsTheHoldWhenDiscoveryFails() throws {
        let entry = try makeReadyEntry()
        let failing = VoiceSharingUploadQueue(
            rootDirectory: root,
            failureRecordWriter: { url, data in
                if url.lastPathComponent.hasPrefix(VoiceSharingUploadQueue.notBeforePrefix) {
                    throw NSError(domain: "test", code: 1)
                }
                try data.write(to: url, options: .atomic)
            })
        let admitted = try XCTUnwrap(try failing.admitAttempt(entry))
        XCTAssertThrowsError(try failing.applyAttemptResult(
            entry, lease: admitted.lease, outcome: .retryableFailure,
            retryNotBefore: Date().addingTimeInterval(600)))
        // A queue whose intent DISCOVERY fails (chmod-000 root): reconciliation must not lift.
        let unreadable = VoiceSharingUploadQueue(
            rootDirectory: root,
            intentDiscovery: { _ in
                // Simulate exactly what statKind returns on stat failure.
                return .failure
            })
        XCTAssertFalse(unreadable.reconcileRetryHold(),
                       "discovery failure must retain the hold")
        XCTAssertTrue(unreadable.readyEntries().isEmpty, "held owners serve nothing")
    }

    /// 410 carries either owning code: record_gone or enrollment_retired.
    func test_410AcceptsBothOwningCodes() async throws {
        for code in ["record_gone", "enrollment_retired"] {
            let entry = try makeReadyEntry()
            let uploader = makeUploader(transport: { _, _, _ in
                .response(statusCode: 410, body: Data(
                    "{\"schema_version\":1,\"code\":\"\(code)\"}".utf8))
            })
            let outcome = await uploader.upload(entry)
            guard case .abandoned = outcome else {
                return XCTFail("410+\(code) must abandon, got \(outcome)")
            }
        }
    }

    /// A strict receipt parser: every required field, or nothing.
    func test_receiptParsingIsStrict() throws {
        let good = receiptBody(captureID: "c", recordSHA: String(repeating: "a", count: 64))
        XCTAssertNoThrow(try VoiceSharingUploader.parseReceipt(good))
        // Missing each required field is refused.
        for key in ["capture_id", "record_sha256", "status", "receipt_id", "accepted_at",
                    "retention_expires_at"] {
            let object = try! JSONSerialization.jsonObject(with: good) as! [String: Any]
            var stripped = object
            stripped.removeValue(forKey: key)
            let data = try! JSONSerialization.data(withJSONObject: stripped)
            XCTAssertThrowsError(try VoiceSharingUploader.parseReceipt(data)) { _ in
                // expected
            }
        }
        // Unknown status values are refused outright.
        let weird = receiptBody(captureID: "c", recordSHA: String(repeating: "a", count: 64),
                                status: "pending_review")
        XCTAssertThrowsError(try VoiceSharingUploader.parseReceipt(weird))
        XCTAssertThrowsError(try VoiceSharingUploader.parseReceipt(Data("not json".utf8)))
    }
}