import Foundation

class VoiceAnalytics {
    private let analytics: AnalyticsService

    init(analytics: AnalyticsService) {
        self.analytics = analytics
    }

    func recordCommand(_ intent: any VoiceIntent, response: VoiceResponse) {
        analytics.track("voice_command_executed", properties: [
            "tool": Self.toolName(from: intent),
            "action": Self.actionName(from: intent),
            "response_type": responseType(from: response),
            "source": "voice_commands",
        ])
    }

    /// Cloud assistant turn outcome — no transcript or generated text.
    func recordCloudAssistantTurn(outcome: String, inputTokens: Int?, outputTokens: Int?) {
        var properties: [String: Any] = [
            "outcome": outcome,
            "source": "voice_commands",
        ]
        if let inputTokens { properties["input_tokens"] = inputTokens }
        if let outputTokens { properties["output_tokens"] = outputTokens }
        analytics.track("cloud_assistant_turn", properties: properties)
    }


    /// Emits the pipeline-level `voice_recognition_latency` event defined by
    /// recognition-pipeline.md "Production Recognition Latency Metrics".
    /// No audio, transcript text, raw confidence scores, or device identifiers
    /// are ever included.
    func recordPipelineLatency(metric: PerformanceMetrics) {
        var properties: [String: Any] = [
            "total_transcript_to_intent_ms": metric.totalTranscriptToIntentMs,
            "backend": metric.backend,
            "fallback": metric.isFallback,
            "model_release": metric.modelRelease,
        ]
        if let pipeline = metric.pipeline {
            properties["segment_to_wake_ms"] = pipeline.segmentToWakeMs
            properties["wake_to_asr_start_ms"] = pipeline.wakeToAsrStartMs
            properties["asr_ms"] = pipeline.asrMs
            if let wakeToAsr = pipeline.wakeToAsrResultMs {
                properties["wake_to_asr_result_ms"] = wakeToAsr
            }
            properties["segment_to_asr_result_ms"] = pipeline.segmentToAsrResultMs
            properties["wake_result"] = pipeline.wakeResult
            if let margin = pipeline.confidenceMargin {
                properties["confidence_margin"] = margin
            }
            properties["listening_mode"] = pipeline.listeningMode
            properties["asr_backend"] = pipeline.backend
        }
        if let outcome = metric.classificationOutcome {
            properties["classification_outcome"] = outcome
        }
        if let release = metric.routerModelRelease {
            properties["router_model_release"] = release
        }
        if let tokens = metric.transcriptTokenCount {
            properties["transcript_token_count"] = tokens
        }
        if let language = metric.backendLanguage {
            properties["backend_language"] = language
        }
        if let code = metric.errorCode {
            properties["error_code"] = code
        }
        analytics.track("voice_recognition_latency", properties: properties)
    }

    static func toolName(from intent: any VoiceIntent) -> String {
        switch intent {
        case is PlaybackIntent: return "playback"
        case is EffectsIntent: return "effects"
        case is VolumeIntent: return "volume"
        case is SleepIntent: return "sleep"
        case is ChapterIntent: return "chapter"
        case is BookmarkIntent: return "bookmark"
        case is QueueIntent: return "queue"
        case is PlaybackQueryIntent: return "playback_query"
        case is StatsQueryIntent: return "stats_query"
        case is CloudRouteIntent: return "cloud_route"
        default: return "unknown"
        }
    }

