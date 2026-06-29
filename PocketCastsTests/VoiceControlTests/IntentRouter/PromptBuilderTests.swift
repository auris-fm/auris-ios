import XCTest
@testable import podcasts

final class PromptBuilderTests: XCTestCase {

    func test_buildSystemPrompt_containsTools() {
        let builder = PromptBuilder()
        let tools: [[String: Any]] = [["name": "playback", "parameters": ["action": ["enum": ["pause"]]]]]
        let prompt = builder.buildSystemPrompt(tools: tools)
        XCTAssertTrue(prompt.contains("<bos>"))
        XCTAssertTrue(prompt.contains("<start_of_turn>developer"))
        XCTAssertTrue(prompt.contains("playback"))
        XCTAssertTrue(prompt.contains("<end_of_turn>"))
    }

    func test_buildUserTurn_wrapsTranscript() {
        let builder = PromptBuilder()
        let prompt = builder.buildUserTurn(transcript: "pause")
        XCTAssertTrue(prompt.contains("<start_of_turn>user"))
        XCTAssertTrue(prompt.contains("pause"))
        XCTAssertTrue(prompt.contains("<start_of_turn>model"))
    }

    func test_buildSystemPrompt_allTenTools() {
        let builder = PromptBuilder()
        let tools = ToolSchema.tools()
        let prompt = builder.buildSystemPrompt(tools: tools)
        XCTAssertTrue(prompt.contains("playback"))
        XCTAssertTrue(prompt.contains("effects"))
        XCTAssertTrue(prompt.contains("volume"))
        XCTAssertTrue(prompt.contains("sleep"))
        XCTAssertTrue(prompt.contains("chapter"))
        XCTAssertTrue(prompt.contains("bookmark"))
        XCTAssertTrue(prompt.contains("queue"))
        XCTAssertTrue(prompt.contains("playback_query"))
        XCTAssertTrue(prompt.contains("stats_query"))
        XCTAssertTrue(prompt.contains("cloud_route"))
    }
}
