struct PendingVoiceDialog {
    let targetTool: String
    let targetAction: String
    var filledSlots: [String: String] = [:]
    let missingSlots: Set<String>
    let requiredSlots: Set<String>
    let lastQuestion: String

    var isComplete: Bool { missingSlots.isEmpty }
}

enum DialogControlAction {
    case begin(targetTool: String, targetAction: String)
    case provideSlot(targetTool: String, targetAction: String, slot: String, value: String)
    case confirm
    case deny
    case cancel
    case newCommand(value: String)
}

struct PendingConfirmation {
    let tool: String
    let action: String
}
