import CryptoKit
import XCTest
@testable import podcasts

/// PHASE 2 of the recording-upload spec (core 0264051b, name schema v1): the record states the wake
/// requirement that was IN FORCE when the speech began, the detector's MEASURED score and threshold,
/// and the recogniser's source language — including on empty and non-content results.
///
/// Every assertion below is made against the PERSISTED record: the encoder's canonical JSON and the
/// production binding, which is the same authority the queue applies to a stored entry. Nothing here
/// asserts on an in-memory intermediate, so "the record says X" means a record on disk says X.
final class VoiceSharingNameSchemaControls: XCTestCase {
    private let samples: [Float] = [0, 0.25, -0.5, 0.99, -1, 0.5]

    private let provenance = VoiceSharingContributionEncoder.Provenance(
        platform: "ios", appVersion: "9.0", build: "1000", captureSessionID: "sess-1",
        models: VoiceSharingContributionEncoder.Models(
            vad: .init(id: "vad-1", version: "1"), wakeword: .init(id: "wake-1", version: "1"),
            asr: .init(id: "asr-1", version: "1"), translation: nil,
            router: .init(id: "router-1", version: "1")),
        conversionVersion: "v1")

    private func event(wakeRequired: Bool) -> VoiceSharingCollector.SegmentEvent {
        .init(
            kind: .completed, captureID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            enrollmentEpoch: "epoch-1", wakeRequired: wakeRequired,
            authorizationSession: "sess-1", retainedSamples: samples.count,
            truncated: false, droppedSpans: [], originalSampleCount: nil, audio: samples,
            isGateControl: false)
    }

    /// A wake-positive capture: the detector ran and measured a score above its threshold.
    private let wakePositiveObservations: [String: VoiceSharingContributionEncoder.StageOutcome] = [
        "wake": .init(state: "completed", score: 0.941, threshold: 0.75),
        "bleed": .init(state: "not_run", reason: "no_playback_reference"),
        "asr": .init(state: "completed", text: "Auris play the news", sourceLanguage: "en",
                     routerInput: "play the news"),
        "translation": .init(state: "not_run", reason: "no_text"),
        "routing": .init(state: "completed", predictedIntent: "play", predictedTool: "play"),
        "execution": .init(state: "completed", outcome: "succeeded"),
    ]

