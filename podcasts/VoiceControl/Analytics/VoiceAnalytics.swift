import Foundation

class VoiceAnalytics {
    private let analytics: AnalyticsService

    init(analytics: AnalyticsService) {
        self.analytics = analytics
    }

    func recordCommand(_ intent: any VoiceIntent, response: VoiceResponse) {
        analytics.track("voice_command_executed", properties: [
            "tool": toolName(from: intent),
            "action": actionName(from: intent),
            "response_type": responseType(from: response),
            "source": "voice_commands",
        ])
    }

    func recordLatency(metric: PerformanceMetrics) {
        analytics.track("voice_router_latency", properties: [
            "total_ms": metric.totalTranscriptToIntentMs,
            "prefill_ms": metric.prefillMs,
            "ttft_ms": metric.timeToFirstTokenMs,
            "decode_ms": metric.decodeMs,
            "backend": metric.backend,
            "fallback": metric.isFallback,
            "model_release": metric.modelRelease,
        ])
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

    private func toolName(from intent: any VoiceIntent) -> String {
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

    private func actionName(from intent: any VoiceIntent) -> String {
        switch intent {
        case let p as PlaybackIntent:
            switch p { case .pause: return "pause"; case .resume: return "resume"; case .seekRelative: return "seek_relative"; case .seekTo: return "seek_to"; case .nextEpisode: return "next_episode" }
        default: return "unknown"
        }
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
