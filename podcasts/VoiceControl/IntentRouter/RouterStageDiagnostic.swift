import Foundation

/// One bounded, privacy-safe diagnostic per routing request.
/// Never includes transcripts, generated text, raw exception messages, or slot values.
struct RouterStageDiagnostic: Equatable {
    let modelRelease: String?
    let quant: String?
    let inputFormat: String?
    let sourceLanguage: String?
    let translationKind: String
    let classifierLabel: String?
    let finalOutcome: String
    let failedStage: String?
    let reason: String?
    let totalLatencyMs: Double

    /// Compatibility alias used by pipeline latency analytics.
    var outcome: String { finalOutcome }
    var totalMs: Double { totalLatencyMs }

    static let outcomeIntent = "intent"
    static let outcomeDialogControl = "dialog_control"
    static let outcomeNoIntent = "no_intent"

    static let stageBlank = "blank"
    static let stageNotReady = "not_ready"
    static let stageTokenize = "tokenize"
    static let stageClassify = "classify"
    static let stageNoMatch = "no_match"
    static let stageGenerate = "generate"
    static let stageParseRepair = "parse_repair"
    static let stageMapperDialog = "mapper_dialog"
    static let stageException = "exception"
    static let stageUnsupportedFormat = "unsupported_format"

    static let reasonBlankTranscript = "blank_transcript"
    static let reasonModelNotLoaded = "model_not_loaded"
    static let reasonTokenizeFailed = "tokenize_failed"
    static let reasonClassifyFailed = "classify_failed"
    static let reasonNoMatch = "no_match"
    static let reasonGenerateFailed = "generate_failed"
    static let reasonParseOrRepairFailed = "parse_or_repair_failed"
    static let reasonMapperOrDialogFailed = "mapper_or_dialog_failed"
    static let reasonInferenceException = "inference_exception"
    static let reasonUnsupportedInputFormat = "unsupported_input_format"
}

/// Legacy name kept for call sites that still refer to metrics.
typealias RouterClassificationMetrics = RouterStageDiagnostic
