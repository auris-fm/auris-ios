import PocketCastsUtils

/// Result of classifying a user transcript.
enum ClassificationResult {
    case intent(any VoiceIntent)
    case dialogControl(DialogControlAction)
    case none
}

class FunctionGemmaIntentRouter {
    private var sessionPool = FunctionGemmaSessionPool()
    private let mapper = ToolCallMapper()
    private let promptBuilder = PromptBuilder()

    func ensureReady() async -> Result<Void, Error> {
        await sessionPool.prepare()
        if sessionPool.acquire() != nil {
            return .success(())
        }
        return .failure(RouterError.modelNotReady)
    }

    func classify(transcript: String, pendingDialog: PendingVoiceDialog? = nil) -> ClassificationResult {
        guard let session = sessionPool.acquire() else {
            FileLog.shared.addMessage("[VoiceControl/Intent] No session available for: \"\(transcript)\"")
            return .none
        }
        defer { sessionPool.scheduleReplacement() }

        let userTurn = promptBuilder.buildUserTurn(transcript: transcript, pendingDialog: pendingDialog)
        guard let output = try? session.generate(userTurn) else {
            FileLog.shared.addMessage("[VoiceControl/Intent] Generation failed for: \"\(transcript)\"")
            return .none
        }
        guard let toolCall = FunctionGemmaParser.parse(output) else {
            FileLog.shared.addMessage("[VoiceControl/Intent] Parse failed — raw output: \(output.prefix(200))")
            return .none
        }
        FileLog.shared.addMessage("[VoiceControl/Intent] Classified: \(toolCall.name)(\(toolCall.arguments))")

        // dialog_control is consumed by VoiceDialogManager, not dispatched to executor
        if toolCall.name == "dialog_control" {
            if let action = mapDialogControl(toolCall.arguments) {
                return .dialogControl(action)
            }
            FileLog.shared.addMessage("[VoiceControl/Intent] dialog_control parse failed")
            return .none
        }

        if let intent = mapper.map(toolCall) {
            return .intent(intent)
        }
        return .none
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
