import Foundation

/// Active FunctionGemma tool schema.
///
/// Mirrors `training/function-call/data/tools.json` exactly (12 tools, ordered
/// parameters, per-parameter descriptions). Parameter order matters: the prompt
/// contract renders declarations in schema order, so this order is part of the
/// trained prompt bytes. `required` defaults to `["action"]` per voice-intents.md
/// ("The `action` field is always required") and `return` is `OBJECT` for every
/// tool, matching the FunctionGemma declaration format in the recognition spec.
enum ToolSchema {
    static func tools() -> [[String: Any]] {
        [
            playbackTool,
            effectsTool,
            volumeTool,
            sleepTool,
            chapterTool,
            bookmarkTool,
            queueTool,
            playbackQueryTool,
            statsQueryTool,
            cloudRouteTool,
            dialogControlTool,
            noMatchTool,
        ]
    }

    private static func tool(
        _ name: String,
        _ description: String,
        parameters: [[String: Any]],
        required: [String] = ["action"]
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": parameters,
            "required": required,
            "return": ["type": "OBJECT"],
        ]
    }

    private static func parameter(_ name: String, _ type: String, _ description: String? = nil, enum values: [String]? = nil) -> [String: Any] {
        var entry: [String: Any] = ["name": name, "type": type]
        if let values { entry["enum"] = values }
        if let description { entry["description"] = description }
        return entry
    }

    private static let playbackTool = tool(
        "playback",
        "Basic playback controls: pause, resume, skip forward or backward, seek to a position, play next episode.",
        parameters: [
            parameter("action", "string", enum: ["pause", "resume", "seek_relative", "seek_to", "next_episode"]),
            parameter("position_seconds", "integer", "Signed absolute episode position. Use with seek_to; non-negative values are offsets from the beginning, 0 means beginning, and negative values are offsets back from the episode end."),
            parameter("delta_seconds", "integer", "Signed seek delta. Use with seek_relative; positive=forward, negative=backward. Omit to use the app's default skip interval."),
        ]
    )

    private static let effectsTool = tool(
        "effects",
        "Playback effects: speed, trim silence, volume boost.",
        parameters: [
            parameter("action", "string", enum: ["set_speed", "adjust_speed", "set_trim_mode", "set_volume_boost", "query"]),
            parameter("speed", "number", "Playback speed (0.5–5.0)."),
            parameter("delta", "number", "Speed delta. Positive = faster, negative = slower."),
            parameter("mode", "string", "Trim silence mode.", enum: ["off", "low", "medium", "high"]),
            parameter("enabled", "boolean", "On/off for volume boost."),
        ]
    )

    private static let volumeTool = tool(
        "volume",
        "Control device volume.",
        parameters: [
            parameter("action", "string", enum: ["set_volume", "adjust_volume", "query"]),
            parameter("volume", "integer", "Volume level (0–100)."),
            parameter("delta", "integer", "Volume delta. Positive = louder, negative = quieter."),
        ]
    )

    private static let sleepTool = tool(
        "sleep",
        "Sleep timer: set a timer, stop at end of episode or chapter, add time, cancel.",
        parameters: [
            parameter("action", "string", enum: ["set", "end_of_episode", "end_of_chapter", "add_time", "cancel", "query"]),
            parameter("minutes", "integer", "Duration in minutes."),
        ]
    )

    private static let chapterTool = tool(
        "chapter",
        "Navigate and query episode chapters.",
        parameters: [
            parameter("action", "string", enum: ["next", "previous", "by_index", "by_title", "open_link", "query_list", "query_current", "query_count", "query_next"]),
            parameter("index", "integer", "Chapter number (1-based)."),
            parameter("query", "string", "Chapter title search query, including chapter-name references for by_title or open_link."),
        ]
    )

    private static let bookmarkTool = tool(
        "bookmark",
        "Create, rename, play, delete, and query bookmarks.",
        parameters: [
            parameter("action", "string", enum: ["add", "rename", "play", "delete", "delete_all", "query_list", "query_count", "query_nearby"]),
            parameter("title", "string", "Bookmark title. For add (optional), rename (new title)."),
            parameter("ref", "string", "Bookmark reference: title, index number (e.g. '3'), or 'latest'."),
        ]
    )

    private static let queueTool = tool(
        "queue",
        "Manage the Up Next queue: add, remove, reorder, clear.",
        parameters: [
            parameter("action", "string", enum: ["add_top", "add_bottom", "remove", "move_to_top", "move_to_bottom", "clear", "remove_by_podcast", "sort", "query_contents", "query_next", "query_length", "query_is_queued"]),
            parameter("episode", "string", "Episode title or description."),
            parameter("podcast", "string", "Podcast name."),
            parameter("sort_order", "string", enum: ["newest_first", "oldest_first"]),
        ]
    )

    private static let playbackQueryTool = tool(
        "playback_query",
        "Query current playback state and stored episode metadata.",
        parameters: [
            parameter("action", "string", enum: ["whats_playing", "position", "time_remaining", "episode_duration", "publish_date", "episode_description", "download_status", "episode_title"]),
        ]
    )

    private static let statsQueryTool = tool(
        "stats_query",
        "Query listening statistics: listening time, top podcasts, streaks, subscription counts.",
        parameters: [
            parameter("action", "string", enum: ["listening_time", "top_podcasts", "episodes_finished", "listening_streak", "subscription_count", "unplayed_total", "download_stats", "new_episodes", "time_since_last_listen"]),
            parameter("period", "string", "Time period: 'today', 'this week', 'this month', 'all time'."),
            parameter("timeframe", "string", "Time window for new_episodes."),
        ]
    )

    private static let cloudRouteTool = tool(
        "cloud_route",
        "Route cross-podcast, cross-episode, web-backed, or cloud-enhanced assistant requests to the cloud assistant. Use when the request is broader than current episode local playback, metadata, queue, chapter, bookmark, or transcript tools. Preserve the full user request; do not locally decompose it into local actions.",
        parameters: [
            parameter("action", "string", enum: ["route"]),
            parameter("request", "string", "The complete user utterance or resolved multi-turn request to send to cloud."),
            parameter("tier", "string", "Lowest cloud tier that appears to cover the request. Use unknown when tier cannot be determined locally.", enum: ["free", "premium", "unknown"]),
        ]
    )

    private static let dialogControlTool = tool(
        "dialog_control",
        "Router-only control for bounded multi-turn voice dialogs. Use only to start a supported clarification/confirmation flow, fill a pending slot, confirm, deny, cancel, or signal that the user started a new command. This tool never dispatches an app action directly.",
        parameters: [
            parameter("action", "string", enum: ["begin", "provide_slot", "confirm", "deny", "cancel", "new_command"]),
            parameter("target_tool", "string", "Tool being clarified, such as bookmark or queue."),
            parameter("target_action", "string", "Action being clarified, such as rename or clear."),
            parameter("slot", "string", "Pending slot supplied by the current turn, such as ref or title."),
            parameter("value", "string", "Normalized slot value, or the replacement utterance when action is new_command."),
        ]
    )

    private static let noMatchTool = tool(
        "no_match",
        "No command was recognized. Select this when the user is not issuing a voice command.",
        parameters: [],
        required: []
    )
}
