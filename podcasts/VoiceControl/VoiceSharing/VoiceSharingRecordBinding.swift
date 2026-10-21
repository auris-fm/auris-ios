import CryptoKit
import Foundation

/// The canonical wire-record and WAV authorities this repository's upload contract is defined
/// against (docs/specs/voice-recording-uploads.md §"HTTPS request and wire identity").
///
/// Why a real implementation rather than a permissive parse: the queue must decide whether a
/// persisted entry is THE immutable record it will transmit. A partial check (digest of one field,
/// or "it looks like JSON") cannot answer that — two payloads a lenient parser collapses would
/// share an identity, and an entry whose bytes differ from its declared digest is not the record
/// it claims to be. So this mirrors the server-side authorities (worker `canonical_json.ts`,
/// `record_schema.ts`, `wav_validate.ts`) and REFUSES anything it cannot represent exactly:
/// duplicate keys, non-finite numbers, missing/unknown fields, wrong WAV representation.
///
/// Descriptions are deliberately short here; the normative rules live in the spec and the server
/// implementations, and the controls in VoiceSharingUploadQueueTests pin the refusals.
enum VoiceSharingRecordBinding {

    enum BindingError: Error, Equatable {
        case malformedJSON(String)
        case duplicateKey(String)
        case nonFiniteNumber(String)
        case missingField(String)
        case unknownField(String, String)
        case invalidField(String, String)
        case digestMismatch
        case audioDigestMismatch
        case audioSizeMismatch
        case invalidAudio(String)
    }

    /// Result of validating a persisted envelope against its audio bytes.
    struct BoundEntry: Equatable {
        let captureID: String
        let enrollmentEpoch: String
        let recordSHA256: String
        let audioSHA256: String
        let audioByteCount: Int
    }

    // MARK: Public binding entry point

    /// Validates `envelope` (UTF-8 JSON of `{record, record_sha256}`) against `audio`, returning the
    /// identity the queue will rely on, or throwing the first reason it does not bind.
    static func bind(envelope: Data, audio: Data) throws -> BoundEntry {
        let value = try parseRefusingDuplicates(envelope)
        guard let object = value as? [String: Any] else {
            throw BindingError.malformedJSON("envelope is not an object")
        }
        guard let recordValue = object["record"] else { throw BindingError.missingField("record") }
        guard let declaredSHA = object["record_sha256"] as? String else {
            throw BindingError.missingField("record_sha256")
        }
        for key in object.keys where key != "record" && key != "record_sha256" {
            throw BindingError.unknownField("envelope", key)
        }
        guard let record = recordValue as? [String: Any] else {
            throw BindingError.malformedJSON("record is not an object")
        }
        try validateRecordShape(record)

        // record_sha256 binds the whole record: recompute over the canonical form.
        let canonical = try canonicalize(record)
        let computed = sha256Hex(canonical)
        guard computed == declaredSHA else { throw BindingError.digestMismatch }

        guard let audioBlock = record["audio"] as? [String: Any] else {
            throw BindingError.missingField("audio")
        }
        guard let declaredAudioSHA = audioBlock["sha256"] as? String else {
            throw BindingError.missingField("audio.sha256")
        }
        guard let declaredByteCount = audioBlock["byte_count"] as? Int else {
            throw BindingError.missingField("audio.byte_count")
        }

        // Audio identity: the real bytes must be the bytes the record declares, AND those bytes
        // must be the one documented representation.
        let actualAudioSHA = sha256Hex(audio)
        guard actualAudioSHA == declaredAudioSHA else { throw BindingError.audioDigestMismatch }
        guard audio.count == declaredByteCount else { throw BindingError.audioSizeMismatch }
        try validateWAV(audio)

        guard let captureID = record["capture_id"] as? String, UUID(uuidString: captureID) != nil else {
            throw BindingError.invalidField("record.capture_id", "UUID required")
        }
        guard let epoch = record["enrollment_epoch"] as? String, !epoch.isEmpty else {
            throw BindingError.invalidField("record.enrollment_epoch", "non-empty string required")
        }

        return BoundEntry(captureID: captureID, enrollmentEpoch: epoch,
                          recordSHA256: computed, audioSHA256: actualAudioSHA,
                          audioByteCount: audio.count)
    }

