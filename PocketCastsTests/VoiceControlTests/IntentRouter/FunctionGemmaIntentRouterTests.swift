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

    func test_classify_withoutSession_returnsNil() {
        let router = FunctionGemmaIntentRouter()
        let result = router.classify(transcript: "pause the podcast")
        XCTAssertNil(result)
    }

    func test_classify_emptyTranscript_returnsNil() {
        let router = FunctionGemmaIntentRouter()
        let result = router.classify(transcript: "")
        XCTAssertNil(result)
    }
}
