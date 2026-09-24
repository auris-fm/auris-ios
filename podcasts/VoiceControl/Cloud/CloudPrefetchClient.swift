import Foundation

/// Item 5 (iOS half), slice 3 — best-effort prefetch client for
/// `POST /api/v1/cloud/context/prefetch`.
///
/// Contract (`docs/specs/cloud-assistant.md` → prefetch): body
/// `{episode_id, podcast_id?}` with verified identity; `202 {status}` where
/// status is `accepted` or `skipped`; `400` malformed, `401` unauthenticated.
/// The endpoint never waits for retrieval, and the client fires it best effort —
/// it must not delay playback and must not retry in a loop.
final class CloudPrefetchClient {
    static let prefetchPath = "/api/v1/cloud/context/prefetch"
    /// Short budget: prefetch is optional and its failure is invisible, so it
    /// must never hold a connection open the way a turn may.
    static let defaultTimeoutSeconds: TimeInterval = 5

    enum Outcome: Equatable {
        case accepted
        case skipped
        /// Any non-202, malformed response or transport failure. Best effort:
        /// callers log/ignore and never retry.
        case failed
    }

    private let baseURL: String
    private let userId: String
    private let tokenProvider: CloudTokenProviding
    private let session: URLSession

    init(baseURL: String, userId: String, session: URLSession? = nil, tokenProvider: CloudTokenProviding? = nil) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.userId = userId
        self.tokenProvider = tokenProvider ?? CloudStaticIdentityTokenProvider()
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = CloudPrefetchClient.defaultTimeoutSeconds
            config.timeoutIntervalForResource = CloudPrefetchClient.defaultTimeoutSeconds * 2
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    /// Fires the hint and returns immediately; the request runs detached and its
    /// outcome is intentionally dropped (no retry, no user-visible failure).
    ///
    /// The task captures `self` **strongly on purpose**: the playback-start hook
    /// creates a client just to fire the hint and drops it immediately, so a weak
    /// capture let the client deallocate before the request was built and the
    /// hint silently never went out (review finding on PR #19). The task ends
    /// when the attempt completes, which releases the client.
    func schedulePrefetch(episodeId: String, podcastId: String?) {
        Task.detached(priority: .utility) { [self] in
            _ = await prefetch(episodeId: episodeId, podcastId: podcastId)
        }
    }

    /// Performs one prefetch attempt. Never throws and never retries.
    func prefetch(episodeId: String, podcastId: String?) async -> Outcome {
        guard let url = URL(string: baseURL + Self.prefetchPath) else { return .failed }

        var body: [String: Any] = ["episode_id": episodeId]
        if let podcastId { body["podcast_id"] = podcastId }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Fail closed / stay silent without a credential (parity with the
        // Android half): prefer one attempt that never happens to a hopeful
        // bearer. Default provider returns the trust-on-first-use id.
        guard let credential = await tokenProvider.token() ?? (userId.isEmpty ? nil : userId) else {
            return .failed
        }
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.defaultTimeoutSeconds
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return .failed }
        request.httpBody = encoded

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 202,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = object["status"] as? String
            else {
                return .failed
            }
            switch status {
            case "accepted": return .accepted
            case "skipped": return .skipped
            default: return .failed
            }
        } catch {
            return .failed
        }
    }
}
