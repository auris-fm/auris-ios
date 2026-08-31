import XCTest
@testable import podcasts

final class PromptBuilderTests: XCTestCase {

    func test_buildSystemPrompt_startsWithBosAndDeveloperTurn() {
        let prompt = PromptBuilder.buildSystemPrompt(tools: [])
        XCTAssertEqual(
            prompt,
            "<bos><start_of_turn>developer\n" +
            "You are a model that can do function calling with the following functions\n" +
            "<end_of_turn>\n"
        )
    }

    func test_buildUserTurn_matchesCanonicalBytes() {
        XCTAssertEqual(
            PromptBuilder.buildUserTurn(transcript: "pause"),
            "\n<start_of_turn>user\npause<end_of_turn>\n<start_of_turn>model\n"
        )
    }

    func test_buildUserTurn_includesBoundedHistoryBeforeCurrentTurn() {
        let history = [
            DialogPromptTurn(role: "user", content: "Rename the bookmark."),
            DialogPromptTurn(
                role: "model",
                content: "<start_function_call>call:dialog_control{action:provide_slot,slot:ref}<end_function_call>"
            ),
        ]
        XCTAssertEqual(
            PromptBuilder.buildUserTurn(transcript: "The second one.", history: history),
            "\n<start_of_turn>user\nRename the bookmark.<end_of_turn>\n" +
            "<start_of_turn>model\n<start_function_call>call:dialog_control{action:provide_slot,slot:ref}<end_function_call><end_of_turn>\n" +
            "<start_of_turn>user\nThe second one.<end_of_turn>\n<start_of_turn>model\n"
        )
    }

    func test_escape_wrapsValue() {
        XCTAssertEqual(PromptBuilder.escape("pause"), "<escape>pause</escape>")
    }

    func test_formatToolDeclaration_rendersCanonicalSleepFormat() {
        let tool: [String: Any] = [
            "name": "sleep",
            "description": "Sleep timer: set a timer, stop at end of episode or chapter, add time, cancel.",
            "parameters": [
                [
                    "name": "action",
                    "type": "string",
                    "enum": ["set", "end_of_episode", "end_of_chapter", "add_time", "cancel", "query"],
                ],
                ["name": "minutes", "type": "integer", "description": "Duration in minutes."],
            ],
            "required": ["action"],
            "return": ["type": "OBJECT"],
        ]
        let expected = "<start_function_declaration>declaration:sleep{description:<escape>Sleep timer: set a timer, stop at end of episode or chapter, add time, cancel.</escape>,parameters:{properties:{action:{description:<escape></escape>,enum:[<escape>set</escape>,<escape>end_of_episode</escape>,<escape>end_of_chapter</escape>,<escape>add_time</escape>,<escape>cancel</escape>,<escape>query</escape>],type:<escape>STRING</escape>},minutes:{description:<escape>Duration in minutes.</escape>,type:<escape>INTEGER</escape>}},required:[<escape>action</escape>],type:<escape>OBJECT<escape>},return:{type:<escape>OBJECT</escape>}}<end_function_declaration>"
        let actual = PromptBuilder.formatToolDeclaration(tool)
        XCTAssertEqual(actual, expected)
    }

    func test_buildSystemPrompt_includesAllTwelveToolDeclarations() {
        let prompt = PromptBuilder.buildSystemPrompt(tools: ToolSchema.tools())
        for tool in ToolSchema.tools() {
            let name = tool["name"] as? String
            XCTAssertNotNil(name)
            XCTAssertTrue(prompt.contains("declaration:\(name!){"))
        }
        XCTAssertTrue(prompt.hasPrefix("<bos><start_of_turn>developer\n"))
        XCTAssertTrue(prompt.hasSuffix("<end_of_turn>\n"))
    }
}
