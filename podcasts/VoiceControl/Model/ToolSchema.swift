enum ToolSchema {
    /// Returns the complete tools array for the FunctionGemma prompt.
    /// Mirrors the voice-intents.md schema exactly.
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
        ]
    }

    private static let playbackTool: [String: Any] = [
        "name": "playback",
        "description": "Control podcast playback",
        "parameters": [
            "action": ["enum": ["pause", "resume", "seek_relative", "seek_to", "next_episode"]],
            "delta_seconds": ["type": "integer"],
            "position_seconds": ["type": "integer"],
        ],
    ]

    private static let effectsTool: [String: Any] = [
        "name": "effects",
        "description": "Adjust playback effects",
        "parameters": [
            "action": ["enum": ["set_speed", "adjust_speed", "set_trim_mode", "set_volume_boost", "query"]],
            "speed": ["type": "number"],
            "delta": ["type": "number"],
            "trim_mode": ["enum": ["off", "low", "medium", "high"]],
            "enabled": ["type": "boolean"],
        ],
    ]

    private static let volumeTool: [String: Any] = [
        "name": "volume",
        "description": "Control playback volume",
        "parameters": [
            "action": ["enum": ["set_volume", "adjust_volume", "query"]],
            "level": ["type": "integer"],
            "delta": ["type": "integer"],
        ],
    ]

    private static let sleepTool: [String: Any] = [
        "name": "sleep",
        "description": "Manage sleep timer",
        "parameters": [
            "action": ["enum": ["set", "end_of_episode", "end_of_chapter", "add_time", "cancel", "query"]],
            "minutes": ["type": "integer"],
        ],
    ]

    private static let chapterTool: [String: Any] = [
        "name": "chapter",
        "description": "Navigate chapters",
        "parameters": [
            "action": ["enum": ["next", "previous", "by_index", "by_title", "open_link", "query_list", "query_current", "query_count", "query_next"]],
            "index": ["type": "integer"],
            "title": ["type": "string"],
            "query": ["type": "string"],
        ],
    ]

    private static let bookmarkTool: [String: Any] = [
        "name": "bookmark",
        "description": "Manage bookmarks",
        "parameters": [
            "action": ["enum": ["add", "rename", "play", "delete", "delete_all", "query_list", "query_count", "query_nearby"]],
            "title": ["type": "string"],
            "ref": ["type": "string"],
        ],
    ]

    private static let queueTool: [String: Any] = [
        "name": "queue",
        "description": "Manage Up Next queue",
        "parameters": [
            "action": ["enum": ["add_top", "add_bottom", "remove", "move_to_top", "move_to_bottom", "clear", "remove_by_podcast", "sort", "query_contents", "query_next", "query_length", "query_is_queued"]],
            "episode": ["type": "string"],
            "podcast": ["type": "string"],
            "sort_order": ["enum": ["newest_first", "oldest_first"]],
        ],
    ]

    private static let playbackQueryTool: [String: Any] = [
        "name": "playback_query",
        "description": "Query current playback state",
        "parameters": [
            "action": ["enum": ["whats_playing", "position", "time_remaining", "episode_duration", "publish_date", "episode_description", "download_status", "episode_title"]],
        ],
    ]

    private static let statsQueryTool: [String: Any] = [
        "name": "stats_query",
        "description": "Query listening statistics",
        "parameters": [
            "action": ["enum": ["listening_time", "top_podcasts", "episodes_finished", "listening_streak", "subscription_count", "unplayed_total", "download_stats", "new_episodes", "time_since_last_listen"]],
            "period": ["type": "string"],
            "timeframe": ["type": "string"],
        ],
    ]

    private static let cloudRouteTool: [String: Any] = [
        "name": "cloud_route",
        "description": "Route complex queries to the cloud",
        "parameters": [
            "request": ["type": "string"],
        ],
    ]
}
