import CryptoKit
import Foundation

/// Turns collector segment events into the record sent with an upload: plain UTF-8 JSON and the
/// exact WAV bytes the record describes. There is no canonical form and no digest — the server
/// parses and validates the fields, so nothing depends on the bytes.
///
/// Composition point: the collector calls this, then publishes the two parts through the queue.
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
        /// Conversion pipeline version for float→PCM s16le. Compiled, not an activation value.
        ///
        /// WIRE type is A STRING (spec ruling): the Worker's record schema requires a
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
        /// ASR's language fact (: the field exists in the owning schema; a site that
        /// observed the language states it). Nil leaves the member absent.
        let sourceLanguage: String?
        /// The exact text handed onward as the command input. Nil leaves the member absent.
        let routerInput: String?
        /// Routing's classification, from the site that classified (analytics' own tool/action names).
        let predictedIntent: String?
        let predictedTool: String?
        /// The executor's own verdict for the turn, from `executionOutcome`'s decision site.
        let outcome: String?
        /// The wake detector's MEASURED score and the threshold it was judged against (spec phase 2,
        /// name schema v1: the values exist whenever the detector ran, so the record must carry them
        /// rather than `na`). Nil leaves the member absent — only a site that ran the detector may set
        /// them, and only when it actually measured.
        let score: Double?
        let threshold: Double?

        init(state: String, reason: String? = nil, text: String? = nil, decision: String? = nil,
             translatedText: String? = nil, targetLanguage: String? = nil,
             routingDisposition: String? = nil, sourceLanguage: String? = nil,
             routerInput: String? = nil, predictedIntent: String? = nil,
             predictedTool: String? = nil, outcome: String? = nil,
             score: Double? = nil, threshold: Double? = nil) {
            self.state = state
            self.reason = reason
            self.text = text
            self.decision = decision
            self.translatedText = translatedText
            self.targetLanguage = targetLanguage
            self.routingDisposition = routingDisposition
            self.sourceLanguage = sourceLanguage
            self.routerInput = routerInput
            self.predictedIntent = predictedIntent
            self.predictedTool = predictedTool
            self.outcome = outcome
            self.score = score
            self.threshold = threshold
        }

        func withDecision(_ decision: String) -> StageOutcome {
            // Measured values survive a decision amendment: a re-stated verdict never un-measures
            // the detector's own score/threshold (phase 2: measured values are always recorded).
            StageOutcome(state: state, reason: reason, text: text, decision: decision,
                         translatedText: translatedText, targetLanguage: targetLanguage,
                         routingDisposition: routingDisposition,
                         score: score, threshold: threshold)
        }

        /// Re-states the wire execution outcome without losing the other members (see
        /// `withDecision`). Used by the collector's execution-stage mapping.
        func withWireOutcome(_ wireOutcome: String?) -> StageOutcome {
            StageOutcome(state: state, reason: reason, text: text, decision: decision,
                         translatedText: translatedText, targetLanguage: targetLanguage,
                         routingDisposition: routingDisposition,
                         outcome: wireOutcome, score: score, threshold: threshold)
        }

        /// SERVER schema: the execution stage's
        /// wire outcome is the schema's OWN enum — {success, failure, refused, cancelled} — reached
        /// by a mapping DISTINCT from settledDisposition's routing tokens (: the
        /// routing tokens `executed`/`pending` leaked into this member at 9653836d3). Every
        /// OBSERVED execution carries an outcome. A REFUSAL is state `failed` with
        /// `client_refused` — matching Android — not a not_run. `unknown` observed nothing and
        /// omits the member.
        static func wireExecutionOutcome(for outcome: StageOutcome) -> String? {
            switch (outcome.state, outcome.reason) {
            case ("completed", _): return "success"
            case ("failed", "client_refused"): return "refused"
            case ("failed", _): return "failure"
            case ("cancelled", _): return "cancelled"
            default: return nil
            }
        }
    }

    struct Encoded {
        /// The `metadata` part: plain JSON of the record.
        let metadata: Data
        /// The `audio` part: the exact WAV bytes the record's audio block describes.
        let wav: Data
    }

    /// The reason a recognition reports when it succeeded and returned nothing usable. One spelling,
    /// named by the producer and read by anyone describing the same fact.
    static let emptyResultReason = "empty_result"

    /// The execution stage's routing disposition still names the classification while the turn is
    /// concluded or failed; `not_run` means the router declined, so carrying names would invent a
    /// classification that never happened.
    static func routingDispositionCarriesClassification(_ disposition: String?) -> Bool {
        guard let disposition else { return false }
        return disposition != "not_run"
    }

    /// Bounds the metadata part a single recording may carry. Generous: the record is a few hundred
    /// bytes, and this only stops a malformed observation from producing an unbounded file.
    static let maximumMetadataBytes = 64 * 1024

    static let sampleRateHz = 16_000

    enum EncodeError: Error, Equatable {
        /// A nonfinite sample (NaN/±inf) is malformed capture audio: REFUSED, never clamped into
        /// a fake value and never allowed to trap the process.
        case nonFiniteSample
        /// The collector's own ceiling bounds one capture; exceeding it is refused before wav
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
            "wake_required": event.wakeRequired,
            "capture_id": event.captureID.uuidString,
            "enrollment_epoch": event.enrollmentEpoch,
            "platform": provenance.platform,
            "app_version": provenance.appVersion,
            "build": provenance.build,
            "capture_session_id": provenance.captureSessionID,
            "audio": audioBlock(event: event, wav: wav, provenance: provenance),
            "models": modelsBlock(event.reportedModels ?? provenance.models),
            "observations": observationsBlock(observations, outcomeWaitExpired: event.outcomeWaitExpired),
        ]
        // Plain JSON. Sorted keys only so a human reading a queue folder sees a stable file; the
        // server does not depend on the ordering or the bytes.
        let metadata = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return Encoded(metadata: metadata, wav: wav)
    }

    // MARK: WAV (pcm_s16le, mono, 16 kHz, 44-byte header)

    private static func wavBytes(from samples: [Float]) throws -> Data {
        // Float→Int conversion TRAPS on NaN/infinity/overflow — validate and
        // clamp in the FLOAT domain first, so the advertised rejection policy runs before any
        // integer conversion exists to crash.
        guard samples.count <= VoiceSharingCollector.maxRetainedSamples else {
            throw EncodeError.sampleCountExceedsCeiling
        }
        for sample in samples where !sample.isFinite {
            throw EncodeError.nonFiniteSample
        }
        var data = Data(capacity: 44 + samples.count * 2)
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
            // before scaling, so ±1.0 maps to ±int16's representable bound and no finite input
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

    private static func observationsBlock(_ observations: [String: StageOutcome], outcomeWaitExpired: Bool) -> [String: Any] {
        var block: [String: Any] = [:]
        for stage in ["wake", "bleed", "asr", "translation", "routing", "execution"] {
            guard let outcome = observations[stage] else {
                // A missing stage is an unstated claim — the caller must state every stage.
                block[stage] = ["state": "unknown", "reason": outcomeWaitExpired ? "outcome_wait_expired" : "observation_unavailable"]
                continue
            }
            var entry: [String: Any] = ["state": outcome.state]
            if let reason = outcome.reason { entry["reason"] = reason }
            if let text = outcome.text { entry["text"] = text }
            if let decision = outcome.decision { entry["decision"] = decision }
            if let score = outcome.score { entry["score"] = score }
            if let threshold = outcome.threshold { entry["threshold"] = threshold }
            if let translated = outcome.translatedText { entry["translated_text"] = translated }
            if let target = outcome.targetLanguage { entry["target_language"] = target }
            if let disposition = outcome.routingDisposition {
                entry["execution_disposition"] = disposition
            }
            if let sourceLanguage = outcome.sourceLanguage {
                entry["source_language"] = sourceLanguage
            }
            if let routerInput = outcome.routerInput {
                entry["router_input"] = routerInput
            }
            if let predictedIntent = outcome.predictedIntent {
                entry["predicted_intent"] = predictedIntent
            }
            if let predictedTool = outcome.predictedTool {
                entry["predicted_tool"] = predictedTool
            }
            if let outcomeValue = outcome.outcome {
                entry["outcome"] = outcomeValue
            }
            block[stage] = entry
        }
        return block
    }
}
