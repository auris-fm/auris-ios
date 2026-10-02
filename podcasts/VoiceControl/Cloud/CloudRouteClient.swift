import Foundation

/// WebSocket client for `GET /api/v1/cloud/route`.
///
/// Sends an authentication frame, then streams binary audio frames and JSON
/// text events (action, result, done, error) until a terminal event or
/// connection close.
///
/// The `CloudRouteSSEParser` struct is retained for the pre-stream error
/// parsing path and for any legacy SSE compatibility; the primary path is
/// WebSocket.
final class CloudRouteClient {
    static let routePath = "/api/v1/cloud/route"
    /// Must sit above the server's 5s first-event budget (cloud-assistant.md).
    static let defaultTimeoutSeconds: TimeInterval = 15

    private let baseURL: String
    private let userId: String
    private let tokenProvider: CloudTokenProviding
    private let session: URLSession
    let requestTimeoutSeconds: TimeInterval

    /// Supported codecs (client offers both; server picks one in `connected`).
    static let supportedCodecs = ["opus@48k", "pcm_s16le@24k"]

    init(
        baseURL: String,
        userId: String,
        session: URLSession? = nil,
        requestTimeoutSeconds: TimeInterval = CloudRouteClient.defaultTimeoutSeconds,
        tokenProvider: CloudTokenProviding? = nil
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.userId = userId
        // Seam (slice 5, design-only): the credential comes from one place so the
        // trusted-issuer swap (task #26) is a provider change. Default preserves
        // today's trust-on-first-use bearer exactly.
        self.tokenProvider = tokenProvider ?? CloudStaticIdentityTokenProvider()
        self.requestTimeoutSeconds = requestTimeoutSeconds
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = requestTimeoutSeconds
            config.timeoutIntervalForResource = max(60, requestTimeoutSeconds * 4)
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Public API

    /// Streams route events until `done`/`error` or connection close.
    ///
    /// A fresh `CloudTurnEnvelope` is minted per call — callers that issue
    /// transport retries for the same logical turn must pass the envelope they
    /// built for that turn so `request_id` stays stable (see `route(request:context:turn:)`).
    func route(request: String, context: CloudRouteContext) -> AsyncStream<CloudRouteEvent> {
        route(
            request: request,
            context: context,
            turn: CloudTurnEnvelope.make(capabilities: [], routeHint: nil, recentConversation: [])
        )
    }

    /// Streams route events for one logical turn.
    ///
    /// `turn.requestId` is client-assigned and must be reused across transport
    /// attempts of the same turn: the server uses it with the verified user id
    /// for admission/deduplication, so a retry that minted a new id would be
    /// admitted as a second turn.
    func route(
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope
    ) -> AsyncStream<CloudRouteEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.performRoute(request: request, context: context, turn: turn, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - WebSocket implementation

    private func performRoute(
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope,
        continuation: AsyncStream<CloudRouteEvent>.Continuation
    ) async {
        guard let url = Self.webSocketURL(baseURL: baseURL, path: Self.routePath) else {
            continuation.yield(.error(code: "invalid_request", message: ""))
            continuation.finish()
            return
        }

        // Build the authentication frame (cloud-assistant.md).
        guard let authFrame = Self.buildAuthFrame(
            request: request,
            context: context,
            turn: turn
        ) else {
            continuation.finish()
            return
        }

        let wsTask = session.webSocketTask(for: url)
        wsTask.timeout.interval = requestTimeoutSeconds

        do {
            // Send authentication frame.
            try await wsTask.send(.string(authFrame))

            var sawTerminalEvent = false

            // First-frame timeout: server must respond within 5 seconds.
            let firstFrameTimeout = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !sawTerminalEvent {
                    continuation.yield(.error(code: "connection_lost", message: ""))
                }
                continuation.finish()
            }

            while case let .message(message)? = try await wsTask.receive() {
                // Cancel the timeout on first frame.
                firstFrameTimeout.cancel()

                switch message {
                case .data(let data):
                    // Binary frame: audio payload.
                    continuation.yield(.audioFrame(CloudAudioFrame(data: data)))

                case .string(let string):
                    // Text frame: JSON event. One event per text frame.
                    for event in Self.parseTextFrame(string) {
                        if case .done = event { sawTerminalEvent = true }
                        if case .error = event { sawTerminalEvent = true }
                        continuation.yield(event)
                    }

                default:
                    break
                }
            }

            // WebSocket closed.
            if !sawTerminalEvent {
                continuation.yield(.error(code: "connection_lost", message: ""))
            }
            continuation.finish()

        } catch is CancellationError {
            continuation.finish()
        } catch {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(
                .error(code: "connection_lost", message: (error as NSError).localizedDescription)
            )
            continuation.finish()
        }
    }

    // MARK: - Auth frame

    private static func buildAuthFrame(
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope
    ) -> [String: Any]? {
        guard let credential = CloudTokenProviderRouter.provider().token() else {
            return nil
        }
        var contextObject: [String: Any] = [
            "episode_id": context.episodeId,
            "client_position_ms": context.clientPositionMs,
            "recent_reference_positions": context.recentReferencePositions,
        ]
        if let podcastId = context.podcastId { contextObject["podcast_id"] = podcastId }
        if let referencePositionMs = context.referencePositionMs {
            contextObject["reference_position_ms"] = referencePositionMs
        }
        if let previousReferencePositionMs = context.previousReferencePositionMs {
            contextObject["previous_reference_position_ms"] = previousReferencePositionMs
        }
        if !turn.recentConversation.isEmpty {
            contextObject["recent_conversation"] = turn.recentConversation.map {
                ["role": $0.role.rawValue, "text": $0.text]
            }
        }

        var payload: [String: Any] = [
            "type": "authenticate",
            "access_token": credential,
            "request_id": turn.requestId,
            "request": request,
            "context": contextObject,
            "codecs": Self.supportedCodecs,
        ]
        if !turn.capabilities.isEmpty {
            payload["capabilities"] = turn.capabilities
        }
        if let routeHint = turn.routeHint {
            payload["route_hint"] = [
                "operation": routeHint.operation,
                "arguments": CloudRouteRequestBuilder.encodeJSONValues(routeHint.arguments),
            ]
        }
        return payload
    }

    // MARK: - URL construction

    private static func webSocketURL(baseURL: String, path: String) -> URL? {
        let wsBase = baseURL.hasPrefix("https://")
            ? "wss://" + baseURL.dropFirst("https://".count)
            : baseURL.hasPrefix("http://")
                ? "ws://" + baseURL.dropFirst("http://".count)
                : "wss://" + baseURL
        return URL(string: wsBase + path)
    }

    // MARK: - Text frame parsing

    /// Parse a complete text frame (one JSON event) from the WebSocket.
    ///
    /// The server sends one JSON event per text frame — no multi-line
    /// accumulation needed.
    private static func parseTextFrame(_ text: String) -> [CloudRouteEvent] {
        guard let raw = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else {
            return []
        }

        guard let type = json["type"] as? String else { return [] }

        switch type {
        case "connected":
            return []

        case "action":
            guard let tool = json["tool"] as? String,
                  let action = json["action"] as? String
            else { return [] }
            let params = (json["params"] as? [String: Any])
                .map { CloudRouteJSONValue.object(from: $0) } ?? [:]
            return [.action(tool: tool, action: action, params: params)]

// No token event on the WebSocket contract (cloud-assistant.md):
        // text frames are connected, action, result, done, error only.
        // The SSE path (retained below) still carries token events for
        // backward compatibility during the pre-enablement window.

        case "result":
            guard let result = DiscoveryResult.parse(json: text) else { return [] }
            return [.result(result)]

        case "done":
            let usage = parseDone(json: json)
            return [.done(usage: usage)]

        case "error":
            guard let code = json["code"] as? String,
                  let message = json["message"] as? String
            else { return [] }
            return [.error(code: code, message: message)]

        default:
            return []
        }
    }

    private static func parseDone(json: [String: Any]) -> CloudTurnUsage {
        guard let usage = json["usage"] as? [String: Any] else {
            return CloudTurnUsage()
        }
        let inputTokens = intValue(usage["input_tokens"])
        let outputTokens = intValue(usage["output_tokens"])

        var speech: CloudSpeechUsage? = nil
        if let speechData = usage["speech"] as? [String: Any] {
            let amount = intValue(speechData["amount"])
            let unit = speechData["unit"] as? ?? ""
            if !unit.isEmpty {
                speech = CloudSpeechUsage(amount: amount, unit: unit)
            }
        }
        return CloudTurnUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            speech: speech
        )
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }
}

