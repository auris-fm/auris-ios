import XCTest
@testable import podcasts

final class ToolSchemaTests: XCTestCase {

    func test_tools_returnsTenTools() {
        let tools = ToolSchema.tools()
        XCTAssertEqual(tools.count, 10)
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

    func test_eachTool_hasNameAndDescription() {
        let tools = ToolSchema.tools()
        for tool in tools {
            XCTAssertNotNil(tool["name"] as? String, "Tool missing name")
            XCTAssertNotNil(tool["description"] as? String, "Tool missing description")
            XCTAssertNotNil(tool["parameters"] as? [String: Any], "Tool missing parameters")
        }
    }
}
