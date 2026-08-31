import XCTest
@testable import podcasts

final class VoiceAnalyticsTests: XCTestCase {

    func test_commandExecuted_recordsVoiceSource() {
        let mockAnalytics = MockAnalyticsService()
        let voiceAnalytics = VoiceAnalytics(analytics: mockAnalytics)
        voiceAnalytics.recordCommand(PlaybackIntent.pause, response: .earcon(.success))
        XCTAssertEqual(mockAnalytics.lastEvent, "voice_command_executed")
        XCTAssertEqual(mockAnalytics.lastProperties?["source"] as? String, "voice_commands")
        XCTAssertEqual(mockAnalytics.lastProperties?["tool"] as? String, "playback")
        XCTAssertEqual(mockAnalytics.lastProperties?["action"] as? String, "pause")
    }

    func test_recordSilentResponse_typeIsSilent() {
        let mockAnalytics = MockAnalyticsService()
        let voiceAnalytics = VoiceAnalytics(analytics: mockAnalytics)
        voiceAnalytics.recordCommand(PlaybackIntent.resume, response: .silent)
        XCTAssertEqual(mockAnalytics.lastProperties?["response_type"] as? String, "silent")
    }

    func test_recordLatency_tracksAllFields() {
        let mockAnalytics = MockAnalyticsService()
        let voiceAnalytics = VoiceAnalytics(analytics: mockAnalytics)
        let metrics = PerformanceMetrics(
            totalTranscriptToIntentMs: 250.0,
            prefillMs: 10.0,
            timeToFirstTokenMs: 50.0,
            decodeMs: 180.0,
            parseResolveMs: 10.0,
            backend: "ANE",
            isFallback: false,
            modelRelease: "v1.0",
            inputTokens: 100,
            outputTokens: 5
        )
        voiceAnalytics.recordLatency(metric: metrics)
        XCTAssertEqual(mockAnalytics.lastEvent, "voice_router_latency")
        XCTAssertEqual(mockAnalytics.lastProperties?["backend"] as? String, "ANE")
        XCTAssertEqual(mockAnalytics.lastProperties?["total_ms"] as? Double, 250.0)
    }

    func test_recordPipelineLatency_tracksStageTimingAndOutcome() {
        let mockAnalytics = MockAnalyticsService()
        let voiceAnalytics = VoiceAnalytics(analytics: mockAnalytics)
        let timing = PipelineStageTiming(
            segmentToWakeMs: 80,
            wakeToAsrStartMs: 10,
            asrMs: 700,
            wakeToAsrResultMs: 720,
            segmentToAsrResultMs: 790,
            wakeResult: "detected",
            confidenceMargin: "high",
            listeningMode: "wake_word",
            backend: "whisper"
        )
        let metrics = PerformanceMetrics(
            totalTranscriptToIntentMs: 200,
            prefillMs: 0,
            timeToFirstTokenMs: 0,
            decodeMs: 0,
            parseResolveMs: 0,
            backend: "ANE",
            isFallback: false,
            modelRelease: "v1",
            inputTokens: 100,
            outputTokens: 5,
            pipeline: timing,
            classificationOutcome: "intent",
            routerModelRelease: "2026-07-31",
            transcriptTokenCount: 8,
            backendLanguage: "en"
        )
        voiceAnalytics.recordPipelineLatency(metric: metrics)
        XCTAssertEqual(mockAnalytics.lastEvent, "voice_recognition_latency")
        XCTAssertEqual(mockAnalytics.lastProperties?["segment_to_wake_ms"] as? Double, 80)
        XCTAssertEqual(mockAnalytics.lastProperties?["wake_to_asr_result_ms"] as? Double, 720)
        XCTAssertEqual(mockAnalytics.lastProperties?["classification_outcome"] as? String, "intent")
        XCTAssertEqual(mockAnalytics.lastProperties?["listening_mode"] as? String, "wake_word")
    }
}

private final class MockAnalyticsService: AnalyticsService {
    var lastEvent: String?
    var lastProperties: [String: Any]?

    func track(_ event: String, properties: [String: Any]) {
        lastEvent = event
        lastProperties = properties
    }
}
