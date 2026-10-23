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
                    XCTAssertTrue(message.contains("requires state unknown"),
                                  "\(stage)/\(state): expected the pairing refusal, got '\(message)'")
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
