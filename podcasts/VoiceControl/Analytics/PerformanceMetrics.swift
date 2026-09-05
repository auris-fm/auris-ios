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

    /// Wake/ASR stage timings from the recognition pipeline, when the detector ran.
    var pipeline: PipelineStageTiming?
    /// Router engagement outcome: intent, dialog_control, no_intent (+ failedStage/reason).
    var classificationOutcome: String?
    var routerModelRelease: String?
    var transcriptTokenCount: Int?
    var backendLanguage: String?
    var errorCode: String?
}
