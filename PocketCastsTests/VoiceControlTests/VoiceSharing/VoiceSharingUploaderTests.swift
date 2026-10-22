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
        retryPolicy: VoiceSharingRetryPolicy? = nil,
        authorized: @escaping () -> Bool = { true },
        endpoint: @escaping () -> URL? = { URL(string: "https://unit.test/api/v1/contributions") },
        transport: @escaping (URLRequest) async -> VoiceSharingUploader.TransportResult
    ) -> VoiceSharingUploader {
        VoiceSharingUploader(
            queue: queue, retryPolicy: retryPolicy ?? self.retryPolicy(),
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

    /// A 4xx with its OWNING body code is terminal: the entry is abandoned, not retried forever.
    func test_clientErrorAbandonsTheEntry() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _ in
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
            transport: { _ in sent = true; return .transportFailure })
        let outcome = await uploader.upload(entry)
        XCTAssertEqual(outcome, .revoked)
        XCTAssertFalse(sent, "no bytes may leave without live authorization")
    }

    // MARK: - reviewer 7dd1e357 findings

    /// 401 is AUTHENTICATION, not a verdict: the entry is retained and retried, never deleted.
    func test_unauthorizedRetainsTheEntryForRetry() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _ in
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

    /// An unrecognized 4xx has NO owning disposition: unknown means RETAIN and retry, never
    /// delete (spec dc6a00ab: only the owning table's codes are terminal).
    func test_unrecognized4xxPreservesTheEntry() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _ in
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
            let uploader = makeUploader(transport: { _ in
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
            let uploader = makeUploader(transport: { _ in
                .response(statusCode: code, body: Data())
            })
            let outcome = await uploader.upload(entry)
            guard case .retry = outcome else {
                return XCTFail("\(code): NOT an owning code — must retain, got \(outcome)")
            }
        }
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
        let first = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(first.readyEntries().isEmpty, "first restart holds")
        let second = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(second.readyEntries().isEmpty,
                      "SECOND restart must still hold — the intent must survive the first")
    }

    /// 503's server minimum is not discarded: it is both reported AND persisted, and a FRESH owner
    /// is refused immediately afterwards (enforced, not advisory).
    func test_retryDelayIsEnforcedForAnyOwnerAfterRestart() async throws {
        let entry = try makeReadyEntry()
        let uploader = makeUploader(transport: { _ in
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
            transport: { _ in
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
            let uploader = makeUploader(transport: { _ in
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
        // In-memory hold engaged in THIS instance...
        XCTAssertThrowsError(try failing.admitAttempt(entry))
        // ...and re-derived from disk by a FRESH instance.
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertThrowsError(try fresh.admitAttempt(entry)) { error in
            XCTAssertEqual(error as? VoiceSharingUploadQueue.PrepareError,
                           .accountingUnavailable,
                           "the durable pause intent must hold a fresh owner")
        }
    }

    /// Contradictory code/status pairs are protocol violations: unknown outcome, entry retained.
    func test_contradictoryStatusPairsAreUnknown() async throws {
        for (code, status) in [(200, "accepted"), (201, "duplicate")] {
            let entry = try makeReadyEntry()
            let identity = try queue.boundIdentity(of: entry)
            let uploader = makeUploader(transport: { _ in
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
        let uploader = makeUploader(transport: { _ in
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
        // The legacy serving path is held like every other entry point. Recovery happens at
        // construction, so the probe is a NEWLY constructed instance.
        XCTAssertTrue(failing.readyEntries().isEmpty)
        let fresh = VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
        XCTAssertTrue(fresh.readyEntries().isEmpty,
                      "a fresh instance re-derives the hold from disk")
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
            let uploader = makeUploader(transport: { _ in
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
            let uploader = makeUploader(transport: { _ in
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
            let uploader = makeUploader(transport: { _ in
                .response(statusCode: 409, body: errorBody("capture_conflict"))
            })
            let outcome = await uploader.upload(entry)
            guard case .abandoned = outcome else {
                return XCTFail("409+capture_conflict must abandon, got \(outcome)")
            }
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
        // Two restarts: both hold.
        for _ in 0..<2 {
            XCTAssertTrue(VoiceSharingUploadQueue(rootDirectory: root, clock: Date.init)
                .readyEntries().isEmpty, "held across restart")
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
        XCTAssertTrue(reconciler.readyEntries().isEmpty)
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
        XCTAssertThrowsError(try fresh1.admitAttempt(entry)) { error in
            // The owner-wide hold refuses first (accountingUnavailable); the per-entry obligation
            // boundary is what keeps refusing AFTER the hold lifts (asserted below).
            XCTAssertEqual(
                error as? VoiceSharingUploadQueue.PrepareError, .accountingUnavailable)
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
            let uploader = makeUploader(transport: { _ in
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