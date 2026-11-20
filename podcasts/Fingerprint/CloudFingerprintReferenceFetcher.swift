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
    private let identity: () -> String
    private let timeoutSeconds: TimeInterval

    init(
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = CloudFingerprintReferenceFetcher.defaultTimeoutSeconds,
        identity: @escaping () -> String = { CloudIdentity.shared.userId }
    ) {
        self.session = session
        self.timeoutSeconds = timeoutSeconds
        self.identity = identity
    }

    /// The parsed reference alongside its matcher: the raw compact-v2 bytes
    /// are the cache/provenance identity for a cloud-built mapping, so the
    /// fetcher hands them back instead of discarding them after parsing.
    struct FetchedReference {
        let matcher: CloudReferenceMatcher
        let reference: ReferenceFingerprint
        let data: Data
    }

    func fetchReference(baseUrl: String, episodeUuid: String) async -> FetchedReference? {
        let trimmedBase = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/api/v1/episodes/\(episodeUuid)/fingerprints") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        // Auris-owned route only — lightweight user_{uuid} Bearer (cloud-identity.md).
        request.setValue("Bearer " + identity(), forHTTPHeaderField: "Authorization")

        do {
            let data: Data = try await withTimeout(seconds: timeoutSeconds) {
                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            return buildFetchedReference(from: data)
        } catch {
            return nil
        }
    }

    /// Parses compact-v2 bytes into a matcher plus the decoded reference and
    /// raw payload, or nil when unusable.
    func buildFetchedReference(from data: Data) -> FetchedReference? {
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
        return FetchedReference(matcher: matcher, reference: reference, data: data)
    }

    /// Parses compact-v2 bytes into a matcher, or nil when unusable.
    func buildMatcher(from data: Data) -> CloudReferenceMatcher? {
        buildFetchedReference(from: data)?.matcher
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
