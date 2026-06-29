import Foundation

struct PerformanceMetrics {
    let totalTranscriptToIntentMs: Double
    let prefillMs: Double
    let timeToFirstTokenMs: Double
    let decodeMs: Double
    let parseResolveMs: Double
    let backend: String
    let isFallback: Bool
    let modelRelease: String
    let inputTokens: Int
    let outputTokens: Int
}
