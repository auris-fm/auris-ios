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
    /// The conversation identity this turn carries. Required by the admission contract on
    /// every turn; nothing is sent when it is absent, so a caller that forgets it produces a
    /// frame the server must refuse rather than a silently stateless turn.
    let conversation: CloudPreparedConversation?

    /// Builds an envelope for one logical turn: a fresh `request_id` (reuse the
    /// returned envelope for transport retries of the same turn) and a bounded
    /// recent-conversation context.
    static func make(
        capabilities: [String],
        routeHint: CloudRouteHint?,
        recentConversation: [RecentConversationTurn],
        conversation: CloudPreparedConversation? = nil
    ) -> CloudTurnEnvelope {
        CloudTurnEnvelope(
            requestId: UUID().uuidString,
            capabilities: capabilities,
            routeHint: routeHint,
            recentConversation: RecentConversation.bounded(recentConversation),
            conversation: conversation
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

/// Builds the turn envelope — the per-turn fields the server contracts on
/// (`request_id`, `capabilities` gating, typed-only `route_hint`, a bounded
/// `context.recent_conversation`).
///
/// This is the **single** place that asserts the envelope's shape: the WebSocket
/// authenticate frame is built from it, and the contract tests pin it through
/// that frame. It previously duplicated the frame assembly as a POST-body
/// builder that no production path called, which meant the tests could pass while
/// the shipped frame drifted from what they pinned.
enum CloudRouteRequestBuilder {
    /// The transport-neutral envelope, as the frame/body merges it.
    static func envelope(
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope
    ) -> [String: Any] {
        // Omitted when absent, never invented. The owning contract scopes the episode and its
        // position to "when a current episode exists" and forbids inventing either: an empty
        // `episode_id` is an ID that names nothing, and a zero position is a measurement the
        // client did not make. Both read as real to the server, so the discovery turn — the
        // app's normal first interaction, with nothing playing — must send neither.
        var contextObject: [String: Any] = [:]
        // EVERY playback-position key is omitted when there is no episode context — not just
        // the id and the client position. `recent_reference_positions` is a position key too:
        // sending an empty array still asserts that the client has a position history for a
        // turn where no current episode exists, and the contract says to omit playback positions
        // entirely in that case. An empty array is not "absent" on the wire.
        if let episodeId = context.episodeId {
            contextObject["episode_id"] = episodeId
            contextObject["recent_reference_positions"] = context.recentReferencePositions
        }
        if let clientPositionMs = context.clientPositionMs {
            contextObject["client_position_ms"] = clientPositionMs
        }
        if let podcastId = context.podcastId { contextObject["podcast_id"] = podcastId }
        if let referencePositionMs = context.referencePositionMs { contextObject["reference_position_ms"] = referencePositionMs }
        if let previousReferencePositionMs = context.previousReferencePositionMs { contextObject["previous_reference_position_ms"] = previousReferencePositionMs }

        // No `recent_conversation`. The owning paragraph retains conversation history
        // SERVER-side and forbids client-supplied history in the frame, so sending ours
        // would offer the model text the server never authenticated. Local memory stays
        // local; the conversation identity below is what makes the server's own history
        // reachable.

        var payload: [String: Any] = [
            "request": request,
            "context": contextObject,
            // The PREPARED request id when there is one. A retry of the same logical turn must
            // present the same `request_id`, so minting a fresh one here would make the server
            // see a second logical turn — which is what the manager's retry branch exists to
            // avoid, and it would be defeated at the last step.
            "request_id": turn.conversation?.requestId ?? turn.requestId,
        ]
        // The admission contract requires both on EVERY turn, first included. Carried at
        // the top level rather than inside `context`, and independent of episode
        // availability: a conversation is not a property of what is playing.
        if let conversation = turn.conversation {
            payload["conversation_id"] = conversation.conversationId
            payload["conversation_mode"] = conversation.mode
        }
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
        return payload
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
