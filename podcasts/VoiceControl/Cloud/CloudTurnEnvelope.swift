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
    /// The app-operation support THIS turn negotiates, captured by the caller from the turn's
    /// own declaration snapshot. nil = no app-ops advertisement: neither key is serialized.
    let appOperationSupport: CloudAppOperationSupport?

    /// Builds an envelope for one logical turn: a fresh `request_id` (reuse the
    /// returned envelope for transport retries of the same turn) and a bounded
    /// recent-conversation context.
    /// Builds the envelope for one logical turn. The prepared conversation is REQUIRED: the
    /// envelope's single identity IS the admitted utterance's `requestId` — the id the ASR
    /// pipeline minted at admission and the manager prepared. There is no fallback mint here:
    /// a turn without an admitted identity is refused upstream (sink), never re-identifed.
    /// Keeping ONE identity on the type means every consumer — wire frame, socket/result
    /// registration, bind callbacks, diagnostics — binds the same value (reviewer 9ab31c6d).
    static func make(
        capabilities: [String],
        routeHint: CloudRouteHint?,
        recentConversation: [RecentConversationTurn],
        conversation: CloudPreparedConversation,
        appOperationSupport: CloudAppOperationSupport? = nil
    ) -> CloudTurnEnvelope {
        CloudTurnEnvelope(
            requestId: conversation.requestId,
            capabilities: capabilities,
            routeHint: routeHint,
            recentConversation: RecentConversation.bounded(recentConversation),
            conversation: conversation,
            appOperationSupport: appOperationSupport
        )
    }
}

/// Client capabilities the server negotiates against. Advertise a capability
/// only when the client implements its side of the contract.
enum CloudClientCapabilities {
    static let searchResultsV1 = "search_results_v1"
    static let appOperationsV1 = "app_operations_v1"

    /// - Parameter rendersStructuredResults: true only once the iOS renderer
    ///   handles the result/empty/unavailable states, scope, and play/seek
    ///   eligibility (`search_results_v1`). Until then the server falls back to
    ///   deterministic short `token` text plus `done`.
    ///
    /// This is a RENDERER capability and nothing more. Whether the client may CLAIM app
    /// operations is a separate question, owned by the operation admission path and, for any
    /// future v1 advertisement, a separately reviewed slice built from that turn's own
    /// authenticated acquisition. Gating this on a principal was out of scope here.
    static func advertised(rendersStructuredResults: Bool,
                           appOperationSupport: CloudAppOperationSupport? = nil) -> [String] {
        var capabilities = rendersStructuredResults ? [searchResultsV1] : []
        // app_operations_v1 rides ONLY alongside a well-formed support manifest; absence of
        // either key preserves today's exact wire shape (search_results_v1 is independent).
        if appOperationSupport != nil {
            capabilities.append(appOperationsV1)
        }
        return capabilities
    }
}

/// The `app_operation_support` object the owning contract (trainer-reduced-local-scope
/// @ 818c8f75, cloud-assistant.md "App-operation protocol v1") requires alongside
/// `app_operations_v1`: exact, unique `tool.action` keys the client fully implements —
/// validation, execution, result observation AND durable replay handling.
/// FAIL CLOSED: a manifest that cannot be constructed exactly is no manifest at all —
/// `init?` returns nil, which grants no operations and serializes neither key. It never
/// traps and never silently repairs (drops duplicates, trims) a malformed list.
struct CloudAppOperationSupport: Equatable {
    static let schemaVersion = "app-ops/1"

    let operations: [String]

    init?(operations: [String]) {
        guard !operations.isEmpty else { return nil }
        var seen = Set<String>()
        for operation in operations {
            // EXACT `tool.action` SHAPE, no trimming or repair: exactly one separator, both
            // segments non-empty, and no whitespace anywhere IN the key. A key that only
            // looks close ("playback..pause", "play back.pause", "a.b.c", " .pause") is
            // malformed — nil, which grants no operations.
            let segments = operation.split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count == 2,
                  !segments[0].isEmpty, !segments[1].isEmpty,
                  !operation.contains(where: { $0.isWhitespace }),
                  seen.insert(operation).inserted else { return nil }
        }
        self.operations = operations
    }

    func supports(tool: String, action: String) -> Bool {
        operations.contains("\(tool).\(action)")
    }

    /// The NATIVE JSON shape the authenticate serializer writes. JSONSerialization cannot
    /// encode the `CloudRouteJSONValue` enum, so the frame carries plain Foundation values.
    var nativeValue: [String: Any] {
        ["schema_version": Self.schemaVersion, "operations": operations]
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
        turn: CloudTurnEnvelope,
        sourceTranscript: String? = nil,
        sourceLanguage: String? = nil
    ) -> [String: Any] {
        // SOURCE-FIRST RUNTIME REQUEST (core b6eafe25): the runtime `request` carries the complete
        // wake-trimmed SOURCE utterance when one is available — the English routing translation
        // selects the action but never REPLACES the original the model answers. When no original
        // exists (backend translate exposes English only), the available text is used without
        // fabricating an original.
        let runtimeRequest = sourceTranscript?.isEmpty == false ? sourceTranscript! : request
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
            "request": runtimeRequest,
            "context": contextObject,
            // The turn's ONE identity: the admitted utterance id the envelope was built with.
            // A retry of the same logical turn must present the same `request_id`, so minting
            // a fresh one here would make the server see a second logical turn.
            "request_id": turn.requestId,
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
        // Omitted with the token when there is no support manifest: the server's fallback is
        // the absence of the capability, so an empty declaration must not degrade the frame.
        // PAIRING IS ENFORCED, FAIL CLOSED: support without the `app_operations_v1` token is
        // dropped — a manifest the frame does not declare must never leak onto the wire. The
        // reverse mismatch (token, no support) serializes nothing: without the required
        // support object the contract grants no operations, so the token rides alone only in
        // that explicitly broken construction and is tested as such.
        if let appOperationSupport = turn.appOperationSupport,
           turn.capabilities.contains(CloudClientCapabilities.appOperationsV1) {
            payload["app_operation_support"] = appOperationSupport.nativeValue
        }
        // OPTIONAL source_language: the ASR pipeline's actual LID when it detected one. Unknown
        // is OMITTED, never invented (not the OS locale, not a default "en"): the wire field's
        // whole value is that it states what the pipeline measured. Preserves yue vs zh.
        if let sourceLanguage, !sourceLanguage.isEmpty {
            payload["source_language"] = sourceLanguage
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
