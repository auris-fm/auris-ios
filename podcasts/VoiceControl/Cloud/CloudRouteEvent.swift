import Foundation

/// SSE events from `POST /api/v1/cloud/route` (cloud-assistant.md).
enum CloudRouteEvent: Equatable {
    case action(tool: String, action: String, params: [String: CloudRouteJSONValue])
    case token(String)
    /// Negotiated structured discovery result (only received when the client
    /// advertised `search_results_v1`).
    case result(DiscoveryResult)
    case done(inputTokens: Int, outputTokens: Int)
    case error(code: String, message: String)
}

/// JSON values that appear in action `params` (numbers normalized to Int64 when integral).
enum CloudRouteJSONValue: Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case object([String: CloudRouteJSONValue])
    case array([CloudRouteJSONValue])

    var int64Value: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value:
            // Range guard mirrors CloudRouteClient: values come off the wire, and
            // Int64(1e300) is a runtime trap rather than an overflow error.
            // Upper bound is strict: Double(Int64.max) rounds UP to 2^63, so
            // `<=` would admit exactly the value that traps the conversion.
            guard value >= Double(Int64.min), value < Double(Int64.max) else { return nil }
            return Int64(value)
        default: return nil
        }
    }
}

/// Request context body for `/api/v1/cloud/route`.
struct CloudRouteContext: Equatable, Encodable {
    let episodeId: String
    let podcastId: String?
    let referencePositionMs: Int64?
    let clientPositionMs: Int64
    let recentReferencePositions: [Int64]
    let previousReferencePositionMs: Int64?

    enum CodingKeys: String, CodingKey {
        case episodeId = "episode_id"
        case podcastId = "podcast_id"
        case referencePositionMs = "reference_position_ms"
        case clientPositionMs = "client_position_ms"
        case recentReferencePositions = "recent_reference_positions"
        case previousReferencePositionMs = "previous_reference_position_ms"
    }

    init(from playback: PlaybackContext) {
        episodeId = playback.episodeId
        podcastId = playback.podcastId
        referencePositionMs = playback.referencePositionMs
        clientPositionMs = playback.clientPositionMs
        recentReferencePositions = playback.recentReferencePositions
        previousReferencePositionMs = playback.previousReferencePositionMs
    }

    init(
        episodeId: String,
        podcastId: String? = nil,
        referencePositionMs: Int64? = nil,
        clientPositionMs: Int64,
        recentReferencePositions: [Int64] = [],
        previousReferencePositionMs: Int64? = nil
    ) {
        self.episodeId = episodeId
        self.podcastId = podcastId
        self.referencePositionMs = referencePositionMs
        self.clientPositionMs = clientPositionMs
        self.recentReferencePositions = recentReferencePositions
        self.previousReferencePositionMs = previousReferencePositionMs
    }
}
