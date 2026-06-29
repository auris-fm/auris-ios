class VoiceDialogManager {
    private(set) var pendingDialog: PendingVoiceDialog?
    private var pendingAction: PendingConfirmation?

    struct Result {
        let intent: (any VoiceIntent)?
        let question: String?
    }

    func handle(_ action: DialogControlAction) -> Result {
        switch action {
        case .begin(let tool, let actionName):
            return beginDialog(tool: tool, actionName: actionName)
        case .provideSlot(let tool, let actionName, let slot, let value):
            return fillSlot(tool: tool, actionName: actionName, slot: slot, value: value)
        case .confirm:
            return confirm()
        case .deny:
            return deny()
        case .cancel:
            return cancel()
        case .newCommand(let value):
            return cancelAndReprocess(value)
        }
    }

    private func beginDialog(tool: String, actionName: String) -> Result {
        let required = requiredSlots(for: tool, action: actionName)
        let question = generateQuestion(tool: tool, action: actionName, missing: required)
        pendingDialog = PendingVoiceDialog(
            targetTool: tool,
            targetAction: actionName,
            missingSlots: required,
            requiredSlots: required,
            lastQuestion: question
        )
        return Result(intent: nil, question: question)
    }

    private func fillSlot(tool: String, actionName: String, slot: String, value: String) -> Result {
        guard var dialog = pendingDialog,
              dialog.targetTool == tool,
              dialog.targetAction == actionName
        else { return Result(intent: nil, question: nil) }

        dialog.filledSlots[slot] = value
        let remaining = dialog.requiredSlots.subtracting(dialog.filledSlots.keys)

        if remaining.isEmpty {
            pendingDialog = nil
            let intent = buildIntent(tool: tool, action: actionName, slots: dialog.filledSlots)
            return Result(intent: intent, question: nil)
        } else {
            var updatedDialog = dialog
            updatedDialog.filledSlots = dialog.filledSlots
            pendingDialog = updatedDialog
            let question = generateQuestion(tool: tool, action: actionName, missing: remaining)
            return Result(intent: nil, question: question)
        }
    }

    private func confirm() -> Result {
        guard let action = pendingAction else { return Result(intent: nil, question: nil) }
        pendingAction = nil
        let intent = buildIntent(tool: action.tool, action: action.action, slots: [:])
        return Result(intent: intent, question: nil)
    }

    private func deny() -> Result {
        pendingAction = nil
        return Result(intent: nil, question: nil)
    }

    private func cancel() -> Result {
        pendingDialog = nil
        pendingAction = nil
        return Result(intent: nil, question: nil)
    }

    private func cancelAndReprocess(_ value: String) -> Result {
        pendingDialog = nil
        pendingAction = nil
        // Signal caller to re-process the new value as a fresh transcript
        return Result(intent: nil, question: value)
    }

    // MARK: - Slot Requirements

    private func requiredSlots(for tool: String, action: String) -> Set<String> {
        switch (tool, action) {
        case ("bookmark", "rename"): return ["ref", "title"]
        case ("bookmark", "play"): return ["ref"]
        case ("bookmark", "delete"): return ["ref"]
        case ("queue", "add_top"): return ["episode"]
        case ("queue", "add_bottom"): return ["episode"]
        case ("queue", "remove"): return ["episode"]
        case ("sleep", "set"): return ["minutes"]
        default: return []
        }
    }

    private func generateQuestion(tool: String, action: String, missing: Set<String>) -> String {
        switch (tool, missing.first ?? "") {
        case ("bookmark", "ref"): return "Which bookmark number?"
        case ("bookmark", "title"): return "What should the new title be?"
        case ("queue", "episode"): return "Which episode?"
        case ("sleep", "minutes"): return "For how many minutes?"
        default: return "What \(missing.first ?? "value")?"
        }
    }

    private func buildIntent(tool: String, action: String, slots: [String: String]) -> (any VoiceIntent)? {
        switch tool {
        case "bookmark":
            if action == "rename", let ref = slots["ref"], let title = slots["title"] {
                return BookmarkIntent.rename(ref: ref, title: title)
            }
            if action == "play", let ref = slots["ref"] { return BookmarkIntent.play(ref: ref) }
            if action == "delete", let ref = slots["ref"] { return BookmarkIntent.delete(ref: ref) }
        case "queue":
            if let episode = slots["episode"] {
                switch action {
                case "add_top": return QueueIntent.addTop(episode: episode)
                case "add_bottom": return QueueIntent.addBottom(episode: episode)
                case "remove": return QueueIntent.remove(episode: episode)
                default: break
                }
            }
        case "sleep":
            if action == "set", let minutesStr = slots["minutes"], let minutes = Int(minutesStr) {
                return SleepIntent.set(minutes: minutes)
            }
        default: break
        }
        return nil
    }
}