// MARK: - SSE parser (retained for pre-stream error parsing)

/// Incremental SSE frame parser (`event:` / multi-line `data:` / blank-line dispatch).
///
/// Retained because `preStreamError` parses HTTP error bodies and the
/// pre-stream error path is still used for non-WebSocket transports.
struct CloudRouteSSEParser {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(line: String) -> [CloudRouteEvent] {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if trimmed.isEmpty {
            let events = dispatch()
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
            return events
        }
        if trimmed.hasPrefix(":") {
            return []
        }
        if trimmed.hasPrefix("event:") {
            eventName = trimmed.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            return []
        }
        if trimmed.hasPrefix("data:") {
            var value = String(trimmed.dropFirst("data:".count))
            if value.hasPrefix(" ") {
                value = String(value.dropFirst())
            }
            dataLines.append(value)
        }
        return []
    }

    mutating func finish() -> [CloudRouteEvent] {
        guard eventName != nil || !dataLines.isEmpty else { return [] }
        let events = dispatch()
        eventName = nil
        dataLines.removeAll()
        return events
    }

    private func dispatch() -> [CloudRouteEvent] {
        let data = dataLines.joined(separator: "\n")
        guard !data.isEmpty, let eventName else { return [] }
        guard let event = Self.parse(eventName: eventName, data: data) else { return [] }
        return [event]
    }

