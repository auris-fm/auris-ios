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
        conversionVersion: 1)

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
