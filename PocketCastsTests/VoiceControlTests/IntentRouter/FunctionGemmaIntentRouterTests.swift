import XCTest
@testable import podcasts

final class FunctionGemmaIntentRouterTests: XCTestCase {

    func test_ensureReady_withoutModel_returnsFailure() async {
        let router = FunctionGemmaIntentRouter()
        let result = await router.ensureReady()
        if case .failure = result {
            // Expected when no Core ML model is available
        } else {
            XCTFail("Expected failure without model")
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
}
