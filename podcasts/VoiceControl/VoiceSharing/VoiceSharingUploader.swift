import Foundation
import PocketCastsUtils

/// Uploads ONE immutable queue entry to the contribution endpoint, and settles the entry from the
/// answer. This is the composition point where the queue, the strict coverage/attempt authorities
/// and the wire contract finally meet.
///
/// The contract this type exists to enforce (voice-recording-uploads spec, "Contribution upload
/// responses"):
///
/// - **A receipt is only acceptance if it MATCHES.** A 2xx whose body is malformed, missing fields,
///   or naming a different capture identity or record digest is an UNKNOWN outcome: the audio is
///   retained and the SAME immutable record is retried. It is never treated as delivered, and the
///   local entry is never deleted for it.
/// - **Ownership fences the settlement.** The attempt lease taken before the request is the only
///   thing that may settle the entry. If the lease was reclaimed while the request was in flight
///   (expiry, revocation, another uploader), the answer is stale: the entry is left alone —
///   `applyAttemptResult` refuses it — and the uploader reports a stale result rather than
///   inventing an outcome for an entry it no longer owns.
/// - **Revocation wins over a late 2xx.** If authorization is withdrawn while a request is in
///   flight, the entry is not quietly completed from the arriving response; it is discarded
///   through the queue's revocation path so the durable hold/coverage rules apply.
/// - **Bounded retry, never a fresh identity.** Retryable failures (5xx, 429, transport) schedule
///   the retry through `VoiceSharingRetryPolicy` for the SAME entry; the capture identity is minted
///   once, at collection time, and is never regenerated here.
///
/// Disabled by construction: this type performs work only when its caller invokes `upload(_:)`,
/// and the production composition does not invoke it until the owner approves activation.
final class VoiceSharingUploader {
    /// The single wire-level answer, before any interpretation.
    enum TransportResult: Equatable {
        case response(statusCode: Int, body: Data)
        case transportFailure
    }

    /// What the uploader did with one entry.
    enum Outcome: Equatable {
        case delivered(receiptID: String, duplicate: Bool)
        /// Retry the SAME entry (bounded by the queue's attempt limits).
        case retry(serverRetryAfterSeconds: Double?, attempt: Int)
        /// The receipt could not be trusted (malformed / identity mismatch). Audio retained.
        case unknownOutcome(reason: String)
        /// Authorization was withdrawn while the request was in flight; the entry is being revoked.
        case revoked
        /// The attempt was no longer ours (lease reclaimed) — nothing was settled.
        case staleAttempt
        /// Terminal refusal (permanent failure); the entry was abandoned.
        case abandoned(reason: String)
        /// The local entry could not be read or is not ready; nothing was sent.
        case unavailable(reason: String)
    }

    struct Receipt {
        let captureID: String
        let recordSHA256: String
        let status: ReceiptStatus
        let receiptID: String
    }

    enum ReceiptError: Error, Equatable {
        case notJSON
        case missingField(String)
        case unexpectedStatus(String)
        case identityMismatch
    }

    private let queue: VoiceSharingUploadQueue
    private let retryPolicy: VoiceSharingRetryPolicy
    private let isAuthorized: () -> Bool
    private let transport: (URLRequest) async -> TransportResult
    private let endpoint: () -> URL?
    private let clock: () -> Date

    init(
        queue: VoiceSharingUploadQueue,
        retryPolicy: VoiceSharingRetryPolicy,
        isAuthorized: @escaping () -> Bool,
        endpoint: @escaping () -> URL?,
        clock: @escaping () -> Date = Date.init,
        transport: @escaping (URLRequest) async -> TransportResult
    ) {
        self.queue = queue
        self.retryPolicy = retryPolicy
        self.isAuthorized = isAuthorized
        self.endpoint = endpoint
        self.clock = clock
        self.transport = transport
    }

