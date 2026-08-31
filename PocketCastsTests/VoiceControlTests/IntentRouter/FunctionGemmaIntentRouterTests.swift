import XCTest
@testable import podcasts

final class FunctionGemmaIntentRouterTests: XCTestCase {

    func test_isReady_falseWithoutSession() {
        let router = FunctionGemmaIntentRouter()
        XCTAssertFalse(router.isReady)
    }

    func test_ensureReady_withoutModel_returnsFailure() async {
        let factory = RecordingSessionFactory()
        factory.makeError = FunctionGemmaSessionPool.SessionError.noModelAvailable
        let pool = FunctionGemmaSessionPool(factory: factory)
        pool.modelFilesReady = { true }
        let router = FunctionGemmaIntentRouter(sessionPool: pool)
        let result = await router.ensureReady()
        if case .failure = result {
            // Expected when no session can be prepared
        } else {
            XCTFail("Expected failure without a prepared session")
        }
    }

    func test_classify_withoutSession_returnsNone() {
        let router = FunctionGemmaIntentRouter()
        let result = router.classify(transcript: "pause the podcast")
        if case .none = result {
            // Expected when no Core ML session is available
        } else {
            XCTFail("Expected .none without model session, got \(result)")
        }
    }

    func test_classify_emptyTranscript_returnsNone() {
        let router = FunctionGemmaIntentRouter()
        let result = router.classify(transcript: "")
        if case .none = result {
            // Expected for empty transcript
        } else {
            XCTFail("Expected .none for empty transcript, got \(result)")
        }
    }

    func test_classify_withoutSession_reportsRouterNotReady() {
        let router = FunctionGemmaIntentRouter()
        var captured: RouterClassificationMetrics?
        router.onMetrics = { captured = $0 }
        let result = router.classify(transcript: "pause the podcast")
        if case .none = result {
            // No session available — router cannot engage
        } else {
            XCTFail("Expected .none without a session, got \(result)")
        }
        XCTAssertEqual(captured?.outcome, "router_not_ready")
        XCTAssertGreaterThanOrEqual(captured?.totalMs ?? -1, 0)
    }

    func test_classify_withPreparedSession_returnsIntentAndReportsOutcome() async {
        let factory = RecordingSessionFactory(
            output: "<start_function_call>call:playback{action:<escape>pause</escape>}<end_function_call>"
        )
        let pool = FunctionGemmaSessionPool(factory: factory)
        pool.modelFilesReady = { true }
        await pool.prepare()

        let router = FunctionGemmaIntentRouter(sessionPool: pool)
        var captured: RouterClassificationMetrics?
        router.onMetrics = { captured = $0 }

        let result = router.classify(transcript: "pause the podcast")
        if case .intent(let intent) = result, let playback = intent as? PlaybackIntent {
            XCTAssertEqual(playback, .pause)
        } else {
            XCTFail("Expected PlaybackIntent.pause, got \(result)")
        }
        XCTAssertEqual(captured?.outcome, "intent")
        XCTAssertGreaterThanOrEqual(captured?.totalMs ?? -1, 0)
    }
}
