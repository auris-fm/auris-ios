import CryptoKit
import Foundation

/// Turns collector segment events into the queue's canonical immutable record: the UTF-8 JSON
/// metadata envelope (`record` + `record_sha256`) and the exact WAV bytes the record declares.
///
/// Composition point: the collector's sink calls this, then hands the result to
/// `VoiceSharingUploadQueue.prepare(metadata:audio:)`. The encoder refuses to emit anything the
/// queue's own validator (`VoiceSharingRecordBinding.bind` — the same authority recovery and
/// readiness apply) would reject: it round-trips EVERY output through `bind` before returning, so
/// a malformed stage outcome or truncation fact fails at collection time, not as a corrupt queue
/// entry discovered later.
///
/// Truthfulness boundary: the OBSERVATION content (stage states, reasons, text) comes from the
/// pipeline caller — the encoder never fabricates a stage claim, a transcript, or a duration. It
/// structures and hashes what it is given; `bind` rejects anything outside the allowlists.
enum VoiceSharingContributionEncoder {

    struct ModelRef: Equatable {
        let id: String
        let version: String
    }

    struct Models: Equatable {
        let vad: ModelRef?
        let wakeword: ModelRef?
        let asr: ModelRef?
        let translation: ModelRef?
        let router: ModelRef?
    }

    struct Provenance {
        let platform: String
        let appVersion: String
        let build: String
        var captureSessionID: String
        let models: Models
        /// Conversion pipeline version for float→PCM s16le. Compiled, NOT an activation value.
        ///
        /// WIRE TYPE IS A STRING (spec ruling 2026-10-22): the Worker's record schema requires a
        /// bounded nonempty string and Android already emits `"v1"`. An Int here produced a
        /// record the pinned intake rejected (`invalid_audio at audio.conversion_version`), caught
        /// only by running a REAL encoder fixture through the Worker.
        let conversionVersion: String
    }

    /// Caller-supplied stage claim. `state` is one of the record schema's enumerated states;
    /// `reason` is REQUIRED for any non-completed state and must be stage-enumerated (enforced by
    /// the round-trip bind). `text` only for a completed ASR stage.
    struct StageOutcome: Equatable {
        let state: String
        let reason: String?
        let text: String?
        /// The stage's own decision verdict (the `decision` member the schema defines for bleed). Only a
        /// site that actually decided may set it; `nil` leaves the member absent.
        let decision: String?
        /// What a successful translation actually produced (schema fields that already exist, spec
        /// d09c320c). Set only by the site that ran the translation.
        let translatedText: String?
        let targetLanguage: String?
        /// Routing's own enumerated field for what became of the routed turn.
        let routingDisposition: String?

        init(state: String, reason: String? = nil, text: String? = nil, decision: String? = nil,
             translatedText: String? = nil, targetLanguage: String? = nil,
             routingDisposition: String? = nil) {
            self.state = state
            self.reason = reason
            self.text = text
            self.decision = decision
            self.translatedText = translatedText
            self.targetLanguage = targetLanguage
            self.routingDisposition = routingDisposition
        }

        func withDecision(_ decision: String) -> StageOutcome {
            StageOutcome(state: state, reason: reason, text: text, decision: decision,
                         translatedText: translatedText, targetLanguage: targetLanguage,
                         routingDisposition: routingDisposition)
        }
    }

    struct Encoded {
        /// Canonicalized `record` object bytes (JCS), the digest preimage.
        let recordJSON: Data
        /// `{"record":…,"record_sha256":…}` — the queue's metadata argument.
        let metadataEnvelope: Data
        /// The exact WAV bytes the record's audio block declares.
        let wav: Data
    }

    static let sampleRateHz = 16_000

    enum EncodeError: Error, Equatable {
        /// A nonfinite sample (NaN/±inf) is malformed capture audio: REFUSED, never clamped into
        /// a fake value and never allowed to trap the process.
        case nonFiniteSample
        /// The collector's own ceiling bounds one capture; exceeding it is refused BEFORE WAV
        /// capacity arithmetic and the UInt32 header sizes are computed.
        case sampleCountExceedsCeiling
    }