    /// Uploads one ready entry. Returns what happened; never throws into the caller's pipeline.
    func upload(_ entry: VoiceSharingUploadQueue.Entry) async -> Outcome {
        // AUTHORIZATION FIRST: no request is ever issued without a live permission.
        guard isAuthorized() else { return .revoked }
        // Ownership: taking the lease is what makes this attempt OURS. Note beginAttempt also
        // enforces the strict owner-wide coverage hold, so an unreconciled owner uploads nothing.
        // Ownership: ONE atomic admission yields the lease AND the attempt number together
        // (reviewer 7dd1e357). Reading them separately let a reclaim in between make this uploader
        // settle under a SUCCESSOR's lease. Only this token may settle from here on.
        let admitted: VoiceSharingUploadQueue.AdmittedAttempt
        do {
            guard let granted = try queue.admitAttempt(entry) else {
                return .unavailable(reason: "attempt refused (held, exhausted or owned)")
            }
            admitted = granted
        } catch {
            // Includes the enforced not-before refusal: a fresh owner is refused until due.
            return .unavailable(reason: "attempt refused: \(type(of: error))")
        }
        let lease = admitted.lease
        let attemptNumber = admitted.attemptNumber

        guard let url = endpoint() else {
            _ = try? queue.applyAttemptResult(entry, lease: lease, outcome: .retryableFailure)
            return .retry(serverRetryAfterSeconds: nil, attempt: attemptNumber)
        }
        let request: URLRequest
        do {
            request = try makeRequest(entry: entry, url: url)
        } catch {
            _ = try? queue.applyAttemptResult(entry, lease: lease, outcome: .retryableFailure)
            return .unavailable(reason: "entry unreadable: \(type(of: error))")
        }

        let result = await transport(request)

        // REVOCATION CHECK IMMEDIATELY AFTER THE AWAIT (reviewer/spec obligation): a withdrawal
        // that landed while the request was in flight must not be overridden by a late 2xx.
        if !isAuthorized() {
            // The lease must still be released; the entry is left for the revocation path.
            _ = try? queue.applyAttemptResult(entry, lease: lease, outcome: .retryableFailure)
            return .revoked
        }

        switch result {
        case .transportFailure:
            return settleRetry(entry: entry, lease: lease, attempt: attemptNumber,
                               serverRetryAfter: nil)
        case .response(let statusCode, let body):
            switch statusCode {
            case 200, 201:
                // 201 = newly accepted, 200 = previously accepted (idempotent replay). Both are
                // only trustworthy when the receipt body validates against OUR record identity.
                return settleReceipt(entry: entry, lease: lease, body: body,
                                     statusCode: statusCode, attempt: attemptNumber)
            case 401:
                // AUTHENTICATION, not a verdict on the record (reviewer 7dd1e357). The credential
                // is refreshed out of band and the SAME immutable entry is retried; deleting it
                // here would discard a valid recording because of a stale token.
                return settleRetry(entry: entry, lease: lease, attempt: attemptNumber,
                                   serverRetryAfter: nil)
            case 503:
                // "upload_pending": transient by contract, and the server may still tell us when.
                // Its minimum is PRESERVED and ENFORCED through the persisted not-before stamp.
                return settleRetry(entry: entry, lease: lease, attempt: attemptNumber,
                                   serverRetryAfter: Self.retryAfterSeconds(body))
            case 429:
                return settleRetry(entry: entry, lease: lease, attempt: attemptNumber,
                                   serverRetryAfter: Self.retryAfterSeconds(body))
            case 408:
                // Request timeout: transient by the owning table, never a judgement on the record.
                return settleRetry(entry: entry, lease: lease, attempt: attemptNumber,
                                   serverRetryAfter: nil)
            case 400, 409, 410, 413, 415, 422:
                // THE OWNING TABLE's terminal dispositions ONLY — and the BODY must carry the
                // code the table pairs with this status (spec 8c5eb290): a malformed body or an
                // unrelated code under a terminal-looking status is NOT proof; it retains.
                // 400 invalid_request, 409 capture_conflict, 410 record_gone/enrollment_retired,
                // 413 payload_too_large, 415 unsupported_audio, 422 integrity_mismatch.
                let code = Self.errorCode(body)
        let owning = code == Self.owningCode[statusCode]
            || (statusCode == 410 && code == "enrollment_retired")
        guard owning else {
                    return unknownOutcome(entry: entry, lease: lease, attempt: attemptNumber,
                                          reason: "terminal status with non-owning body")
                }
                return settleTerminal(entry: entry, lease: lease, statusCode: statusCode)
            case 403:
                // The table's stop disposition — only when the body names it:
                // not_enrolled / collection_disabled. An unrelated 403 is just unknown.
                guard let code = Self.errorCode(body),
                    code == "not_enrolled" || code == "collection_disabled" else {
                    return unknownOutcome(entry: entry, lease: lease, attempt: attemptNumber,
                                          reason: "403 without owning code")
                }
                return settleTerminal(entry: entry, lease: lease, statusCode: statusCode)
            default:
                // Everything unmatched (unknown 4xx, 5xx other than 503, odd 3xx): the record's
                // fate is unknown, so it is retained and retried with bounded backoff.
                return settleRetry(entry: entry, lease: lease, attempt: attemptNumber,
                                   serverRetryAfter: Self.retryAfterSeconds(body))
            }
        }
    }

    // MARK: - settlement