    // MARK: Record shape

    private static let requiredTopLevel: Set<String> = [
        "schema_version", "capture_id", "enrollment_epoch", "platform", "app_version", "build",
        "capture_session_id", "audio", "models", "observations",
    ]
    /// `links` is the only optional top-level group; feedback is intentionally NOT accepted
    /// (a record must hash identically before and after annotation).
    private static let optionalTopLevel: Set<String> = ["links"]

    private static func validateRecordShape(_ record: [String: Any]) throws {
        for key in record.keys where !requiredTopLevel.contains(key) && !optionalTopLevel.contains(key) {
            throw BindingError.unknownField("record", key)
        }
        for key in requiredTopLevel where record[key] == nil {
            throw BindingError.missingField("record.\(key)")
        }
        guard let schemaVersion = record["schema_version"] as? Int, schemaVersion == 1 else {
            throw BindingError.invalidField("record.schema_version", "must be 1")
        }
        for key in ["platform", "app_version", "build", "capture_session_id"] {
            guard let string = record[key] as? String, !string.isEmpty else {
                throw BindingError.invalidField("record.\(key)", "non-empty string required")
            }
        }
        guard let audioBlock = record["audio"] as? [String: Any] else {
            throw BindingError.missingField("record.audio")
        }
        try validateAudioBlock(audioBlock)
        guard let models = record["models"] as? [String: Any], !models.isEmpty else {
            throw BindingError.invalidField("record.models", "non-empty object required")
        }
        guard let observations = record["observations"] as? [String: Any], !observations.isEmpty else {
            throw BindingError.invalidField("record.observations", "non-empty object required")
        }
        if let links = record["links"] {
            guard let linksObject = links as? [String: Any] else {
                throw BindingError.invalidField("record.links", "object required")
            }
            let allowed: Set<String> = ["conversation_id", "request_id", "operation_id", "turn_id"]
            for key in linksObject.keys where !allowed.contains(key) {
                throw BindingError.unknownField("record.links", key)
            }
        }
    }

    private static let requiredAudioFields: Set<String> = [
        "sha256", "byte_count", "encoding", "sample_rate_hz", "channels", "retained_samples",
        "original_format", "conversion_version", "truncated", "dropped_spans",
    ]

