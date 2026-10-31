import Foundation

/// The codec the server negotiated in its `connected` frame, with the sample
/// rate parsed from the codec name (the wire carries no separate rate field).
///
/// The bytes of every binary frame are in this codec at this rate, so the
/// player must build its buffer at this rate rather than at the output
/// hardware's — a 24 kHz stream played through a 48 kHz buffer is double-speed.
struct CloudAudioCodec: Equatable {
    /// The codec as negotiated, e.g. `pcm_s16le@24k`.
    let name: String
    /// Base codec name without the rate suffix, e.g. `pcm_s16le`.
    let base: String
    /// Negotiated sample rate in Hz, when the name carries one.
    let sampleRateHz: Double?

    init?(name: String) {
        guard !name.isEmpty else { return nil }
        self.name = name
        if let at = name.lastIndex(of: "@") {
            let base = String(name[name.startIndex..<at])
            let suffix = String(name[name.index(after: at)...]).lowercased()
            self.base = base.isEmpty ? name : base
            if suffix.hasSuffix("k"), let value = Double(suffix.dropLast()) {
                self.sampleRateHz = value * 1000
            } else if let value = Double(suffix) {
                self.sampleRateHz = value
            } else {
                self.sampleRateHz = nil
            }
        } else {
            self.base = name
            self.sampleRateHz = nil
        }
    }
}

/// Audio frame carrying synthesised speech from the cloud server.
struct CloudAudioFrame: Equatable {
    /// Raw audio payload in the codec negotiated in the `connected` frame.
    ///
    /// This client advertises `pcm_s16le@24k` only (see
    /// `CloudRouteClient.supportedCodecs`) and plays the bytes as raw Int16
    /// PCM; there is no Opus decoder in this path. The sample rate is encoded
    /// in the negotiated codec name — the wire has no separate rate field.
    let data: Data
    /// Ephemeral diagnostic metadata only; nil unless explicitly enabled in a Debug build.
    var timingReceipt: CloudPlaybackTiming.Receipt? = nil
}

/// Usage reported in the `done` frame (cloud-assistant.md).
struct CloudTurnUsage: Equatable {
    /// Model input tokens; `nil` when the provider completed without reporting.
    let inputTokens: Int?
    /// Model output tokens; `nil` when the provider completed without reporting.
    let outputTokens: Int?
    /// Speech synthesis usage. `nil` when the frame carried no usable record —
    /// an absent `speech` object, or one with no unit (see
    /// `CloudSpeechUsage.init?`). A provider failure is not nil: the server
    /// reports it as `amount: null` with `unit: "unavailable"`, which is
    /// information and is kept. `amount` may also be zero (explicitly no usage).
    let speech: CloudSpeechUsage?

    init(inputTokens: Int? = nil, outputTokens: Int? = nil, speech: CloudSpeechUsage? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.speech = speech
    }
}

/// Speech synthesis usage reported in the `done` frame.
struct CloudSpeechUsage: Equatable {
    /// Amount of speech produced; `nil` when unavailable.
    let amount: Int?
    /// Unit string (e.g. "ms", "samples", "tokens").
    let unit: String

    /// A usage record with no unit cannot be interpreted (the amount means
    /// nothing without one), so it is not a usable record: an empty unit is
    /// treated as absent rather than carried as a value nobody can read.
    init?(amount: Int?, unit: String) {
        guard !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.amount = amount
        self.unit = unit
    }
}

/// Events from the cloud WebSocket route (cloud-assistant.md).
/// The origin of a `CloudRouteEvent.error`.
enum CloudRouteErrorSource: String, Equatable {
    /// The client could not CONSTRUCT the request (bad URL, unencodable frame). The frame never left.
    case requestConstruction
    /// The TRANSFER failed or the connection dropped. The frame may or may not have been admitted.
    case transport
    /// An error FRAME parsed from the server.
    case server
}

