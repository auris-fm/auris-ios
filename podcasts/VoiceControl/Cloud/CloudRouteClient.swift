import Foundation

/// SSE client for `POST /api/v1/cloud/route`.
///
/// Pre-stream HTTP failures (400/401) and mid-stream failures surface as a single
/// `.error` event so callers can handle all outcomes uniformly. Cancellation cancels
/// the underlying `URLSession` task and closes the byte stream.
final class CloudRouteClient {
    static let routePath = "/api/v1/cloud/route"
    /// Must sit above the server's 5s first-event budget (cloud-assistant.md).
    static let defaultTimeoutSeconds: TimeInterval = 15

    private let baseURL: String
    private let userId: String
    private let tokenProvider: CloudTokenProviding
    private let session: URLSession
    let requestTimeoutSeconds: TimeInterval

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

    private func performRoute(
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope,
        continuation: AsyncStream<CloudRouteEvent>.Continuation
    ) async {
        guard let url = URL(string: baseURL + Self.routePath) else {
            continuation.yield(.error(code: "invalid_request", message: ""))  // code only: a non-empty message is spoken by TTS (see the fail-closed guard above)
            continuation.finish()
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        // Fail closed when a credential provider yields nothing (parity with the
        // Android half): no credential ⇒ no turn, rather than sending a hopeful
        // bearer. The default provider always returns the trust-on-first-use id,
        // so today's behavior is unchanged.
        guard let credential = await tokenProvider.token() ?? nonEmpty(userId) else {
            // No human-readable message: `CloudRouteSink` speaks any non-empty
            // `.error` message through TTS in the user's locale, so a diagnostic
            // English string here would be read aloud to a non-English user.
            // The code carries the diagnosis; the sink maps an empty message to
            // its localized error earcon (review finding on PR #19).
            continuation.yield(.error(code: "unauthorized", message: ""))
            continuation.finish()
            return
        }
        urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = requestTimeoutSeconds

        do {
            urlRequest.httpBody = try CloudRouteRequestBuilder.body(request: request, context: context, turn: turn)
        } catch {
            continuation.yield(.error(code: "invalid_request", message: ""))
            continuation.finish()
            return
        }

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                continuation.yield(.error(code: "connection_lost", message: ""))
                continuation.finish()
                return
            }

            if !(200..<300).contains(http.statusCode) {
                var errorBody = Data()
                for try await byte in bytes {
                    errorBody.append(byte)
                    if errorBody.count > 4096 { break }
                }
                continuation.yield(Self.preStreamError(status: http.statusCode, body: errorBody))
                continuation.finish()
                return
            }

            var parser = CloudRouteSSEParser()
            var sawTerminalEvent = false
            do {
                var residual = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    residual.append(byte)
                    while let newline = residual.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = residual.subdata(in: residual.startIndex..<newline)
                        residual.removeSubrange(residual.startIndex...newline)
                        let line = String(data: lineData, encoding: .utf8) ?? ""
                        for event in parser.consume(line: line) {
                            if case .done = event { sawTerminalEvent = true }
                            if case .error = event { sawTerminalEvent = true }
                            continuation.yield(event)
                        }
                    }
                }
                if !residual.isEmpty {
                    let line = String(data: residual, encoding: .utf8) ?? ""
                    for event in parser.consume(line: line) {
                        if case .done = event { sawTerminalEvent = true }
                        if case .error = event { sawTerminalEvent = true }
                        continuation.yield(event)
                    }
                }
                for event in parser.finish() {
                    if case .done = event { sawTerminalEvent = true }
                    if case .error = event { sawTerminalEvent = true }
                    continuation.yield(event)
                }
                if !sawTerminalEvent {
                    // Code only: the user hears a localized earcon rather than an
                    // English sentence (reachable on any mid-stream drop).
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
                    .error(
                        code: "connection_lost",
                        message: (error as NSError).localizedDescription
                    )
                )
                continuation.finish()
            }
        } catch is CancellationError {
            continuation.finish()
        } catch {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(
                .error(
                    code: "connection_lost",
                    message: (error as NSError).localizedDescription
                )
            )
            continuation.finish()
        }
    }

    private func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    static func preStreamError(status: Int, body: Data) -> CloudRouteEvent {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = (parsed?["code"] as? String)
            ?? (parsed?["error"] as? String)
            ?? httpStatusCode(status)
        // A server-supplied message is passed through (its localisation is the
        // server's); a synthesized default stays empty so the client never
        // invents English prose for TTS.
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

/// Incremental SSE frame parser (`event:` / multi-line `data:` / blank-line dispatch).
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

    /// True when a `result` payload is structurally invalid (valid JSON, but not
    /// a usable result object). Unknown `kind` values are *not* malformed — they
    /// are forward-compatible and ignored.
    private static func isMalformedResultPayload(_ data: String) -> Bool {
        guard let raw = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else {
            return true
        }
        if object["kind"] == nil { return true }
        if let kind = object["kind"] as? String, kind != DiscoveryResult.supportedKind {
            return false // unknown kind: forward-compatible, ignored
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
            // Malformed payload on a known event is a server bug: surface it as
            // the standard payload-failure error (parity with the other events
            // and with Android's reviewed behavior). Unknown *kinds* stay
            // forward-compatible and are ignored.
            guard !isMalformedResultPayload(data) else {
                // No human-readable message, same reason as the fail-closed guard
                // below: `CloudRouteSink` speaks any non-empty `.error` message via
                // TTS in the user's locale, so an internal diagnostic must not be
                // English prose (PR #19 review, follow-up).
                return .error(code: "invalid_response", message: "")
            }
            guard let result = DiscoveryResult.parse(json: data) else { return nil }
            return .result(result)
        case "done":
            let input = intValue(json["input_tokens"]) ?? 0
            let output = intValue(json["output_tokens"]) ?? 0
            return .done(inputTokens: input, outputTokens: output)
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

extension CloudRouteJSONValue {
    static func from(_ any: Any?) -> CloudRouteJSONValue {
        switch any {
        case nil, is NSNull: return .null
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let n as NSNumber:
            // Distinguish Bool (NSNumber subclass) already handled; prefer Int64 when integral.
            let d = n.doubleValue
            // Strict upper bound: Double(Int64.max) rounds up to 2^63, and
            // int64Value on that magnitude is implementation-defined.
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
