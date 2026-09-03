import XCTest
@testable import podcasts

final class LfmPromptTests: XCTestCase {
    func test_systemPrompt_isExactShortLine() {
        XCTAssertEqual(
            LfmPrompt.system,
            "You map podcast voice commands to a tool call."
        )
    }

    func test_request_doesNotDumpTools() {
        let text = LfmPrompt.render(transcript: "pause", history: [])
        XCTAssertFalse(text.contains("List of tools"))
        XCTAssertTrue(
            text.contains("<|im_start|>system\nYou map podcast voice commands to a tool call.")
        )
        XCTAssertTrue(text.hasSuffix("<|im_start|>assistant\n"))
    }

    func test_request_includesHistoryUpToFourTurns() {
        let history = (1...5).map { index in
            DialogPromptTurn(
                role: index % 2 == 1 ? "user" : "assistant",
                content: "turn-\(index)"
            )
        }
        let text = LfmPrompt.render(transcript: "pause", history: history)
        XCTAssertFalse(text.contains("turn-1"))
        XCTAssertTrue(text.contains("turn-2"))
        XCTAssertTrue(text.contains("turn-5"))
    }
}
