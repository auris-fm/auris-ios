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
        let status: String // "accepted" | "duplicate"
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
        let lease: VoiceSharingUploadQueue.AttemptLease
        do {
            guard try queue.beginAttempt(entry) else {
                return .unavailable(reason: "attempt refused (held, exhausted or owned)")
            }
            guard let acquired = try queue.currentLease(for: entry) else {
                return .unavailable(reason: "attempt granted without a lease")
            }
            lease = acquired
        } catch {
            return .unavailable(reason: "attempt refused: \(type(of: error))")
        }
        let attemptNumber: Int
        do {
            attemptNumber = try queue.attemptNumber(for: entry)
        } catch {
            _ = try? queue.applyAttemptResult(entry, lease: lease, outcome: .retryableFailure)
            return .unavailable(reason: "attempt accounting unavailable")
        }

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
                return settleReceipt(entry: entry, lease: lease, body: body)
            case 503:
                // "upload_pending": transient by contract; retry the same immutable record.
                return settleRetry(entry: entry, lease: lease, attempt: attemptNumber,
                                   serverRetryAfter: nil)
            case 429:
                return settleRetry(entry: entry, lease: lease, attempt: attemptNumber,
                                   serverRetryAfter: Self.retryAfterSeconds(body))
            case 400...499:
                // Terminal for THIS record (validated/conflicting/expired). Not retryable: the
                // record is immutable, so repeating it cannot help.
                return settleTerminal(entry: entry, lease: lease, statusCode: statusCode)
            default:
                return settleRetry(entry: entry, lease: lease, attempt: attemptNumber,
                                   serverRetryAfter: Self.retryAfterSeconds(body))
            }
        }
    }

    // MARK: - settlement

    private func settleReceipt(
        entry: VoiceSharingUploadQueue.Entry, lease: VoiceSharingUploadQueue.AttemptLease, body: Data
    ) -> Outcome {
        let expected: VoiceSharingRecordBinding.BoundEntry
        do {
            expected = try queue.boundIdentity(of: entry)
        } catch {
            return unknownOutcome(entry: entry, lease: lease, reason: "local identity unreadable")
        }
        let receipt: Receipt
        do {
            receipt = try Self.parseReceipt(body)
        } catch {
            // UNKNOWN OUTCOME: retain audio, retry the same record. Never delete for a bad receipt.
            return unknownOutcome(entry: entry, lease: lease, reason: "malformed receipt")
        }
        // The receipt must describe THIS entry. A well-formed receipt for another identity is a
        // protocol violation, not acceptance of ours.
        guard receipt.captureID == expected.captureID,
              receipt.recordSHA256 == expected.recordSHA256 else {
            return unknownOutcome(entry: entry, lease: lease, reason: "receipt identity mismatch")
        }
        do {
            try queue.applyAttemptResult(entry, lease: lease, outcome: .delivered)
        } catch VoiceSharingUploadQueue.PrepareError.resultStale {
            return .staleAttempt
        } catch {
            return .unavailable(reason: "settlement failed: \(type(of: error))")
        }
        return .delivered(receiptID: receipt.receiptID, duplicate: receipt.status == "duplicate")
    }

    private func unknownOutcome(
        entry: VoiceSharingUploadQueue.Entry, lease: VoiceSharingUploadQueue.AttemptLease, reason: String
    ) -> Outcome {
        // Retain the entry AND release the lease as a retryable failure: by contract this is not
        // acceptance, so the next attempt sends the same immutable record.
        _ = try? queue.applyAttemptResult(entry, lease: lease, outcome: .retryableFailure)
        return .unknownOutcome(reason: reason)
    }

    private func settleRetry(
        entry: VoiceSharingUploadQueue.Entry, lease: VoiceSharingUploadQueue.AttemptLease, attempt: Int,
        serverRetryAfter: Double?
    ) -> Outcome {
        do {
            try queue.applyAttemptResult(entry, lease: lease, outcome: .retryableFailure)
        } catch VoiceSharingUploadQueue.PrepareError.resultStale {
            return .staleAttempt
        } catch {
            return .unavailable(reason: "settlement failed: \(type(of: error))")
        }
        // The DELAY is advisory here: scheduling is the caller's (this type does not sleep, and
        // does not hold a lease across a wait). The policy supplies the honest, jittered delay.
        let delay = retryPolicy.delay(afterAttempt: attempt, serverRetryAfter: serverRetryAfter)
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

    // MARK: - request

    private func makeRequest(
        entry: VoiceSharingUploadQueue.Entry, url: URL
    ) throws -> URLRequest {
        let metadata = try queue.metadata(of: entry)
        let audio = try queue.audio(of: entry)
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
        guard let schemaVersion = object["schema_version"] as? Int, schemaVersion == 1 else {
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
        let status = try string("status")
        guard status == "accepted" || status == "duplicate" else {
            throw ReceiptError.unexpectedStatus(status)
        }
        let receiptID = try string("receipt_id")
        // accepted_at / retention_expires_at must be present; their VALUES are not this type's
        // business, but a receipt without them is not a receipt.
        _ = try string("accepted_at")
        _ = try string("retention_expires_at")
        return Receipt(captureID: captureID, recordSHA256: recordSHA, status: status,
                       receiptID: receiptID)
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