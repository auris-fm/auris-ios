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

    /// Transport the route turn uses.
    ///
    /// The voice turn is **WebSocket-only**: a failed upgrade is a terminal turn
    /// failure, never an automatic SSE fallback. `sse` is an explicit selection
    /// of the spec's stated POST path — chosen deliberately, never picked up
    /// after a WebSocket failure.
    enum Transport {
        case webSocket
        case sse
    }
    private let transport: Transport

    /// Optional seam for the WebSocket task (see `WebSocketTasking`); `nil`
    /// uses the session's real web socket.
    private let webSocketTaskFactory: ((URLRequest) -> WebSocketTasking)?

    /// Codecs advertised to the server in the authenticate frame.
    ///
    /// PCM only. `CloudAudioPlayer` copies frames as raw Int16 PCM and has no
    /// Opus decoder, so advertising `opus@48k` would claim a capability the
    /// client cannot back — the server could pick it and send frames we cannot
    /// play, which surfaces as "speech is broken" rather than "the client lied".
    /// Add `opus@48k` here only together with a real Opus decoder and the
    /// matching entry in `CloudAudioPlayer.decodableCodecs` (see
    /// `testAdvertisedCodecsAreDecodableByThePlayer`).
    static let supportedCodecs = ["pcm_s16le@24k"]

    /// The rate of the codec this client advertises, used until the server's
    /// `connected` frame names the negotiated one.
    static let advertisedPCMasterRateHz: Double = 24_000

    /// Seam for the WebSocket task so tests can drive the transport the app
    /// actually uses. `URLProtocol` stubs only the URL loading system, which
    /// `URLSessionWebSocketTask` does not go through, so without this the
    /// production path has no test behind it.
    protocol WebSocketTasking: AnyObject {
        func send(_ message: URLSessionWebSocketTask.Message) async throws
        func receive() async throws -> URLSessionWebSocketTask.Message
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    }

    init(
        baseURL: String,
        userId: String,
        session: URLSession? = nil,
        requestTimeoutSeconds: TimeInterval = CloudRouteClient.defaultTimeoutSeconds,
        tokenProvider: CloudTokenProviding? = nil,
        transport: Transport = .webSocket,
        webSocketTaskFactory: ((URLRequest) -> WebSocketTasking)? = nil
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.userId = userId
        // Seam (slice 5, design-only): the credential comes from one place so the
        // trusted-issuer swap (task #26) is a provider change. Default preserves
        // today's trust-on-first-use bearer exactly.
        self.tokenProvider = tokenProvider ?? CloudStaticIdentityTokenProvider()
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.transport = transport
        self.webSocketTaskFactory = webSocketTaskFactory
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
                switch self.transport {
                case .webSocket:
                    await self.performRoute(request: request, context: context, turn: turn, continuation: continuation)
                case .sse:
                    await self.performSSE(request: request, context: context, turn: turn, continuation: continuation)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Transport selection

    /// Drives the voice turn over the selected transport.
    ///
    /// The default is WebSocket (no-fallbacks principle): a failed upgrade is a
    /// terminal turn failure with a visible error, never a silent degradation.
    /// The POST transport is reachable only by explicit selection (see
    /// `Transport`) — it is never entered automatically after a WebSocket
    /// failure.
    private func performRoute(
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope,
        continuation: AsyncStream<CloudRouteEvent>.Continuation
    ) async {
        switch transport {
        case .webSocket:
            // `performWebSocket` always terminates the stream itself — on
            // success or with a delivered error — so there is nothing left to
            // fall back to.
            _ = await performWebSocket(request: request, context: context, turn: turn, continuation: continuation)
        case .sse:
            await performSSE(request: request, context: context, turn: turn, continuation: continuation)
        }
    }

    // MARK: - WebSocket implementation

    /// Drives the turn over the WebSocket and always terminates the stream —
    /// either with the turn's events or with a delivered error. The return value
    /// is always `true`; it is kept for the caller's shape.
    private func performWebSocket(
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope,
        continuation: AsyncStream<CloudRouteEvent>.Continuation
    ) async -> Bool {
        guard let url = Self.webSocketURL(baseURL: baseURL, path: Self.routePath) else {
            continuation.yield(.error(code: "invalid_request", message: ""))
            continuation.finish()
            return true
        }

        // Build the authentication frame (cloud-assistant.md).
        guard let authFrame = await Self.buildAuthFrame(
            tokenProvider: self.tokenProvider,
            request: request,
            context: context,
            turn: turn
        ) else {
            // No credential: fail closed with the same terminal event the SSE
            // path and `main` yield, so the sink can speak/earcon the failure.
            // Finishing silently left the user with no error and no outcome.
            continuation.yield(.error(code: "unauthorized", message: ""))
            continuation.finish()
            return true
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = requestTimeoutSeconds
        let wsTask: WebSocketTasking = webSocketTaskFactory?(req) ?? session.webSocketTask(with: req)

        // Close the socket whenever this call returns, on every path. The
        // stream's `onTermination` cancels only the surrounding Swift task, so
        // without this a superseded turn leaves the socket open and the server
        // generating and streaming an answer the user abandoned (billed, and
        // the connection held until the server's own idle timeout).
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        do {
            // Send authentication frame. The task's text message is a String,
            // so the frame is serialized to JSON text here.
            let authJSON = try JSONSerialization.data(withJSONObject: authFrame)
            guard let authText = String(data: authJSON, encoding: .utf8) else {
                continuation.yield(.error(code: "invalid_request", message: ""))
                continuation.finish()
                return true
            }
            try await wsTask.send(.string(authText))

            var sawTerminalEvent = false

            // First-frame timeout: server must respond within 5 seconds.
            //
            // The task must not finish the stream once it has been cancelled:
            // cancellation is how a received frame says "the deadline was met",
            // and `Task.sleep` throwing on cancel would otherwise fall through
            // to `finish()` and truncate the turn's remaining events.
            let firstFrameTimeout = Task {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return // cancelled: a frame arrived, the main loop owns the stream
                }
                if !sawTerminalEvent {
                    continuation.yield(.error(code: "connection_lost", message: ""))
                    continuation.finish()
                }
            }

            receiveLoop: while true {
                let message = try await wsTask.receive()
                // Cancel the timeout on first frame.
                firstFrameTimeout.cancel()

                switch message {
                case .data(let data):
                    // Binary frame: audio payload.
                    continuation.yield(.audioFrame(CloudAudioFrame(data: data)))

                case .string(let string):
                    // Text frame: JSON event. One event per text frame.
                    for event in Self.parseTextFrame(string) {
                        continuation.yield(event)
                        // A terminal event ends the turn: the server closes the
                        // connection after `done`/`error`, so continuing to
                        // receive would turn that normal close into a spurious
                        // `connection_lost` after a successful answer.
                        if case .done = event { sawTerminalEvent = true; break receiveLoop }
                        if case .error = event { sawTerminalEvent = true; break receiveLoop }
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
            return true

        } catch is CancellationError {
            continuation.finish()
            return true
        } catch {
            if Task.isCancelled {
                continuation.finish()
                return true
            }
            continuation.yield(
                .error(code: "connection_lost", message: (error as NSError).localizedDescription)
            )
            continuation.finish()
            return true
        }
    }

    // MARK: - SSE fallback

    /// Fallback SSE stream (POST /api/v1/cloud/route).
    ///
    /// Used when WebSocket is not supported or the upgrade fails.
    /// Uses a custom delegate to stream data chunk-by-chunk.
    private func performSSE(
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope,
        continuation: AsyncStream<CloudRouteEvent>.Continuation
    ) async {
        guard let url = Self.sseURL(baseURL: baseURL, path: Self.routePath) else {
            continuation.yield(.error(code: "invalid_request", message: ""))
            continuation.finish()
            return
        }

        let bodyData = Self.buildPostBody(request: request, context: context, turn: turn)

        // Fail closed before dialing: a turn with no credential sends nothing
        // and reports the same `unauthorized` code the server would return, so
        // the user gets one line either way.
        guard let credential = await tokenProvider.token() else {
            continuation.yield(.error(code: "unauthorized", message: ""))
            continuation.finish()
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = requestTimeoutSeconds
        req.httpBody = bodyData

        // Streaming SSE delegate reads chunks incrementally. The delegate's
        // session is built from the injected session's configuration so an
        // injected protocol class (tests) still intercepts the request;
        // `.default` here would quietly bypass it.
        let sseDelegate = SSESSEStreamingDelegate(
            request: req,
            continuation: continuation,
            timeout: requestTimeoutSeconds,
            onUnauthorized: { [tokenProvider] in
                await tokenProvider.handleUnauthorized(rejectedToken: credential)
            }
        )
        // Rebuild the configuration so the injected session's protocol classes
        // (test stubs) survive: URLSession copies its configuration, and a
        // configuration without them would dial the network for real.
        let sseConfig = URLSessionConfiguration.ephemeral
        sseConfig.protocolClasses = session.configuration.protocolClasses
        sseConfig.timeoutIntervalForRequest = session.configuration.timeoutIntervalForRequest
        sseConfig.timeoutIntervalForResource = session.configuration.timeoutIntervalForResource
        let sseSession = URLSession(
            configuration: sseConfig,
            delegate: sseDelegate,
            delegateQueue: nil
        )
        let task = sseSession.dataTask(with: req)
        task.resume()
    }

    // MARK: - URL construction

    private static func sseURL(baseURL: String, path: String) -> URL? {
        let scheme = baseURL.hasPrefix("https://") ? "https://" : "http://"
        let host = baseURL.hasPrefix(scheme) ? String(baseURL.dropFirst(scheme.count)) : baseURL
        return URL(string: scheme + host + path)
    }

    // MARK: - Auth frame

    private static func buildAuthFrame(
        tokenProvider: CloudTokenProviding,
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope
    ) async -> [String: Any]? {
        guard let credential = await tokenProvider.token() else {
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
                "arguments": Self.encodeJSONValues(routeHint.arguments),
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

    // MARK: - SSE body builder

    private static func buildPostBody(
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope
    ) -> Data {
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
            "request": request,
            "request_id": turn.requestId,
            "context": contextObject,
        ]
        if !turn.capabilities.isEmpty {
            payload["capabilities"] = turn.capabilities
        }
        if let routeHint = turn.routeHint {
            payload["route_hint"] = [
                "operation": routeHint.operation,
                "arguments": Self.encodeJSONValues(routeHint.arguments),
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return Data()
        }
        return data
    }

    // MARK: - Text frame parsing

    /// Parse a complete text frame (one JSON event) from the WebSocket.
    ///
    /// The server sends one JSON event per text frame — no multi-line
    /// accumulation needed.
    /// Parses one text frame into the events it carries. Internal so the
    /// parser tests can exercise it directly.
    static func parseTextFrame(_ text: String) -> [CloudRouteEvent] {
        guard let raw = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else {
            return []
        }

        guard let type = json["type"] as? String else { return [] }

        switch type {
        case "connected":
            // The negotiated codec decides how the binary frames are decoded:
            // `pcm_s16le@24k` means raw 16-bit PCM at 24 kHz. Dropping it left
            // the player guessing a rate from the output hardware.
            guard let name = json["codec"] as? String,
                  let codec = CloudAudioCodec(name: name)
            else { return [] }
            return [.connected(codec: codec)]

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

    static func parseDone(json: [String: Any]) -> CloudTurnUsage {
        // Usage normally arrives nested under `usage`. Older SSE frames put the
        // two token counts at the top level; accept both so neither transport's
        // fixtures silently lose their counts.
        guard let usage = json["usage"] as? [String: Any] else {
            return CloudTurnUsage(
                inputTokens: intValue(json["input_tokens"]),
                outputTokens: intValue(json["output_tokens"])
            )
        }
        let inputTokens = intValue(usage["input_tokens"])
        let outputTokens = intValue(usage["output_tokens"])

        var speech: CloudSpeechUsage? = nil
        if let speechData = usage["speech"] as? [String: Any] {
            let amount = intValue(speechData["amount"])
            let unit = speechData["unit"] as? String ?? ""
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
            // The `done` payload carries usage under `usage` on the wire (see
            // `parseDone`). Parse it the same way here so both transports agree.
            return .done(usage: CloudRouteClient.parseDone(json: json))
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

extension CloudRouteClient {
    /// Encodes typed JSON values into the `[String: Any]` shape
    /// `JSONSerialization` accepts.
    static func encodeJSONValues(_ values: [String: CloudRouteJSONValue]) -> [String: Any] {
        values.mapValues { encodeJSONValue($0) }
    }

    static func encodeJSONValue(_ value: CloudRouteJSONValue) -> Any {
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

// MARK: - SSE Streaming Delegate

/// URLSession delegate that streams SSE data chunk-by-chunk for the fallback path.
private final class SSESSEStreamingDelegate: NSObject, URLSessionDataDelegate {
    private let request: URLRequest
    private let continuation: AsyncStream<CloudRouteEvent>.Continuation
    private let timeout: TimeInterval
    private var parser = CloudRouteSSEParser()
    private var sawTerminal = false
    private var buffer = Data()
    private let deadline: Date
    private var hasError = false
    private var httpResponseStatusCode: Int = 200
    /// Called once, after the stream ends, when the server refused the
    /// credential presented for this turn. The client owns the provider, so the
    /// delegate reports rather than acting.
    private let onUnauthorized: (@Sendable () async -> Void)?

    init(
        request: URLRequest,
        continuation: AsyncStream<CloudRouteEvent>.Continuation,
        timeout: TimeInterval,
        onUnauthorized: (@Sendable () async -> Void)? = nil
    ) {
        self.request = request
        self.continuation = continuation
        self.timeout = timeout
        self.deadline = Date().addingTimeInterval(timeout)
        self.onUnauthorized = onUnauthorized
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        httpResponseStatusCode = httpResponse.statusCode
        if (400...499).contains(httpResponse.statusCode) {
            // Will yield pre-stream error after reading body.
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard Date() < deadline else { return }
        buffer.append(data)

        // Process only complete lines: everything up to and including the last
        // `\n`. A trailing partial line stays buffered until its newline
        // arrives. Splitting this way preserves the *empty* lines that delimit
        // SSE events, which `split` would drop — without them the parser never
        // dispatches an event.
        guard let lastNewline = buffer.lastIndex(of: UInt8(10)) else { return }
        let complete = buffer[buffer.startIndex...lastNewline]
        buffer = Data(buffer[buffer.index(after: lastNewline)...])

        for rawLine in complete.split(separator: UInt8(10), omittingEmptySubsequences: false) {
            let lineStr = String(bytes: rawLine, encoding: .utf8) ?? ""
            for event in parser.consume(line: lineStr) {
                continuation.yield(event)
                if case .done = event { sawTerminal = true }
                if case .error = event { sawTerminal = true }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if !hasError {
                continuation.yield(.error(code: "connection_lost", message: ""))
            }
            continuation.finish()
            return
        }

        // Handle HTTP error body.
        if httpResponseStatusCode == 401 {
            // Report the rejected credential for recovery. Detached: the spec's
            // `unauthorized` row owes one refresh, and the caller is handed its
            // error first so recovery can never delay the user's feedback.
            if let onUnauthorized {
                Task.detached { await onUnauthorized() }
            }
            continuation.yield(CloudRouteClient.preStreamError(status: httpResponseStatusCode, body: Data(buffer)))
            continuation.finish()
            return
        }
        if (400...499).contains(httpResponseStatusCode) {
            continuation.yield(CloudRouteClient.preStreamError(status: httpResponseStatusCode, body: Data(buffer)))
            continuation.finish()
            return
        }

        // Finalize any remaining data.
        for event in parser.finish() {
            continuation.yield(event)
        }

        if !sawTerminal {
            continuation.yield(.error(code: "connection_lost", message: ""))
        }
        continuation.finish()
    }
}


// The real task satisfies the seam unchanged.
extension URLSessionWebSocketTask: CloudRouteClient.WebSocketTasking {}
