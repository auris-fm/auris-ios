import XCTest
@testable import podcasts

final class ToolSchemaTests: XCTestCase {

    func test_tools_returnsTwelveTools() {
        let tools = ToolSchema.tools()
        XCTAssertEqual(tools.count, 12)
    }

    func test_tools_containsPlayback() {
        let tools = ToolSchema.tools()
        let playback = tools.first { ($0["name"] as? String) == "playback" }
        XCTAssertNotNil(playback)
    }

    func test_tools_containsEffects() {
        let tools = ToolSchema.tools()
        let effects = tools.first { ($0["name"] as? String) == "effects" }
        XCTAssertNotNil(effects)
    }

    func test_tools_containsVolume() {
        let tools = ToolSchema.tools()
        let volume = tools.first { ($0["name"] as? String) == "volume" }
        XCTAssertNotNil(volume)
    }

    func test_tools_containsSleep() {
        let tools = ToolSchema.tools()
        let sleep = tools.first { ($0["name"] as? String) == "sleep" }
        XCTAssertNotNil(sleep)
    }

    func test_tools_containsChapter() {
        let tools = ToolSchema.tools()
        let chapter = tools.first { ($0["name"] as? String) == "chapter" }
        XCTAssertNotNil(chapter)
    }

    func test_tools_containsBookmark() {
        let tools = ToolSchema.tools()
        let bookmark = tools.first { ($0["name"] as? String) == "bookmark" }
        XCTAssertNotNil(bookmark)
    }

    func test_tools_containsQueue() {
        let tools = ToolSchema.tools()
        let queue = tools.first { ($0["name"] as? String) == "queue" }
        XCTAssertNotNil(queue)
    }

    func test_tools_containsPlaybackQuery() {
        let tools = ToolSchema.tools()
        let query = tools.first { ($0["name"] as? String) == "playback_query" }
        XCTAssertNotNil(query)
    }

    func test_tools_containsStatsQuery() {
        let tools = ToolSchema.tools()
        let query = tools.first { ($0["name"] as? String) == "stats_query" }
        XCTAssertNotNil(query)
    }

    func test_tools_containsCloudRoute() {
        let tools = ToolSchema.tools()
        let route = tools.first { ($0["name"] as? String) == "cloud_route" }
        XCTAssertNotNil(route)
    }

    func test_tools_containsNoMatch() {
        let tools = ToolSchema.tools()
        let noMatch = tools.first { ($0["name"] as? String) == "no_match" }
        XCTAssertNotNil(noMatch)
    }

    func test_effects_usesModeParameterNotTrimMode() {
        let tools = ToolSchema.tools()
        let effects = tools.first { ($0["name"] as? String) == "effects" }
        let params = effects?["parameters"] as? [[String: Any]] ?? []
        XCTAssertTrue(params.contains { ($0["name"] as? String) == "mode" })
        XCTAssertFalse(params.contains { ($0["name"] as? String) == "trim_mode" })
    }

    func test_playback_parameterOrderMatchesTrainingSchema() {
        let tools = ToolSchema.tools()
        let playback = tools.first { ($0["name"] as? String) == "playback" }
        let params = playback?["parameters"] as? [[String: Any]] ?? []
        XCTAssertEqual(params.map { $0["name"] as? String }, ["action", "position_seconds", "delta_seconds"])
    }

    func test_eachTool_hasNameDescriptionAndOrderedParameters() {
        let tools = ToolSchema.tools()
        for tool in tools {
            XCTAssertNotNil(tool["name"] as? String, "Tool missing name")
            XCTAssertNotNil(tool["description"] as? String, "Tool missing description")
            let params = tool["parameters"] as? [[String: Any]]
            XCTAssertNotNil(params, "Tool missing ordered parameters")
            for param in params ?? [] {
                XCTAssertNotNil(param["name"] as? String, "Parameter missing name")
                XCTAssertNotNil(param["type"] as? String, "Parameter missing type")
            }
        }
    }

    func test_eachTool_declaresActionRequired() {
        let tools = ToolSchema.tools()
        for tool in tools where tool["name"] as? String != "no_match" {
            let required = tool["required"] as? [String]
            XCTAssertEqual(required, ["action"])
        }
    }
}
