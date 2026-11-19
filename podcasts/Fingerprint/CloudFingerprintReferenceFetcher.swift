import Foundation

/// Fetches the Auris cloud reference fingerprints for an episode from
/// `GET /api/v1/episodes/{episode_uuid}/fingerprints` (cloud-ingestion.md) and
/// parses the `fingerprint-compact-v2` payload into a `CloudReferenceMatcher`.
///
/// Returns nil on any failure (unconfigured, network, decode, no checkpoints,
/// client-side timeout) so callers degrade gracefully to the transcript-sync
/// path / `client_position_ms`.
final class CloudFingerprintReferenceFetcher {
    static let shared = CloudFingerprintReferenceFetcher()

    /// Server blocks up to 2 minutes; client budget sits slightly above that.
    static let defaultTimeoutSeconds: TimeInterval = 150

    private let session: URLSession
    private let tokenProvider: any CloudTokenProviding
    private let timeoutSeconds: TimeInterval

    /// Test seam: the provider the fetcher will present. Production callers
    /// never read this; the default is the turn route's shared router choice.
    var tokenProviderForTesting: any CloudTokenProviding { tokenProvider }

    init(
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = CloudFingerprintReferenceFetcher.defaultTimeoutSeconds,
        tokenProvider: any CloudTokenProviding = CloudTokenProviderRouter.fingerprintReferenceProvider()
    ) {
        self.session = session
        self.timeoutSeconds = timeoutSeconds
        self.tokenProvider = tokenProvider
    }

    func fetchReference(baseUrl: String, episodeUuid: String, podcastUuid: String) async -> CloudReferenceMatcher? {
        let trimmedBase = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(trimmedBase)/api/v1/episodes/\(episodeUuid)/fingerprints") else {
            return nil
        }
        // The server resolves uncached episodes through the catalog, which
        // needs the show id (cloud-ingestion.md resolution rule).
        components.queryItems = [URLQueryItem(name: "podcast_id", value: podcastUuid)]
        guard let url = components.url else { return nil }

        // The Auris access token, directly from the shared Auris provider —
        // never the router's legacy branch, whose `user_<uuid>` is a guaranteed
        // 401 once the server verifier ships. No token ⇒ fail closed, dial
        // nothing.
        // A 401 refreshes once and retries once with the fresh token; a second
        // rejection gives up (the reference is additive, never worth a loop).
        var rejectedToken: String?
        for attempt in 0..<2 {
            guard let token = await tokenProvider.token(), !token.isEmpty else { return nil }
            if attempt > 0, token == rejectedToken { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = timeoutSeconds
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")

            do {
                let outcome: FetchOutcome = try await withTimeout(seconds: timeoutSeconds) {
                    let (data, response) = try await self.session.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    if http.statusCode == 401 {
                        return .unauthorized
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    return .body(data)
                }
                switch outcome {
                case .body(let data):
                    return buildMatcher(from: data)
                case .unauthorized:
                    // Report the bearer this request carried so a concurrent
                    // refresh that already replaced it makes this a no-op.
                    await tokenProvider.handleUnauthorized(rejectedToken: token)
                    rejectedToken = token
                }
            } catch {
                return nil
            }
        }
        return nil
    }

    private enum FetchOutcome {
        case body(Data)
        case unauthorized
    }

    /// Parses compact-v2 bytes into a matcher, or nil when unusable.
    func buildMatcher(from data: Data) -> CloudReferenceMatcher? {
        guard let reference = ReferenceFingerprint.decode(from: data) else { return nil }
        let checkpoints = reference.libraryCheckpoints()
        guard !checkpoints.isEmpty else { return nil }

        let matcher = CloudReferenceMatcher()
        for checkpoint in checkpoints {
            matcher.add(
                timestampSeconds: checkpoint.timestampSeconds,
                hashes: checkpoint.hashes,
                durationSeconds: reference.checkpointDurationSeconds
            )
        }
        return matcher
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
