import XCTest

@testable import podcasts

/// A latency timeline is only useful if its events mean what they say. The local path's final event
/// must not report a refused or failed attempt as an executed action, because a failure followed
/// immediately by "executed" reads as a zero-latency success — the exact confusion this log was
/// added to remove.
///
/// The classification is controlled directly rather than through log output, and the stated limit
/// is asserted too: the response model cannot see most local failures, so "executed" is a claim
/// about the response, not about the world.
final class LocalActionStageTests: XCTestCase {

    func test_errorResponseIsReportedAsFailed() {
        XCTAssertEqual(VoiceIntentExecutor.localActionStage(for: .earcon(.error)), "localActionFailed")
    }

    /// Every non-error response is reported as executed — including the silent ones. This is the
    /// behaviour, and the test exists so the limit below is not mistaken for a bug and quietly
    /// "fixed" into asserting something the model cannot observe.
    func test_nonErrorResponsesAreReportedAsExecuted() {
        XCTAssertEqual(VoiceIntentExecutor.localActionStage(for: .silent), "localActionExecuted")
        XCTAssertEqual(VoiceIntentExecutor.localActionStage(for: .earcon(.success)), "localActionExecuted")
        XCTAssertEqual(VoiceIntentExecutor.localActionStage(for: .spoken("done")), "localActionExecuted")
    }

    /// The limit, stated as a control rather than only in a comment: `.silent` and
    /// `.earcon(.success)` are what a local sink returns when it *could not* perform the action —
    /// a pause with nothing playing still returns success. So the executed stage cannot be read as
    /// a measurement of effect, and a future change that assumed otherwise would break here.
    func test_executedDoesNotMeanTheActionWasPerformed() {
        // A refusal that the response model cannot express looks exactly like a success.
        let refusalAsTheModelExpressesIt = VoiceResponse.earcon(.success)
        XCTAssertEqual(VoiceIntentExecutor.localActionStage(for: refusalAsTheModelExpressesIt),
                       "localActionExecuted",
                       "documented limit: the model cannot distinguish this refusal from a success")
    }
}
