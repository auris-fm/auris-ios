import Foundation

/// The schema-version-1 record sent as the `metadata` part of an upload.
///
/// Plain `Codable` JSON from a normal encoder: the server parses and validates the fields, so
/// nothing here depends on exact bytes. There are no digests and no canonical form — a field the
/// server does not need is not carried, and an absent optional member is simply absent.
struct VoiceSharingRecord: Encodable, Equatable {
    struct Audio: Encodable, Equatable {
        /// Exact WAV byte count, which the server compares against the `audio` part.
        var byteCount: Int
        var encoding: String
        var sampleRateHz: Int
        var channels: Int
        var retainedSamples: Int
        var originalFormat: String
        var conversionVersion: String
        var truncated: Bool
        var droppedSpans: [DroppedSpan]

        struct DroppedSpan: Encodable, Equatable {
            var startSample: Int
            var endSample: Int
        }

        enum CodingKeys: String, CodingKey {
            case byteCount = "byte_count"
            case encoding
            case sampleRateHz = "sample_rate_hz"
            case channels
            case retainedSamples = "retained_samples"
            case originalFormat = "original_format"
            case conversionVersion = "conversion_version"
            case truncated
            case droppedSpans = "dropped_spans"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(byteCount, forKey: .byteCount)
            try c.encode(encoding, forKey: .encoding)
            try c.encode(sampleRateHz, forKey: .sampleRateHz)
            try c.encode(channels, forKey: .channels)
            try c.encode(retainedSamples, forKey: .retainedSamples)
            try c.encode(originalFormat, forKey: .originalFormat)
            try c.encode(conversionVersion, forKey: .conversionVersion)
            try c.encode(truncated, forKey: .truncated)
            try c.encode(droppedSpans, forKey: .droppedSpans)
        }
    }

    struct ModelRef: Encodable, Equatable {
        var id: String
        var version: String
    }

    struct Models: Encodable, Equatable {
        var vad: ModelRef?
        var wakeword: ModelRef?
        var asr: ModelRef?
        var translation: ModelRef?
        var router: ModelRef?
    }

    /// One stage's real outcome. `state` is the schema's enumerated state; the remaining members are
    /// present only when that stage actually produced them.
    struct Observation: Encodable, Equatable {
        var state: String
        var reason: String?
        var text: String?
        var decision: String?
        var score: Double?
        var threshold: Double?
        var translatedText: String?
        var targetLanguage: String?
        var sourceLanguage: String?
        var routingDisposition: String?

        enum CodingKeys: String, CodingKey {
            case state, reason, text, decision, score, threshold
            case translatedText = "translated_text"
            case targetLanguage = "target_language"
            case sourceLanguage = "source_language"
            case routingDisposition = "routing_disposition"
        }
    }

    var schemaVersion: Int = 1
    var captureID: String
    var enrollmentEpoch: String
    var platform: String
    var appVersion: String
    var build: String
    var captureSessionID: String
    /// The client's real grace state when the segment started.
    var wakeRequired: Bool
    var audio: Audio
    var models: Models
    var observations: [String: Observation]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case captureID = "capture_id"
        case enrollmentEpoch = "enrollment_epoch"
        case platform
        case appVersion = "app_version"
        case build
        case captureSessionID = "capture_session_id"
        case wakeRequired = "wake_required"
        case audio, models, observations
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(captureID, forKey: .captureID)
        try c.encode(enrollmentEpoch, forKey: .enrollmentEpoch)
        try c.encode(platform, forKey: .platform)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(build, forKey: .build)
        try c.encode(captureSessionID, forKey: .captureSessionID)
        try c.encode(wakeRequired, forKey: .wakeRequired)
        try c.encode(audio, forKey: .audio)
        try c.encode(models, forKey: .models)
        try c.encode(observations, forKey: .observations)
    }

    /// The bytes written to `metadata.json`. Sorted keys keep the file stable for a human reading a
    /// queue folder; the server does not depend on it.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}