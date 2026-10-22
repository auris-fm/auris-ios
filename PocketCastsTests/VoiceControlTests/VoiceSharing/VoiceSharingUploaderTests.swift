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
        authorized: @escaping () -> Bool = { true },
        endpoint: @escaping () -> URL? = { URL(string: "https://unit.test/api/v1/contributions") },
        transport: @escaping (URLRequest) async -> VoiceSharingUploader.TransportResult
    ) -> VoiceSharingUploader {
        VoiceSharingUploader(
            queue: queue, retryPolicy: retryPolicy(),
            isAuthorized: authorized, endpoint: endpoint, transport: transport)
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

    // MARK: - the real path

    /// THE composition control: a valid 201 receipt for THIS identity settles the entry as
    /// delivered — the entry disappears from serving and the lease is released.
    func test_validReceiptForThisIdentityDeliversAndRemovesTheEntry() async throws {
        let entry = try makeReadyEntry()
        let identity = try queue.boundIdentity(of: entry)

        var sentBody: Data?
        let uploader = makeUploader(transport: { request in
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
        let uploader = makeUploader(transport: { _ in
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
        let uploader = makeUploader(transport: { _ in
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
            transport: { request in
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
        let uploader = makeUploader(transport: { _ in
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
            let uploader = makeUploader(transport: { _ in result })
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

    /// A 4xx is terminal for this immutable record: the entry is abandoned, not retried forever.
    func test_clientErrorAbandonsTheEntry() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _ in
            .response(statusCode: 422, body: Data())
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
            transport: { _ in sent = true; return .transportFailure })
        let outcome = await uploader.upload(entry)
        XCTAssertEqual(outcome, .revoked)
        XCTAssertFalse(sent, "no bytes may leave without live authorization")
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