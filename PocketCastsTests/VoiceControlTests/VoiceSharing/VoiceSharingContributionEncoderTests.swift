import CryptoKit
import XCTest
@testable import podcasts

/// Composition slice: collector segment events become canonical queue-ready records.
/// The oracle is the EXISTING validator — whatever the encoder emits must round-trip through
/// VoiceSharingRecordBinding.bind, the same authority the queue applies to persisted entries.
final class VoiceSharingContributionEncoderTests: XCTestCase {
    private let samples: [Float] = [0, 0.25, -0.5, 0.99, -1, 0.5]

    private func event(truncated: Bool = false) -> VoiceSharingCollector.SegmentEvent {
        .init(
            kind: .completed, captureID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            enrollmentEpoch: "epoch-1", authorizationSession: "sess-1", retainedSamples: samples.count,
            truncated: truncated, droppedSpans: truncated
                ? [VoiceSharingCollector.DropSpan(start: 0, end: 3)] : [],
            originalSampleCount: truncated ? 16_032 : nil, audio: samples, isGateControl: false)
    }

    private let provenance = VoiceSharingContributionEncoder.Provenance(
        platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
        models: VoiceSharingContributionEncoder.Models(
            vad: VoiceSharingContributionEncoder.ModelRef(id: "vad-1", version: "1"), wakeword: VoiceSharingContributionEncoder.ModelRef(id: "wake-1", version: "1"),
            asr: VoiceSharingContributionEncoder.ModelRef(id: "asr-1", version: "1"), translation: nil,
            router: VoiceSharingContributionEncoder.ModelRef(id: "router-1", version: "1")),
        conversionVersion: "v1")

    /// A stage-claim set the caller (pipeline) supplies — every non-completed stage states an
    /// enumerated reason; nothing is fabricated by the encoder.
    // MARK: - detector_error is a REAL observed failure (spec 9578b16, reviewer 6c3fed9b)

