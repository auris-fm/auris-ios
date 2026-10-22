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
            let (data, response) = try await session.data(for: request)
            // BOUNDED response (reviewer ce001b9a): a receipt is a small JSON object. An
            // oversized or non-small body is not a receipt — it is refused as a transport-class
            // failure (unknown, retryable) rather than parsed or buffered further.
            guard data.count <= Self.maxResponseBytes else { return .transportFailure }
            guard let http = response as? HTTPURLResponse else {
                // A non-HTTP response is not an answer about this record.
                return .transportFailure
            }
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