    private func settleReceipt(
        entry: VoiceSharingUploadQueue.Entry, lease: VoiceSharingUploadQueue.AttemptLease,
        body: Data, statusCode: Int, attempt: Int
    ) -> Outcome {
        let expected: VoiceSharingRecordBinding.BoundEntry
        do {
            expected = try queue.boundIdentity(of: entry)
        } catch {
            return unknownOutcome(entry: entry, lease: lease, attempt: attempt, reason: "local identity unreadable")
        }
        let receipt: Receipt
        do {
            receipt = try Self.parseReceipt(body)
        } catch {
            // UNKNOWN OUTCOME: retain audio, retry the same record. Never delete for a bad receipt.
            return unknownOutcome(entry: entry, lease: lease, attempt: attempt, reason: "malformed receipt")
        }
        // The PAIR must agree: 201 with "duplicate" or 200 with "accepted" is a contradiction —
        // the server is describing a different history than the code it sent. Unknown, retained.
        guard receipt.status.contradicts(statusCode) == false else {
            return unknownOutcome(entry: entry, lease: lease, attempt: attempt,
                                  reason: "receipt status contradicts http status")
        }
        // The receipt must describe THIS entry. A well-formed receipt for another identity is a
        // protocol violation, not acceptance of ours.
        guard receipt.captureID == expected.captureID,
              receipt.recordSHA256 == expected.recordSHA256 else {
            return unknownOutcome(entry: entry, lease: lease, attempt: attempt, reason: "receipt identity mismatch")
        }
        do {
            try queue.applyAttemptResult(entry, lease: lease, outcome: .delivered)
        } catch VoiceSharingUploadQueue.PrepareError.resultStale {
            return .staleAttempt
        } catch {
            return .unavailable(reason: "settlement failed: \(type(of: error))")
        }
        return .delivered(receiptID: receipt.receiptID, duplicate: receipt.status == .duplicate)
    }

    private func unknownOutcome(
        entry: VoiceSharingUploadQueue.Entry, lease: VoiceSharingUploadQueue.AttemptLease,
        attempt: Int, reason: String, serverRetryAfter: Double? = nil
    ) -> Outcome {
        // Same transaction discipline as a 503: unknown is as retryable, so it gets the same
        // lease-validated, durably published boundary.
        let delay = retryPolicy.delay(afterAttempt: attempt, serverRetryAfter: serverRetryAfter)
        do {
            try queue.applyAttemptResult(
                entry, lease: lease, outcome: .retryableFailure,
                retryNotBefore: clock().addingTimeInterval(delay))
        } catch VoiceSharingUploadQueue.PrepareError.resultStale {
            return .staleAttempt
        } catch {
            return .unavailable(reason: "settlement failed: \(type(of: error))")
        }
        return .unknownOutcome(reason: reason)
    }

    private func settleRetry(
        entry: VoiceSharingUploadQueue.Entry, lease: VoiceSharingUploadQueue.AttemptLease, attempt: Int,
        serverRetryAfter: Double?
    ) -> Outcome {
        // ONE AUTHORITATIVE TRANSACTION (reviewer ce001b9a / spec b9a416d6): the queue validates
        // the lease FIRST, publishes the durable boundary inside the same serialized operation,
        // and only then releases. A stale result can neither settle nor touch a successor's
        // boundary; a failed barrier engages the owner-wide hold instead of degrading to advisory.
        let delay = retryPolicy.delay(afterAttempt: attempt, serverRetryAfter: serverRetryAfter)
        do {
            try queue.applyAttemptResult(
                entry, lease: lease, outcome: .retryableFailure,
                retryNotBefore: clock().addingTimeInterval(delay))
        } catch VoiceSharingUploadQueue.PrepareError.resultStale {
            return .staleAttempt
        } catch {
            return .unavailable(reason: "settlement failed: \(type(of: error))")
        }
        return .retry(serverRetryAfterSeconds: delay, attempt: attempt)
    }

    private func settleTerminal(
        entry: VoiceSharingUploadQueue.Entry, lease: VoiceSharingUploadQueue.AttemptLease, statusCode: Int
    ) -> Outcome {
        do {
            try queue.applyAttemptResult(entry, lease: lease, outcome: .abandoned)
        } catch VoiceSharingUploadQueue.PrepareError.resultStale {
            return .staleAttempt
        } catch {
            return .unavailable(reason: "settlement failed: \(type(of: error))")
        }
        return .abandoned(reason: "http \(statusCode)")
    }

    /// Builds the multipart body for an entry, plus the boundary used. Exposed so the production
    /// transport can send EXACTLY these bytes (one builder, no drift between what is tested and
    /// what is sent).
    static func multipartBody(
        metadata: Data, audio: Data
    ) -> (body: Data, boundary: String) {
        let boundary = "auris-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"metadata\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(metadata)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return (body, boundary)
    }

    // MARK: - request

