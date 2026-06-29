class ToolCallMapper {
    func map(_ call: ToolCall) -> (any VoiceIntent)? {
        switch call.name {
        case "playback": return mapPlayback(call.arguments)
        case "effects": return mapEffects(call.arguments)
        case "volume": return mapVolume(call.arguments)
        case "sleep": return mapSleep(call.arguments)
        case "chapter": return mapChapter(call.arguments)
        case "bookmark": return mapBookmark(call.arguments)
        case "queue": return mapQueue(call.arguments)
        case "playback_query": return mapPlaybackQuery(call.arguments)
        case "stats_query": return mapStatsQuery(call.arguments)
        case "cloud_route": return mapCloudRoute(call.arguments)
        case "no_match": return nil
        default: return nil
        }
    }

    private func mapPlayback(_ args: [String: Any]) -> PlaybackIntent? {
        guard let action = args["action"] as? String else { return nil }
        switch action {
        case "pause": return .pause
        case "resume": return .resume
        case "seek_relative":
            let delta = args["delta_seconds"] as? Int
            return .seekRelative(deltaSeconds: delta ?? 30)
        case "seek_to":
            guard let pos = args["position_seconds"] as? Int else { return nil }
            return .seekTo(positionSeconds: pos)
        case "next_episode": return .nextEpisode
        default: return nil
        }
    }

    private func mapEffects(_ args: [String: Any]) -> EffectsIntent? {
        guard let action = args["action"] as? String else { return nil }
        switch action {
        case "set_speed":
            guard let speed = args["speed"] as? Double else { return nil }
            return .setSpeed(speed)
        case "adjust_speed":
            let delta = args["delta"] as? Double ?? 0.25
            return .adjustSpeed(delta: delta)
        case "set_trim_mode":
            guard let raw = args["trim_mode"] as? String, let mode = TrimMode(rawValue: raw) else { return nil }
            return .setTrimMode(mode)
        case "set_volume_boost":
            guard let enabled = args["enabled"] as? Bool else { return nil }
            return .setVolumeBoost(enabled: enabled)
        case "query": return .query
        default: return nil
        }
    }

    private func mapVolume(_ args: [String: Any]) -> VolumeIntent? {
        guard let action = args["action"] as? String else { return nil }
        switch action {
        case "set":
            guard let level = args["level"] as? Int else { return nil }
            return .setVolume(level)
        case "adjust":
            let delta = args["delta"] as? Int ?? 10
            return .adjustVolume(delta: delta)
        case "query": return .query
        default: return nil
        }
    }

    private func mapSleep(_ args: [String: Any]) -> SleepIntent? {
        guard let action = args["action"] as? String else { return nil }
        switch action {
        case "set":
            guard let minutes = args["minutes"] as? Int else { return nil }
            return .set(minutes: minutes)
        case "end_of_episode": return .endOfEpisode
        case "end_of_chapter": return .endOfChapter
        case "add_time":
            let minutes = args["minutes"] as? Int ?? 5
            return .addTime(minutes: minutes)
        case "cancel": return .cancel
        case "query": return .query
        default: return nil
        }
    }

    private func mapChapter(_ args: [String: Any]) -> ChapterIntent? {
        guard let action = args["action"] as? String else { return nil }
        switch action {
        case "next": return .next
        case "previous": return .previous
        case "by_index":
            guard let index = args["index"] as? Int else { return nil }
            return .byIndex(index)
        case "by_title":
            guard let title = args["title"] as? String else { return nil }
            return .byTitle(title)
        case "open_link":
            let index = args["index"] as? Int
            let query = args["query"] as? String
            return .openLink(index: index, query: query)
        case "query_list": return .queryList
        case "query_current": return .queryCurrent
        case "query_count": return .queryCount
        case "query_next": return .queryNext
        default: return nil
        }
    }

    private func mapBookmark(_ args: [String: Any]) -> BookmarkIntent? {
        guard let action = args["action"] as? String else { return nil }
        switch action {
        case "add":
            let title = args["title"] as? String
            return .add(title: title)
        case "rename":
            guard let ref = args["ref"] as? String, let title = args["title"] as? String else { return nil }
            return .rename(ref: ref, title: title)
        case "play":
            guard let ref = args["ref"] as? String else { return nil }
            return .play(ref: ref)
        case "delete":
            guard let ref = args["ref"] as? String else { return nil }
            return .delete(ref: ref)
        case "delete_all": return .deleteAll
        case "query_list": return .queryList
        case "query_count": return .queryCount
        case "query_nearby": return .queryNearby
        default: return nil
        }
    }

    private func mapQueue(_ args: [String: Any]) -> QueueIntent? {
        guard let action = args["action"] as? String else { return nil }
        switch action {
        case "add_top":
            guard let episode = args["episode"] as? String else { return nil }
            return .addTop(episode: episode)
        case "add_bottom":
            guard let episode = args["episode"] as? String else { return nil }
            return .addBottom(episode: episode)
        case "remove":
            guard let episode = args["episode"] as? String else { return nil }
            return .remove(episode: episode)
        case "move_to_top":
            guard let episode = args["episode"] as? String else { return nil }
            return .moveToTop(episode: episode)
        case "move_to_bottom":
            guard let episode = args["episode"] as? String else { return nil }
            return .moveToBottom(episode: episode)
        case "clear": return .clear
        case "remove_by_podcast":
            guard let podcast = args["podcast"] as? String else { return nil }
            return .removeByPodcast(podcast: podcast)
        case "sort":
            guard let raw = args["sort_order"] as? String, let order = SortOrder(rawValue: raw) else { return nil }
            return .sort(sortOrder: order)
        case "query_contents": return .queryContents
        case "query_next": return .queryNext
        case "query_length": return .queryLength
        case "query_is_queued":
            guard let episode = args["episode"] as? String else { return nil }
            return .queryIsQueued(episode: episode)
        default: return nil
        }
    }

    private func mapPlaybackQuery(_ args: [String: Any]) -> PlaybackQueryIntent? {
        guard let action = args["action"] as? String else { return nil }
        switch action {
        case "whats_playing": return .whatsPlaying
        case "position": return .position
        case "time_remaining": return .timeRemaining
        case "episode_duration": return .episodeDuration
        case "publish_date": return .publishDate
        case "episode_description": return .episodeDescription
        case "download_status": return .downloadStatus
        case "episode_title": return .episodeTitle
        default: return nil
        }
    }

    private func mapStatsQuery(_ args: [String: Any]) -> StatsQueryIntent? {
        guard let action = args["action"] as? String else { return nil }
        let period = args["period"] as? String
        switch action {
        case "listening_time": return .listeningTime(period: period)
        case "top_podcasts": return .topPodcasts(period: period)
        case "episodes_finished": return .episodesFinished(period: period)
        case "listening_streak": return .listeningStreak
        case "subscription_count": return .subscriptionCount
        case "unplayed_total": return .unplayedTotal
        case "download_stats": return .downloadStats
        case "new_episodes":
            let timeframe = args["timeframe"] as? String
            return .newEpisodes(timeframe: timeframe)
        case "time_since_last_listen": return .timeSinceLastListen
        default: return nil
        }
    }

    private func mapCloudRoute(_ args: [String: Any]) -> CloudRouteIntent? {
        guard let request = args["request"] as? String else { return nil }
        let tierRaw = args["tier"] as? String ?? "unknown"
        let tier = CloudTier(rawValue: tierRaw) ?? .unknown
        let context = PlaybackContext(episodeId: "", positionMs: 0, recentTimestamps: [])
        return CloudRouteIntent(request: request, tier: tier, context: context)
    }
}
