import Foundation

/// Fetches the Auris cloud reference fingerprints for an episode from
/// `GET /api/v1/episodes/{episode_uuid}/fingerprints` (cloud-ingestion.md) and
/// parses the `fingerprint-compact-v2` payload into a `CloudReferenceMatcher`.
///
/// Returns nil on any failure (unconfigured, network, decode, no checkpoints)
/// so callers degrade gracefully to the transcript-sync path.
final class CloudFingerprintReferenceFetcher {
    static let shared = CloudFingerprintReferenceFetcher()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchReference(baseUrl: String, episodeUuid: String) async -> CloudReferenceMatcher? {
        let trimmedBase = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/api/v1/episodes/\(episodeUuid)/fingerprints") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + CloudIdentity.shared.userId, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return buildMatcher(from: data)
        } catch {
            return nil
        }
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
}