    /// The exact pairing the detector produces must ENCODE and reach a durable-ready record. Before this
    /// rule existed the known failure was refused by the binding, so a real engine detector error could
    /// never publish at all — the record silently never existed.
    func test_theDetectorErrorPairingEncodesIntoAnImmutableRecord() throws {
        var claims = observations
        claims["wake"] = .init(state: "failed", reason: "detector_error")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(), provenance: provenance, observations: claims)
        let object = try JSONSerialization.jsonObject(with: encoded.recordJSON) as? [String: Any]
        let wake = (object?["observations"] as? [String: Any])?["wake"] as? [String: Any]
        XCTAssertEqual(wake?["state"] as? String, "failed")
        XCTAssertEqual(wake?["reason"] as? String, "detector_error")
        // And it BINDS through the production validator (envelope + audio), not just encodes.
        XCTAssertNoThrow(try VoiceSharingRecordBinding.bind(
            envelope: encoded.metadataEnvelope, audio: encoded.wav))
    }

    /// REJECTION MATRIX: `detector_error` names the wake detector's failure and nothing else. Every other
    /// stage/state pairing is refused — including `wake` + `completed`, which would publish a failure that
    /// did not happen, and `wake` + `unknown`, which would turn an observed failure into non-observation.
    func test_detectorErrorIsRefusedForEveryPairingOtherThanWakeFailed() throws {
        let otherStates = ["completed", "not_run", "cancelled", "unknown"]
        for stage in ["wake", "bleed", "asr", "translation", "routing", "execution"] {
            let states = stage == "wake" ? otherStates : otherStates + ["failed"]
            for state in states {
                var claims = observations
                // ASR's completed state independently requires text; supply it so the ONLY rule that can
                // reject this pair is the detector_error pairing (proven by the asserted message).
                claims[stage] = .init(state: state, reason: "detector_error",
                                      text: stage == "asr" && state == "completed" ? "hello" : nil)
                do {
                    let encoded = try VoiceSharingContributionEncoder.encode(
                        event: event(), provenance: provenance, observations: claims)
                    XCTFail("detector_error must be refused for \(stage)/\(state); it encoded")
                    _ = encoded
                } catch let error as VoiceSharingRecordBinding.BindingError {
                    // Assert WHY, not just that something threw (a generic path can throw the same type).
                    guard case .invalidField(let path, let message) = error else {
                        XCTFail("expected invalidField for \(stage)/\(state), got \(error)")
                        continue
                    }
                    XCTAssertEqual(path, "observations.\(stage).reason",
                                   "the refusal must name the offending stage for \(stage)/\(state)")
                    // f8 says a COMPLETED stage carries no reason at all, and that rule is checked first,
                    // so for these pairs the refusal correctly names that stronger rule. Both are real
                    // refusals of the same payload; asserting the specific cause keeps this honest about
                    // WHICH rule fired instead of accepting any message.
                    let expected = state == "completed"
                        ? "a completed stage carries no reason"
                        : "detector_error requires wake+failed"
                    XCTAssertTrue(message.contains(expected),
                                  "refusal for \(stage)/\(state) must state its rule (\(expected)), "
                                      + "got: \(message)")
                }
            }
        }
    }

    /// The completed-stage path enforces the SAME rule (the binding validates reasons twice); a rule added
    /// to only one path leaves the other open.
    func test_theDetectorErrorPairingIsEnforcedOnTheCompletedPathToo() throws {
        var claims = observations
        claims["wake"] = .init(state: "failed", reason: "detector_error")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(), provenance: provenance, observations: claims)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded.recordJSON) as? [String: Any])
        var stageBlock = try XCTUnwrap((object["observations"] as? [String: Any])?["wake"] as? [String: Any])
        stageBlock["state"] = "completed"
        var observationsBlock = try XCTUnwrap(object["observations"] as? [String: Any])
        observationsBlock["wake"] = stageBlock
        object["observations"] = observationsBlock
        // Re-seal the mutated record with a digest computed by the PRODUCTION canonicalizer, so the digest
        // is not what rejects it — the pairing rule must be.
        var digest = ""
        #if canImport(CryptoKit)
        digest = SHA256.hash(data: try VoiceSharingRecordBinding.canonicalizeForTesting(object))
            .map { String(format: "%02x", $0) }.joined()
        #endif
        let resealed: [String: Any] = [
            "record": object,
            "record_sha256": digest,
        ]
        let envelope = try JSONSerialization.data(withJSONObject: resealed)
        do {
            _ = try VoiceSharingRecordBinding.bind(envelope: envelope, audio: encoded.wav)
            XCTFail("a completed wake stage must not carry the detector's failure reason")
        } catch let error as VoiceSharingRecordBinding.BindingError {
            guard case .invalidField(let path, let message) = error else {
                return XCTFail("expected invalidField, got \(error)")
            }
            XCTAssertEqual(path, "observations.wake.reason")
            // The completed path is now refused by f8's no-reason rule, which is the stronger and
            // earlier check for a completed stage; that rule is what must be named.
            XCTAssertTrue(message.contains("a completed stage carries no reason"), "got: \(message)")
        }
    }

    private let observations: [String: VoiceSharingContributionEncoder.StageOutcome] = [
        "wake": .init(state: "completed"),
        "bleed": .init(state: "not_run", reason: "no_playback_reference"),
        "asr": .init(state: "not_run", reason: "local_only_action"),
        "translation": .init(state: "not_run", reason: "no_text"),
        "routing": .init(state: "not_run", reason: "no_candidates"),
        "execution": .init(state: "not_run", reason: "client_refused"),
    ]

    func test_encodedRecordRoundTripsThroughTheQueueValidator() throws {
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(), provenance: provenance, observations: observations)
        let bound = try VoiceSharingRecordBinding.bind(
            envelope: encoded.metadataEnvelope, audio: encoded.wav)
        XCTAssertEqual(bound.captureID, event().captureID.uuidString)
        XCTAssertEqual(bound.enrollmentEpoch, "epoch-1")
        XCTAssertEqual(bound.audioByteCount, encoded.wav.count)
        XCTAssertEqual(bound.audioSHA256,
                       SHA256.hash(data: encoded.wav).map { String(format: "%02x", $0) }.joined())
    }

    /// Emits a REAL encoder fixture (envelope + WAV) for the pinned Worker intake harness, so the
    /// cross-repo check uses bytes this encoder actually produces rather than a hand-written
    /// sample. Skips silently unless AURIS_FIXTURE_DIR points at a writable directory.
    func test_exportFixtureForPinnedWorkerIntake() throws {
        guard let dir = ProcessInfo.processInfo.environment["AURIS_FIXTURE_DIR"] else {
            return // not a fixture run
        }
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(), provenance: provenance, observations: observations)
        let base = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try encoded.metadataEnvelope.write(to: base.appendingPathComponent("metadata.json"))
        try encoded.wav.write(to: base.appendingPathComponent("audio.wav"))
        // The fixture must be SELF-CONSISTENT before it leaves this runner.
        let bound = try VoiceSharingRecordBinding.bind(
            envelope: encoded.metadataEnvelope, audio: encoded.wav)
        XCTAssertEqual(bound.audioByteCount, encoded.wav.count)
        XCTAssertEqual(bound.audioSHA256,
                       SHA256.hash(data: encoded.wav).map { String(format: "%02x", $0) }.joined())
    }

    /// The pinned cross-client WIRE fixture for spec delta 736d3180: a capture whose ASR stage is
    /// explicitly unobserved (`state: "unknown"` + `observation_unavailable`). Deterministic capture
    /// id, enrollment epoch, samples and provenance, so the emitted record bytes are reproducible and
    /// hashable by another client's intake. Skips unless AURIS_UNAVAILABLE_FIXTURE_DIR is set.
    func test_exportUnavailableObservationFixtureForCrossClientWireParity() throws {
        // Host environment variables do not reach the simulator test process, so the fixture is
        // always written to a fixed, readable location inside the runner's temporary directory and
        // copied out with `simctl get_app_container` afterwards. It is a no-op for normal runs
        // beyond one small write.
        let dir = NSTemporaryDirectory() + "/auris-wire-fixture"
        var claims = observations
        claims["asr"] = .init(state: "unknown", reason: "observation_unavailable")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(), provenance: provenance, observations: claims)
        let base = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try encoded.metadataEnvelope.write(to: base.appendingPathComponent("metadata.json"))
        try encoded.wav.write(to: base.appendingPathComponent("audio.wav"))
        // Read the record digest back from the bound envelope rather than recomputing it here, so
        // the manifest can never disagree with the bytes beside it.
        let bound = try VoiceSharingRecordBinding.bind(
            envelope: encoded.metadataEnvelope, audio: encoded.wav)
        XCTAssertFalse(bound.recordSHA256.isEmpty, "the exported envelope carries its record digest")
        let manifest: [String: String] = [
            "record_sha256": bound.recordSHA256,
            "metadata_sha256": SHA256.hash(data: encoded.metadataEnvelope)
                .map { String(format: "%02x", $0) }.joined(),
            "audio_sha256": SHA256.hash(data: encoded.wav)
                .map { String(format: "%02x", $0) }.joined(),
            "capture_id": event().captureID.uuidString,
            "unobserved_stage": "asr",
            "unobserved_reason": "observation_unavailable",
            "unobserved_state": "unknown",
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        try manifestData.write(to: base.appendingPathComponent("manifest.json"))
    }

    /// The PINNED f8 WIRE fixtures (spec: exact `3dd0c91d` emitted-byte parity). Three deterministic
    /// records exercising every byte shape f8 introduced — routing with a structured disposition,
    /// completed stages carrying NO reason, the asr/empty_result exception, and the three translation
    /// skip reasons — exported for the pinned Worker intake so parity is checked against bytes this
    /// encoder ACTUALLY emits, bound-verified before they leave the runner. Always written to a fixed
    /// runner-temporary location (host env does not reach the simulator); copied out via simctl.
    func test_exportF8FixturesForPinnedWorkerIntake() throws {
        func capture(_ id: String) -> VoiceSharingCollector.SegmentEvent {
            .init(kind: .completed, captureID: UUID(uuidString: id)!,
                  enrollmentEpoch: "epoch-1", authorizationSession: "sess-1",
                  retainedSamples: samples.count, truncated: false, droppedSpans: [],
                  originalSampleCount: nil, audio: samples, isGateControl: false)
        }
        let cases: [String: (String, [String: VoiceSharingContributionEncoder.StageOutcome])] = [
            // Full happy path AS THE ENCODER EMITS IT: completed stages carry NO reason; routing
            // carries its structured disposition. NOTE: StageOutcome has no members for asr's
            // source_language/router_input, routing's predicted_intent/tool/validation, or
            // execution's outcome — if the pinned intake requires any of those, this fixture is
            // the exact bytes that show the gap.
            "f8-routing-executed": (
                "22222222-2222-3333-4444-555555555555",
                ["wake": .init(state: "completed"),
                 "bleed": .init(state: "not_run", reason: "no_playback_reference"),
                 "asr": .init(state: "completed", text: "pause"),
                 "translation": .init(state: "not_run", reason: "source_language_target_language"),
                 "routing": .init(state: "completed", routingDisposition: "executed"),
                 "execution": .init(state: "completed")]),
            // A genuinely empty recognition: asr COMPLETED with the sole sanctioned reason.
            "f8-empty-result": (
                "33333333-2222-3333-4444-555555555555",
                ["wake": .init(state: "completed"),
                 "bleed": .init(state: "not_run", reason: "no_playback_reference"),
                 "asr": .init(state: "completed", reason: "empty_result"),
                 "translation": .init(state: "not_run", reason: "no_text"),
                 "routing": .init(state: "not_run", reason: "no_candidates"),
                 "execution": .init(state: "not_run", reason: "precondition_failed")]),
            // The backend-translation skip: translation NOT RUN for a reason that is a DECISION,
            // while asr still carries its own text facts (spec 4d10275f).
            "f8-translation-skip": (
                "44444444-2222-3333-4444-555555555555",
                ["wake": .init(state: "completed"),
                 "bleed": .init(state: "not_run", reason: "no_playback_reference"),
                 "asr": .init(state: "completed", text: "spielt den nächsten Titel"),
                 "translation": .init(state: "not_run", reason: "backend_handles_translation"),
                 "routing": .init(state: "completed", routingDisposition: "pending"),
                 "execution": .init(state: "unknown", reason: "observation_unavailable")]),
        ]
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auris-f8-fixtures")
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for (name, (captureID, observations)) in cases {
            let encoded = try VoiceSharingContributionEncoder.encode(
                event: capture(captureID), provenance: provenance, observations: observations)
            // SELF-CONSISTENT before export: the production binding must accept these bytes.
            let bound = try VoiceSharingRecordBinding.bind(
                envelope: encoded.metadataEnvelope, audio: encoded.wav)
            XCTAssertFalse(bound.recordSHA256.isEmpty)
            let dir = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encoded.metadataEnvelope.write(to: dir.appendingPathComponent("metadata.json"))
            try encoded.wav.write(to: dir.appendingPathComponent("audio.wav"))
            let manifest: [String: String] = [
                "record_sha256": bound.recordSHA256,
                "metadata_sha256": SHA256.hash(data: encoded.metadataEnvelope)
                    .map { String(format: "%02x", $0) }.joined(),
                "audio_sha256": SHA256.hash(data: encoded.wav)
                    .map { String(format: "%02x", $0) }.joined(),
                "capture_id": captureID,
                "f8_case": name,
            ]
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
                .write(to: dir.appendingPathComponent("manifest.json"))
        }
    }

    func test_wavRepresentationIsCanonicalPcmS16leMono16k() throws {
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(), provenance: provenance, observations: observations)
        XCTAssertEqual(encoded.wav.count, VoiceSharingRecordBinding.wavHeaderBytes + samples.count * 2,
                       "44-byte header + one little-endian int16 per sample")
        // Float 0.5 must map to int16 16384 (round-nearest), not truncate.
        let payload = encoded.wav.subdata(in: VoiceSharingRecordBinding.wavHeaderBytes..<encoded.wav.count)
        // samples = [0, 0.25, -0.5, 0.99, -1, 0.5]; index 5 is the 0.5.
        let fifthLE: UInt16 = payload.subdata(in: (5*2)..<(6*2)).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(Int16(bitPattern: fifthLE), 16384, "Float 0.5 -> int16 16384 (round-nearest)")
        let thirdLE: UInt16 = payload.subdata(in: (3*2)..<(4*2)).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(Int16(bitPattern: thirdLE), 32440, "Float 0.99 -> round-nearest, not truncated")
    }

    func test_nonFiniteSamplesAreRefusedNotClampedAndNeverTrap() throws {
        // Reviewer 9fbb9d24: NaN/±inf must throw BEFORE any Float→Int conversion; a large finite
        // value must clamp in the float domain without trapping.
        for bad: [Float] in [[.nan], [.infinity], [-.infinity], [0.5, .nan]] {
            XCTAssertThrowsError(
                try VoiceSharingContributionEncoder.encode(
                    event: eventReplaced(audio: bad), provenance: provenance, observations: observations)
            ) { error in
                XCTAssertEqual(
                    error as? VoiceSharingContributionEncoder.EncodeError,
                    .nonFiniteSample, "nonfinite audio is malformed, refused at encode time")
            }
        }
        let huge: [Float] = [.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: eventReplaced(audio: huge), provenance: provenance, observations: observations)
        let payload = encoded.wav.subdata(in: VoiceSharingRecordBinding.wavHeaderBytes..<encoded.wav.count)
        let hi = Int16(bitPattern: payload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) })
        let lo = Int16(bitPattern: payload.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self) })
        XCTAssertEqual(hi, 32767)
        XCTAssertEqual(lo, -32768)
        // ±1 exactly maps to the representable bounds.
        let exact = try VoiceSharingContributionEncoder.encode(
            event: eventReplaced(audio: [1, -1]), provenance: provenance, observations: observations)
        let exactPayload = exact.wav.subdata(
            in: VoiceSharingRecordBinding.wavHeaderBytes..<exact.wav.count)
        let p1 = Int16(bitPattern: exactPayload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) })
        let n1 = Int16(bitPattern: exactPayload.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self) })
        XCTAssertEqual(p1, 32767)
        XCTAssertEqual(n1, -32768)
    }

    func test_sampleCountAboveCollectorCeilingIsRefusedBeforeSizing() {
        var oversized = samples
        oversized.append(
            contentsOf: [Float](repeating: 0, count: VoiceSharingCollector.maxRetainedSamples + 1))
        XCTAssertThrowsError(
            try VoiceSharingContributionEncoder.encode(
                event: eventReplaced(audio: oversized), provenance: provenance, observations: observations)
        ) { error in
            XCTAssertEqual(
                error as? VoiceSharingContributionEncoder.EncodeError,
                .sampleCountExceedsCeiling)
        }
    }

    // MARK: observation_unavailable parity (spec delta 736d3180)

    /// An unobserved stage is stated as `state: "unknown"` + `observation_unavailable`: the client
    /// does not claim the stage ran, failed, was cancelled or timed out. The record must round-trip
    /// through the same binding the queue applies, on EVERY stage.
    func test_observationUnavailableWithUnknownStateIsAcceptedOnEveryStage() throws {
        for stage in ["wake", "bleed", "asr", "translation", "routing", "execution"] {
            var claim = observations
            claim[stage] = .init(state: "unknown", reason: "observation_unavailable")
            let encoded = try VoiceSharingContributionEncoder.encode(
                event: event(), provenance: provenance, observations: claim)
            let bound = try VoiceSharingRecordBinding.bind(
                envelope: encoded.metadataEnvelope, audio: encoded.wav)
            XCTAssertEqual(bound.captureID, event().captureID.uuidString,
                           "\(stage): an unobserved stage must not break the record")
        }
    }

    /// The pairing rule in the OTHER direction: the reason describes a stage whose outcome cannot be
    /// established, so attaching it to any known outcome is refused — including completed, which
    /// always keeps its specific reason (or none at all).
    func test_observationUnavailableIsRefusedWithAnyKnownState() throws {
        for state in ["completed", "not_run", "failed", "cancelled"] {
            for stage in ["wake", "bleed", "asr", "translation", "routing", "execution"] {
                var claim = observations
                // A completed ASR stage must carry its text, which the validator checks before the
                // reason pairing — supply it so the REASON rule is the one under test.
                claim[stage] = state == "completed" && stage == "asr"
                    ? .init(state: state, reason: "observation_unavailable", text: "hello")
                    : .init(state: state, reason: "observation_unavailable")
                XCTAssertThrowsError(
                    try VoiceSharingContributionEncoder.encode(
                        event: event(), provenance: provenance, observations: claim),
                    "\(stage)/\(state): observation_unavailable must be refused"
                ) { error in
                    guard let binding = error as? VoiceSharingRecordBinding.BindingError,
                        case .invalidField(let path, let message) = binding
                    else {
                        return XCTFail("\(stage)/\(state): expected a binding refusal, got \(error)")
                    }
                    XCTAssertEqual(path, "observations.\(stage).reason")
                    // The refusal must be the PAIRING rule, not the generic "not enumerated" — a
                    // validator that merely lacks the reason would also throw here for the wrong
                    // reason and leave this control green (found by mutation: removing the pairing
                    // check left this test passing).
                    // f8 refuses ANY reason on a completed stage before the pairing rule is reached, so
                    // for completed pairs the stronger rule is the one that correctly fires. Asserting
                    // the rule that applies keeps this from silently accepting an unrelated refusal.
                    let expected = state == "completed"
                        ? "a completed stage carries no reason"
                        : "requires state unknown"
                    XCTAssertTrue(message.contains(expected),
                                  "\(stage)/\(state): expected '\(expected)', got '\(message)'")
                }
            }
        }
    }

    /// Parity with the Worker's strict intake (Cloud `c569b319`): the same reason on the same stage
    /// is accepted on one state and refused on the others — the accept-any-state mutant must fail.
    func test_theAcceptAnyStateMutantFailsThePairingRule() throws {
        var accepted = observations
        accepted["asr"] = .init(state: "unknown", reason: "observation_unavailable")
        XCTAssertNoThrow(
            try VoiceSharingRecordBinding.bind(
                envelope: VoiceSharingContributionEncoder.encode(
                    event: event(), provenance: provenance, observations: accepted
                ).metadataEnvelope,
                audio: VoiceSharingContributionEncoder.encode(
                    event: event(), provenance: provenance, observations: accepted
                ).wav),
            "the accepted pair must bind")
        var refused = accepted
        refused["asr"] = .init(state: "failed", reason: "observation_unavailable")
        XCTAssertThrowsError(
            try VoiceSharingRecordBinding.bind(
                envelope: VoiceSharingContributionEncoder.encode(
                    event: event(), provenance: provenance, observations: refused
                ).metadataEnvelope,
                audio: VoiceSharingContributionEncoder.encode(
                    event: event(), provenance: provenance, observations: refused
                ).wav),
            "the same reason with a known outcome must be refused")
    }

    private func eventReplaced(audio: [Float]) -> VoiceSharingCollector.SegmentEvent {
        let e = event()
        return VoiceSharingCollector.SegmentEvent(
            kind: e.kind, captureID: e.captureID, enrollmentEpoch: e.enrollmentEpoch,
            authorizationSession: e.authorizationSession, retainedSamples: audio.count,
            truncated: e.truncated, droppedSpans: [], originalSampleCount: nil,
            audio: audio, isGateControl: false)
    }

    func test_truncationFactsAreRecordedExplicitly() throws {
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(truncated: true), provenance: provenance, observations: observations)
        let bound = try VoiceSharingRecordBinding.bind(
            envelope: encoded.metadataEnvelope, audio: encoded.wav)
        // Explicitness of dropped spans / original duration is pinned via the record content:
        let record = try JSONSerialization.jsonObject(with: encoded.recordJSON) as! [String: Any]
        let audio = record["audio"] as! [String: Any]
        XCTAssertEqual(audio["truncated"] as! Bool, true)
        XCTAssertEqual((audio["dropped_spans"] as! [[String: Int]]).count, 1)
        XCTAssertEqual(audio["original_duration_ms"] as? Int ?? -1, 1_002,
                       "original duration derives from the segmenter's own count — recorded, never omitted")
    }
}
