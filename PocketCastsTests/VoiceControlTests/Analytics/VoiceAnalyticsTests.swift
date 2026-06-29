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
}

private final class MockAnalyticsService: AnalyticsService {
    var lastEvent: String?
    var lastProperties: [String: Any]?

    func track(_ event: String, properties: [String: Any]) {
        lastEvent = event
        lastProperties = properties
    }
}