    private static func validateAudioBlock(_ audio: [String: Any]) throws {
        for key in audio.keys where !requiredAudioFields.contains(key) && key != "original_duration_ms" {
            throw BindingError.unknownField("record.audio", key)
        }
        for key in requiredAudioFields where audio[key] == nil {
            throw BindingError.missingField("record.audio.\(key)")
        }
        guard let sha = audio["sha256"] as? String,
            sha.count == 64, sha.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw BindingError.invalidField("record.audio.sha256", "lowercase hex SHA-256 required")
        }
        guard let byteCount = audio["byte_count"] as? Int, byteCount > 0 else {
            throw BindingError.invalidField("record.audio.byte_count", "positive integer required")
        }
        guard let encoding = audio["encoding"] as? String, encoding == "pcm_s16le" else {
            throw BindingError.invalidField("record.audio.encoding", "pcm_s16le required")
        }
        guard let sampleRate = audio["sample_rate_hz"] as? Int, sampleRate == 16_000 else {
            throw BindingError.invalidField("record.audio.sample_rate_hz", "16000 required")
        }
        guard let channels = audio["channels"] as? Int, channels == 1 else {
            throw BindingError.invalidField("record.audio.channels", "1 required")
        }
        guard let retainedSamples = audio["retained_samples"] as? Int, retainedSamples >= 0 else {
            throw BindingError.invalidField("record.audio.retained_samples", "non-negative integer required")
        }
        guard let truncated = audio["truncated"] as? Bool else {
            throw BindingError.invalidField("record.audio.truncated", "boolean required")
        }
        guard let droppedSpans = audio["dropped_spans"] as? [[String: Any]] else {
            throw BindingError.invalidField("record.audio.dropped_spans", "array of spans required")
        }
        for span in droppedSpans {
            guard let start = span["start_sample"] as? Int, let end = span["end_sample"] as? Int,
                start >= 0, end >= start
            else {
                throw BindingError.invalidField("record.audio.dropped_spans", "half-open sample intervals required")
            }
        }
        if truncated, audio["original_duration_ms"] == nil {
            throw BindingError.missingField("record.audio.original_duration_ms")
        }
    }

    // MARK: WAV representation

    /// The documented training representation only: PCM16, mono, 16 kHz. Every value is READ from
    /// the header and compared; nothing is defaulted or inferred from a `.wav` name, and the
    /// duration comes from bytes actually present (the declared size is what an interrupted
    /// prepare lies about).
    private static func validateWAV(_ data: Data) throws {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> UInt16? {
            guard offset + 2 <= bytes.count else { return nil }
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        func tag(_ offset: Int) -> String? {
            guard offset + 4 <= bytes.count else { return nil }
            return String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
        }

        guard tag(0) == "RIFF", tag(8) == "WAVE" else { throw BindingError.invalidAudio("malformed_header:RIFF/WAVE") }
        guard u32(4) != nil else { throw BindingError.invalidAudio("malformed_header:declared size") }

        var offset = 12
        var sawFormat = false
        var sawData = false
        while offset + 8 <= bytes.count {
            guard let chunkID = tag(offset), let chunkSize = u32(offset + 4) else {
                throw BindingError.invalidAudio("malformed_header:chunk")
            }
            let bodyStart = offset + 8
            switch chunkID {
            case "fmt ":
                guard chunkSize >= 16, bodyStart + 16 <= bytes.count else {
                    throw BindingError.invalidAudio("malformed_header:fmt")
                }
                guard let formatTag = u16(bodyStart), formatTag == 1 else {
                    throw BindingError.invalidAudio("unsupported_format: PCM required")
                }
                guard let channels = u16(bodyStart + 2), channels == 1 else {
                    throw BindingError.invalidAudio("unsupported_format: mono required")
                }
                guard let sampleRate = u32(bodyStart + 4), sampleRate == 16_000 else {
                    throw BindingError.invalidAudio("unsupported_format: 16000 Hz required")
                }
                guard let bits = u16(bodyStart + 14), bits == 16 else {
                    throw BindingError.invalidAudio("unsupported_format: 16-bit required")
                }
                sawFormat = true
            case "data":
                // Duration comes from bytes ACTUALLY present, not the declared chunk size.
                let available = bytes.count - bodyStart
                guard available > 0 else { throw BindingError.invalidAudio("truncated_body:data") }
                if Int(chunkSize) > available {
                    throw BindingError.invalidAudio("truncated_body:declared \(chunkSize) present \(available)")
                }
                guard sawFormat else { throw BindingError.invalidAudio("malformed_header:data before fmt") }
                sawData = true
            default:
                break
            }
            if sawData { break }
            offset = bodyStart + Int(chunkSize) + (Int(chunkSize) % 2)
        }
        guard sawFormat else { throw BindingError.invalidAudio("malformed_header:no fmt chunk") }
        guard sawData else { throw BindingError.invalidAudio("malformed_header:no data chunk") }
    }

    // MARK: RFC 8785 canonicalization

    /// Canonical JSON per RFC 8785: object members sorted by UTF-16 code unit, no insignificant
    /// whitespace, numbers in the ECMAScript form. Values it cannot represent exactly are refused.
    static func canonicalize(_ value: Any) throws -> String {
        var output = ""
        try writeCanonical(value, into: &output)
        return output
    }

    private static func writeCanonical(_ value: Any, into output: inout String) throws {
        switch value {
        case let string as String:
            try writeCanonicalString(string, into: &output)
        case let number as NSNumber:
            try writeCanonicalNumber(number, into: &output)
        case let array as [Any]:
            output += "["
            for (index, element) in array.enumerated() {
                if index > 0 { output += "," }
                try writeCanonical(element, into: &output)
            }
            output += "]"
        case let object as [String: Any]:
            output += "{"
            for (index, key) in sortedKeys(object.keys).enumerated() {
                if index > 0 { output += "," }
                try writeCanonicalString(key, into: &output)
                output += ":"
                try writeCanonical(object[key]!, into: &output)
            }
            output += "}"
        case is NSNull:
            output += "null"
        default:
            throw BindingError.malformedJSON("unsupported value")
        }
    }

    /// RFC 8785 sorts member names by UTF-16 code units (not by Unicode code points).
    private static func sortedKeys<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        keys.sorted { lhs, rhs in
            let left = Array(lhs.utf16), right = Array(rhs.utf16)
            for index in 0..<min(left.count, right.count) where left[index] != right[index] {
                return left[index] < right[index]
            }
            return left.count < right.count
        }
    }

    private static func writeCanonicalString(_ string: String, into output: inout String) throws {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{8}": output += "\\b"
            case "\u{C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    /// Numbers: ECMAScript serialization (shortest round-trip form; integers without a fraction).
    private static func writeCanonicalNumber(_ number: NSNumber, into output: inout String) throws {
        let double = number.doubleValue
        guard double.isFinite else { throw BindingError.nonFiniteNumber("number") }
        if double == double.rounded(), abs(double) < 1e21 {
            output += String(format: "%.0f", double)
        } else {
            output += "\(double)"
        }
    }

    // MARK: Parsing

    /// Parses JSON refusing duplicate keys and non-finite numbers — the two collapses a lenient
    /// parser would silently accept and thereby let a different record share one digest.
    private static func parseRefusingDuplicates(_ data: Data) throws -> Any {
        guard let text = String(data: data, encoding: .utf8) else {
            throw BindingError.malformedJSON("not UTF-8")
        }
        try scanForDuplicateKeys(text)
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw BindingError.malformedJSON(String(describing: error))
        }
        try assertFinite(value, path: "")
        return value
    }

    private static func assertFinite(_ value: Any, path: String) throws {
        if let number = value as? NSNumber, !isBoolean(number), !number.doubleValue.isFinite {
            throw BindingError.nonFiniteNumber(path.isEmpty ? "root" : path)
        }
        if let object = value as? [String: Any] {
            for (key, element) in object {
                try assertFinite(element, path: path.isEmpty ? key : "\(path).\(key)")
            }
        }
        if let array = value as? [Any] {
            for (index, element) in array.enumerated() {
                try assertFinite(element, path: "\(path)[\(index)]")
            }
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Tracks JSON string state so a brace or repeated word inside a string is never treated as a
    /// member name; compares member names within one object scope only.
    private static func scanForDuplicateKeys(_ text: String) throws {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var scopes: [[String]] = []
        var expectingKey: [Bool] = []

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                var cursor = index + 1
                var literal = ""
                while cursor < scalars.count {
                    let current = scalars[cursor]
                    if current == "\\" {
                        if cursor + 1 < scalars.count { literal.append(Character(scalars[cursor + 1])) }
                        cursor += 2
                        continue
                    }
                    if current == "\"" { break }
                    literal.append(Character(current))
                    cursor += 1
                }
                let afterString = cursor + 1
                var lookahead = afterString
                while lookahead < scalars.count, scalars[lookahead] == " " || scalars[lookahead] == "\n"
                    || scalars[lookahead] == "\t" || scalars[lookahead] == "\r" {
                    lookahead += 1
                }
                if let top = scopes.indices.last, expectingKey[top],
                    lookahead < scalars.count, scalars[lookahead] == ":" {
                    if scopes[top].contains(literal) {
                        throw BindingError.duplicateKey(literal)
                    }
                    scopes[top].append(literal)
                    expectingKey[top] = false
                }
                index = afterString
                continue
            }
            if scalar == "{" {
                scopes.append([])
                expectingKey.append(true)
            } else if scalar == "}" {
                if !scopes.isEmpty { scopes.removeLast(); expectingKey.removeLast() }
            } else if scalar == "," {
                if let top = expectingKey.indices.last { expectingKey[top] = true }
            } else if scalar == ":" {
                if let top = expectingKey.indices.last { expectingKey[top] = false }
            } else if scalar == "[" || scalar == "]" {
                // Arrays carry no member names; keys inside them belong to their own objects.
                if let top = expectingKey.indices.last { expectingKey[top] = false }
            }
            index += 1
        }
    }

    private static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}