    static func encode(
        event: VoiceSharingCollector.SegmentEvent,
        provenance: Provenance,
        observations: [String: StageOutcome]
    ) throws -> Encoded {
        let wav = try wavBytes(from: event.audio)
        let record: [String: Any] = [
            "schema_version": 1,
            "capture_id": event.captureID.uuidString,
            "enrollment_epoch": event.enrollmentEpoch,
            "platform": provenance.platform,
            "app_version": provenance.appVersion,
            "build": provenance.build,
            "capture_session_id": provenance.captureSessionID,
            "audio": audioBlock(event: event, wav: wav, provenance: provenance),
            "models": modelsBlock(provenance.models),
            "observations": observationsBlock(observations),
        ]
        let canonical = try VoiceSharingRecordBinding.canonicalize(record)
        let recordJSON = Data(canonical.utf8)
        let digest = SHA256.hash(data: recordJSON).map { String(format: "%02x", $0) }.joined()
        let envelope: [String: Any] = ["record": record, "record_sha256": digest]
        let envelopeCanonical = try VoiceSharingRecordBinding.canonicalize(envelope)
        let encoded = Encoded(
            recordJSON: recordJSON,
            metadataEnvelope: Data(envelopeCanonical.utf8),
            wav: wav)
        // THE self-check: the queue must accept exactly what we emit. Any structural or
        // allowlist failure is a collection-time error, never a persisted corrupt entry.
        _ = try VoiceSharingRecordBinding.bind(envelope: encoded.metadataEnvelope, audio: encoded.wav)
        return encoded
    }

    // MARK: WAV (pcm_s16le, mono, 16 kHz, canonical 44-byte header)

    private static func wavBytes(from samples: [Float]) throws -> Data {
        // Reviewer 9fbb9d24: Float→Int conversion TRAPS on NaN/infinity/overflow — validate and
        // clamp in the FLOAT domain first, so the advertised rejection policy runs before any
        // integer conversion exists to crash.
        guard samples.count <= VoiceSharingCollector.maxRetainedSamples else {
            throw EncodeError.sampleCountExceedsCeiling
        }
        for sample in samples where !sample.isFinite {
            throw EncodeError.nonFiniteSample
        }
        var data = Data(capacity: VoiceSharingRecordBinding.wavHeaderBytes + samples.count * 2)
        let byteRate = sampleRateHz * 2
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(16)                          // PCM chunk size
        append16(1)                         // PCM format
        append16(1)                         // mono
        append(UInt32(sampleRateHz))
        append(UInt32(byteRate))
        append16(2)                         // block align
        append16(16)                        // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count * 2))
        for sample in samples {
            // Round-nearest with FLOAT-domain clamping: finite out-of-range values pin to ±1
            // BEFORE scaling, so ±1.0 maps to ±int16's representable bound and no finite input
            // can overflow the integer conversion.
            let clampedSample = min(max(sample, -1), 1)
            let scaled = (clampedSample * 32768).rounded()
            let clamped = Int16(clamping: Int(scaled))
            withUnsafeBytes(of: clamped.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: Record blocks

    private static func audioBlock(
        event: VoiceSharingCollector.SegmentEvent, wav: Data, provenance: Provenance
    ) -> [String: Any] {
        var block: [String: Any] = [
            "sha256": SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined(),
            "byte_count": wav.count,
            "encoding": "pcm_s16le",
            "sample_rate_hz": sampleRateHz,
            "channels": 1,
            "retained_samples": event.retainedSamples,
            // The collector owns mono Float32 capture; the ORIGINAL format is that, never implied.
            "original_format": "pcm_f32le",
            "conversion_version": provenance.conversionVersion,
            "truncated": event.truncated,
            "dropped_spans": event.droppedSpans.map {
                ["start_sample": $0.start, "end_sample": $0.end]
            },
        ]
        if event.truncated {
            // Explicit, never fabricated: derived from the segmenter's own original count.
            let original = event.originalSampleCount ?? 0
            block["original_duration_ms"] = Int((Double(original) / Double(sampleRateHz) * 1000).rounded())
        }
        return block
    }

    private static func modelsBlock(_ models: Models) -> [String: Any] {
        func ref(_ m: ModelRef?) -> Any { m.map { ["id": $0.id, "version": $0.version] } ?? NSNull() }
        return [
            "vad": ref(models.vad),
            "wakeword": ref(models.wakeword),
            "asr": ref(models.asr),
            "translation": ref(models.translation),
            "router": ref(models.router),
        ]
    }

    private static func observationsBlock(_ observations: [String: StageOutcome]) -> [String: Any] {
        var block: [String: Any] = [:]
        for stage in ["wake", "bleed", "asr", "translation", "routing", "execution"] {
            guard let outcome = observations[stage] else {
                // A missing stage is an unstated claim — the caller must state every stage.
                block[stage] = ["state": "unknown", "reason": "outcome_wait_expired"]
                continue
            }
            var entry: [String: Any] = ["state": outcome.state]
            if let reason = outcome.reason { entry["reason"] = reason }
            if let text = outcome.text { entry["text"] = text }
            if let decision = outcome.decision { entry["decision"] = decision }
            if let translated = outcome.translatedText { entry["translated_text"] = translated }
            if let target = outcome.targetLanguage { entry["target_language"] = target }
            if let disposition = outcome.routingDisposition {
                entry["execution_disposition"] = disposition
            }
            block[stage] = entry
        }
        return block
    }
}