    /// The persisted record's `observations.wake` block, read back out of the canonical JSON.
    private func persistedWake(_ encoded: VoiceSharingContributionEncoder.Encoded) throws -> [String: Any] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded.recordJSON) as? [String: Any])
        return try XCTUnwrap((object["observations"] as? [String: Any])?["wake"] as? [String: Any])
    }

    private func persistedRecord(_ encoded: VoiceSharingContributionEncoder.Encoded) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded.recordJSON) as? [String: Any])
    }

    // MARK: - wake_required states the mode the speech began under

    /// Wake word required: the record says `true` and still binds. Asserted from the persisted record, so a
    /// dropped or renamed member fails here rather than at the server.
    func test_wakeRequiredTrueIsPersistedAndBinds() throws {
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(wakeRequired: true), provenance: provenance, observations: wakePositiveObservations)
        let record = try persistedRecord(encoded)
        XCTAssertEqual(record["wake_required"] as? Bool, true)
        XCTAssertNoThrow(try VoiceSharingRecordBinding.bind(
            envelope: encoded.metadataEnvelope, audio: encoded.wav))
    }

    /// Grace active (speech heard WITHOUT a wake word): the same field states `false`. A record that kept
    /// the wake-positive shape while stating `false` is exactly the interesting case — the mode and the
    /// detector's verdict are independent facts.
    func test_wakeRequiredFalseIsPersistedForGraceSpeechWithoutAWakeWord() throws {
        let observations: [String: VoiceSharingContributionEncoder.StageOutcome] = [
            "wake": .init(state: "completed", decision: "rejected", score: 0.112, threshold: 0.75),
            "bleed": .init(state: "not_run", reason: "no_playback_reference"),
            "asr": .init(state: "completed", text: "play the news", sourceLanguage: "en",
                         routerInput: "play the news"),
            "translation": .init(state: "not_run", reason: "no_text"),
            "routing": .init(state: "completed", predictedIntent: "play", predictedTool: "play"),
            "execution": .init(state: "completed", outcome: "succeeded"),
        ]
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(wakeRequired: false), provenance: provenance, observations: observations)
        let record = try persistedRecord(encoded)
        XCTAssertEqual(record["wake_required"] as? Bool, false)
        XCTAssertNoThrow(try VoiceSharingRecordBinding.bind(
            envelope: encoded.metadataEnvelope, audio: encoded.wav))
    }

    /// One breath: "Auris, play the news" heard in wake-word mode — the wake word is required AND the
    /// recognition is non-empty. Both facts are on the same record: `wake_required` true, the measured
    /// pair, and the recogniser's language.
    func test_combinedWakeWordAndCommandInOneBreathRecordsEveryFact() throws {
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(wakeRequired: true), provenance: provenance, observations: wakePositiveObservations)
        let record = try persistedRecord(encoded)
        XCTAssertEqual(record["wake_required"] as? Bool, true)
        let wake = try persistedWake(encoded)
        XCTAssertEqual(wake["score"] as? Double, 0.941)
        XCTAssertEqual(wake["threshold"] as? Double, 0.75)
        let asr = try XCTUnwrap((record["observations"] as? [String: Any])?["asr"] as? [String: Any])
        XCTAssertEqual(asr["source_language"] as? String, "en")
        XCTAssertEqual(asr["text"] as? String, "Auris play the news")
        XCTAssertNoThrow(try VoiceSharingRecordBinding.bind(
            envelope: encoded.metadataEnvelope, audio: encoded.wav))
    }

    // MARK: - measured wake values

    /// The score and threshold are MEASURED numbers on the record, not `na` or absent. A detector that ran
    /// always measured both, so a record that omits them loses a real observation.
    func test_measuredWakeScoreAndThresholdArePersisted() throws {
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(wakeRequired: true), provenance: provenance, observations: wakePositiveObservations)
        let wake = try persistedWake(encoded)
        XCTAssertEqual(wake["score"] as? Double, 0.941)
        XCTAssertEqual(wake["threshold"] as? Double, 0.75)
        XCTAssertEqual(wake["state"] as? String, "completed")
    }

    /// A re-stated decision must not erase the measurement: the detector measured the pair, and a later
    /// verdict amendment is not a second observation.
    func test_restatingTheDecisionKeepsTheMeasuredValues() throws {
        var observations = wakePositiveObservations
        observations["wake"] = observations["wake"]?.withDecision("accepted")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(wakeRequired: true), provenance: provenance, observations: observations)
        let wake = try persistedWake(encoded)
        XCTAssertEqual(wake["decision"] as? String, "accepted")
        XCTAssertEqual(wake["score"] as? Double, 0.941)
        XCTAssertEqual(wake["threshold"] as? Double, 0.75)
    }

    // MARK: - source_language on empty and non-content results

    /// An EMPTY recognition is still a recognition that heard a language. Before this control the
    /// `empty_result` branch published no language at all, so an empty transcript lost the one fact that
    /// explains it.
    func test_emptyRecognitionStillPersistsItsSourceLanguage() throws {
        var observations = wakePositiveObservations
        observations["asr"] = .init(state: "completed", reason: "empty_result", sourceLanguage: "ja")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(wakeRequired: true), provenance: provenance, observations: observations)
        let record = try persistedRecord(encoded)
        let asr = try XCTUnwrap((record["observations"] as? [String: Any])?["asr"] as? [String: Any])
        XCTAssertEqual(asr["reason"] as? String, "empty_result")
        XCTAssertEqual(asr["source_language"] as? String, "ja")
        XCTAssertNoThrow(try VoiceSharingRecordBinding.bind(
            envelope: encoded.metadataEnvelope, audio: encoded.wav))
    }

    /// Non-content output (punctuation or whitespace only) still carries the recogniser's language: the
    /// recogniser ran and reported it, and dropping it would make a dropped utterance indistinguishable
    /// from one in an unknown language.
    func test_nonContentResultStillPersistsItsSourceLanguage() throws {
        var observations = wakePositiveObservations
        observations["asr"] = .init(state: "completed", text: "…", sourceLanguage: "zh")
        observations["routing"] = .init(state: "not_run", reason: "no_candidates")
        observations["execution"] = .init(state: "not_run", reason: "client_refused")
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(wakeRequired: false), provenance: provenance, observations: observations)
        let record = try persistedRecord(encoded)
        let asr = try XCTUnwrap((record["observations"] as? [String: Any])?["asr"] as? [String: Any])
        XCTAssertEqual(asr["source_language"] as? String, "zh")
        XCTAssertEqual(record["wake_required"] as? Bool, false)
        XCTAssertNoThrow(try VoiceSharingRecordBinding.bind(
            envelope: encoded.metadataEnvelope, audio: encoded.wav))
    }

    // MARK: - the required field cannot be silently omitted

    /// RED CONTROL: a record without `wake_required` must be REFUSED by the production binding. Without this
    /// rule an encoder regression could drop the member and the server would accept a record whose mode is
    /// unknowable.
    func test_recordWithoutWakeRequiredIsRefusedByTheBinding() throws {
        let encoded = try VoiceSharingContributionEncoder.encode(
            event: event(wakeRequired: true), provenance: provenance, observations: wakePositiveObservations)
        var object = try persistedRecord(encoded)
        object.removeValue(forKey: "wake_required")
        var digest = ""
        #if canImport(CryptoKit)
        digest = SHA256.hash(data: try VoiceSharingRecordBinding.canonicalizeForTesting(object))
            .map { String(format: "%02x", $0) }.joined()
        #endif
        let resealed = try JSONSerialization.data(withJSONObject: ["record": object, "record_sha256": digest])
        XCTAssertThrowsError(try VoiceSharingRecordBinding.bind(envelope: resealed, audio: encoded.wav)) { error in
            guard let binding = error as? VoiceSharingRecordBinding.BindingError,
                  case .missingField(let path) = binding else {
                return XCTFail("expected missingField, got \(error)")
            }
            XCTAssertEqual(path, "record.wake_required")
        }
    }
}