    /// Every local intent's canonical action name. The names are the SCHEMA's own enum values
    /// (`ToolSchema`), so a name here is the same token the model was asked to produce and the
    /// server already understands — never a spelling invented in this file.
    ///
    /// Only the action is named. Every associated value (a delta, a title, an episode, a query
    /// period) is argument CONTENT and must never reach a name field, which is why the data-carrying
    /// cases below are named by their enum case and nothing else.
    static func actionName(from intent: any VoiceIntent) -> String {
        switch intent {
        case let p as PlaybackIntent:
            switch p {
            case .pause: return "pause"
            case .resume: return "resume"
            case .seekRelative: return "seek_relative"
            case .seekTo: return "seek_to"
            case .nextEpisode: return "next_episode"
            }
        case let e as EffectsIntent:
            switch e {
            case .setSpeed: return "set_speed"
            case .adjustSpeed: return "adjust_speed"
            case .setTrimMode: return "set_trim_mode"
            case .setVolumeBoost: return "set_volume_boost"
            case .query: return "query"
            }
        case let v as VolumeIntent:
            switch v {
            case .setVolume: return "set_volume"
            case .adjustVolume: return "adjust_volume"
            case .query: return "query"
            }
        case let s as SleepIntent:
            switch s {
            case .set: return "set"
            case .endOfEpisode: return "end_of_episode"
            case .endOfChapter: return "end_of_chapter"
            case .addTime: return "add_time"
            case .cancel: return "cancel"
            case .query: return "query"
            }
        case let c as ChapterIntent:
            switch c {
            case .next: return "next"
            case .previous: return "previous"
            case .byIndex: return "by_index"
            case .byTitle: return "by_title"
            case .openLink: return "open_link"
            case .queryList: return "query_list"
            case .queryCurrent: return "query_current"
            case .queryCount: return "query_count"
            case .queryNext: return "query_next"
            }
        case let b as BookmarkIntent:
            switch b {
            case .add: return "add"
            case .rename: return "rename"
            case .play: return "play"
            case .delete: return "delete"
            case .deleteAll: return "delete_all"
            case .queryList: return "query_list"
            case .queryCount: return "query_count"
            case .queryNearby: return "query_nearby"
            }
        case let q as QueueIntent:
            switch q {
            case .addTop: return "add_top"
            case .addBottom: return "add_bottom"
            case .remove: return "remove"
            case .moveToTop: return "move_to_top"
            case .moveToBottom: return "move_to_bottom"
            case .clear: return "clear"
            case .removeByPodcast: return "remove_by_podcast"
            case .sort: return "sort"
            case .queryContents: return "query_contents"
            case .queryNext: return "query_next"
            case .queryLength: return "query_length"
            case .queryIsQueued: return "query_is_queued"
            }
        case let pq as PlaybackQueryIntent:
            switch pq {
            case .whatsPlaying: return "whats_playing"
            case .position: return "position"
            case .timeRemaining: return "time_remaining"
            case .episodeDuration: return "episode_duration"
            case .publishDate: return "publish_date"
            case .episodeDescription: return "episode_description"
            case .downloadStatus: return "download_status"
            case .episodeTitle: return "episode_title"
            }
        case let sq as StatsQueryIntent:
            switch sq {
            case .listeningTime: return "listening_time"
            case .topPodcasts: return "top_podcasts"
            case .episodesFinished: return "episodes_finished"
            case .listeningStreak: return "listening_streak"
            case .subscriptionCount: return "subscription_count"
            case .unplayedTotal: return "unplayed_total"
            case .downloadStats: return "download_stats"
            case .newEpisodes: return "new_episodes"
            case .timeSinceLastListen: return "time_since_last_listen"
            }
        case is CloudRouteIntent:
            // The tool's own single action. NOT `request`: that member is "the complete user
            // utterance or resolved multi-turn request", and a name carries no content.
            return "route"
        default: return "unknown"
        }
    }

    /// The contribution record's `predicted_intent`.
    ///
    /// The spec fixes the vocabulary as `<tool>.<action>` — the tool and action names exactly as the
    /// Voice Intents tool schema spells them — and `cloud_route` ALONE for a cloud route. It is
    /// derived from the intent's type and action, never from argument values or request text. The
    /// server adds the `route-` prefix to the folder name, so it must not be part of this value.
    ///
    /// Nil for a turn that was not routed at all: `no_match` is not a routed intent, so the member is
    /// left absent rather than carrying a name for something that never happened.
    static func predictedIntentName(from intent: any VoiceIntent) -> String? {
        if intent is CloudRouteIntent { return "cloud_route" }
        let action = actionName(from: intent)
        guard action != unknownName else { return nil }
        return "\(toolName(from: intent)).\(action)"
    }

    /// The name for an intent this mapping does not recognise. Reported as a tool/action fact but
    /// never used to build `predicted_intent`: a name nobody agreed on is worse than an absent one.
    static let unknownName = "unknown"

    /// The contribution record's `predicted_tool`: the tool half of the same mapping.
    static func predictedToolName(from intent: any VoiceIntent) -> String? {
        if intent is CloudRouteIntent { return "cloud_route" }
        let tool = toolName(from: intent)
        return tool == unknownName ? nil : tool
    }

    private func responseType(from response: VoiceResponse) -> String {
        switch response {
        case .silent: return "silent"
        case .earcon: return "earcon"
        case .spoken: return "spoken"
        case .combined: return "combined"
        }
    }
}

// MARK: - Analytics Service Protocol

protocol AnalyticsService {
    func track(_ event: String, properties: [String: Any])
}
