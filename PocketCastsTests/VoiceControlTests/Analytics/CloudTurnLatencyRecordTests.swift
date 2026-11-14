import XCTest

@testable import podcasts

/// The per-turn latency record: what it reports, and that it reports it exactly once per request.
///
/// `cloud-assistant.md` (L33) requires clients to measure first audible audio on their own clock.
/// Android already reports `end of speech → first audible`; these controls pin the same numbers on
/// this side, including the cases where a number must be ABSENT rather than invented.
final class CloudTurnLatencyRecordTests: XCTestCase {
    /// The headline figure: end of speech to first audible, plus the request leg in between.
    func test_reportsEndOfSpeechToFirstAudibleAndTheRequestLeg() {
        let record = CloudTurnLatencyRecord(requestId: "r1", endOfSpeech: 100.0)
        let line = record.logLine(requestSent: 100.4, firstAudible: 102.1, outcome: "done")

        XCTAssertTrue(line.contains("end_of_speech_to_request=400ms"), line)
        XCTAssertTrue(line.contains("request_to_first_audible=1700ms"), line)
        XCTAssertTrue(line.contains("end_of_speech_to_first_audible=2100ms"), line)
        XCTAssertFalse(line.contains("first_audible=absent"))
        XCTAssertTrue(line.contains("request_id=r1"), line)
    }

    /// A turn that produced no audio says so. A record that silently omitted the number would be
    /// indistinguishable from one that never ran, which is exactly the failure worth measuring.
    func test_aTurnWithNoAudioReportsAbsenceRatherThanZero() {
        let record = CloudTurnLatencyRecord(requestId: "r2", endOfSpeech: 50.0)
        let line = record.logLine(requestSent: 50.2, firstAudible: nil, outcome: "error")

        XCTAssertTrue(line.contains("first_audible=absent"), line)
        XCTAssertTrue(line.contains("end_of_speech_to_first_audible=none"), line)
        XCTAssertFalse(line.contains("end_of_speech_to_first_audible=0ms"),
                       "zero would claim instantaneous audio")
    }

    /// A request with no spoken start (a typed request, an acceptance run) still reports the
    /// request-to-audible leg rather than inventing an end of speech.
    func test_aRequestWithoutASpokenStartStillReportsItsAudibleLeg() {
        let record = CloudTurnLatencyRecord(requestId: "r3", endOfSpeech: nil)
        let line = record.logLine(requestSent: 10.0, firstAudible: 11.5, outcome: "done")

        XCTAssertTrue(line.contains("end_of_speech_to_request=none"), line)
        XCTAssertTrue(line.contains("request_to_first_audible=1500ms"), line)
        XCTAssertTrue(line.contains("end_of_speech_to_first_audible=none"), line)
    }

    /// An order that cannot be true (audible before the request) is refused rather than reported
    /// as a negative duration: a skewed clock is a measurement bug, not a very fast turn.
    func test_impossibleOrderingsAreNotReportedAsNegativeDurations() {
        let record = CloudTurnLatencyRecord(requestId: "r4", endOfSpeech: 100.0)
        XCTAssertNil(record.requestToFirstAudibleMs(requestSent: 10.0, firstAudible: 5.0))
        XCTAssertNil(record.endOfSpeechToFirstAudibleMs(firstAudible: 99.0))
        XCTAssertNil(record.endOfSpeechToRequestMs(requestSent: 99.0))
    }
}
