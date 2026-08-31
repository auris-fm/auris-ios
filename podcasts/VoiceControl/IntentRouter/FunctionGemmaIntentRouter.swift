import Foundation
import PocketCastsUtils

/// Result of classifying a user transcript.
enum ClassificationResult {
    case intent(any VoiceIntent)
    case dialogControl(DialogControlAction)
    case none
}

/// Engagement/latency observation for one classification request.
/// `outcome` is one of: `intent`, `dialog_control`, `no_match`, `parse_failure`,
/// `router_not_ready`.
struct RouterClassificationMetrics {
    let totalMs: Double
    let outcome: String
    let modelRelease: String?
}

class FunctionGemmaIntentRouter {
    private let sessionPool: FunctionGemmaSessionPool
    private let mapper = ToolCallMapper()

    /// Called after every `classify` so engagement is observable even when the
    /// router cannot engage (functiongemma-performance.md "Instrumentation").
    var onMetrics: ((RouterClassificationMetrics) -> Void)?

    var isReady: Bool {
        sessionPool.acquire() != nil
    }

    init(sessionPool: FunctionGemmaSessionPool = FunctionGemmaSessionPool()) {
        self.sessionPool = sessionPool
    }

    func ensureReady() async -> Result<Void, Error> {
        await sessionPool.prepare()
        if sessionPool.acquire() != nil {
            return .success(())
        }
        return .failure(RouterError.modelNotReady)
    }

    func classify(transcript: String, pendingDialog: PendingVoiceDialog? = nil) -> ClassificationResult {
        let start = CACurrentMediaTime()
        guard let session = sessionPool.acquire() else {
            FileLog.shared.addMessage("[VoiceControl/Intent] No session available for: \"\(transcript)\"")
            reportMetrics(start: start, outcome: "router_not_ready")
            return .none
        }
        defer { sessionPool.scheduleReplacement() }

        // Pending-dialog history is supplied by the dialog manager; it is not yet
        // accumulated (tracked in the FunctionGemma latency plan), so requests
        // currently render as single-turn prompts.
        _ = pendingDialog
        let userTurn = PromptBuilder.buildUserTurn(transcript: transcript)
        guard let output = try? session.generate(userTurn) else {
            FileLog.shared.addMessage("[VoiceControl/Intent] Generation failed for: \"\(transcript)\"")
            reportMetrics(start: start, outcome: "parse_failure")
            return .none
        }
        guard let toolCall = FunctionGemmaParser.parse(output) else {
            FileLog.shared.addMessage("[VoiceControl/Intent] Parse failed — raw output: \(output.prefix(200))")
            reportMetrics(start: start, outcome: "parse_failure")
            return .none
        }
        FileLog.shared.addMessage("[VoiceControl/Intent] Classified: \(toolCall.name)(\(toolCall.arguments))")

        if toolCall.name == "dialog_control" {
            if let action = mapDialogControl(toolCall.arguments) {
                reportMetrics(start: start, outcome: "dialog_control")
                return .dialogControl(action)
            }
            FileLog.shared.addMessage("[VoiceControl/Intent] dialog_control parse failed")
            reportMetrics(start: start, outcome: "parse_failure")
            return .none
        }

        if toolCall.name == "no_match" {
            reportMetrics(start: start, outcome: "no_match")
            return .none
        }

        if let intent = mapper.map(toolCall) {
            reportMetrics(start: start, outcome: "intent")
            return .intent(intent)
        }
        reportMetrics(start: start, outcome: "parse_failure")
        return .none
    }

    private func reportMetrics(start: CFTimeInterval, outcome: String) {
        let totalMs = (CACurrentMediaTime() - start) * 1000
        onMetrics?(RouterClassificationMetrics(totalMs: totalMs, outcome: outcome, modelRelease: nil))
    }

    // MARK: - Dialog Control Mapping

    private func mapDialogControl(_ args: [String: Any]) -> DialogControlAction? {
        guard let action = args["action"] as? String else { return nil }
        switch action {
        case "begin":
            guard let tool = args["target_tool"] as? String,
                  let actionName = args["target_action"] as? String else { return nil }
            return .begin(targetTool: tool, targetAction: actionName)
        case "provide_slot":
            guard let tool = args["target_tool"] as? String,
                  let actionName = args["target_action"] as? String,
                  let slot = args["slot"] as? String,
                  let value = args["value"] as? String else { return nil }
            return .provideSlot(targetTool: tool, targetAction: actionName, slot: slot, value: value)
        case "confirm": return .confirm
        case "deny": return .deny
        case "cancel": return .cancel
        case "new_command":
            guard let value = args["value"] as? String else { return nil }
            return .newCommand(value: value)
        default: return nil
        }
    }

    enum RouterError: Error {
        case modelNotReady
    }
}
