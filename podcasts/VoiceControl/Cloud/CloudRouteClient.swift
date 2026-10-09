import Foundation

/// WebSocket client for `GET /api/v1/cloud/route`.
///
/// Sends an authentication frame, then streams binary audio frames and JSON
/// text events (`connected`, `action`, `token`, `result`, `done`, `error`) until
/// a terminal event or connection close.
///
/// All six are parsed because the wire defines all six. Two are easy to omit
/// from a summary and both matter: `connected` names the codec the binary frames
/// are decoded at, and `token` is an event the parser used to drop — a
/// wire-fidelity fix rather than a user-visible one, since the sink plays answers
/// instead of speaking them (`CloudRouteSink`). The list is kept current with the
/// dispatch rather than paraphrased.
///
/// WebSocket is the only transport: a failed upgrade is a terminal turn
/// failure with a visible error, never a silent fallback. (The legacy SSE path
/// was retired — no back compatibility is maintained.)
final class CloudRouteClient {
    static let routePath = "/api/v1/cloud/route"
    /// Must sit above the server's 5s first-event budget (cloud-assistant.md).
    static let defaultTimeoutSeconds: TimeInterval = 15

    private let baseURL: String
    private let userId: String
    private let tokenProvider: CloudTokenProviding
    private let session: URLSession
    let requestTimeoutSeconds: TimeInterval

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
        webSocketTaskFactory: ((URLRequest) -> WebSocketTasking)? = nil
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.userId = userId
        // Seam (slice 5, design-only): the credential comes from one place so the
        // trusted-issuer swap (task #26) is a provider change. Default preserves
        // today's trust-on-first-use bearer exactly.
        self.tokenProvider = tokenProvider ?? CloudStaticIdentityTokenProvider()
        self.requestTimeoutSeconds = requestTimeoutSeconds
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
                await self.performWebSocket(request: request, context: context, turn: turn, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
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
            // No credential: fail closed with a terminal event, so the sink can
            // speak/earcon the failure. Finishing silently would leave the user
            // with no error and no outcome.
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

            // Written by the receive loop and read by the timeout task, so the
            // flag is lock-protected rather than a plain `Bool` shared across
            // tasks.
            let terminalFlag = TerminalFlag()

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
                if !terminalFlag.isSet {
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
                        if case .done = event { terminalFlag.set(); break receiveLoop }
                        if case .error = event { terminalFlag.set(); break receiveLoop }
                    }

                default:
                    break
                }
            }

            // WebSocket closed.
            if !terminalFlag.isSet {
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
            // A transport failure is the same user-facing fact as a socket
            // that closed without a terminal event (above), so it carries the
            // same code and *no* message. The `localizedDescription` that used
            // to ride here is an English URLSession diagnostic — and the sink
            // speaks a non-empty message verbatim, so it reached the user as
            // English prose in whatever locale they had set, instead of the
            // localized template or the error earcon.
            continuation.yield(.error(code: "connection_lost", message: ""))
            continuation.finish()
            return true
        }
    }

    // MARK: - Auth frame

    /// Builds the WebSocket authenticate frame.
    ///
    /// The envelope comes from `CloudRouteRequestBuilder` — the same builder the
    /// contract tests pin — so the frame the app sends and the frame the tests
    /// assert on are one construction rather than two that can drift.
    private static func buildAuthFrame(
        tokenProvider: CloudTokenProviding,
        request: String,
        context: CloudRouteContext,
        turn: CloudTurnEnvelope
    ) async -> [String: Any]? {
        guard let credential = await tokenProvider.token() else {
            return nil
        }
        var frame = CloudRouteRequestBuilder.envelope(request: request, context: context, turn: turn)
        // Transport-specific fields: the credential rides the first frame, and
        // the codecs are advertised here so the server negotiates the binary
        // frame format up front.
        frame["type"] = "authenticate"
        frame["access_token"] = credential
        frame["codecs"] = Self.supportedCodecs
        return frame
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

    /// True when a `result` frame's payload cannot be a supported discovery
    /// payload: unparseable JSON, no `kind`, or a supported `kind` with a
    /// missing or malformed `scope`/`items` shape. Unknown kinds are *not*
    /// malformed — they are forward-compatible and ignored.
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

    /// Parses one text frame into the events it carries.
    ///
    /// The server sends one JSON event per text frame — no multi-line
    /// accumulation is needed. Internal so the parser tests can exercise it
    /// directly.
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

        case "token":
            // `token` rides the **socket**: the Worker's `lifecycle.ts` calls
            // `sendVisible("token", { text })` on the live WebSocket. Without this
            // case the frame fell to `default: return []`, so the parser dropped
            // an event the wire defines.
            guard let text = json["text"] as? String else { return [] }
            return [.token(text)]

        case "result":
            // Parity with the reviewed Android behaviour (PR #19): a malformed
            // payload on a *known* event is a surfaced `invalid_response`, not a
            // silently dropped frame. An unknown `kind` stays forward-compatible
            // and is ignored. This guard lived in the retired SSE parser; the
            // contract it enforced rides the socket too.
            if isMalformedResultPayload(text) {
                return [.error(code: "invalid_response", message: "")]
            }
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
        // Usage arrives nested under `usage` (`worker/src/protocol/frames.ts`).
        // The counts have one shape on the wire, so there is no top-level
        // fallback. Rejecting a second shape is not itself a detection: a frame
        // without `usage` parses to unknown counts, which the analytics path
        // then omits — the detection is the regression test, not this parse.
        let usage = json["usage"] as? [String: Any] ?? [:]
        let inputTokens = intValue(usage["input_tokens"])
        let outputTokens = intValue(usage["output_tokens"])

        var speech: CloudSpeechUsage? = nil
        if let speechData = usage["speech"] as? [String: Any] {
            // `CloudSpeechUsage` owns the validity rule (a unit-less amount is
            // not a usable record), so the parse does not restate it — a second
            // check here is how the two drift apart.
            let amount = intValue(speechData["amount"])
            let unit = speechData["unit"] as? String ?? ""
            speech = CloudSpeechUsage(amount: amount, unit: unit)
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

// MARK: - JSON value decoding

/// Turns parsed JSON back into `CloudRouteJSONValue`, for the events this file
/// parses. The *encoding* half lives in `CloudRouteRequestBuilder`, which is the
/// only caller that needs it, so this extension is decode-only and local to this
/// file.
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

// The real task satisfies the seam unchanged.
extension URLSessionWebSocketTask: CloudRouteClient.WebSocketTasking {}

/// A one-way flag shared between the receive loop and the first-frame timeout
/// task. Plain cross-task `Bool` access is a data race; this is the smallest
/// thing that is not.
private final class TerminalFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}