enum CloudRouteEvent: Equatable {
    /// Server handshake: the codec selected for this turn's audio frames.
    case connected(codec: CloudAudioCodec)
    /// Binary audio frame from the server's speech synthesiser.
    case audioFrame(CloudAudioFrame)
    /// Server-directed action. App operations carry `operationId`/`capabilityVersion` (wire
    /// contract rev da327e624); existing local-path holds carry neither and parse as nils.
    ///
    /// `actionBytes` are the action frame's serialized UTF-8 bytes EXACTLY as received: replay
    /// identity is byte equality (cloud-assistant.md @ bf5fb219), so re-serializing parsed
    /// parts would lose the identity the server can reproduce. Nil only for events a test
    /// constructs directly, which then carry no replay identity.
    case action(tool: String, action: String, params: [String: CloudRouteJSONValue],
                operationId: String?, capabilityVersion: String?,
                actionBytes: Data? = nil, precondition: [String: CloudRouteJSONValue] = [:],
                // A request whose identity is intact but whose parameters do not match its
                // action. It is still DELIVERED, so the operation can be settled with the honest
                // refusal instead of vanishing; the sink must refuse before any effect.
                parameterViolation: AppOperationRequest.ParameterViolation? = nil)
    /// Text token the Worker sends on the socket. It rides the live transport
    /// rather than a retired one; the sink plays answers as audio instead of
    /// accumulating text, so this is parsed and then intentionally unused.
    case token(String)
    /// Negotiated structured discovery result (only when client advertised
    /// `search_results_v1`).
    case result(DiscoveryResult)
    /// Terminal success: answer model finished, final audio delivered.
    case done(usage: CloudTurnUsage)
    /// Terminal error.
    /// WHERE the error originated, carried STRUCTURALLY so a consumer never has to infer it from the
    /// message text. Text sniffing misclassifies: a server could legitimately send a message that looks
    /// like a client tag, and a client tag could be reworded.
    case error(source: CloudRouteErrorSource, code: String, message: String)
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

    /// The string this value carries, if it is one. Action parameters arrive
    /// from the wire as `CloudRouteJSONValue`, so reading one as a string has to
    /// go through the enum — `as? String` on the wrapper always fails, which is
    /// how a direction-only `seek_relative` silently lost its direction.
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The string this value carries when it is usable as an IDENTITY (a non-empty string).
    /// Blank is not an identity, so it yields nil exactly like an absent field.
    var identityValue: String? {
        guard case let .string(value) = self, !value.isEmpty else { return nil }
        return value
    }

    /// True when this value is the JSON kind a declared parameter requires.
    ///
    /// The cases are already separated (`.int`/`.double`/`.bool` are distinct), which is the whole
    /// point: decoding kept them apart, so validation can refuse a string where an integer is
    /// declared WITHOUT any coercion being possible in the first place.
    func matches(_ parameter: AppOperationRequest.ActionParameter) -> Bool {
        switch (self, parameter) {
        case (.int, .integer), (.double, .number), (.int, .number), (.string, .string):
            return true
        case let (.string(value), .enumerated(allowed)):
            // A closed set: the string must be one of the declared values, exactly.
            return allowed.contains(value)
        case let (.string(value), .identity):
            return !value.isEmpty
        default:
            // Includes `.bool` for every declared type: a boolean is never a number or a string,
            // however readily `NSNumber` would let it masquerade as one.
            return false
        }
    }

    /// Total decoder from Foundation JSON (journal persistence of a settled state). Returns nil
    /// for shapes this build does not model — callers treat nil as unreadable history, never as
    /// an invented value.
    init?(json: Any) {
        // BOOLEANS FIRST, AS NSNumber. `JSONSerialization` bridges every JSON scalar to
        // `NSNumber`, and `NSNumber(true)` also satisfies `as Int` — so the obvious
        // String/Int/Double/Bool order silently turns a persisted `true` into `.int(1)`. A
        // settled state read back from the journal would then disagree with the frame that was
        // sent for it. `CFGetTypeID` is the supported way to tell the two apart.
        if let number = json as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
            return
        }
        switch json {
        case let v as String: self = .string(v)
        case let v as Int: self = .int(Int64(v))
        case let v as Int64: self = .int(v)
        case let v as Double: self = .double(v)
        case is NSNull: self = .null
        case let dict as [String: Any]:
            var decoded: [String: CloudRouteJSONValue] = [:]
            for (key, value) in dict {
                guard let item = CloudRouteJSONValue(json: value) else { return nil }
                decoded[key] = item
            }
            self = .object(decoded)
        case let arr as [Any]:
            var decoded: [CloudRouteJSONValue] = []
            for value in arr {
                guard let item = CloudRouteJSONValue(json: value) else { return nil }
                decoded.append(item)
            }
            self = .array(decoded)
        default:
            return nil
        }
    }

    /// Plain Foundation JSON for outbound frame encoding (`app_operation_result` state).
    func toJSONSerializable() -> Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .null: return NSNull()
        case .object(let dict): return dict.mapValues { $0.toJSONSerializable() }
        case .array(let arr): return arr.map { $0.toJSONSerializable() }
        }
    }

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
    /// Absent when no current episode exists. Nil rather than empty: an empty id names nothing
    /// but still reads as a supplied value, and the contract forbids inventing one.
    let episodeId: String?
    let podcastId: String?
    let referencePositionMs: Int64?
    /// Absent when there is no current episode to have a position in.
    let clientPositionMs: Int64?
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
        episodeId: String?,
        podcastId: String? = nil,
        referencePositionMs: Int64? = nil,
        clientPositionMs: Int64?,
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
