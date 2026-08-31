import XCTest
@testable import podcasts

final class FunctionGemmaSessionPoolTests: XCTestCase {

    func test_prepare_prefillsTheSystemPromptExactlyOnce() async {
        let factory = RecordingSessionFactory()
        let pool = FunctionGemmaSessionPool(factory: factory)
        pool.modelFilesReady = { true }

        await pool.prepare()

        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(
            factory.sessions.first?.prefilled,
            [PromptBuilder.buildSystemPrompt(tools: ToolSchema.tools())]
        )
        XCTAssertNotNil(pool.acquire())
    }

    func test_prepare_factoryFailure_leavesPoolNotReady() async {
        let factory = RecordingSessionFactory()
        factory.makeError = FunctionGemmaSessionPool.SessionError.noModelAvailable
        let pool = FunctionGemmaSessionPool(factory: factory)
        pool.modelFilesReady = { true }

        await pool.prepare()

        XCTAssertNil(pool.acquire())
    }

    func test_coreMLContract_requiresDocumentedIO() {
        XCTAssertNoThrow(
            try CoreMLModelContract.validate(inputNames: ["input_text"], outputNames: ["output_text"])
        )
        XCTAssertThrowsError(
            try CoreMLModelContract.validate(inputNames: ["input_ids"], outputNames: ["logits"])
        )
    }
}
