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
        case audioSampleCountMismatch(declared: Int, actual: Int)
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
    /// Test-only entry point to the SAME canonicalizer the digest uses, so a test that mutates a record
    /// can re-seal it and be rejected for the rule under test rather than for a stale digest.
    static func canonicalizeForTesting(_ record: [String: Any]) throws -> Data {
        Data(try canonicalize(record).utf8)
    }

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
        let wav = try validateWAV(audio)

        // retained_samples is a claim about the audio; compare it with the samples actually present
        // rather than accepting a number that describes a different recording.
        guard let retainedSamples = audioBlock["retained_samples"] as? Int else {
            throw BindingError.missingField("audio.retained_samples")
        }
        guard retainedSamples == wav.sampleCount else {
            throw BindingError.audioSampleCountMismatch(declared: retainedSamples, actual: wav.sampleCount)
        }

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
        guard let models = record["models"] as? [String: Any] else {
            throw BindingError.invalidField("record.models", "object required")
        }
        try validateModels(models)
        guard let observations = record["observations"] as? [String: Any] else {
            throw BindingError.invalidField("record.observations", "object required")
        }
        try validateObservations(observations)
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

    // MARK: Nested model/observation schema

    /// The five model slots the record declares; absence of a model is `null`, never a missing key.
    private static let modelKeys = ["vad", "wakeword", "asr", "translation", "router"]

    private static let observationStages = ["wake", "bleed", "asr", "translation", "routing", "execution"]

    private static let observationStates: Set<String> = ["completed", "not_run", "failed", "cancelled", "unknown"]

    /// Reasons are ENUMERATED per stage. An arbitrary sentence is where stack traces and file paths
    /// enter the dataset, so a free-form reason is refused rather than stored.
    /// Reasons valid at ANY non-completed state on every stage (spec delta 736d3180):
    /// `observation_unavailable` states that normal execution supplied no trustworthy observation
    /// by finalization. It is allowed ONLY with `state: "unknown"` — it asserts nothing about
    /// whether the stage ran, so pairing it with a known outcome would attach a non-claim to a
    /// claim. The pairing rule is enforced below, not by mere membership here.
    private static let anyStateReasons: Set<String> = ["observation_unavailable"]

    /// A reason that names a REAL observed failure rather than an absence of observation (spec 9578b16,
    /// reviewer 6c3fed9b). `detector_error` is what the wake detector actually reported when it failed, so
    /// it must survive into the durable record — but only as the exact wake+failed pairing it describes.
    /// Attaching it to any other stage, or to `completed`, would assert a failure that did not happen.
    private static let detectorErrorReason = "detector_error"

    /// A recognition that SUCCEEDED and produced no usable text (spec delta c6f3bdf7). This is the one
    /// reason that describes `completed`: the recogniser ran and returned nothing, which is a real result,
    /// not a failure and not an absence of observation. It is valid ONLY on ASR, ONLY with `completed`, and
    /// ONLY with both `text` and `router_input` absent — a stage that produced no text cannot have produced
    /// a router input, and carrying either would contradict the reason it is declaring.
    private static let emptyResultReason = "empty_result"

    /// The engine names this reason when a recognition succeeded and returned nothing usable. Exposed so
    /// the producer and the validator cannot drift to two spellings of the same fact.
    static let emptyResultReasonForEngine = "empty_result"

    private static let stageReasons: [String: Set<String>] = [
        "wake": ["no_wake_detected", "below_threshold", "detector_disabled", "outcome_wait_expired"],
        "bleed": ["no_playback_reference", "reference_unavailable", "bleed_detector_disabled", "outcome_wait_expired"],
        "asr": ["local_only_action", "rejected_by_wake", "provider_error", "outcome_wait_expired", "cancelled_by_user"],
        "translation": ["source_language_target_language", "no_text", "provider_error", "outcome_wait_expired"],
        "routing": ["no_candidates", "low_confidence", "validation_failed", "outcome_wait_expired"],
        "execution": ["client_refused", "precondition_failed", "action_failed", "cancelled_by_user", "outcome_wait_expired"],
    ]

    /// Approved argument members per intent. An intent absent from this table has NO approved
    /// argument list, so any `arguments` member is refused. The client must omit `arguments` before
    /// finalizing the immutable record — sanitizing afterwards would change the bytes the digest
    /// covers, and the Worker recomputes that digest.
    private static let intentArgumentAllowlist: [String: Set<String>] = [
        "playlist.play": ["playlist_hint"],
        "track.play": ["track_hint", "artist_hint"],
        "track.pause": [],
        "sleep_timer.set": ["duration_minutes"],
    ]

    private static let routingValidationStates: Set<String> = ["valid", "invalid", "not_run"]

    private static let routingDispositions: Set<String> = ["executed", "refused", "failed", "not_run", "pending"]

    private static let stageFields: [String: Set<String>] = [
        "wake": ["state", "reason", "decision", "score", "threshold", "speech_offset_ms", "wake_offset_ms"],
        "bleed": ["state", "reason", "decision", "overlap_ratio"],
        "asr": ["state", "reason", "text", "source_language", "router_input"],
        "translation": ["state", "reason", "translated_text", "target_language"],
        "routing": [
            "state", "reason", "predicted_intent", "predicted_tool", "validation",
            "execution_disposition", "failure_reason", "arguments",
        ],
        "execution": ["state", "reason", "outcome"],
    ]

    private static func validateModels(_ models: [String: Any]) throws {
        try assertAllowedKeys(models, allowed: Set(modelKeys), path: "models")
        for key in modelKeys {
            guard let entry = models[key] else {
                throw BindingError.missingField("models.\(key)")
            }
            // "absent means not run/unknown" — null is the declared absence.
            if entry is NSNull { continue }
            guard let declared = entry as? [String: Any] else {
                throw BindingError.invalidField("models.\(key)", "object or null required")
            }
            try assertAllowedKeys(declared, allowed: ["id", "version"], path: "models.\(key)")
            guard let id = declared["id"] as? String, !id.isEmpty else {
                throw BindingError.missingField("models.\(key).id")
            }
            guard let version = declared["version"] as? String, !version.isEmpty else {
                throw BindingError.missingField("models.\(key).version")
            }
        }
    }

    /// Exposed so a control can assert the observation rules directly instead of assembling a whole
    /// record and mutating a hex digest.
    static func validateObservationsForTesting(_ observations: [String: Any]) throws {
        try validateObservations(observations)
    }

    private static func validateObservations(_ observations: [String: Any]) throws {
        try assertAllowedKeys(observations, allowed: Set(observationStages), path: "observations")
        for stage in observationStages {
            let stagePath = "observations.\(stage)"
            guard let entry = observations[stage] else {
                // Every stage must be stated: a missing stage is an unstated claim about a stage the
                // pipeline either observed or did not run.
                throw BindingError.missingField(stagePath)
            }
            guard let declared = entry as? [String: Any] else {
                throw BindingError.invalidField(stagePath, "object required")
            }
            guard let allowed = stageFields[stage] else { throw BindingError.invalidField(stagePath, "unknown stage") }
            try assertAllowedKeys(declared, allowed: allowed, path: stagePath)
            guard let state = declared["state"] as? String, observationStates.contains(state) else {
                throw BindingError.invalidField("\(stagePath).state", "enumerated state required")
            }
            // Only a completed stage may omit a reason; anything else must say why, from the list.
            if state != "completed" {
                guard let reason = declared["reason"] as? String, !reason.isEmpty else {
                    throw BindingError.missingField("\(stagePath).reason")
                }
                // `observation_unavailable` is a non-claim: it is allowed ONLY with `state:
                // "unknown"` (spec delta 736d3180). With any known outcome the stage keeps its
                // specific reason, so the pair is refused rather than reinterpreted.
                if anyStateReasons.contains(reason) {
                    guard state == "unknown" else {
                        throw BindingError.invalidField(
                            "\(stagePath).reason",
                            "observation_unavailable requires state unknown, not \(state)")
                    }
                } else if reason == detectorErrorReason {
                    try assertDetectorErrorPairing(stage: stage, state: state, path: "\(stagePath).reason")
                } else if reason == emptyResultReason {
                    throw BindingError.invalidField(
                        "\(stagePath).reason",
                        "empty_result requires state completed, not \(state)")
                } else {
                    guard let enumerated = stageReasons[stage], enumerated.contains(reason) else {
                        throw BindingError.invalidField("\(stagePath).reason", "not enumerated")
                    }
                }
            }

            // Per-stage conditional rules. Found by running the real Worker intake: a completed ASR
            // stage MUST carry its text, and a non-completed one must NOT — text present for a
            // stage that produced nothing is how an empty transcript becomes a silent success.
            if stage == "asr" {
                let text = declared["text"]
                let hasText = !(text is NSNull) && text != nil
                // `completed` needs its transcript — EXCEPT for a recognition that genuinely returned no
                // usable text, which states `empty_result` and carries nothing (spec c6f3bdf7).
                let declaresEmptyResult = (declared["reason"] as? String) == emptyResultReason
                if state == "completed", !hasText, !declaresEmptyResult {
                    throw BindingError.missingField("\(stagePath).text")
                }
                if state != "completed", hasText {
                    throw BindingError.invalidField("\(stagePath).text", "text present for a non-completed stage")
                }
                if let value = text as? String, value.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw BindingError.invalidField("\(stagePath).text", "whitespace only")
                }
            }

            if stage == "routing" {
                try validateRoutingArguments(declared, path: stagePath)
            }

            if let reason = declared["reason"], !(reason is NSNull) {
                guard let text = reason as? String, !text.isEmpty else {
                    throw BindingError.invalidField("\(stagePath).reason", "non-empty string required")
                }
                if anyStateReasons.contains(text) {
                    // Same pairing rule for the completed case: a non-claim cannot describe a known
                    // outcome, so a completed stage carrying it is refused.
                    guard state == "unknown" else {
                        throw BindingError.invalidField(
                            "\(stagePath).reason",
                            "observation_unavailable requires state unknown, not \(state)")
                    }
                } else if text == detectorErrorReason {
                    // Same enforcement on the completed path: a real failure cannot be attached to a
                    // stage that reports success, nor to a stage other than wake (spec 9578b16).
                    try assertDetectorErrorPairing(stage: stage, state: state, path: "\(stagePath).reason")
                } else if text == emptyResultReason {
                    // `empty_result` is the ONLY reason a completed stage may carry, and only on ASR.
                    // Asserted BEFORE the per-stage field rules below, which must then see an absent text.
                    try assertEmptyResultPairing(stage: stage, state: state, declared: declared,
                                                 path: "\(stagePath).reason")
                } else {
                    guard let enumerated = stageReasons[stage], enumerated.contains(text) else {
                        throw BindingError.invalidField("\(stagePath).reason", "not enumerated")
                    }
                }
            }
        }
    }

    /// `detector_error` is a REAL observed failure, so it is a legitimate known outcome — but it names
    /// exactly one thing: the wake detector failed for this capture. Any other stage, or any state other
    /// than `failed`, would publish a failure that did not happen (spec 9578b16, reviewer 6c3fed9b).
    /// `empty_result` describes a SUCCESSFUL recognition with nothing usable in it, so it is valid only on
    /// ASR with `completed` and with both `text` and `router_input` absent (spec c6f3bdf7). Any other
    /// combination asserts something the capture cannot have done.
    private static func assertEmptyResultPairing(
        stage: String, state: String, declared: [String: Any], path: String
    ) throws {
        guard stage == "asr" else {
            throw BindingError.invalidField(path, "empty_result is valid only on the asr stage, not \(stage)")
        }
        guard state == "completed" else {
            throw BindingError.invalidField(path, "empty_result requires state completed, not \(state)")
        }
        // ABSENT means the KEY IS NOT THERE (review 2f8e5d90). An explicit JSON `null` is present: it
        // states the field exists and is empty, which is not what this reason declares. Testing the VALUE
        // instead of the key let `text: null` and `router_input: null` through.
        if declared.keys.contains("text") {
            throw BindingError.invalidField(
                "\(path)",
                "empty_result must not carry a text key at all; a transcription is not an empty result")
        }
        if declared.keys.contains("router_input") {
            throw BindingError.invalidField(
                "\(path)",
                "empty_result must not carry a router_input key at all; no command proceeded")
        }
    }

    private static func assertDetectorErrorPairing(stage: String, state: String, path: String) throws {
        guard stage == "wake", state == "failed" else {
            throw BindingError.invalidField(
                path, "detector_error requires wake+failed, not \(stage)+\(state)")
        }
    }

    /// `routing.arguments` may only carry members the record's own intent authorizes. This runs at
    /// BINDING time, i.e. before finalization and hashing, not only during recovery: an argument
    /// payload that survives into the immutable record can never be removed afterwards without
    /// changing the digest, so the correct behaviour is to refuse it here and require the client to
    /// omit `arguments` while still retaining the action category and disposition.
    private static func validateRoutingArguments(_ routing: [String: Any], path: String) throws {
        guard let raw = routing["arguments"], !(raw is NSNull) else { return }
        guard let arguments = raw as? [String: Any] else {
            throw BindingError.invalidField("\(path).arguments", "object required")
        }
        let intent = routing["predicted_intent"] as? String ?? ""
        guard let allowed = intentArgumentAllowlist[intent] else {
            // Missing authorization: the intent has no approved argument list at all. Refused
            // rather than partially retained — a partial payload would misrepresent what the model
            // saw, and mutating it here would break the digest contract.
            throw BindingError.invalidField("\(path).arguments", "intent has no approved argument list")
        }
        for key in arguments.keys where !allowed.contains(key) {
            throw BindingError.invalidField("\(path).arguments", "unrecognized argument member")
        }
    }

    private static func assertAllowedKeys(_ object: [String: Any], allowed: Set<String>, path: String) throws {
        for key in object.keys where !allowed.contains(key) {
            throw BindingError.unknownField(path, key)
        }
    }

    // MARK: WAV representation

    /// The documented training representation only: PCM16, mono, 16 kHz, in the canonical
    /// 44-byte layout. Every value is READ from the header and cross-checked; nothing is defaulted
    /// or inferred from a `.wav` name.
    ///
    /// Returned facts come from bytes actually RECEIVED, except where the server compares a
    /// declared length against the received one — which it always does, because a torn upload
    /// declares whatever it wanted to be.
    struct WavFacts: Equatable {
        let sampleCount: Int
        let durationMs: Int
        let dataLength: Int
    }

    static let wavHeaderBytes = 44

    private static func validateWAV(_ data: Data) throws -> WavFacts {
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
        func ascii(_ offset: Int) -> String? {
            guard offset + 4 <= bytes.count else { return nil }
            return String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
        }

        guard bytes.count >= wavHeaderBytes else { throw BindingError.invalidAudio("malformed_header:too_short") }
        guard ascii(0) == "RIFF" else { throw BindingError.invalidAudio("malformed_header:riff") }
        guard ascii(8) == "WAVE" else { throw BindingError.invalidAudio("malformed_header:wave") }
        // The canonical layout is fixed, so the chunk headers are at known offsets.
        guard ascii(12) == "fmt " else { throw BindingError.invalidAudio("malformed_header:fmt_chunk") }

        let formatSize = u32(16).map(Int.init) ?? -1
        guard formatSize >= 16 else { throw BindingError.invalidAudio("malformed_header:fmt_size") }
        guard formatSize == 16 else {
            throw BindingError.invalidAudio("unsupported_format:fmt_size\(formatSize)")
        }

        guard let formatTag = u16(20), formatTag == 1 else {
            throw BindingError.invalidAudio("unsupported_format:format_tag")
        }
        guard let channels = u16(22), channels == 1 else {
            throw BindingError.invalidAudio("unsupported_format:channels")
        }
        guard let sampleRate = u32(24), sampleRate == 16_000 else {
            throw BindingError.invalidAudio("unsupported_format:sample_rate")
        }
        guard let byteRate = u32(28) else { throw BindingError.invalidAudio("malformed_header:byte_rate") }
        guard let blockAlign = u16(32) else { throw BindingError.invalidAudio("malformed_header:block_align") }
        guard let bitsPerSample = u16(34), bitsPerSample == 16 else {
            throw BindingError.invalidAudio("unsupported_format:bits_per_sample")
        }

        // Self-consistency: derived fields must agree with declared ones. Choosing which field to
        // believe when they disagree would be arbitrary.
        let expectedBlockAlign = Int(channels) * Int(bitsPerSample) / 8
        guard Int(blockAlign) == expectedBlockAlign else {
            throw BindingError.invalidAudio("malformed_header:block_align")
        }
        guard Int(byteRate) == Int(sampleRate) * expectedBlockAlign else {
            throw BindingError.invalidAudio("malformed_header:byte_rate")
        }

        guard ascii(36) == "data" else { throw BindingError.invalidAudio("malformed_header:data_chunk") }
        guard let declaredDataSize = u32(40).map(Int.init) else {
            throw BindingError.invalidAudio("malformed_header:data_length")
        }

        // RIFF size claims total-8. Compared against RECEIVED bytes, never against the declared
        // chunk size: two header fields agree with each other for free.
        guard let riffDeclared = u32(4).map(Int.init) else {
            throw BindingError.invalidAudio("malformed_header:riff_size")
        }
        guard riffDeclared + 8 == bytes.count else {
            throw BindingError.invalidAudio("malformed_header:riff_size")
        }

        let available = bytes.count - wavHeaderBytes
        // The declared size is a claim; the received length is the fact.
        guard declaredDataSize <= available else {
            throw BindingError.invalidAudio("truncated_body:data_length")
        }
        // Bytes beyond the declared chunk mean a second chunk nobody parsed or a corrupt length;
        // digesting fewer bytes than were uploaded changes what the record claims to contain.
        guard available == declaredDataSize else {
            throw BindingError.invalidAudio("malformed_header:bytes beyond declared chunk")
        }
        // A half frame is a torn sample, not a rounding detail.
        guard declaredDataSize % expectedBlockAlign == 0 else {
            throw BindingError.invalidAudio("unsupported_format:data_length")
        }

        let sampleCount = declaredDataSize / expectedBlockAlign
        let durationMs = Int((Double(sampleCount) / Double(sampleRate) * 1000).rounded())
        return WavFacts(sampleCount: sampleCount, durationMs: durationMs, dataLength: declaredDataSize)
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
        // CFBoolean is an NSNumber subclass, so `as? NSNumber` matches booleans too. Discriminating
        // on the CoreFoundation type id first is what keeps `false` from serializing as `0`.
        if let number = value as? NSNumber, isBoolean(number) {
            output += number.boolValue ? "true" : "false"
            return
        }
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

    /// Numbers: ECMAScript `Number::toString` rendering via [ES6NumberFormat]. The record digest is
    /// compared against the server's, so a locally-convenient formatting (fixed decimals, `1e-07`,
    /// `-0`) rejects records the server accepts.
    private static func writeCanonicalNumber(_ number: NSNumber, into output: inout String) throws {
        let double = number.doubleValue
        guard let text = ES6NumberFormat.canonical(double) else {
            throw BindingError.nonFiniteNumber("number")
        }
        output += text
    }

    // MARK: Parsing

    /// Parses JSON refusing duplicate keys and non-finite numbers — the two collapses a lenient
    /// parser would silently accept and thereby let a different record share one digest.
    static func parseRefusingDuplicates(_ data: Data) throws -> Any {
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

    /// Hex value of a single scalar, or nil when it is not a hex digit.
    private static func hexValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar {
        case "0"..."9": return Int(scalar.value) - 0x30
        case "a"..."f": return Int(scalar.value) - 0x61 + 10
        case "A"..."F": return Int(scalar.value) - 0x41 + 10
        default: return nil
        }
    }

    /// Decodes one JSON string escape at `index` (pointing at the backslash), returning the decoded
    /// text and the index just past the escape. Used so duplicate detection compares NAMES, not their
    /// spellings.
    private static func decodeEscape(_ scalars: [Unicode.Scalar], at index: Int) -> (String, Int)? {
        guard index + 1 < scalars.count else { return nil }
        switch scalars[index + 1] {
        case "\"": return ("\"", index + 2)
        case "\\": return ("\\", index + 2)
        case "/": return ("/", index + 2)
        case "b": return ("\u{8}", index + 2)
        case "f": return ("\u{c}", index + 2)
        case "n": return ("\n", index + 2)
        case "r": return ("\r", index + 2)
        case "t": return ("\t", index + 2)
        case "u":
            guard index + 5 < scalars.count else { return nil }
            var value: UInt32 = 0
            for offset in 2...5 {
                guard let digit = scalars[index + offset].properties.numericValue.flatMap({ $0 >= 0 ? Int($0) : nil }) ?? hexValue(scalars[index + offset]) else { return nil }
                value = value << 4 | UInt32(digit)
            }
            // A high surrogate pairs with the following \uXXXX low surrogate; both are consumed so
            // a supplementary character compares equal to its escaped form.
            if value >= 0xD800, value <= 0xDBFF, index + 11 < scalars.count,
                scalars[index + 6] == "\\", scalars[index + 7] == "u" {
                var low: UInt32 = 0
                var paired = true
                for offset in 8...11 {
                    guard let digit = hexValue(scalars[index + offset]) else { paired = false; break }
                    low = low << 4 | UInt32(digit)
                }
                if paired, low >= 0xDC00, low <= 0xDFFF,
                    let scalar = Unicode.Scalar(0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)) {
                    return (String(Character(scalar)), index + 12)
                }
            }
            guard let scalar = Unicode.Scalar(value) else { return nil }
            return (String(Character(scalar)), index + 6)
        default:
            return nil
        }
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
                        // An escaped member name must compare equal to its decoded form: `"a"` and
                        // `"\u0061"` are the SAME key, so the escape is decoded before comparison.
                        guard let (decoded, next) = decodeEscape(scalars, at: cursor) else {
                            throw BindingError.malformedJSON("bad escape")
                        }
                        literal.append(decoded)
                        cursor = next
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