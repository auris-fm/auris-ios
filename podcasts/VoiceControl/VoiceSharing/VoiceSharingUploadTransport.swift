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
    static let bodyDeadline: TimeInterval = 90

    /// Receives the response body with a hard byte ceiling (cancel past it) and a hard total
    /// deadline. Returns nil for any violation — the record's fate stays unknown.
    private static func receive(
        session: URLSession, request: URLRequest, byteLimit: Int, deadline: TimeInterval
    ) async throws -> (HTTPURLResponse, Data)? {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        var data = Data()
        data.reserveCapacity(min(byteLimit, 4096))
        var task: Task<Void, Never>?
        return try await withThrowingTaskGroup(of: (HTTPURLResponse, Data)?.self) { group in
            defer { task?.cancel() }
            // Deadline task: fails the group if the body has not COMPLETED in time.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                if !Task.isCancelled { throw URLError(.timedOut) }
                return nil
            }
            // Receive task: accumulate with the ceiling; past it, cancel the stream.
            group.addTask {
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count > byteLimit {
                            throw URLError(.dataNotAllowed)
                        }
                    }
                    return (http, data)
                } catch {
                    // Ceiling exceeded or stream error: violation.
                    return nil
                }
            }
            // First finish decides: a completed transfer returns it; a violation (nil) or a
            // deadline throw cancels the sibling immediately — no waiting out the deadline.
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
        session: URLSession = .shared
    ) {
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.session = session
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
        // Uploads are slow by nature but must not hang forever: a stuck request would pin the
        // attempt lease until expiry.
        request.timeoutInterval = 60
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
                byteLimit: Self.maxResponseBytes, deadline: Self.bodyDeadline)
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
