import Foundation
import PocketCastsUtils

/// The PRODUCTION transport for contribution uploads: builds the real request (bearer credential,
/// real endpoint, bounded timeouts) and executes it through URLSession.
///
/// What lives here rather than in `VoiceSharingUploader`: everything that touches the network
/// stack. The uploader owns the DECISION (settle / retry / unknown / abandon); this type owns the
/// WIRE. Keeping them apart is what let the uploader's controls run without a network.
///
/// Credential lifetime (spec: "Authentication"): a 401 means the credential was rejected, not that
/// the upload failed permanently. It is reported to the token provider (so a concurrent refresh is
/// not duplicated) and the attempt is classified as RETRYABLE — the same immutable record is
/// retried under the next credential. No credential in hand means no request is issued at all:
/// fail closed, never a request without a bearer.
final class VoiceSharingUploadTransport {
    /// Production route (worker/src/contributions/upload_route.ts, mounted as
    /// POST /api/v1/voice-recordings).
    static let uploadPath = "/api/v1/voice-recordings"
    /// Receipt bodies are small JSON objects; anything larger is not one.
    static let maxResponseBytes = 64 * 1024
    /// Full body deadline: the transfer must COMPLETE within this budget, not merely stay active.
    /// Starts BEFORE the request is issued, so stalled headers count. Injectable for controls.
    let bodyDeadline: TimeInterval

    /// Receives the response body with a hard byte ceiling (cancel past it) and a hard total
    /// deadline. Returns nil for any violation — the record's fate stays unknown.
    /// Receives the response with a hard byte ceiling (cancel past it) and a TOTAL deadline that
    /// starts BEFORE the request is issued — stalled headers count against it too. The underlying
    /// transfer is cancelled through the session task handle, not just abandoned.
    private static func receive(
        session: URLSession, request: URLRequest, byteLimit: Int, deadline: TimeInterval
    ) async throws -> (HTTPURLResponse, Data)? {
        // The REAL task handle: cancelling it tears down the actual URL transfer.
        let transferTask = Task<(HTTPURLResponse, Data)?, Error> {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            var data = Data()
            data.reserveCapacity(min(byteLimit, 4096))
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > byteLimit {
                        // Ceiling crossed mid-stream: kill the underlying transfer NOW.
                        throw URLError(.dataNotAllowed)
                    }
                }
            } catch {
                return nil
            }
            return (http, data)
        }
        // Deadline task: races the transfer; the loser is cancelled.
        let deadlineTask = Task<Void, Error> {
            try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            throw URLError(.timedOut)
        }
        defer {
            transferTask.cancel()
            deadlineTask.cancel()
        }
        return try await withThrowingTaskGroup(
            of: (HTTPURLResponse, Data)?.self
        ) { group in
            group.addTask { [transferTask, deadlineTask] in
                let outcome = try await transferTask.value
                // Transfer decided: release the deadline sleeper immediately. It is a SEPARATE
                // top-level task, so group cancellation cannot reach it — only this explicit
                // cancel can, and without it every completed transfer would still wait out the
                // full deadline before returning.
                deadlineTask.cancel()
                return outcome
            }
            group.addTask { [transferTask] in
                do {
                    _ = try await deadlineTask.value
                } catch {
                    // The deadline (or its own cancellation) fired: kill the underlying URL
                    // transfer FIRST so the transfer child can actually finish.
                    transferTask.cancel()
                    if !Task.isCancelled { throw error }
                    return nil
                }
                transferTask.cancel()
                throw URLError(.timedOut)
            }
            guard let first = try await group.next() else { return nil }
            group.cancelAll()
            return first
        }
    }

    private let baseURLProvider: () -> String
    private let tokenProvider: CloudTokenProviding
    private let session: URLSession

    init(
        baseURLProvider: @escaping () -> String,
        tokenProvider: CloudTokenProviding,
        session: URLSession = .shared,
        bodyDeadline: TimeInterval = 90
    ) {
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.session = session
        self.bodyDeadline = bodyDeadline
    }

    /// The endpoint this transport will use, or nil when configuration is missing. Nil is NOT
    /// defaulted to something plausible: an unconfigured build must not upload anywhere.
    var endpoint: URL? {
        let base = baseURLProvider()
        guard !base.isEmpty else { return nil }
        return URL(string: base + Self.uploadPath)
    }

    /// Executes an already-built request. Returns the wire answer; never throws.
    ///
    /// The request ARRIVES complete (URL, body, boundary, idempotency key) from the uploader; this
    /// type adds the credential and executes it. That split means the bytes the controls assert on
    /// are the bytes that go on the wire.
    func send(request built: URLRequest) async -> VoiceSharingUploader.TransportResult {
        // No bearer, no call — nothing is created, nothing is sent.
        guard let credential = await tokenProvider.token(), !credential.isEmpty else {
            return .transportFailure
        }
        var request = built
        // The CONFIGURED endpoint decides, not anything the caller supplied: a build with no base
        // URL must upload nowhere, even if it was handed a well-formed request.
        guard let endpoint else { return .transportFailure }
        request.url = endpoint
        // IDLE deadline (headers or any gap): URLSession natively aborts a transfer that stays
        // silent this long — cooperative cancellation alone does not interrupt a stalled
        // stream. The WALL deadline below separately bounds total body lifetime, so a dribbling
        // body that resets the idle timer still dies.
        request.timeoutInterval = bodyDeadline
        // The credential is the ONLY header this type adds: URL, body, content type and the
        // idempotency key all arrive from the uploader, so what the controls assert is what ships.
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        do {
            // STREAMING bound (reviewer 8ba9c45f): `session.data` allocates the WHOLE body before
            // this code runs, so a post-hoc count check is a parse bound, not a memory bound. The
            // byte ceiling is enforced WHILE receiving and the transfer is cancelled the moment it
            // is exceeded. A full-body deadline bounds the transfer's total lifetime as well.
            let transfer = try await Self.receive(
                session: session, request: request,
                byteLimit: Self.maxResponseBytes, deadline: bodyDeadline)
            guard let (http, data) = transfer else { return .transportFailure }

            if http.statusCode == 401 {
                // Report WHICH credential was rejected, then let the caller retry: a 401 is an
                // authentication event, not a verdict on the record.
                await tokenProvider.handleUnauthorized(rejectedToken: credential)
            }
            return .response(statusCode: http.statusCode, body: data)
        } catch {
            // Transport-level failure (offline, timeout, TLS): the record's fate is unknown, which
            // the uploader treats as retryable — never as delivered.
            return .transportFailure
        }
    }

}
