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
}

/// Usage reported in the `done` frame (cloud-assistant.md).
struct CloudTurnUsage: Equatable {
    /// Model input tokens; `nil` when the provider completed without reporting.
    let inputTokens: Int?
    /// Model output tokens; `nil` when the provider completed without reporting.
    let outputTokens: Int?
    /// Speech synthesis usage; `nil` when the provider failed before reporting
    /// an amount. `amount` may also be zero (explicitly no usage).
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
}

/// Events from the cloud WebSocket route (cloud-assistant.md).
enum CloudRouteEvent: Equatable {
    /// Server handshake: the codec selected for this turn's audio frames.
    case connected(codec: CloudAudioCodec)
    /// Binary audio frame from the server's speech synthesiser.
    case audioFrame(CloudAudioFrame)
    /// Server-directed local action (seek, pause, etc.).
    case action(tool: String, action: String, params: [String: CloudRouteJSONValue])
    /// Text token — retained for backward-compatibility; cloud answers
    /// are played as audio, not accumulated text.
    case token(String)
    /// Negotiated structured discovery result (only when client advertised
    /// `search_results_v1`).
    case result(DiscoveryResult)
    /// Terminal success: answer model finished, final audio delivered.
    case done(usage: CloudTurnUsage)
    /// Terminal error.
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