    private static func isMalformedResultPayload(_ data: String) -> Bool {
        guard let raw = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else {
            return true
        }
        if object["kind"] == nil { return true }
        if let kind = object["kind"] as? String, kind != DiscoveryResult.supportedKind {
            return false
        }
        return object["scope"] is String == false || object["items"] is [[String: Any]] == false
    }

    static func parse(eventName: String, data: String) -> CloudRouteEvent? {
        guard let raw = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else {
            return nil
        }

        switch eventName {
        case "action":
            guard let tool = json["tool"] as? String,
                  let action = json["action"] as? String
            else { return nil }
            let params = (json["params"] as? [String: Any]).map(CloudRouteJSONValue.object(from:)) ?? [:]
            return .action(tool: tool, action: action, params: params)
        case "token":
            guard let text = json["text"] as? String else { return nil }
            return .token(text)
        case "result":
            guard !isMalformedResultPayload(data) else {
                return .error(code: "invalid_response", message: "")
            }
            guard let result = DiscoveryResult.parse(json: data) else { return nil }
            return .result(result)
        case "done":
            // Old SSE path: input/output tokens were non-nullable.
            // The SSE parser is retained for legacy error handling;
            // the new WebSocket path uses parseDone() above.
            let input = intValue(json["input_tokens"]) ?? 0
            let output = intValue(json["output_tokens"]) ?? 0
            let usage = CloudTurnUsage(inputTokens: input, outputTokens: output)
            return .done(usage: usage)
        case "error":
            guard let code = json["code"] as? String,
                  let message = json["message"] as? String
            else { return nil }
            return .error(code: code, message: message)
        default:
            return nil
        }
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }
}

// MARK: - Pre-stream error (HTTP failures)

extension CloudRouteClient {
    static func preStreamError(status: Int, body: Data) -> CloudRouteEvent {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = (parsed?["code"] as? String)
            ?? (parsed?["error"] as? String)
            ?? httpStatusCode(status)
        let message = (parsed?["message"] as? String) ?? ""
        return .error(code: code, message: message)
    }

    private static func httpStatusCode(_ status: Int) -> String {
        switch status {
        case 400: return "invalid_request"
        case 401: return "unauthorized"
        default: return "http_\(status)"
        }
    }
}

// MARK: - JSON value encoding (shared with CloudTurnEnvelope)

extension CloudRouteJSONValue {
    static func from(_ any: Any?) -> CloudRouteJSONValue {
        switch any {
        case nil, is NSNull: return .null
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let n as NSNumber:
            let d = n.doubleValue
            if d.rounded() == d, d >= Double(Int64.min), d < Double(Int64.max) {
                return .int(n.int64Value)
            }
            return .double(d)
        case let dict as [String: Any]:
            return .object(object(from: dict))
        case let arr as [Any]:
            return .array(arr.map { from($0) })
        default:
            return .string(String(describing: any!))
        }
    }

    static func object(from dict: [String: Any]) -> [String: CloudRouteJSONValue] {
        var result: [String: CloudRouteJSONValue] = [:]
        for (key, value) in dict {
            result[key] = from(value)
        }
        return result
    }
}
