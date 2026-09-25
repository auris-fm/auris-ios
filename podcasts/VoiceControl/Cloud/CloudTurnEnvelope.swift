import Foundation

/// Item 5 (iOS half) — the per-logical-turn envelope for `POST /api/v1/cloud/route`.
///
/// Contract (`docs/specs/cloud-assistant.md` → "Turn control fields"):
/// - `request_id`: client-assigned UUID, stable for the logical turn, reused
///   across transport attempts; a server-assigned id must never be auto-retried.
/// - `capabilities`: advertise `search_results_v1` only when the client can
///   render the structured `result` event (see `CloudClientCapabilities`).
/// - `route_hint`: `{operation, arguments}` supplied only by typed UI flows or a
///   validated upstream parser — never synthesized from free text.
/// - `context.recent_conversation`: up to four `{role, text}` entries, at most
///   8 KiB UTF-8 in total, treated as untrusted context.
struct CloudTurnEnvelope: Equatable {
    let requestId: String
    let capabilities: [String]
    let routeHint: CloudRouteHint?
    let recentConversation: [RecentConversationTurn]

    /// Builds an envelope for one logical turn: a fresh `request_id` (reuse the
    /// returned envelope for transport retries of the same turn) and a bounded
    /// recent-conversation context.
    static func make(
        capabilities: [String],
        routeHint: CloudRouteHint?,
        recentConversation: [RecentConversationTurn]
    ) -> CloudTurnEnvelope {
        CloudTurnEnvelope(
            requestId: UUID().uuidString,
            capabilities: capabilities,
            routeHint: routeHint,
            recentConversation: RecentConversation.bounded(recentConversation)
        )
    }
}

/// Client capabilities the server negotiates against. Advertise a capability
/// only when the client implements its side of the contract.
enum CloudClientCapabilities {
    static let searchResultsV1 = "search_results_v1"

    /// - Parameter rendersStructuredResults: true only once the iOS renderer
    ///   handles the result/empty/unavailable states, scope, and play/seek
    ///   eligibility (`search_results_v1`). Until then the server falls back to
    ///   deterministic short `token` text plus `done`.
    static func advertised(rendersStructuredResults: Bool) -> [String] {
        rendersStructuredResults ? [searchResultsV1] : []
    }
}

/// A structured, validated route hint. Constructed only by typed UI flows or a
/// validated upstream parser — free-text turns pass `nil` and keep today's
/// `cloud_route` interpretation path.
struct CloudRouteHint: Equatable {
    let operation: String
    let arguments: [String: CloudRouteJSONValue]
}

/// One bounded prior turn in the request context. Untrusted context only —
/// never treated as system instructions or authenticated tool results.
struct RecentConversationTurn: Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let role: Role
    let text: String
}

/// Bounds for the recent-conversation context (≤4 turns, ≤8 KiB UTF-8).
enum RecentConversation {
    static let maxTurns = 4
    static let maxBytes = 8 * 1024

    /// Keeps the newest turns within both bounds: drops oldest entries first,
    /// then trims the remaining newest entry if it alone exceeds the byte cap.
    static func bounded(_ turns: [RecentConversationTurn]) -> [RecentConversationTurn] {
        var result = Array(turns.suffix(maxTurns))
        // Newest-first trimming so the most recent context survives.
        while !result.isEmpty {
            let totalBytes = result.reduce(0) { $0 + $1.text.utf8.count }
            if totalBytes <= maxBytes { break }
            if result.count == 1 {
                // Single oversized turn: keep its tail (newest speech) within
                // budget, measured in **UTF-8 bytes** — `String.suffix` counts
                // Characters, so a CJK/emoji turn would trim to 8 Ki *characters*
                // (~32 KiB of bytes) and blow the bound (review finding on #19).
                let only = result[0]
                let truncated = Self.utf8Suffix(only.text, maxBytes: maxBytes)
                result = [RecentConversationTurn(role: only.role, text: truncated)]
                break
            }
            result.removeFirst()
        }
        return result
    }

    /// The longest suffix of `text` within `maxBytes` UTF-8 bytes, without
    /// splitting a multi-byte scalar (leading continuation bytes are dropped, so
    /// the result always decodes).
    static func utf8Suffix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0, text.utf8.count > maxBytes else { return maxBytes > 0 ? text : "" }
        var bytes = Array(text.utf8.suffix(maxBytes))
        while let first = bytes.first, (first & 0b1100_0000) == 0b1000_0000 {
            bytes.removeFirst()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Encodes the `/api/v1/cloud/route` request body, including the turn envelope.
enum CloudRouteRequestBuilder {
    static func body(
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope
    ) throws -> Data {
        var contextObject: [String: Any] = [
            "episode_id": context.episodeId,
            "client_position_ms": context.clientPositionMs,
            "recent_reference_positions": context.recentReferencePositions,
        ]
        if let podcastId = context.podcastId { contextObject["podcast_id"] = podcastId }
        if let referencePositionMs = context.referencePositionMs { contextObject["reference_position_ms"] = referencePositionMs }
        if let previousReferencePositionMs = context.previousReferencePositionMs { contextObject["previous_reference_position_ms"] = previousReferencePositionMs }
        if !turn.recentConversation.isEmpty {
            contextObject["recent_conversation"] = turn.recentConversation.map {
                ["role": $0.role.rawValue, "text": $0.text]
            }
        }

        var payload: [String: Any] = [
            "request": request,
            "context": contextObject,
            "request_id": turn.requestId,
        ]
        // Omitted (not empty) when nothing is advertised: the server's fallback
        // path is the absence of the capability.
        if !turn.capabilities.isEmpty {
            payload["capabilities"] = turn.capabilities
        }
        if let routeHint = turn.routeHint {
            payload["route_hint"] = [
                "operation": routeHint.operation,
                "arguments": encodeJSONValues(routeHint.arguments),
            ]
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func encodeJSONValues(_ values: [String: CloudRouteJSONValue]) -> [String: Any] {
        values.mapValues { encodeJSONValue($0) }
    }

    private static func encodeJSONValue(_ value: CloudRouteJSONValue) -> Any {
        switch value {
        case .string(let string): return string
        case .int(let int): return int
        case .double(let double): return double
        case .bool(let bool): return bool
        case .null: return NSNull()
        case .object(let object): return encodeJSONValues(object)
        case .array(let array): return array.map { encodeJSONValue($0) }
        }
    }
}