    /// Public so the production transport can obtain the EXACT request the uploader built (and so
    /// controls can assert on it) without duplicating body construction.
    func makeRequest(
        entry: VoiceSharingUploadQueue.Entry, url: URL
    ) throws -> URLRequest {
        let metadata = try queue.metadata(of: entry)
        let audio = try queue.audio(of: entry)
        let (body, boundary) = Self.multipartBody(metadata: metadata, audio: audio)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        // A stable idempotency header lets the server recognize the retry of the SAME immutable
        // record rather than a second upload (spec: retries carry the same identity/body).
        if let identity = try? queue.boundIdentity(of: entry) {
            request.setValue(identity.captureID, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpBody = body
        return request
    }

    // MARK: - receipt parsing

    /// Strict: a receipt is accepted only if EVERY required field is the expected type. Anything
    /// else is `.missingField`/`.notJSON` — which the caller treats as an UNKNOWN outcome.
    static func parseReceipt(_ data: Data) throws -> Receipt {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReceiptError.notJSON
        }
        // schema_version must be the INTEGER 1. `as? Int` would bridge a JSON boolean to 1, which
        // would let `true` authorize a receipt (reviewer 7dd1e357).
        guard Self.isExactInteger(object["schema_version"], 1) else {
            throw ReceiptError.missingField("schema_version")
        }
        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String, !value.isEmpty else {
                throw ReceiptError.missingField(key)
            }
            return value
        }
        let captureID = try string("capture_id")
        let recordSHA = try string("record_sha256")
        // Digests are lowercase hex of a SHA-256: anything else is not a digest.
        guard recordSHA.count == 64,
            recordSHA.allSatisfy({ ($0.isNumber && $0.isASCII) || ("a"..."f").contains($0) })
        else {
            throw ReceiptError.missingField("record_sha256")
        }
        let rawStatus = try string("status")
        guard let status = ReceiptStatus(rawValue: rawStatus) else {
            throw ReceiptError.unexpectedStatus(rawStatus)
        }
        let receiptID = try string("receipt_id")
        // Timestamps are part of the contract, not decoration: a receipt whose times do not parse
        // cannot be reasoned about for retention, so it is refused.
        _ = try timestamp(object, "accepted_at")
        _ = try timestamp(object, "retention_expires_at")
        return Receipt(captureID: captureID, recordSHA256: recordSHA, status: status,
                       receiptID: receiptID)
    }

    /// Accepts only a genuine JSON number that is integral and equal to `expected`. Booleans are
    /// rejected explicitly because `as? Int` bridges them.
    static func isExactInteger(_ value: Any?, _ expected: Int) -> Bool {
        guard let number = value as? NSNumber else { return false }
        // CFBoolean is an NSNumber subclass: refuse it by type.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        guard number.doubleValue.isFinite, number.doubleValue == Double(expected) else {
            return false
        }
        return true
    }

    /// ISO-8601 with a timezone designator; fractional seconds are accepted, a zone is required.
    static func timestamp(_ object: [String: Any], _ key: String) throws -> Date {
        guard let raw = object[key] as? String, !raw.isEmpty else {
            throw ReceiptError.missingField(key)
        }
        guard raw.hasSuffix("Z") || raw.range(of: "[+-]\\d{2}:\\d{2}$", options: .regularExpression)
            != nil
        else {
            throw ReceiptError.missingField(key)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else {
            throw ReceiptError.missingField(key)
        }
        return date
    }

    /// The ONLY two statuses a trustworthy receipt may carry. A string field would let new server
    /// values silently read as accepted.
    enum ReceiptStatus: String {
        case accepted
        case duplicate

        /// A code/status pair the owning table never produces is a protocol violation.
        func contradicts(_ httpStatus: Int) -> Bool {
            switch (httpStatus, self) {
            case (201, .accepted), (200, .duplicate): return false
            default: return true
            }
        }
    }

    /// The owning status→code pairs (specs/voice-recording-uploads.md). A terminal disposition
    /// requires BOTH halves.
    static let owningCode: [Int: String] = [
        400: "invalid_request",
        409: "capture_conflict",
        410: "record_gone",
        413: "payload_too_large",
        415: "unsupported_audio",
        422: "integrity_mismatch",
    ]

    /// Strict error-body read: `{schema_version: 1, code: nonempty}` exactly (the worker's
    /// errorBody shape). Anything else yields nil — which retains.
    static func errorCode(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            isExactInteger(object["schema_version"], 1),
            let code = object["code"] as? String, !code.isEmpty
        else { return nil }
        return code
    }

    /// Retry-After is advisory server guidance; unparseable values are simply absent (the policy
    /// then uses its own bounded backoff).
    static func retryAfterSeconds(_ body: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        if let value = object["retry_after_s"] as? Double, value > 0, value.isFinite { return value }
        if let value = object["retry_after_s"] as? Int, value > 0 { return Double(value) }
        return nil
    }
}